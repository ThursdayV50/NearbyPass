// P0-4 探针：锁屏/解锁状态检测
// 用法: session           打印一次后进入监听
//       session --once    只打印一次
import Foundation
import CoreGraphics

func snapshot() -> (locked: Bool?, dict: [String: Any]) {
    let d = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    return (d["CGSSessionScreenIsLocked"] as? Bool, d)
}

func dump(_ tag: String) {
    let (locked, d) = snapshot()
    let onConsole = d["kCGSSessionOnConsoleKey"].map { "\($0)" } ?? "nil"
    let user = d["kCGSessionUserNameKey"].map { "\($0)" } ?? "nil"
    let loginDone = d["kCGSessionLoginDoneKey"].map { "\($0)" } ?? "nil"
    let allKeys = d.keys.sorted().joined(separator: ",")
    print("[\(tag)] ScreenIsLocked=\(locked.map { $0 ? "true" : "false" } ?? "<键不存在>") onConsole=\(onConsole) loginDone=\(loginDone) user=\(user)")
    print("        全部键: \(allKeys)")
}

dump("初始")

if CommandLine.arguments.contains("--once") {
    exit(0)
}

let center = DistributedNotificationCenter.default()
center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
    print(">>> 通知: com.apple.screenIsLocked")
    dump("锁屏事件")
}
center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
    print(">>> 通知: com.apple.screenIsUnlocked")
    dump("解锁事件")
}
// 这两个通知名在部分系统版本上会带上会话前缀，做一次宽松订阅
for n in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
          "com.apple.sessionDidLock", "com.apple.sessionDidUnlock"] {
    center.addObserver(forName: NSNotification.Name(n), object: nil, queue: nil) { note in
        print(">>> 宽泛命中: \(note.name.rawValue)")
    }
}

print("监听中（Ctrl+C 结束）。轮询 250ms，状态变化时打印。")
var last = snapshot().locked
let t = Timer(timeInterval: 0.25, repeats: true) { _ in
    let cur = snapshot().locked
    if cur != last {
        last = cur
        dump("轮询变化")
    }
}
RunLoop.main.add(t, forMode: .common)
RunLoop.main.run()
