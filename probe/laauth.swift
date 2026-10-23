import Foundation
import LocalAuthentication

// 触发一次 LAContext 认证，观察宿主窗口（用于确定 F1 需要支持哪些认证 UI 进程）
let ctx = LAContext()
ctx.localizedReason = "NearbyPass 测试：解锁系统设置"
ctx.localizedFallbackTitle = "使用密码"
var err: NSError?
let can = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
print("canEvaluatePolicy=\(can) err=\(err?.localizedDescription ?? "-")")
print("biometryType=\(ctx.biometryType.rawValue)")

ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "NearbyPass 测试：解锁系统设置") { ok, e in
    print("结果 ok=\(ok) err=\(e?.localizedDescription ?? "-")")
    exit(0)
}
RunLoop.main.run()
