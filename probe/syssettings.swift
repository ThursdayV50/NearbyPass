import Foundation
import Security

// 用 system.settings 这个真实 right 触发「修改你的系统设置」认证弹窗
let rightName = "system.settings"
var authRef: AuthorizationRef?
let st = AuthorizationCreate(nil, nil, [], &authRef)
guard st == errAuthorizationSuccess, let auth = authRef else {
    print("AuthorizationCreate 失败: \(st)"); exit(1)
}
var item = AuthorizationItem(name: "", valueLength: 0, value: nil, flags: 0)
var rights = AuthorizationRights(count: 0, items: &item)
let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
print("请求 right=\(rightName) …")
fflush(stdout)
rightName.withCString { cstr in
    item.name = cstr
    rights.count = 1
    let r = AuthorizationCopyRights(auth, &rights, nil, flags, nil)
    print("AuthorizationCopyRights 结果 = \(r)")
    fflush(stdout)
    exit(r == errAuthorizationSuccess ? 0 : 2)
}
