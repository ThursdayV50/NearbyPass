// P0-5 探针：触发一个真实的系统授权密码弹窗（SecurityAgent）
// 每次用全新的自定义 right 名，绕过 Authorization Services 的 ~20 分钟凭证缓存。
//
// 用法:
//   authdialog                 触发并阻塞等待你操作（默认）
//   authdialog --wait 0        触发后立刻返回（不管结果）
//   authdialog --right NAME    指定 right 名（调试用，会命中缓存）
//
// 注意: 这个进程会一直运行到你在弹窗上点「取消」或输入密码为止。
//       点「取消」是安全的，不会改变任何系统设置。
import Foundation
import Security

let args = CommandLine.arguments

let rightName: String = {
    if let i = args.firstIndex(of: "--right"), i + 1 < args.count {
        return args[i + 1]
    }
    // 时间戳 + pid，保证唯一
    return "com.lcg.beprobe.\(Int(Date().timeIntervalSince1970)).\(getpid())"
}()

print("right = \(rightName)")
print("正在创建 AuthorizationRef …")

var authRef: AuthorizationRef?
var status = AuthorizationCreate(nil, nil, [], &authRef)
guard status == errAuthorizationSuccess, let auth = authRef else {
    print("AuthorizationCreate 失败 status=\(status)")
    exit(1)
}
print("AuthorizationRef 创建成功")

// right 名必须活到 AuthorizationCopyRights 返回，所以用 withCString 括住整个调用，
// 否则 Swift 可能提前释放临时缓冲区。
var item = AuthorizationItem(name: "", valueLength: 0, value: nil, flags: 0)
var rights = AuthorizationRights(count: 0, items: &item)
let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]

print("调用 AuthorizationCopyRights（应当弹出 SecurityAgent 密码框）…")
let t0 = Date()
status = rightName.withCString { cname -> OSStatus in
    item.name = cname
    rights = AuthorizationRights(count: 1, items: &item)
    return withUnsafePointer(to: &rights) { rightsPtr in
        AuthorizationCopyRights(auth, rightsPtr, nil, flags, nil)
    }
}
let dt = Date().timeIntervalSince(t0)

switch status {
case errAuthorizationSuccess:
    print("结果: 成功 (errAuthorizationSuccess) 耗时 \(String(format: "%.1f", dt))s")
    print("  → 你输入了正确密码，或命中了凭证缓存")
    print("  → 若要再次触发弹窗，请重新运行本工具（会生成新的 right 名）")
case errAuthorizationCanceled:
    print("结果: 已取消 (errAuthorizationCanceled) 耗时 \(String(format: "%.1f", dt))s")
case errAuthorizationDenied:
    print("结果: 被拒绝 (errAuthorizationDenied)")
default:
    print("结果: status=\(status) 耗时 \(String(format: "%.1f", dt))s")
}

AuthorizationFree(auth, [])
