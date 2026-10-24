import Foundation
import ServiceManagement

/// 登录项注册。
///
/// 菜单栏常驻工具如果不注册登录项，重启之后三个功能全是哑的——用户只会以为"这软件坏了"。
/// macOS 13 起用 SMAppService.mainApp，不需要写 LaunchAgent plist，也不需要辅助脚本。
/// 系统里的状态才是唯一真相，所以这里不另存一份布尔值，避免和系统设置不一致。
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 已注册但用户还没在「系统设置 › 通用 › 登录项」里放行
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "已启用"
        case .requiresApproval: return "待系统允许"
        case .notFound:         return "未找到 App"
        case .notRegistered:    return "未注册"
        @unknown default:       return "未知"
        }
    }

    /// 返回错误描述；nil 表示成功
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
