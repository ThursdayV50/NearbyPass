// 注入探针：把文本 / 按键送进当前焦点（或指定 pid）
// 用法:
//   inject --text zqx9                全局 HID 注入（默认）
//   inject --text zqx9 --mode pid --pid 1234   定向到某个进程
//   inject --text zqx9 --return        输入后按 Return
//   inject --esc                       先按 Esc 清空输入框
//   inject --delay 1500                等 1.5 秒再输入
//   inject --mode private              用 privateState 事件源
//   inject --key 36                    只按一个键（keycode）
//   inject --dump-keys                 打印 keycode 表
import Foundation
import CoreGraphics
import ApplicationServices
import Carbon

// MARK: - keycode 表（US 布局）

let baseKey: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
    "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 23, "5": 22,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
    "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    " ": 49, "`": 50
]

// 需要 Shift 的字符 → (基础字符)
let shifted: [Character: Character] = [
    "A": "a", "S": "s", "D": "d", "F": "f", "H": "h", "G": "g",
    "Z": "z", "X": "x", "C": "c", "V": "v", "B": "b",
    "Q": "q", "W": "w", "E": "e", "R": "r", "Y": "y", "T": "t",
    "O": "o", "U": "u", "I": "i", "P": "p", "L": "l", "J": "j",
    "K": "k", "N": "n", "M": "m",
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
    "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
    ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
]

// MARK: - 参数解析

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--dump-keys") {
    print("未加 Shift:")
    for (k, v) in baseKey.sorted(by: { $0.value < $1.value }) { print("  '\(k)' = \(v)") }
    print("需 Shift:")
    for (k, v) in shifted.sorted(by: { $0.key < $1.key }) { print("  '\(k)' => '\(v)'") }
    exit(0)
}

let modeName = value("--mode") ?? "hid"
let targetPid: pid_t? = value("--pid").flatMap { pid_t($0) }
let text = value("--text")
let singleKey: CGKeyCode? = value("--key").flatMap { CGKeyCode($0) }
let pressReturn = args.contains("--return")
let pressEsc = args.contains("--esc")
let delayMs: Int = value("--delay").flatMap(Int.init) ?? 0

if text == nil && singleKey == nil && !pressReturn && !pressEsc {
    print("用法: inject --text <字符串> [--mode hid|pid|private] [--pid N] [--return] [--esc] [--delay ms]")
    print("      inject --key <keycode>")
    print("      inject --dump-keys")
    exit(1)
}

print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
print("IsSecureEventInputEnabled = \(IsSecureEventInputEnabled())")

if delayMs > 0 {
    print("等待 \(delayMs)ms …")
    Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
}

// MARK: - 事件源与投递

enum Mode { case hid, pid, priv }
let mode: Mode = {
    switch modeName {
    case "pid": return .pid
    case "private": return .priv
    default: return .hid
    }
}()

let sourceState: CGEventSourceStateID = (mode == .priv) ? .privateState : .hidSystemState
guard let source = CGEventSource(stateID: sourceState) else {
    print("CGEventSource 初始化失败")
    exit(1)
}
// 关掉"本地事件抑制"，否则连续按键会被合并/丢弃
source.localEventsSuppressionInterval = 0

func post(_ ev: CGEvent) {
    switch mode {
    case .hid, .priv:
        ev.post(tap: .cghidEventTap)
    case .pid:
        if let p = targetPid {
            ev.postToPid(p)
        } else {
            ev.post(tap: .cghidEventTap)
        }
    }
}

func press(_ code: CGKeyCode, shift: Bool) {
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
        print("事件构造失败 key=\(code)")
        return
    }
    if shift {
        down.flags = .maskShift
        up.flags = .maskShift
    }
    post(down)
    usleep(8_000)
    post(up)
    usleep(12_000)
}

/// 用 unicode 字符串直接注入（适合中文等 keycode 表覆盖不到的字符）
func typeUnicode(_ s: String) {
    for ch in s {
        var utf16 = Array(String(ch).utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        post(down)
        usleep(6_000)
        post(up)
        usleep(10_000)
    }
}

func typeAscii(_ s: String) {
    for ch in s {
        if let base = baseKey[ch] {
            press(base, shift: false)
        } else if let base = shifted[ch], let code = baseKey[base] {
            press(code, shift: true)
        } else {
            // 兜底：走 unicode 注入
            typeUnicode(String(ch))
        }
    }
}

// MARK: - 执行

if pressEsc {
    print("按 Esc")
    press(53, shift: false)
    Thread.sleep(forTimeInterval: 0.15)
}

if let t = text {
    print("输入 \(t.count) 个字符 (mode=\(modeName)): \(t)")
    typeAscii(t)
}

if let k = singleKey {
    print("按键 keycode=\(k)")
    press(k, shift: false)
}

if pressReturn {
    print("按 Return")
    press(36, shift: false)
}

print("完成")
