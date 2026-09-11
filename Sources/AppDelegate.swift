import AppKit
import MetalKit
import ScreenCaptureKit
import Foundation

final class PerspectiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let capture = DesktopCapture()
    private let filter = LidMotionFilter()

    private var sensor: LidAngleSensor?
    private var sensorError: String?
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    private var renderer: PerspectiveRenderer?
    private var panel: PerspectiveOverlayPanel?
    private var metalView: MTKView?
    private var builtInDisplayID: CGDirectDisplayID?

    private var latestSample = LidMotionSample(angle: 0, velocity: 0)
    private var enabled = false
    private var captureReady = false
    private var overlayVisible = false
    private var startingCapture = false
    private var statusMessage = "待机"

    // The system menu bar is hidden only while the transformed overlay is visible.
    // Opening the lid back to the reference angle restores it automatically.
    private var menuBarHiddenForEffect = false
    private var menuBarWasVisible = true

    private let referenceKey = "perspectiveReferenceAngle"
    private let strengthKey = "perspectiveStrength"
    private let softnessKey = "perspectiveSoftness"
    private let perspectiveKey = "perspectiveDepth"
    private let welcomeKey = "welcomeShownV2"

    private var referenceAngle: Double {
        get {
            let saved = defaults.double(forKey: referenceKey)
            return saved > 5 ? saved : 110
        }
        set { defaults.set(newValue, forKey: referenceKey) }
    }

    private var strength: Double {
        get {
            let saved = defaults.double(forKey: strengthKey)
            return saved > 0 ? saved : 1.0
        }
        set { defaults.set(newValue, forKey: strengthKey) }
    }

    private var softness: Double {
        get {
            if defaults.object(forKey: softnessKey) == nil { return 0.25 }
            return defaults.double(forKey: softnessKey)
        }
        set { defaults.set(newValue, forKey: softnessKey) }
    }

    private var perspectiveDepth: Double {
        get {
            if defaults.object(forKey: perspectiveKey) == nil { return 0.75 }
            return defaults.double(forKey: perspectiveKey)
        }
        set { defaults.set(newValue, forKey: perspectiveKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupCaptureCallbacks()
        connectSensor()
        startPolling()

        if !defaults.bool(forKey: welcomeKey) {
            defaults.set(true, forKey: welcomeKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        capture.stop()
        hideOverlay()
        restoreMenuBarIfNeeded()
        panel?.close()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LAS …"
        statusItem.button?.toolTip = "MacBook Duo Screen · Perspective Lock"

        statusMenu = NSMenu(title: "MacBook Duo Screen")
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildMenu()
    }

    private func setupCaptureCallbacks() {
        capture.onFirstFrame = { [weak self] in
            guard let self, self.enabled else { return }
            self.captureReady = true
            self.statusMessage = "桌面捕获已连接"
            self.updateOverlayVisibility()
            self.rebuildMenu()
        }
        capture.onUnavailable = { [weak self] in
            guard let self else { return }
            self.captureReady = false
            self.hideOverlay()
            self.statusMessage = "桌面画面暂不可用"
            self.rebuildMenu()
        }
        capture.onFailure = { [weak self] reason in
            guard let self else { return }
            self.captureReady = false
            self.enabled = false
            self.hideOverlay()
            self.statusMessage = "捕获中断：\(reason)"
            self.rebuildMenu()
        }
    }

    private func connectSensor() {
        do {
            sensor = try LidAngleSensor()
            sensorError = nil
            filter.reset()
            let raw = try sensor?.readAngle() ?? 0
            latestSample = filter.update(rawAngle: raw)
            if defaults.object(forKey: referenceKey) == nil {
                referenceAngle = latestSample.angle
            }
            updateStatusTitle()
        } catch {
            sensor = nil
            sensorError = error.localizedDescription
            statusItem.button?.title = "LAS !"
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSensor() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func pollSensor() {
        guard let sensor else { return }
        do {
            latestSample = filter.update(rawAngle: try sensor.readAngle())
            updateStatusTitle()
            if enabled { updateOverlayVisibility() }
        } catch {
            sensorError = error.localizedDescription
            self.sensor = nil
            statusItem.button?.title = "LAS !"
            disableEffect(message: "转轴传感器中断")
        }
    }

    private func compensationAmount() -> Double {
        let clear = min(150.0, max(60.0, referenceAngle))
        guard clear > 6 else { return 0 }
        let t = min(1.0, max(0.0, (clear - latestSample.angle) / (clear - 5.0)))
        let eased = t * t * (3.0 - 2.0 * t)
        return min(1.0, max(0.0, eased * strength))
    }

    private func updateOverlayVisibility() {
        guard enabled, captureReady else {
            hideOverlay()
            return
        }

        if compensationAmount() > 0.0005 {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    private func updateStatusTitle() {
        let angle = Int(round(latestSample.angle))
        let prefix = enabled ? "P" : ""
        statusItem.button?.title = "\(prefix)\(angle)°"
        statusItem.button?.toolTip = "当前 \(String(format: "%.1f", latestSample.angle))° · 基准 \(String(format: "%.1f", referenceAngle))° · \(latestSample.directionText)"
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let id = CGDirectDisplayID(number.uint32Value)
            return CGDisplayIsBuiltin(id) != 0 && CGDisplayIsActive(id) != 0
        }
    }

    private func prepareOverlay() throws -> (screen: NSScreen, displayID: CGDirectDisplayID) {
        guard let screen = builtInScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.message("没有找到可用的 MacBook 内置屏幕。")
        }
        let displayID = CGDirectDisplayID(number.uint32Value)

        if panel != nil && (builtInDisplayID != displayID || panel?.frame != screen.frame) {
            hideOverlay()
            panel?.close()
            panel = nil
            metalView = nil
            renderer = nil
        }
        builtInDisplayID = displayID

        if panel == nil {
            let renderer = try PerspectiveRenderer()
            renderer.frames = capture.frames
            renderer.parameters = { [weak self] in
                guard let self else { return PerspectiveUniforms() }
                return PerspectiveUniforms(
                    amount: Float(self.compensationAmount()),
                    perspective: Float(self.perspectiveDepth),
                    softness: Float(self.softness),
                    dimming: 0.15,
                    size: SIMD2<Float>(1, 1),
                    padding: SIMD2<Float>(0, 0)
                )
            }
            renderer.onFailure = { [weak self] reason in
                self?.disableEffect(message: "Metal 渲染失败：\(reason)")
            }

            let panel = PerspectiveOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.level = .floating
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.sharingType = .none
            panel.setFrame(screen.frame, display: false)

            let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: renderer.device)
            view.autoresizingMask = [.width, .height]
            view.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: screen.frame.size)
            renderer.configure(view, fps: 60)
            panel.contentView = view

            self.renderer = renderer
            self.panel = panel
            self.metalView = view
        }

        return (screen, displayID)
    }

    private func hideMenuBarForEffect() {
        guard !menuBarHiddenForEffect else { return }
        menuBarWasVisible = NSMenu.menuBarVisible()
        if menuBarWasVisible {
            NSMenu.setMenuBarVisible(false)
        }
        menuBarHiddenForEffect = true
    }

    private func restoreMenuBarIfNeeded() {
        guard menuBarHiddenForEffect else { return }
        if menuBarWasVisible {
            NSMenu.setMenuBarVisible(true)
        }
        menuBarHiddenForEffect = false
    }

    private func showOverlay() {
        guard let panel else { return }
        hideMenuBarForEffect()
        guard !overlayVisible else { return }
        panel.orderFrontRegardless()
        overlayVisible = true
    }

    private func hideOverlay() {
        if overlayVisible {
            panel?.orderOut(nil)
            overlayVisible = false
        }
        restoreMenuBarIfNeeded()
    }

    private func enableEffect() {
        guard !enabled, !startingCapture else { return }
        guard sensor != nil else {
            statusMessage = "转轴传感器不可用"
            rebuildMenu()
            return
        }

        referenceAngle = latestSample.angle
        startingCapture = true
        statusMessage = "正在连接屏幕捕获…"
        rebuildMenu()

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.startingCapture = false
                self.rebuildMenu()
            }
            do {
                let prepared = try self.prepareOverlay()
                try await self.capture.verifyAccess()

                let scale = prepared.screen.backingScaleFactor
                let nativeWidth = Int(prepared.screen.frame.width * scale)
                let nativeHeight = Int(prepared.screen.frame.height * scale)
                let maxWidth = 2560
                let captureScale = min(1.0, Double(maxWidth) / Double(max(nativeWidth, 1)))
                let width = Int(Double(nativeWidth) * captureScale)
                let height = Int(Double(nativeHeight) * captureScale)

                try await self.capture.start(
                    displayID: prepared.displayID,
                    width: width,
                    height: height,
                    fps: 30
                )
                self.enabled = true
                self.statusMessage = "视觉锁定已启用"
                self.updateStatusTitle()
            } catch {
                self.enabled = false
                self.captureReady = false
                self.hideOverlay()
                self.statusMessage = "无法启用：\(error.localizedDescription)"
            }
        }
    }

    private func disableEffect(message: String = "视觉锁定已关闭") {
        enabled = false
        captureReady = false
        hideOverlay()
        capture.stop()
        statusMessage = message
        updateStatusTitle()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        if let sensorError {
            addDisabledItem("LAS：异常 · \(sensorError)")
        } else if sensor != nil {
            addDisabledItem("LAS：\(String(format: "%.1f", latestSample.angle))° · \(latestSample.directionText)")
        } else {
            addDisabledItem("LAS：未连接")
        }
        addDisabledItem("视觉基准：\(String(format: "%.1f", referenceAngle))°")
        addDisabledItem("补偿量：\(Int(round(compensationAmount() * 100)))%")
        addDisabledItem("状态：\(statusMessage)")
        statusMenu.addItem(.separator())

        let toggle = NSMenuItem(
            title: enabled ? "关闭视觉锁定" : (startingCapture ? "正在启用…" : "启用视觉锁定"),
            action: #selector(toggleEffect(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = !startingCapture
        toggle.state = enabled ? .on : .off
        statusMenu.addItem(toggle)

        let calibrate = NSMenuItem(title: "将当前角度设为视觉基准", action: #selector(calibrate(_:)), keyEquivalent: "")
        calibrate.target = self
        calibrate.isEnabled = sensor != nil
        statusMenu.addItem(calibrate)

        let strengthItem = NSMenuItem(title: "补偿强度", action: nil, keyEquivalent: "")
        let strengthMenu = NSMenu(title: "补偿强度")
        for (label, value, tag) in [("70%", 0.7, 70), ("85%", 0.85, 85), ("100%", 1.0, 100), ("115%", 1.15, 115)] {
            let item = NSMenuItem(title: label, action: #selector(selectStrength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = value
            item.state = abs(strength - value) < 0.001 ? .on : .off
            strengthMenu.addItem(item)
        }
        strengthItem.submenu = strengthMenu
        statusMenu.addItem(strengthItem)

        let perspectiveItem = NSMenuItem(title: "透视补偿", action: nil, keyEquivalent: "")
        let perspectiveMenu = NSMenu(title: "透视补偿")
        for (label, value, tag) in [("柔和", 0.45, 45), ("标准", 0.75, 75), ("强", 1.0, 100)] {
            let item = NSMenuItem(title: label, action: #selector(selectPerspective(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = value
            item.state = abs(perspectiveDepth - value) < 0.001 ? .on : .off
            perspectiveMenu.addItem(item)
        }
        perspectiveItem.submenu = perspectiveMenu
        statusMenu.addItem(perspectiveItem)

        let softnessItem = NSMenuItem(title: "纵向模糊", action: nil, keyEquivalent: "")
        let softnessMenu = NSMenu(title: "纵向模糊")
        for (label, value, tag) in [("关闭", 0.0, 0), ("低", 0.15, 15), ("标准", 0.25, 25), ("高", 0.45, 45)] {
            let item = NSMenuItem(title: label, action: #selector(selectSoftness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = value
            item.state = abs(softness - value) < 0.001 ? .on : .off
            softnessMenu.addItem(item)
        }
        softnessItem.submenu = softnessMenu
        statusMenu.addItem(softnessItem)

        statusMenu.addItem(.separator())

        let privacy = NSMenuItem(title: "打开屏幕录制权限设置…", action: #selector(openScreenRecording(_:)), keyEquivalent: "")
        privacy.target = self
        statusMenu.addItem(privacy)

        let reconnect = NSMenuItem(title: "重新连接转轴传感器", action: #selector(reconnectSensor(_:)), keyEquivalent: "")
        reconnect.target = self
        statusMenu.addItem(reconnect)

        statusMenu.addItem(.separator())
        let about = NSMenuItem(title: "关于 / 使用说明", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        statusMenu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        statusMenu.addItem(item)
    }

    @objc private func toggleEffect(_ sender: NSMenuItem) {
        if enabled { disableEffect() } else { enableEffect() }
        rebuildMenu()
    }

    @objc private func calibrate(_ sender: NSMenuItem) {
        referenceAngle = latestSample.angle
        statusMessage = "已将 \(String(format: "%.1f", referenceAngle))° 设为视觉基准"
        updateOverlayVisibility()
        updateStatusTitle()
        rebuildMenu()
    }

    @objc private func selectStrength(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { strength = value }
        rebuildMenu()
    }

    @objc private func selectPerspective(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { perspectiveDepth = value }
        rebuildMenu()
    }

    @objc private func selectSoftness(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { softness = value }
        rebuildMenu()
    }

    @objc private func openScreenRecording(_ sender: NSMenuItem) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reconnectSensor(_ sender: NSMenuItem) {
        connectSensor()
        rebuildMenu()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "MacBook Duo Screen · Perspective Lock"
        alert.informativeText = "程序实时捕获内置屏幕，并根据 LAS 转轴角度对整块桌面做反向透视补偿。透视动画出现时系统菜单栏会暂时隐藏；打开回视觉基准角度后自动恢复。\n\n模糊从屏幕顶部开始，随着合盖逐渐向下扩散，并用模糊桌面替代透视图像周围原来的纯黑区域。覆盖层不会拦截鼠标，但大角度补偿时视觉位置与真实点击位置暂时不会完全一致。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "Perspective Lock 已就绪"
        alert.informativeText = "点击菜单栏角度 →“启用视觉锁定”。程序会把启用时的屏幕角度作为视觉基准；向下合屏时，桌面内容围绕底部转轴做反向透视补偿。\n\n透视动画开始后菜单栏会自动隐藏；合盖越深，模糊会从顶部逐渐向下扩散。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
