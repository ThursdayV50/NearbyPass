// P0-1 / P0-3 探针：真锁屏 → 探测锁屏界面 → 尝试注入
//
// 流程:
//   1. 打印锁屏前状态
//   2. 等 2 秒
//   3. Ctrl+Cmd+Q 锁屏
//   4. 轮询状态直到 locked（最多 12 秒）—— 同时验证 P0-3
//   5. 唤醒显示器、枚举窗口、找 loginwindow/SecurityAgent
//   6. 探测 AX 树并打印
//   7. 截图 locktest_A.png
//   8. AX 往密码框写 "aa" → 截图 locktest_B.png
//   9. CGEventPost 输入 "bb" → 截图 locktest_C.png
//  10. 尝试清空密码框 → 截图 locktest_D.png
//
// 全程不按 Return，不会提交假密码。
// 运行结束后屏幕仍处于锁定状态，需要手动解锁。
import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

let OUT = "/tmp/locktest"
try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)

func log(_ s: String) {
    print(s)
    // 同时落盘，防止 stdout 丢失
    let line = s + "\n"
    let p = OUT + "/log.txt"
    if let h = FileHandle(forWritingAtPath: p) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? line.write(toFile: p, atomically: true, encoding: .utf8)
    }
}

// MARK: - 会话状态

func sessionDict() -> [String: Any] {
    (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
}
func isLocked() -> Bool? {
    sessionDict()["CGSSessionScreenIsLocked"] as? Bool
}
func statusLine() -> String {
    let d = sessionDict()
    let l = isLocked()
    let ls = l.map { $0 ? "true" : "false" } ?? "<键缺失>"
    return "ScreenIsLocked=\(ls) onConsole=\(d["kCGSSessionOnConsoleKey"] ?? "nil")"
}

// MARK: - 外部命令

@discardableResult
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "spawn 失败: \(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func pidOf(_ name: String) -> pid_t? {
    let (rc, out) = run("/usr/bin/pgrep", ["-x", name])
    guard rc == 0 else { return nil }
    let first = out.split(separator: "\n").first.map(String.init) ?? ""
    return pid_t(first.trimmingCharacters(in: .whitespaces))
}

func shot(_ name: String) {
    let path = "\(OUT)/\(name).png"
    let (rc, out) = run("/usr/sbin/screencapture", ["-x", path])
    let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    log("截图 \(name): rc=\(rc) size=\(size) \(out.isEmpty ? "" : "err=\(out)")")
}

// MARK: - 窗口枚举

func dumpWindows(_ tag: String) {
    let opts: CGWindowListOption = [.excludeDesktopElements]
    guard let all = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        log("[\(tag)] 窗口枚举失败")
        return
    }
    let want: Set<String> = ["SecurityAgent", "loginwindow", "LoginUICore", "authorizationhost",
                             "WindowServer", "ControlCenter", "UserNotificationCenter"]
    log("[\(tag)] 窗口总数=\(all.count)，可疑窗口:")
    var n = 0
    for w in all {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        guard want.contains(owner) else { continue }
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = (b["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (b["Y"] as? NSNumber)?.doubleValue ?? 0
        let wd = (b["Width"] as? NSNumber)?.doubleValue ?? 0
        let ht = (b["Height"] as? NSNumber)?.doubleValue ?? 0
        let on = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let nm = w[kCGWindowName as String] as? String ?? "-"
        log("   \(owner) pid=\(pid) layer=\(layer) bounds=\(Int(wd))x\(Int(ht)) @ (\(Int(x)),\(Int(y))) onscreen=\(on ? "Y":"N") name=\(nm)")
        n += 1
    }
    if n == 0 { log("   （无可疑窗口）") }
}

// MARK: - AX 工具

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}
func sAttr(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
func kids(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func allEls(_ root: AXUIElement, limit: Int = 3000) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var q: [AXUIElement] = [root]
    while !q.isEmpty && out.count < limit {
        let c = q.removeFirst()
        out.append(c)
        q.append(contentsOf: kids(c))
    }
    return out
}

func dumpAX(_ pid: pid_t, _ tag: String) -> [AXUIElement] {
    let app = AXUIElementCreateApplication(pid)
    var names: CFArray?
    let e = AXUIElementCopyAttributeNames(app, &names)
    log("[\(tag)] pid=\(pid) 属性数=\(names.map { ($0 as? [String])?.count ?? -1 } ?? -1) err=\(e.rawValue)")
    let els = allEls(app)
    log("[\(tag)] 元素总数=\(els.count)")
    for el in els.prefix(40) {
        let role = sAttr(el, kAXRoleAttribute as String) ?? "?"
        let sub = sAttr(el, kAXSubroleAttribute as String) ?? "-"
        let title = sAttr(el, kAXTitleAttribute as String) ?? "-"
        let desc = sAttr(el, kAXDescriptionAttribute as String) ?? "-"
        let val = sAttr(el, kAXValueAttribute as String) ?? "-"
        let foc = (attr(el, kAXFocusedAttribute as String) as? Bool).map { $0 ? "F" : "-" } ?? "-"
        log("   [\(role)] sub=\(sub) focus=\(foc) title=\(title) desc=\(desc) value=\(val)")
    }
    return els
}

// MARK: - 输入注入

func keyEvent(_ code: CGKeyCode, _ down: Bool, flags: CGEventFlags = []) -> CGEvent? {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return nil }
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return nil }
    e.flags = flags
    return e
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    keyEvent(code, true, flags: flags)?.post(tap: .cghidEventTap)
    usleep(30_000)
    keyEvent(code, false, flags: flags)?.post(tap: .cghidEventTap)
    usleep(50_000)
}

// US keycode
let keyA: CGKeyCode = 0, keyB: CGKeyCode = 11

func typeAB(_ pair: String) {
    for ch in pair {
        if ch == "a" { postKey(keyA) }
        else if ch == "b" { postKey(keyB) }
    }
}

// MARK: - 主流程

log("==================== 锁屏注入测试开始 \(Date()) ====================")
log("AXIsProcessTrusted = \(AXIsProcessTrusted())")
log("锁屏前: \(statusLine())")

log("2 秒后触发锁屏（Ctrl+Cmd+Q）…")
sleep(2)

// P0-3: 发送 Ctrl+Cmd+Q
if let d = keyEvent(12, true, flags: [.maskCommand, .maskControl]) {
    d.post(tap: .cghidEventTap)
    usleep(60_000)
    keyEvent(12, false, flags: [.maskCommand, .maskControl])?.post(tap: .cghidEventTap)
    log("已发送 Ctrl+Cmd+Q")
} else {
    log("事件构造失败")
}

// 轮询等待锁定
var lockedAt: Double? = nil
let t0 = Date()
for i in 0..<75 {
    usleep(200_000)
    if isLocked() == true {
        lockedAt = Date().timeIntervalSince(t0)
        log("检测到锁屏，耗时 \(String(format: "%.1f", lockedAt!))s（第 \(i+1) 次轮询）")
        break
    }
}
if lockedAt == nil {
    log("!! 12 秒内未检测到锁屏。Ctrl+Cmd+Q 可能未生效。")
    log("当前: \(statusLine())")
    dumpWindows("未锁屏")
    exit(1)
}

// 唤醒显示器，确保锁屏界面可见
_ = run("/usr/bin/caffeinate", ["-u", "-t", "2"])
usleep(1_200_000)
log("唤醒后: \(statusLine())")

dumpWindows("锁屏后")

// 找宿主进程
let lwPid = pidOf("loginwindow")
let saPids = run("/usr/bin/pgrep", ["-x", "SecurityAgent"]).1
    .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
log("loginwindow pid = \(lwPid.map(String.init) ?? "nil")")
log("SecurityAgent pids = \(saPids)")

// 截图（原始锁屏界面）
shot("A_locked")

// 探 AX
var secureFields: [AXUIElement] = []
for pid in ([lwPid].compactMap { $0 } + saPids) {
    let els = dumpAX(pid, "AX@\(pid)")
    for el in els where sAttr(el, kAXSubroleAttribute as String) == "AXSecureTextField" {
        secureFields.append(el)
    }
}
log("找到 AXSecureTextField 数量 = \(secureFields.count)")

// 尝试 1: AX 写值
if let f = secureFields.first {
    _ = AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    let err = AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, "aa" as CFString)
    log("AX 写入 \"aa\" err=\(err.rawValue)")
} else {
    log("无 secure field，跳过 AX 写入")
}
usleep(500_000)
shot("B_afterAX")

// 尝试 2: CGEventPost 输入 "bb"
log("CGEventPost 输入 \"bb\" …")
typeAB("bb")
usleep(600_000)
shot("C_afterCGEvent")

// 尝试 3: 清空
if let f = secureFields.first {
    let err = AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, "" as CFString)
    log("AX 清空 err=\(err.rawValue)")
} else {
    // 退路：全选删除
    postKey(0, flags: .maskCommand)  // Cmd+A
    postKey(51)                      // Delete
    log("已尝试 Cmd+A/Delete 清空")
}
usleep(500_000)
shot("D_afterClear")

log("==================== 测试结束 \(Date()) ====================")
log("屏幕仍处于锁定状态，请手动输入密码解锁。")
log("请检查解锁时密码框里是否有残留字符。")
