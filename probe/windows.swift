// P0-2 探针：窗口枚举（找 SecurityAgent / loginwindow 的锁屏和授权窗口）
// 用法:
//   windows           只看可疑窗口（SecurityAgent、loginwindow 等 + layer>=100）
//   windows --all     列出全部窗口
//   windows --grep X  过滤 owner 名称包含 X 的窗口
import Foundation
import CoreGraphics

let args = CommandLine.arguments
let wantAll = args.contains("--all")
var grep: String? = nil
if let i = args.firstIndex(of: "--grep"), i + 1 < args.count {
    grep = args[i + 1]
}

// 不加 optionOnScreenOnly 才能看到离屏/隐藏窗口（锁屏前的 loginwindow 就是 -2147483625 层 0x0）
let opts: CGWindowListOption = wantAll ? [.excludeDesktopElements]
                                      : [.excludeDesktopElements, .optionOnScreenOnly]

guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("CGWindowListCopyWindowInfo 返回 nil（可能无屏幕录制权限）")
    exit(1)
}

// 我们也扫一次全量，用来找离屏窗口
let all = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

print("屏幕可见窗口数 = \(list.count)，全部窗口数 = \(all.count)")

let suspects: Set<String> = [
    "SecurityAgent", "loginwindow", "LoginUICore", "CoreServicesUIAgent",
    "universalAccessAuthWarn", "authd", "authorizationhost",
    "ControlCenter", "NotificationCenter", "ScreensharingAgent",
    "UserNotificationCenter", "WindowServer"
]

func fmt(_ w: [String: Any]) -> String {
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = (b["X"] as? NSNumber)?.doubleValue ?? 0
    let y = (b["Y"] as? NSNumber)?.doubleValue ?? 0
    let wd = (b["Width"] as? NSNumber)?.doubleValue ?? 0
    let ht = (b["Height"] as? NSNumber)?.doubleValue ?? 0
    let name = w[kCGWindowName as String] as? String ?? "-"
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    let wid = w[kCGWindowNumber as String] as? Int ?? -1
    return "\(owner.padding(toLength: 22, withPad: " ", startingAt: 0)) pid=\(pid) win=\(wid) layer=\(layer) bounds=\(Int(wd))x\(Int(ht)) @ (\(Int(x)),\(Int(y))) onscreen=\(onscreen ? "Y" : "N") alpha=\(String(format: "%.2f", alpha)) name=\(name)"
}

print("\n-- 可疑窗口（含离屏）--")
var shown = 0
for w in all {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    var hit = suspects.contains(owner) || layer >= 100 || layer < 0
    if let g = grep { hit = owner.localizedCaseInsensitiveContains(g) }
    if hit {
        print(fmt(w))
        shown += 1
    }
}
if shown == 0 { print("（未找到）") }

if wantAll {
    print("\n-- 全部窗口 --")
    for w in all { print(fmt(w)) }
}
