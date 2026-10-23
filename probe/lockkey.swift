// P0-3 探针：锁屏命令可行性
// 用法:
//   lockkey                 只构造事件并打印（不触发）
//   lockkey --fire          用 CGEvent 模拟 Ctrl+Cmd+Q 真锁屏
//   lockkey --fire --delay 3  延迟 3 秒后触发（留手动准备时间）
//   lockkey --osascript     用 osascript 走 System Events 退路
//   lockkey --displaysleep  用 pmset displaysleepnow 退路
import Foundation
import CoreGraphics
import ApplicationServices

let args = CommandLine.arguments
let fire = args.contains("--fire")
let useOsa = args.contains("--osascript")
let useSleep = args.contains("--displaysleep")

var delay: Double = 0
if let i = args.firstIndex(of: "--delay"), i + 1 < args.count, let v = Double(args[i + 1]) {
    delay = v
}

// 权限自检（CGEventPost 到 cghidEventTap 需要辅助功能）
let axTrusted = AXIsProcessTrusted()
print("AXIsProcessTrusted = \(axTrusted)")

func fireLockScreen() {
    guard let src = CGEventSource(stateID: .hidSystemState) else {
        print("CGEventSource 创建失败")
        return
    }
    src.localEventsSuppressionInterval = 0

    guard let down = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: false) else {
        print("事件构造失败")
        return
    }
    // Ctrl+Cmd+Q = 锁屏。keyDown 与 keyUp 都必须带同样的修饰键，
    // 否则系统可能只看到裸 Q 键。
    down.flags = [.maskCommand, .maskControl]
    up.flags = [.maskCommand, .maskControl]

    print("POST keyDown(12) flags=[Cmd,Ctrl] → cghidEventTap")
    down.post(tap: .cghidEventTap)
    usleep(60_000)
    print("POST keyUp(12)   flags=[Cmd,Ctrl]")
    up.post(tap: .cghidEventTap)
}

if useSleep {
    print("执行: pmset displaysleepnow")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["displaysleepnow"]
    try? p.run()
    p.waitUntilExit()
    print("退出码 \(p.terminationStatus)")
    exit(0)
}

if useOsa {
    print("执行: osascript System Events 模拟 Ctrl+Cmd+Q")
    let src = """
    tell application "System Events" to key code 12 using {command down, control down}
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    let pe = Pipe(); p.standardError = pe
    try? p.run()
    p.waitUntilExit()
    let err = String(data: pe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print("退出码 \(p.terminationStatus) stderr=\(err)")
    exit(0)
}

if !fire {
    // 只验证构造
    if let src = CGEventSource(stateID: .hidSystemState),
       let down = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: true),
       let up = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: false) {
        down.flags = [.maskCommand, .maskControl]
        up.flags = [.maskCommand, .maskControl]
        print("构造成功: down.flags=\(down.flags.rawValue) up.flags=\(up.flags.rawValue)")
        print("（未发送。加 --fire 真触发，会立即锁屏）")
    } else {
        print("构造失败")
    }
    exit(0)
}

if delay > 0 {
    print("\(delay) 秒后锁屏…")
    Thread.sleep(forTimeInterval: delay)
}

if !axTrusted {
    print("警告: 无辅助功能权限，CGEventPost 可能被静默丢弃")
}

fireLockScreen()
print("已发送锁屏事件")
