// AX 操作探针：读树 / 设密码框 / 按按钮
// 用法:
//   axfill --pid 1234 --dump
//   axfill --pid 1234 --secure zqx9          给第一个 AXSecureTextField 设值
//   axfill --pid 1234 --press 取消            按描述/标题匹配的按钮
//   axfill --pid 1234 --info                 打印关键元素（密码框/按钮）的坐标
import Foundation
import ApplicationServices

var args = CommandLine.arguments

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

guard let pidStr = value("--pid"), let pid = pid_t(pidStr) else {
    print("用法: axfill --pid <pid> [--dump | --secure <text> | --press <label> | --info]")
    exit(1)
}

let app = AXUIElementCreateApplication(pid)

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}
func strAttr(_ el: AXUIElement, _ name: String) -> String? {
    attr(el, name) as? String
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

/// 广度优先收集整棵树的所有元素
func allElements(_ root: AXUIElement, limit: Int = 4000) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue: [AXUIElement] = [root]
    while !queue.isEmpty && out.count < limit {
        let cur = queue.removeFirst()
        out.append(cur)
        queue.append(contentsOf: children(cur))
    }
    return out
}

let elements = allElements(app)
print("元素总数 = \(elements.count)")

if args.contains("--dump") {
    for el in elements {
        let role = strAttr(el, kAXRoleAttribute as String) ?? "?"
        let sub = strAttr(el, kAXSubroleAttribute as String) ?? "-"
        let title = strAttr(el, kAXTitleAttribute as String) ?? "-"
        let desc = strAttr(el, kAXDescriptionAttribute as String) ?? "-"
        let val = strAttr(el, kAXValueAttribute as String) ?? "-"
        print("[\(role)] sub=\(sub) title=\(title) desc=\(desc) value=\(val)")
    }
}

if args.contains("--info") {
    for el in elements {
        let role = strAttr(el, kAXRoleAttribute as String) ?? "?"
        let sub = strAttr(el, kAXSubroleAttribute as String) ?? "-"
        guard role == kAXTextFieldRole as String || role == kAXButtonRole as String else { continue }
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let raw = attr(el, kAXPositionAttribute as String), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgPoint, &pos)
        }
        if let raw = attr(el, kAXSizeAttribute as String), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgSize, &size)
        }
        let title = strAttr(el, kAXTitleAttribute as String) ?? "-"
        let desc = strAttr(el, kAXDescriptionAttribute as String) ?? "-"
        let focused = (attr(el, kAXFocusedAttribute as String) as? Bool) ?? false
        print("\(role) sub=\(sub) title=\(title) desc=\(desc) pos=(\(Int(pos.x)),\(Int(pos.y))) size=\(Int(size.width))x\(Int(size.height)) focused=\(focused)")
    }
}

// MARK: - 设密码框

if let text = value("--secure") {
    guard let field = elements.first(where: {
        strAttr($0, kAXSubroleAttribute as String) == "AXSecureTextField"
    }) else {
        print("未找到 AXSecureTextField")
        exit(2)
    }
    // 先聚焦
    let ferr = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("设焦点 err=\(ferr.rawValue)")
    usleep(80_000)

    let err = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
    print("AXUIElementSetAttributeValue(kAXValue) err=\(err.rawValue)")
    usleep(120_000)
    let readback = strAttr(field, kAXValueAttribute as String) ?? "<nil>"
    print("回读 value=\(readback.isEmpty ? "<空>" : readback)")

    if err != .success {
        // 退路：AXSelectedText 替换
        let err2 = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString)
        print("退路 AXUIElementSetAttributeValue(kAXSelectedText) err=\(err2.rawValue)")
    }
}

// MARK: - 按按钮

if let label = value("--press") {
    let buttons = elements.filter { strAttr($0, kAXRoleAttribute as String) == kAXButtonRole as String }
    print("按钮列表: \(buttons.map { (strAttr($0, kAXDescriptionAttribute as String) ?? strAttr($0, kAXTitleAttribute as String) ?? "?") })")
    guard let target = buttons.first(where: {
        let d = strAttr($0, kAXDescriptionAttribute as String) ?? ""
        let t = strAttr($0, kAXTitleAttribute as String) ?? ""
        return d == label || t == label
    }) else {
        print("未找到按钮: \(label)")
        exit(2)
    }
    let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
    print("AXPress err=\(err.rawValue)")
}
