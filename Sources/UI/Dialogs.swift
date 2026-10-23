// Dialogs.swift — 原生弹窗类的小动作（SwiftUI 里沿用 NSAlert 更省事）

import AppKit

enum Dialogs {

    static func permissionCheck() {
        let ax = AX.isTrusted ? "已授权" : "未授权（三个功能都依赖它）"
        let bt: String
        switch PresenceMonitor.shared.bluetoothState {
        case .poweredOn:    bt = "正常"
        case .poweredOff:   bt = "已关闭"
        case .unauthorized: bt = "未授权"
        case .unsupported:  bt = "不支持"
        default:            bt = "状态 \(PresenceMonitor.shared.bluetoothState.rawValue)"
        }
        let pw = KeychainStore.shared.hasPassword() ? "已设置" : "未设置"
        let dev = Settings.shared.isConfigured
            ? "\(Settings.shared.trustedDeviceIDs.count) 个" : "未配置"

        let alert = NSAlert()
        alert.messageText = "权限自检"
        alert.informativeText = """
        辅助功能：\(ax)
        蓝牙：\(bt)
        密码：\(pw)
        信任设备：\(dev)
        """
        alert.addButton(withTitle: "好")
        if !AX.isTrusted {
            alert.addButton(withTitle: "去授权")
            if alert.runModal() == .alertSecondButtonReturn { AX.promptTrust() }
        } else {
            alert.runModal()
        }
    }

    static func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.shared.logFilePath))
    }
}

extension Dialogs {
    static func info(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "好")
        a.runModal()
    }
}
