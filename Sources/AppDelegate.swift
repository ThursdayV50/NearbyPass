// AppDelegate.swift — 装配与菜单栏
//
// 菜单只构建一次，之后只改标题与勾选状态。
// （每秒重建 NSMenu 会产生大量临时对象，是本进程内存的主要来源之一。）
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?
    private var activityToken: NSObjectProtocol?

    // 动态菜单项
    private var presenceItem: NSMenuItem!
    private var sessionItem: NSMenuItem!
    private var rssiItem: NSMenuItem!
    private var fillItem: NSMenuItem!
    private var unlockItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var installItem: NSMenuItem!

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("NearbyPass 启动 v1.0")
        Settings.shared.migrateAutoAliasesIfNeeded()
        // 锁屏 / 屏保时别被 App Nap 降频，否则蓝牙采样和定时器会被拖慢甚至停摆
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "锁屏后仍需持续采样蓝牙信号以判断人是否在附近")
        Log.info("辅助功能权限: \(AX.isTrusted ? "已授权" : "未授权")；密码: \(KeychainStore.shared.hasPassword() ? "已保存" : "未设置")")

        buildMenu()

        if let pw = KeychainStore.shared.load() {
            Log.shared.registerSecret(pw)
        }

        PresenceMonitor.shared.onUpdate = { [weak self] in
            self?.refreshStatus()
        }
        PresenceMonitor.shared.onPresenceChange = { [weak self] state in
            LockReasonTracker.shared.onPresenceChange(state)
            self?.refreshStatus()
        }

        SessionMonitor.shared.onChange = { [weak self] _ in
            self?.refreshStatus()
        }
        SessionMonitor.shared.onLock = {
            LockReasonTracker.shared.evaluateOnLock(
                nowPresence: PresenceMonitor.shared.presence
            )
            AutoUnlockHandler.shared.onSessionLocked()
        }
        SessionMonitor.shared.start()

        AutoLockHandler.shared.start()
        AutoUnlockHandler.shared.start()
        AuthDialogHandler.shared.start()

        // 每秒刷新（只改文字，不重建菜单）
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t

        refreshStatus()

        if !AX.isTrusted {
            Log.warn("辅助功能未授权 —— 三个功能都无法工作，弹出系统引导")
            AX.promptTrust()
        }

        let forceSettings = CommandLine.arguments.contains("--settings")
        let forceTutorial = CommandLine.arguments.contains("--tutorial")
        let firstRun = !Settings.shared.hasCompletedOnboard

        if forceTutorial || firstRun {
            Log.info(forceTutorial ? "命令行要求看教程" : "第一次启动，展示教程")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                TutorialWindow.shared.show()
            }
        } else if forceSettings || (!Settings.shared.isConfigured && !UserDefaults.standard.bool(forKey: "noAutoOpen")) {
            Log.info(forceSettings ? "命令行要求打开设置" : "尚未配置信任设备，打开设置引导")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                SettingsWindow.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionMonitor.shared.stop()
        Log.info("NearbyPass 退出")
    }

    // MARK: - 菜单

    private func makeItem(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil { i.target = self }
        return i
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "●"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()

        presenceItem = makeItem("状态：● 未知", nil)
        presenceItem.isEnabled = false
        menu.addItem(presenceItem)

        sessionItem = makeItem("会话：未知", nil)
        sessionItem.isEnabled = false
        menu.addItem(sessionItem)

        rssiItem = makeItem("信号：—", nil)
        rssiItem.isEnabled = false
        menu.addItem(rssiItem)

        menu.addItem(.separator())

        fillItem = makeItem("授权弹窗自动填密码", #selector(toggleAuthFill))
        menu.addItem(fillItem)

        unlockItem = makeItem("锁屏自动解锁", #selector(toggleAutoUnlock))
        menu.addItem(unlockItem)

        lockItem = makeItem("远离自动锁屏", #selector(toggleAutoLock))
        menu.addItem(lockItem)

        menu.addItem(.separator())

        pauseItem = makeItem("暂停全部", #selector(togglePaused))
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        menu.addItem(makeItem("设置…", #selector(openSettings), ","))
        menu.addItem(makeItem("权限自检…", #selector(showDiagnostics)))
        menu.addItem(makeItem("检查更新…", #selector(checkUpdate)))
        menu.addItem(makeItem("查看日志", #selector(openLog)))

        installItem = makeItem("安装到「应用程序」", #selector(installToApplications))
        menu.addItem(installItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("退出 NearbyPass", #selector(quit), "q"))

        statusItem.menu = menu
    }

    private var isInstalled: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/NearbyPass.app"
    }

    private func refreshStatus() {
        let p = PresenceMonitor.shared
        let s = Settings.shared

        var title = p.presence.symbol
        if s.paused {
            title = "‖"
        } else if let r = p.bestTrustedRSSI() {
            title += " \(r)"
        }
        if statusItem.button?.title != title {
            statusItem.button?.title = title
        }

        presenceItem.title = "状态：\(p.presence.symbol) \(p.presence.rawValue)"
        sessionItem.title = "会话：\(SessionMonitor.shared.state.rawValue)"
        if let r = p.bestTrustedRSSI() {
            rssiItem.title = "信号：\(r) dBm（解锁 ≥\(s.unlockThreshold) / 锁屏 ≤\(s.lockThreshold)）"
        } else if s.isConfigured {
            rssiItem.title = "信号：无（信任设备当前无广播）"
        } else {
            rssiItem.title = "信号：尚未选择信任设备"
        }

        fillItem.state = s.authFillEnabled ? .on : .off
        unlockItem.state = s.autoUnlockEnabled ? .on : .off
        lockItem.state = s.autoLockEnabled ? .on : .off
        pauseItem.title = s.paused ? "恢复运行" : "暂停全部"
        installItem.isHidden = isInstalled
    }

    // MARK: - 动作

    @objc private func toggleAuthFill() {
        Settings.shared.authFillEnabled.toggle()
        Log.info("授权弹窗自动填密码 → \(Settings.shared.authFillEnabled ? "开" : "关")")
        refreshStatus()
    }

    @objc private func toggleAutoUnlock() {
        Settings.shared.autoUnlockEnabled.toggle()
        Log.info("锁屏自动解锁 → \(Settings.shared.autoUnlockEnabled ? "开" : "关")")
        refreshStatus()
    }

    @objc private func toggleAutoLock() {
        Settings.shared.autoLockEnabled.toggle()
        Log.info("远离自动锁屏 → \(Settings.shared.autoLockEnabled ? "开" : "关")")
        refreshStatus()
    }

    @objc private func togglePaused() {
        Settings.shared.paused.toggle()
        Log.info("全局暂停 → \(Settings.shared.paused ? "是" : "否")")
        refreshStatus()
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
    }

    @objc private func installToApplications() {
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications/NearbyPass.app")
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            Log.info("已安装到 /Applications/NearbyPass.app")
            Notifier.post(title: "NearbyPass", body: "已安装到「应用程序」")
            NSWorkspace.shared.activateFileViewerSelecting([dst])
            refreshStatus()
        } catch {
            Log.error("安装失败: \(error.localizedDescription)")
            Notifier.post(title: "安装失败", body: error.localizedDescription)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.shared.logFilePath))
    }

    @objc private func checkUpdate() {
        Updater.shared.checkInteractive()
    }

    @objc private func showDiagnostics() {
        let ax = AX.isTrusted ? "✅ 已授权" : "❌ 未授权"
        let bt: String
        switch PresenceMonitor.shared.bluetoothState {
        case .poweredOn: bt = "✅ 正常"
        case .poweredOff: bt = "❌ 已关闭"
        case .unauthorized: bt = "❌ 未授权"
        case .unsupported: bt = "❌ 不支持"
        default: bt = "⏳ \(PresenceMonitor.shared.bluetoothState.rawValue)"
        }
        let pw = KeychainStore.shared.hasPassword() ? "✅ 已保存" : "❌ 未设置"
        let cfg = Settings.shared.isConfigured ? "✅ 已配置" : "❌ 未配置"

        let alert = NSAlert()
        alert.messageText = "权限自检"
        alert.informativeText = """
        辅助功能：\(ax)
        蓝牙：\(bt)
        密码：\(pw)
        信任设备：\(cfg)

        辅助功能权限是三个功能的基础，未授权时无法合成键盘事件。
        """
        alert.addButton(withTitle: "好")
        if !AX.isTrusted {
            alert.addButton(withTitle: "去授权")
            if alert.runModal() == .alertSecondButtonReturn {
                AX.promptTrust()
            }
        } else {
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
