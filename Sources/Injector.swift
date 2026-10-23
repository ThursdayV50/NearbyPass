// Injector.swift — 合成键盘/鼠标事件
//
// Phase 0 已验证：CGEventPost(.cghidEventTap) 能穿透 Secure Input，
// 对 SecurityAgent 的授权弹窗与 loginwindow 的锁屏密码框都有效。
import Foundation
import CoreGraphics
import Carbon.HIToolbox

enum InjectMode: String {
    case unicode = "unicode"
    case keycode = "keycode"
}

final class Injector {

    static let shared = Injector()

    /// 注入方式：unicode 与键盘布局无关（可打中文和符号），keycode 只支持 US 布局字母数字
    var mode: InjectMode = .unicode

    private let source: CGEventSource?

    private init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
    }

    // MARK: - 键盘

    /// 逐字符输入。返回是否全部投递成功。
    @discardableResult
    func typeText(_ text: String, perCharDelayMS: Int = 8) -> Bool {
        var ok = true
        let delay = useconds_t(max(0, perCharDelayMS) * 1000)
        for ch in text {
            if mode == .keycode, let code = Injector.keyCode(for: ch) {
                ok = postKey(code) && ok
            } else {
                ok = postUnicode(ch) && ok
            }
            if delay > 0 { usleep(delay) }
        }
        return ok
    }

    private func postUnicode(_ ch: Character) -> Bool {
        let units = Array(String(ch).utf16)
        guard !units.isEmpty else { return false }
        var ok = true
        units.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { ok = false; return }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                down.post(tap: .cghidEventTap)
            } else { ok = false }
            usleep(2000)
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: base)
                up.post(tap: .cghidEventTap)
            } else { ok = false }
        }
        return ok
    }

    private func postKey(_ code: CGKeyCode, shift: Bool = false) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return false }
        if shift {
            down.flags = .maskShift
            up.flags = .maskShift
        }
        down.post(tap: .cghidEventTap)
        usleep(6000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// 回车（提交）
    func pressReturn() {
        _ = postKey(CGKeyCode(kVK_Return))
    }

    func pressEscape() {
        _ = postKey(CGKeyCode(kVK_Escape))
    }

    func pressTab() {
        _ = postKey(CGKeyCode(kVK_Tab))
    }

    func pressDelete() {
        _ = postKey(CGKeyCode(kVK_Delete))
    }

    /// 全选后删除（清空输入框）
    func clearField() {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        usleep(20000)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_A), keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
        usleep(20000)
        pressDelete()
    }

    // MARK: - 鼠标

    func moveMouse(to point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source,
                              mouseType: .mouseMoved,
                              mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// 点击全局坐标（左上原点，逻辑点，与 AX frame / CGWindowList bounds 同一坐标系）
    func click(at point: CGPoint) {
        moveMouse(to: point)
        usleep(40000)
        if let down = CGEvent(mouseEventSource: source,
                              mouseType: .leftMouseDown,
                              mouseCursorPosition: point,
                              mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        usleep(60000)
        if let up = CGEvent(mouseEventSource: source,
                            mouseType: .leftMouseUp,
                            mouseCursorPosition: point,
                            mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }

    /// 点击某个 AX 元素的中心
    func click(element el: AXUIElement) -> Bool {
        guard let f = AX.frame(el), f.width > 0, f.height > 0 else { return false }
        click(at: CGPoint(x: f.midX, y: f.midY))
        return true
    }

    // MARK: - US 布局 keycode（仅 keycode 模式使用）

    private static let map: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50
    ]

    /// 只对小写字母与不需要 shift 的符号返回 keycode；大写和其余字符走 unicode 路径
    private static func keyCode(for ch: Character) -> CGKeyCode? {
        map[ch]
    }
}
