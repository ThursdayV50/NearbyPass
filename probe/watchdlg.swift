import Foundation
import CoreGraphics

// 持续 dump 所有高浮层窗口（layer >= 900），用于识别新的认证弹窗宿主
var last = ""
let deadline = Date().addingTimeInterval(Double(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 60 : 60))
while Date() < deadline {
    if let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        var rows: [String] = []
        for w in list {
            guard let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue, layer >= 900, layer < 100000 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            let on = (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            guard on else { continue }
            var b = CGRect.zero
            if let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d as CFDictionary) { b = r }
            rows.append("  \(owner) pid=\(pid) layer=\(layer) \(Int(b.width))x\(Int(b.height)) @ \(Int(b.origin.x)),\(Int(b.origin.y))")
        }
        let s = rows.joined(separator: "\n")
        if s != last { last = s; print("--- \(Date().description)\n\(s)"); fflush(stdout) }
    }
    usleep(300_000)
}
