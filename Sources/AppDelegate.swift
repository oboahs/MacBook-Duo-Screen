import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let windowManager = DuoWindowManager()
    private let filter = LidMotionFilter()

    private var sensor: LidAngleSensor?
    private var sensorError: String?
    private var timer: Timer?
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    private var latestSample = LidMotionSample(angle: 0, velocity: 0)
    private var duoTriggered = false
    private var manualLayout = false
    private var lastLayoutUpdate: TimeInterval = 0
    private var lastLayoutDescription = ""

    private let duoEnabledKey = "duoEnabled"
    private let dynamicSplitKey = "dynamicSplit"
    private let enterAngleKey = "enterAngle"
    private let exitAngleKey = "exitAngle"
    private let welcomeShownKey = "welcomeShownV1"

    private var duoEnabled: Bool {
        get { defaults.bool(forKey: duoEnabledKey) }
        set { defaults.set(newValue, forKey: duoEnabledKey) }
    }

    private var dynamicSplit: Bool {
        get { defaults.object(forKey: dynamicSplitKey) == nil ? true : defaults.bool(forKey: dynamicSplitKey) }
        set { defaults.set(newValue, forKey: dynamicSplitKey) }
    }

    private var enterAngle: Double {
        get {
            let value = defaults.double(forKey: enterAngleKey)
            return value == 0 ? 100 : value
        }
        set { defaults.set(newValue, forKey: enterAngleKey) }
    }

    private var exitAngle: Double {
        get {
            let value = defaults.double(forKey: exitAngleKey)
            return value == 0 ? 108 : value
        }
        set { defaults.set(newValue, forKey: exitAngleKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        connectSensor()
        startPolling()

        if !defaults.bool(forKey: welcomeShownKey) {
            defaults.set(true, forKey: welcomeShownKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        windowManager.restore()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LAS …"
        statusItem.button?.toolTip = "MacBook Duo Screen"

        statusMenu = NSMenu(title: "MacBook Duo Screen")
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildMenu()
    }

    private func connectSensor() {
        do {
            sensor = try LidAngleSensor()
            sensorError = nil
            filter.reset()
            let raw = try sensor?.readAngle() ?? 0
            latestSample = filter.update(rawAngle: raw)
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
            self?.pollSensor()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func pollSensor() {
        guard let sensor = sensor else { return }

        do {
            let raw = try sensor.readAngle()
            latestSample = filter.update(rawAngle: raw)
            updateStatusTitle()
            evaluateDuoState()
        } catch {
            sensorError = error.localizedDescription
            self.sensor = nil
            statusItem.button?.title = "LAS !"
            if duoTriggered {
                exitDuo(reason: "传感器中断")
            }
        }
    }

    private func updateStatusTitle() {
        let angle = Int(round(latestSample.angle))
        let marker = duoTriggered || manualLayout ? "D" : ""
        statusItem.button?.title = "\(marker)\(angle)°"
        statusItem.button?.toolTip = "MacBook Duo Screen · \(String(format: "%.1f", latestSample.angle))° · \(latestSample.directionText)"
    }

    private func evaluateDuoState() {
        guard duoEnabled, !manualLayout else { return }

        if !duoTriggered && latestSample.angle <= enterAngle {
            enterDuo()
            return
        }

        if duoTriggered && latestSample.angle >= exitAngle {
            exitDuo(reason: "屏幕已打开")
            return
        }

        if duoTriggered && dynamicSplit {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLayoutUpdate >= 0.10 {
                windowManager.updateDuo(ratio: ratio(for: latestSample.angle))
                lastLayoutUpdate = now
            }
        }
    }

    private func enterDuo() {
        guard !duoTriggered else { return }

        if !windowManager.isAccessibilityTrusted() {
            _ = windowManager.requestAccessibilityPermission()
            lastLayoutDescription = "需要在系统设置中允许辅助功能权限"
            return
        }

        let split = dynamicSplit ? ratio(for: latestSample.angle) : 0.5
        guard let result = windowManager.beginDuo(ratio: split) else {
            lastLayoutDescription = "没有找到两个可移动窗口"
            return
        }

        duoTriggered = true
        lastLayoutUpdate = ProcessInfo.processInfo.systemUptime
        lastLayoutDescription = "\(result.leftApp) + \(result.rightApp)"
        updateStatusTitle()
    }

    private func exitDuo(reason: String) {
        windowManager.restore()
        duoTriggered = false
        manualLayout = false
        lastLayoutDescription = reason
        updateStatusTitle()
    }

    private func ratio(for angle: Double) -> CGFloat {
        let normalized = (angle - 65.0) / 35.0
        let clamped = min(max(normalized, 0.0), 1.0)
        return CGFloat(0.35 + clamped * 0.30)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        let sensorLine: String
        if let error = sensorError {
            sensorLine = "传感器：异常 · \(error)"
        } else if sensor != nil {
            sensorLine = "传感器：已连接 · \(String(format: "%.1f", latestSample.angle))° · \(latestSample.directionText)"
        } else {
            sensorLine = "传感器：正在等待"
        }
        addDisabledItem(sensorLine)

        let modeText: String
        if manualLayout {
            modeText = "布局：手动 Duo"
        } else if duoTriggered {
            modeText = "布局：Duo 已触发 · \(lastLayoutDescription)"
        } else if duoEnabled {
            modeText = "布局：自动待机（≤ \(Int(enterAngle))° 触发）"
        } else {
            modeText = "布局：关闭"
        }
        addDisabledItem(modeText)
        addDisabledItem("恢复阈值：≥ \(Int(exitAngle))°")
        statusMenu.addItem(.separator())

        let enableItem = NSMenuItem(title: "启用角度驱动 Duo 布局", action: #selector(toggleDuoEnabled(_:)), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = duoEnabled ? .on : .off
        statusMenu.addItem(enableItem)

        let dynamicItem = NSMenuItem(title: "用转轴角度控制左右比例", action: #selector(toggleDynamicSplit(_:)), keyEquivalent: "")
        dynamicItem.target = self
        dynamicItem.state = dynamicSplit ? .on : .off
        statusMenu.addItem(dynamicItem)

        let thresholdItem = NSMenuItem(title: "触发角度", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu(title: "触发角度")
        for value in [80, 90, 100, 110] {
            let item = NSMenuItem(title: "\(value)°", action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = Int(enterAngle) == value ? .on : .off
            thresholdMenu.addItem(item)
        }
        thresholdItem.submenu = thresholdMenu
        statusMenu.addItem(thresholdItem)

        statusMenu.addItem(.separator())

        let forceItem = NSMenuItem(title: "立即把最前面的两个窗口设为 50/50", action: #selector(forceDuo(_:)), keyEquivalent: "")
        forceItem.target = self
        statusMenu.addItem(forceItem)

        let restoreItem = NSMenuItem(title: "恢复窗口原位置", action: #selector(restoreWindows(_:)), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = windowManager.isManagingWindows
        statusMenu.addItem(restoreItem)

        statusMenu.addItem(.separator())

        let permissionTitle = windowManager.isAccessibilityTrusted() ? "辅助功能权限：已允许" : "辅助功能权限：需要允许…"
        let permissionItem = NSMenuItem(title: permissionTitle, action: #selector(openAccessibility(_:)), keyEquivalent: "")
        permissionItem.target = self
        statusMenu.addItem(permissionItem)

        let reconnectItem = NSMenuItem(title: "重新连接转轴传感器", action: #selector(reconnectSensor(_:)), keyEquivalent: "")
        reconnectItem.target = self
        statusMenu.addItem(reconnectItem)

        statusMenu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 MacBook Duo Screen", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        statusMenu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private func addDisabledItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        statusMenu.addItem(item)
    }

    @objc private func toggleDuoEnabled(_ sender: NSMenuItem) {
        duoEnabled.toggle()
        if !duoEnabled {
            exitDuo(reason: "Duo 已关闭")
        } else if !windowManager.isAccessibilityTrusted() {
            _ = windowManager.requestAccessibilityPermission()
        } else {
            evaluateDuoState()
        }
        rebuildMenu()
    }

    @objc private func toggleDynamicSplit(_ sender: NSMenuItem) {
        dynamicSplit.toggle()
        if duoTriggered && windowManager.isManagingWindows {
            let split = dynamicSplit ? ratio(for: latestSample.angle) : 0.5
            windowManager.updateDuo(ratio: split)
        }
        rebuildMenu()
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        enterAngle = Double(sender.tag)
        exitAngle = Double(sender.tag + 8)
        if duoTriggered && latestSample.angle >= exitAngle {
            exitDuo(reason: "阈值已调整")
        } else {
            evaluateDuoState()
        }
        rebuildMenu()
    }

    @objc private func forceDuo(_ sender: NSMenuItem) {
        if !windowManager.isAccessibilityTrusted() {
            _ = windowManager.requestAccessibilityPermission()
            lastLayoutDescription = "请允许辅助功能权限后再点一次"
            rebuildMenu()
            return
        }

        if windowManager.isManagingWindows {
            windowManager.restore()
        }
        guard let result = windowManager.beginDuo(ratio: 0.5) else {
            lastLayoutDescription = "没有找到两个可移动窗口"
            rebuildMenu()
            return
        }
        manualLayout = true
        duoTriggered = false
        lastLayoutDescription = "\(result.leftApp) + \(result.rightApp)"
        updateStatusTitle()
        rebuildMenu()
    }

    @objc private func restoreWindows(_ sender: NSMenuItem) {
        exitDuo(reason: "已手动恢复")
        rebuildMenu()
    }

    @objc private func openAccessibility(_ sender: NSMenuItem) {
        if !windowManager.isAccessibilityTrusted() {
            _ = windowManager.requestAccessibilityPermission()
        }
        windowManager.openAccessibilitySettings()
    }

    @objc private func reconnectSensor(_ sender: NSMenuItem) {
        connectSensor()
        rebuildMenu()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        let model = currentMacModel()
        let alert = NSAlert()
        alert.messageText = "MacBook Duo Screen 1.0"
        alert.informativeText = "用 MacBook 的转轴角度驱动窗口布局。\n\n当前机器：\(model)\n传感器：\(sensor == nil ? "未连接" : "已连接")\n当前角度：\(String(format: "%.1f", latestSample.angle))°"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "MacBook Duo Screen 已启动"
        alert.informativeText = "转轴传感器已经进入后台监测，菜单栏会实时显示角度。\n\nDuo 布局默认关闭。开启后，屏幕合到 \(Int(enterAngle))° 以下时，程序会把最前面的两个应用窗口铺到内置屏幕；继续开合屏幕可以改变左右比例，重新打开到 \(Int(exitAngle))° 以上会自动恢复窗口原位置。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
