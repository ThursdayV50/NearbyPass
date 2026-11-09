// Diagnostics.swift — 一键导出诊断日志，方便用户快速提 issue
//
// 报告内容：环境、配置摘要、设备表、最近日志。
// 密码等敏感串在 Log 写入时就已打码（registerSecret/scrub），报告只拼装
// 已打码的日志行；不读 secret.bin，不输出任何凭证。
import AppKit
import UniformTypeIdentifiers

enum Diagnostics {

    // MARK: - 报告

    /// 汇总一份可直接贴进 issue 的纯文本诊断报告
    static func buildReport() -> String {
        let s = Settings.shared
        let p = PresenceMonitor.shared
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = ""

        out += "=== NearbyPass 诊断报告 ===\n"
        out += "导出时间: \(fmt.string(from: Date()))\n"
        out += "App: \(Updater.currentVersion) (\(machineModel()))\n"
        out += "系统: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"

        let bt: String
        switch p.bluetoothState {
        case .poweredOn:    bt = "正常"
        case .poweredOff:   bt = "已关闭"
        case .unauthorized: bt = "未授权"
        case .unsupported:  bt = "不支持"
        default:            bt = "状态 \(p.bluetoothState.rawValue)"
        }
        out += "蓝牙: \(bt)\n"
        out += "在场状态: \(p.presence.rawValue)"
        if let rssi = p.bestTrustedRSSI() { out += "（最强信任设备 \(rssi) dBm）" }
        out += "\n"
        out += "辅助功能: \(AX.isTrusted ? "已授权" : "未授权")\n"
        out += "登录密码: \(KeychainStore.shared.hasPassword() ? "已设置" : "未设置")\n"
        out += "阈值: 解锁 \(s.unlockThreshold) dBm / 锁屏 \(s.lockThreshold) dBm\n"
        out += "行为: 自动填密=\(onoff(s.authFillEnabled)) 自动解锁=\(onoff(s.autoUnlockEnabled)) " +
               "自动锁屏=\(onoff(s.autoLockEnabled)) 冷却=\(Int(s.authCooldown))s " +
               "延迟=\(Int(s.autoLockDelay))s 暂停=\(onoff(s.paused))\n"
        out += "只看随身设备: \(onoff(s.wearableOnly))\n"

        out += "\n=== 设备（★主设备 ✓已勾选）===\n"
        let devices = p.allDevices()
        if devices.isEmpty {
            out += "（还没扫到任何设备）\n"
        }
        for d in devices {
            let star = s.primaryDeviceID == d.id ? "★" : " "
            let check = s.isTrusted(d.id) ? "✓" : " "
            let age = Int(Date().timeIntervalSince(d.lastSeen))
            out += "\(star)\(check) \(p.displayName(d.id))  [\(p.kind(d.id).badge)]  " +
                   "raw=\(d.rawRSSI) ema=\(Int(d.emaRSSI.rounded()))dBm  \(age)s前\n"
        }

        out += "\n=== 最近日志（敏感串已打码）===\n"
        // 优先读落盘日志：内容比内存环形缓冲更全（含重启前的记录）
        var logLines = Log.shared.fileTailLines(500)
        if logLines.isEmpty {
            logLines = Log.shared.snapshot(500).map(\.line)
        }
        if logLines.isEmpty {
            out += "（日志为空）\n"
        }
        for line in logLines { out += line + "\n" }

        return out
    }

    // MARK: - 导出 + 提 issue 流

    /// 弹保存面板导出诊断报告；成功后引导用户去 GitHub 提 issue
    static func export() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { export() }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "导出诊断日志"
        panel.message = "把设备列表和最近日志写成一个 txt，提 Issue 时拖进输入框即可"
        panel.nameFieldStringValue = "NearbyPass-诊断-\(fileStamp()).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try buildReport().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Dialogs.info("导出失败", error.localizedDescription)
            return
        }
        Log.info("诊断日志已导出: \(url.lastPathComponent)")

        let a = NSAlert()
        a.messageText = "诊断日志已导出"
        a.informativeText = "\(url.path)\n\n提 Issue 时把这个文件拖进输入框或粘贴内容即可。"
        a.addButton(withTitle: "去提 Issue")
        a.addButton(withTitle: "好")
        if a.runModal() == .alertFirstButtonReturn {
            openNewIssue()
        }
    }

    /// 打开预填好模板的 GitHub 新 issue 页
    static func openNewIssue() {
        NSWorkspace.shared.open(newIssueURL())
    }

    /// 新 issue 地址：标题和正文模板都预填好，用户只补现象
    static func newIssueURL() -> URL {
        let body = """
        **环境**（设置 →「导出诊断日志」，把生成的 txt 拖到这里或粘贴内容）
        - macOS 版本：
        - App 版本：

        **问题描述**


        **复现步骤**
        1.
        2.

        **期望行为**

        """
        var c = URLComponents(string: "https://github.com/ThursdayV50/NearbyPass/issues/new")!
        c.queryItems = [
            URLQueryItem(name: "title", value: "[问题] "),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url!
    }

    // MARK: - 小工具

    private static func onoff(_ v: Bool) -> String { v ? "开" : "关" }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    private static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "未知机型" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
