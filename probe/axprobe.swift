// AX 探测：打印某个进程的辅助功能树（含跨用户进程）
// 用法: axprobe <pid> [--depth 4] [--attrs]
import Foundation
import ApplicationServices

let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
guard args.count >= 2, let pid = pid_t(args[1]) else {
    print("用法: axprobe <pid> [--depth N] [--attrs]")
    exit(1)
}

var maxDepth = 4
if let i = CommandLine.arguments.firstIndex(of: "--depth"),
   i + 1 < CommandLine.arguments.count,
   let v = Int(CommandLine.arguments[i + 1]) {
    maxDepth = v
}
let showAttrs = CommandLine.arguments.contains("--attrs")

print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
print("目标 pid = \(pid)")

let app = AXUIElementCreateApplication(pid)

var names: CFArray?
let nerr = AXUIElementCopyAttributeNames(app, &names)
if nerr == .success, let arr = names as? [String] {
    print("应用属性数 = \(arr.count)")
    if showAttrs { print("  \(arr.joined(separator: ", "))") }
} else {
    print("AXUIElementCopyAttributeNames 失败 err=\(nerr.rawValue)")
}

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
    if let s = v as? String { return "\"\(s)\"" }
    if let n = v as? NSNumber { return "\(n)" }
    return "<\(type(of: v))>"
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}

var visited = 0

func walk(_ el: AXUIElement, depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    var role: CFTypeRef?
    let rerr = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    let roleStr = (role as? String) ?? "<?>"
    let sub = str(el, kAXSubroleAttribute as String) ?? "-"
    let title = str(el, kAXTitleAttribute as String) ?? "-"
    let value = str(el, kAXValueAttribute as String) ?? "-"
    let desc = str(el, kAXDescriptionAttribute as String) ?? "-"

    var detail = "\(pad)[\(roleStr)] sub=\(sub) title=\(title) desc=\(desc) value=\(value)"
    if depth == 0 {
        detail = "\(pad)[\(roleStr) err=\(rerr.rawValue)] sub=\(sub) title=\(title)"
    }
    print(detail)
    visited += 1
    if visited > 500 { print("\(pad)… 超过 500 个节点，停止"); return }
    if depth >= maxDepth { return }

    let kids = children(el)
    if kids.isEmpty {
        // 某些容器用 AXWindows / AXRows 而不是 AXChildren
        let alts: [String] = [kAXWindowsAttribute, kAXRowsAttribute, "AXContents"]
        for alt in alts {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, alt as CFString, &v) == .success,
               let arr = v as? [AXUIElement], !arr.isEmpty {
                print("\(pad)  ↳ \(alt) 有 \(arr.count) 个子元素")
                for k in arr { walk(k, depth: depth + 1) }
                return
            }
        }
    }
    for k in kids { walk(k, depth: depth + 1) }
}

walk(app, depth: 0)
print("\n共访问 \(visited) 个节点")
