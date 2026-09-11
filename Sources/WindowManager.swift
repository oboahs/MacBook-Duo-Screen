import AppKit
import ApplicationServices
import CoreFoundation
import Foundation
import Darwin

struct DuoLayoutResult {
    let leftApp: String
    let rightApp: String
}

final class DuoWindowManager {
    private struct ManagedWindow {
        let element: AXUIElement
        let originalPosition: CGPoint
        let originalSize: CGSize
        let appName: String
    }

    private var managedWindows: [ManagedWindow] = []
    private var lastAppliedRatio: CGFloat?

    var isManagingWindows: Bool { !managedWindows.isEmpty }

    func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func beginDuo(ratio: CGFloat) -> DuoLayoutResult? {
        guard isAccessibilityTrusted() else { return nil }

        if !managedWindows.isEmpty {
            restore()
        }

        let candidates = frontmostCandidateWindows(limit: 2)
        guard candidates.count >= 2 else { return nil }

        var captured: [ManagedWindow] = []
        for candidate in candidates.prefix(2) {
            guard let position = readPosition(candidate.element), let size = readSize(candidate.element) else {
                continue
            }
            captured.append(ManagedWindow(
                element: candidate.element,
                originalPosition: position,
                originalSize: size,
                appName: candidate.appName
            ))
        }

        guard captured.count == 2 else { return nil }
        managedWindows = captured
        lastAppliedRatio = nil
        applyLayout(ratio: ratio, force: true)

        return DuoLayoutResult(leftApp: captured[0].appName, rightApp: captured[1].appName)
    }

    func updateDuo(ratio: CGFloat) {
        guard managedWindows.count == 2 else { return }
        applyLayout(ratio: ratio, force: false)
    }

    func restore() {
        for window in managedWindows {
            setPosition(window.element, point: window.originalPosition)
            setSize(window.element, size: window.originalSize)
        }
        managedWindows.removeAll()
        lastAppliedRatio = nil
    }

    private func applyLayout(ratio rawRatio: CGFloat, force: Bool) {
        guard managedWindows.count == 2 else { return }

        let ratio = min(max(rawRatio, 0.30), 0.70)
        if !force, let previous = lastAppliedRatio, abs(previous - ratio) < 0.01 {
            return
        }

        guard let screen = preferredScreen() else { return }
        let visible = screen.visibleFrame
        let axFrame = convertToAXCoordinates(visible)

        let gap: CGFloat = 10
        let availableWidth = max(axFrame.width - gap, 200)
        let leftWidth = floor(availableWidth * ratio)
        let rightWidth = availableWidth - leftWidth

        let leftPosition = CGPoint(x: axFrame.minX, y: axFrame.minY)
        let leftSize = CGSize(width: leftWidth, height: axFrame.height)
        let rightPosition = CGPoint(x: axFrame.minX + leftWidth + gap, y: axFrame.minY)
        let rightSize = CGSize(width: rightWidth, height: axFrame.height)

        setPosition(managedWindows[0].element, point: leftPosition)
        setSize(managedWindows[0].element, size: leftSize)
        setPosition(managedWindows[1].element, point: rightPosition)
        setSize(managedWindows[1].element, size: rightSize)

        lastAppliedRatio = ratio
    }

    private func preferredScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(number.uint32Value)
                if CGDisplayIsBuiltin(displayID) != 0 {
                    return screen
                }
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func convertToAXCoordinates(_ rect: NSRect) -> CGRect {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryTop = primary?.frame.maxY ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private struct CandidateWindow {
        let element: AXUIElement
        let appName: String
    }

    private func frontmostCandidateWindows(limit: Int) -> [CandidateWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [CandidateWindow] = []
        var usedPIDs = Set<pid_t>()

        for info in rawList {
            guard result.count < limit else { break }
            guard let layerNumber = info[kCGWindowLayer as String] as? NSNumber, layerNumber.intValue == 0 else { continue }
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            guard pid != getpid(), !usedPIDs.contains(pid) else { continue }

            let appName = (info[kCGWindowOwnerName as String] as? String) ?? "未知应用"
            if appName == "Dock" || appName == "Window Server" || appName == "Control Center" {
                continue
            }

            if let window = firstMovableWindow(for: pid) {
                result.append(CandidateWindow(element: window, appName: appName))
                usedPIDs.insert(pid)
            }
        }

        if result.count < limit, let firstPID = usedPIDs.first {
            let additional = movableWindows(for: firstPID)
            for window in additional.dropFirst() where result.count < limit {
                result.append(CandidateWindow(element: window, appName: result.first?.appName ?? "未知应用"))
            }
        }

        return result
    }

    private func firstMovableWindow(for pid: pid_t) -> AXUIElement? {
        return movableWindows(for: pid).first
    }

    private func movableWindows(for pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }

        return windows.filter { window in
            if let minimized = boolAttribute(window, attribute: kAXMinimizedAttribute as CFString), minimized {
                return false
            }
            guard readPosition(window) != nil, readSize(window) != nil else { return false }
            return true
        }
    }

    private func boolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    /// Swift 6 no longer permits a conditional cast from CFTypeRef to AXValue because
    /// CoreFoundation reference types are bridged as always-castable at compile time.
    /// Validate the runtime CFTypeID first, then reinterpret the already-validated value.
    private func axValueAttribute(_ element: AXUIElement, attribute: CFString, expectedType: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue: AXValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == expectedType else {
            return nil
        }
        return axValue
    }

    private func readPosition(_ element: AXUIElement) -> CGPoint? {
        guard let axValue = axValueAttribute(
            element,
            attribute: kAXPositionAttribute as CFString,
            expectedType: .cgPoint
        ) else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func readSize(_ element: AXUIElement) -> CGSize? {
        guard let axValue = axValueAttribute(
            element,
            attribute: kAXSizeAttribute as CFString,
            expectedType: .cgSize
        ) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func setPosition(_ element: AXUIElement, point: CGPoint) {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ element: AXUIElement, size: CGSize) {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}
