// AX.swift — 辅助功能（Accessibility）封装
//
// Phase 0 已验证：
//   · SecurityAgent 的授权弹窗 AX 树完整可读可写
//   · loginwindow 的锁屏密码框 AX 树完整可读可写
//   两者都是 AXTextField + AXSubrole=AXSecureTextField
import Foundation
import ApplicationServices
import AppKit

enum AX {

    // MARK: - 权限

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权引导
    static func promptTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - 基础读写

    static func app(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func role(_ el: AXUIElement) -> String {
        string(el, kAXRoleAttribute as String) ?? ""
    }

    static func subrole(_ el: AXUIElement) -> String {
        string(el, kAXSubroleAttribute as String) ?? ""
    }

    static func label(_ el: AXUIElement) -> String {
        // 按钮的可见文字有时在 description，有时在 title
        let d = string(el, kAXDescriptionAttribute as String) ?? ""
        if !d.isEmpty { return d }
        return string(el, kAXTitleAttribute as String) ?? ""
    }

    static func isFocused(_ el: AXUIElement) -> Bool {
        (attr(el, kAXFocusedAttribute as String) as? Bool) ?? false
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var p = CGPoint.zero
        var s = CGSize.zero
        if let raw = attr(el, kAXPositionAttribute as String), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgPoint, &p)
        } else {
            return nil
        }
        if let raw = attr(el, kAXSizeAttribute as String), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgSize, &s)
        }
        return CGRect(origin: p, size: s)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    /// 广度优先遍历整棵子树
    static func all(_ root: AXUIElement, limit: Int = 2000) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var queue: [AXUIElement] = [root]
        while !queue.isEmpty && out.count < limit {
            let cur = queue.removeFirst()
            out.append(cur)
            queue.append(contentsOf: children(cur))
        }
        return out
    }

    // MARK: - 语义查询

    /// 某个进程里所有安全输入框（密码框）
    static func secureFields(pid: pid_t) -> [AXUIElement] {
        all(app(pid)).filter { subrole($0) == "AXSecureTextField" }
    }

    /// 某个进程里所有按钮，附可见文字
    static func buttons(pid: pid_t) -> [(el: AXUIElement, label: String)] {
        all(app(pid))
            .filter { role($0) == kAXButtonRole as String }
            .map { (el: $0, label: label($0)) }
    }

    /// 某个进程里所有静态文本（用来判断弹窗内容类型）
    static func staticTexts(pid: pid_t) -> [String] {
        all(app(pid))
            .filter { role($0) == kAXStaticTextRole as String }
            .compactMap { string($0, kAXValueAttribute as String) }
            .filter { !$0.isEmpty }
    }

    /// 顶层窗口数（用来判断弹窗是否还在）
    static func windowCount(pid: pid_t) -> Int {
        (attr(app(pid), kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? 0
    }

    // MARK: - 写入

    @discardableResult
    static func focus(_ el: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// 直接把文本写进输入框。Phase 0 已验证对 NSSecureTextField 有效。
    @discardableResult
    static func setValue(_ el: AXUIElement, _ value: String) -> AXError {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> AXError {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    /// 按可见文字找按钮并点击
    @discardableResult
    static func pressButton(pid: pid_t, label wanted: String) -> Bool {
        guard let target = buttons(pid: pid).first(where: { $0.label == wanted }) else {
            return false
        }
        return press(target.el) == .success
    }
}
