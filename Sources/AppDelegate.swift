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

    private let referenceKey = "perspectiveReferenceAngle"
    private let strengthKey = "perspectiveStrength"
    private let blurKey = "gaussianBlurStrengthV3"
    private let perspectiveKey = "perspectiveDepth"
    private let welcomeKey = "welcomeShownV2"

    private var referenceAngle: Double {
        get {
            let saved = defaults.double(forKey: referenceKey)
            return saved > 5 ? saved : 110
        }
        set { defaults.set(newValue, forKey: referenceKey) }
    }

    /// 0.5...3.0. Unlike the old implementation this is not folded into the
    /// 0...1 lid progress, so values above 100% really increase geometry strength.
    private var strength: Double {
        get {
            let saved = defaults.double(forKey: strengthKey)
            return saved > 0 ? min(3.0, max(0.5, saved)) : 1.0
        }
        set { defaults.set(min(3.0, max(0.5, newValue)), forKey: strengthKey) }
    }

    /// 0...1. A new key intentionally resets the previous subtle blur setting.
    /// 60% maps to roughly 38 px Gaussian sigma at the capture resolution.
    private var blurStrength: Double {
        get {
            if defaults.object(forKey: blurKey) == nil { return 0.60 }
            return min(1.0, max(0.0, defaults.double(forKey: blurKey)))
        }
        set { defaults.set(min(1.0, max(0.0, newValue)), forKey: blurKey) }
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

    /// Pure 0...1 angle progress. Strength is intentionally applied only in the shader.
    private func compensationProgress() -> Double {
        let clear = min(150.0, max(60.0, referenceAngle))
        guard clear > 6 else { return 0 }
        let t = min(1.0, max(0.0, (clear - latestSample.angle) / (clear - 5.0)))
        return t * t * (3.0 - 2.0 * t)
    }

    private func updateOverlayVisibility() {
        guard enabled, captureReady else {
            hideOverlay()
            return
        }

        if compensationProgress() > 0.0005 {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    private func updateStatusTitle() {
        let angle = Int(round(latestSample.angle))
        let prefix = enabled ? "P" : ""
        statusItem.button?.title = "\(prefix)\(angle)°"
        statusItem.button?.toolTip = "当前 \(String(format: "%.1f", latestSample.angle))° · 基准 \(String(format: "%.1f", referenceAngle))° · 补偿 \(Int(round(strength * 100)))% · 高斯模糊 \(Int(round(blurStrength * 100)))%"
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
                    amount: Float(self.compensationProgress()),
                    perspective: Float(self.perspectiveDepth),
                    softness: Float(self.blurStrength),
                    dimming: 0.15,
                    size: SIMD2<Float>(1, 1),
                    padding: SIMD2<Float>(Float(self.strength), 0)
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
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
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

    private func showOverlay() {
        guard !overlayVisible, let panel else { return }
        panel.orderFrontRegardless()
        overlayVisible = true
    }

    private func hideOverlay() {
        guard overlayVisible else { return }
        panel?.orderOut(nil)
        overlayVisible = false
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
        addDisabledItem("合盖进度：\(Int(round(compensationProgress() * 100)))%")
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

        statusMenu.addItem(.separator())
        statusMenu.addItem(makeSliderItem(
            title: "补偿强度",
            value: strength * 100,
            minValue: 50,
            maxValue: 300,
            valueTag: 9101,
            action: #selector(compensationSliderChanged(_:))
        ))
        statusMenu.addItem(makeSliderItem(
            title: "高斯模糊",
            value: blurStrength * 100,
            minValue: 0,
            maxValue: 100,
            valueTag: 9102,
            action: #selector(blurSliderChanged(_:))
        ))

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

    private func makeSliderItem(
        title: String,
        value: Double,
        minValue: Double,
        maxValue: Double,
        valueTag: Int,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 292, height: 58))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.frame = NSRect(x: 14, y: 34, width: 170, height: 17)
        view.addSubview(titleLabel)

        let valueLabel = NSTextField(labelWithString: "\(Int(round(value)))%")
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.tag = valueTag
        valueLabel.frame = NSRect(x: 205, y: 34, width: 72, height: 17)
        view.addSubview(valueLabel)

        let slider = NSSlider(
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            target: self,
            action: action
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 6
        slider.allowsTickMarkValuesOnly = false
        slider.frame = NSRect(x: 12, y: 7, width: 266, height: 24)
        view.addSubview(slider)

        item.view = view
        return item
    }

    private func updateSliderLabel(_ slider: NSSlider, tag: Int) {
        guard let label = slider.superview?.viewWithTag(tag) as? NSTextField else { return }
        label.stringValue = "\(Int(round(slider.doubleValue)))%"
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

    @objc private func compensationSliderChanged(_ sender: NSSlider) {
        strength = sender.doubleValue / 100.0
        updateSliderLabel(sender, tag: 9101)
        updateStatusTitle()
    }

    @objc private func blurSliderChanged(_ sender: NSSlider) {
        blurStrength = sender.doubleValue / 100.0
        updateSliderLabel(sender, tag: 9102)
        updateStatusTitle()
    }

    @objc private func selectPerspective(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double { perspectiveDepth = value }
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
        alert.informativeText = "程序实时捕获内置屏幕，并根据 LAS 转轴角度对整块桌面做反向透视补偿。覆盖层位于系统菜单栏之上，因此菜单栏也会一起进入视觉效果。\n\n补偿强度可在 50%–300% 连续调节；高斯模糊使用 Metal Performance Shaders 的 GPU 高斯核，可在 0%–100% 连续调节。模糊从屏幕顶部开始，随着合盖逐渐向底部扩散。"
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
        alert.informativeText = "点击菜单栏角度 →“启用视觉锁定”。程序会把启用时的屏幕角度作为视觉基准；向下合屏时，桌面内容围绕底部转轴做反向透视补偿。\n\n现在可用滑块连续调整 50%–300% 补偿强度和 0%–100% GPU 高斯模糊强度。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
