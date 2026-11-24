import AppKit
import ApplicationServices
import CoreGraphics

final class AuthDialogHandler {
    static let shared = AuthDialogHandler()

    private enum Host: Equatable {
        case authorizationAgent, localAuthentication, systemSettings, passwords

        init?(executablePath path: String) {
            switch path {
            case "/System/Applications/Passwords.app/Contents/MacOS/Passwords":
                self = .passwords
            case "/System/Applications/System Settings.app/Contents/MacOS/System Settings":
                self = .systemSettings
            default:
                guard path.hasPrefix("/System/Library/") else { return nil }
                if path.hasSuffix("/SecurityAgent.bundle/Contents/MacOS/SecurityAgent")
                    || path.hasSuffix("/SecurityAgent.app/Contents/MacOS/SecurityAgent") {
                    self = .authorizationAgent
                } else if path.hasSuffix("/coreautha.bundle/Contents/MacOS/coreautha")
                    || path.hasSuffix("/LocalAuthenticationRemoteService.xpc/Contents/MacOS/LocalAuthenticationRemoteService")
                    || path.hasSuffix("/LocalAuthentication.framework/Support/coreauthd") {
                    self = .localAuthentication
                } else {
                    return nil
                }
            }
        }
    }

    private struct Target {
        let host: Host
        let pid: pid_t
        let window: AXUIElement
        let scope: AXUIElement
        let bounds: CGRect

        func matches(_ other: Target) -> Bool {
            pid == other.pid && CFEqual(window, other.window) && CFEqual(scope, other.scope)
        }
    }

    private enum Prompt {
        case password(field: AXUIElement, submit: AXUIElement?)
        case usePassword(button: AXUIElement)

        func matches(_ other: Prompt) -> Bool {
            switch (self, other) {
            case (.password(let field, _), .password(let otherField, _)),
                 (.usePassword(let field), .usePassword(let otherField)):
                return CFEqual(field, otherField)
            default:
                return false
            }
        }
    }

    private static let passwordActions: Set<String> = [
        "use password", "use password instead", "enter password", "unlock with password",
        "使用密码", "输入密码", "使用密码解锁", "使用密碼", "輸入密碼", "使用密碼解鎖"
    ]
    private static let unlockActions: Set<String> = [
        "unlock", "unlock passwords", "解锁", "解锁密码", "解鎖", "解鎖密碼"
    ]
    private static let passwordsLockedHeadings = [
        "passwordsislocked", "passwordsarelocked", "密码已锁定", "密碼已鎖定", "密碼已鎖住"
    ]
    private static let headingSeparators = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\"“”‘’「」『』")
    )
    private static let submitActions = unlockActions.union([
        "ok", "modify settings", "continue", "allow", "authenticate",
        "好", "修改设置", "确定", "繼續", "继续", "允许", "允許", "認證", "认证"
    ])

    private var timer: Timer?
    private var handled: [(target: Target, prompt: Prompt)] = []
    private var cooldownUntil: Date?
    private var busy = false

    private init() {}

    func start() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("授权弹窗监听已启用（冷却 \(Int(Settings.shared.authCooldown)) 秒）")
    }

    private var canFill: Bool {
        let settings = Settings.shared
        return settings.authFillEnabled && !settings.paused && AX.isTrusted
            && SessionMonitor.shared.state == .unlocked
            && PresenceMonitor.shared.presence == .present
    }

    private func tick() {
        guard canFill, !busy, !ConfirmPanel.shared.isPresenting,
              cooldownUntil.map({ Date() >= $0 }) ?? true else { return }

        let targets = authTargets()
        handled.removeAll { previous in
            !targets.contains { previous.target.matches($0.target) && previous.prompt.matches($0.prompt) }
        }
        guard let (target, prompt) = targets.first(where: { target, prompt in
            !handled.contains { $0.target.matches(target) && $0.prompt.matches(prompt) }
        }), KeychainStore.shared.hasPassword() else { return }
        handled.append((target, prompt))

        let presence = PresenceMonitor.shared
        let primary = Settings.shared.primaryDeviceID
        let name = primary.map(presence.displayName) ?? "信任设备在附近"
        let rssi = primary.flatMap(presence.liveRSSI) ?? presence.bestTrustedRSSI() ?? 0
        let reason = target.host == .passwords
            ? "为「密码」App 的解锁提示填入登录密码"
            : "为这次系统授权自动填入登录密码"
        Log.info("检测到系统认证提示，等待用户确认")
        ConfirmPanel.shared.show(
            device: name, rssi: rssi, reason: reason, anchor: target.bounds,
            isTargetActive: { Self.currentPrompt(for: target)?.matches(prompt) == true }
        ) { [weak self] in
            self?.fill(target, approved: prompt)
        }
    }

    private struct VisibleWindow {
        let pid: pid_t
        let bounds: CGRect
    }

    private static func visibleWindows() -> [VisibleWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap { window in
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != getpid(),
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  bounds.width >= 180, bounds.height >= 100 else { return nil }
            return VisibleWindow(pid: pid, bounds: bounds)
        }
    }

    private static func matches(_ axBounds: CGRect, _ cgBounds: CGRect) -> Bool {
        // 窗口边框在两个 API 中的坐标可能相差几个点。
        abs(axBounds.minX - cgBounds.minX) <= 8 && abs(axBounds.minY - cgBounds.minY) <= 8
            && abs(axBounds.width - cgBounds.width) <= 12 && abs(axBounds.height - cgBounds.height) <= 12
    }

    private static func host(_ pid: pid_t) -> Host? {
        if let path = NSRunningApplication(processIdentifier: pid)?.executableURL?.path,
           let host = Host(executablePath: path) {
            return host
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Host(executablePath: String(cString: path))
    }

    private func authTargets() -> [(target: Target, prompt: Prompt)] {
        let visible = Self.visibleWindows()
        let byPID = Dictionary(grouping: visible, by: \.pid)
        var seen: Set<pid_t> = []
        var targets: [(Target, Prompt)] = []
        for entry in visible where seen.insert(entry.pid).inserted {
            let pid = entry.pid
            guard let host = Self.host(pid) else { continue }
            let app = AX.app(pid)
            let windows = AX.attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows {
                guard let bounds = AX.frame(window),
                      byPID[pid]?.contains(where: { Self.matches(bounds, $0.bounds) }) == true
                else { continue }
                for scope in Self.scopes(in: window) {
                    let target = Target(host: host, pid: pid, window: window, scope: scope,
                                        bounds: AX.frame(scope) ?? bounds)
                    if let prompt = Self.prompt(in: target) { targets.append((target, prompt)) }
                }
            }
        }
        return targets
    }

    private static func visible(_ target: Target) -> Bool {
        guard let frame = AX.frame(target.window) else { return false }
        return visibleWindows().contains { $0.pid == target.pid && matches(frame, $0.bounds) }
    }

    private static func scopes(in window: AXUIElement) -> [AXUIElement] {
        let sheets = AX.children(window).filter { AX.role($0) == kAXSheetRole as String }
        return sheets.isEmpty ? [window] : sheets
    }

    private static func currentPrompt(for target: Target) -> Prompt? {
        guard visible(target) else { return nil }
        return prompt(in: target)
    }

    private static func prompt(in target: Target) -> Prompt? {
        let root = target.scope
        guard !AX.role(root).isEmpty,
              scopes(in: target.window).contains(where: { CFEqual(root, $0) }) else { return nil }

        let elements = AX.all(root, limit: 240)
        let fields = elements.filter { AX.subrole($0) == kAXSecureTextFieldSubrole as String }
        let buttons = elements.filter { AX.role($0) == kAXButtonRole as String }
        let submit = buttons.first { matchesLabel($0, in: submitActions) }
        let fallback = buttons.first { matchesLabel($0, in: passwordActions) }

        if target.host == .passwords {
            // 密码 App 的编辑页面也有安全输入框。只有解锁入口可使用 Mac 登录密码。
            let unlock = buttons.first { matchesLabel($0, in: unlockActions) }
            if fields.isEmpty { return fallback.map(Prompt.usePassword) }
            guard fields.count == 1, let field = fields.first,
                  unlock != nil || elements.contains(where: isPasswordsLockedHeading),
                  !elements.contains(where: {
                      AX.role($0) == kAXTextFieldRole as String && !CFEqual($0, field)
                  }) else { return nil }
            return .password(field: field, submit: unlock)
        }

        if target.host == .systemSettings && CFEqual(root, target.window) {
            let isDialog = AX.subrole(root) == kAXDialogSubrole as String
                || (AX.attr(root, kAXModalAttribute) as? Bool) == true
            guard isDialog || (target.bounds.width <= 520 && target.bounds.height <= 650)
            else { return nil }
        }

        if fields.isEmpty { return fallback.map(Prompt.usePassword) }
        guard fields.count == 1, let field = fields.first else { return nil }
        return .password(field: field, submit: submit)
    }

    private static func matchesLabel(_ element: AXUIElement, in labels: Set<String>) -> Bool {
        let punctuation = CharacterSet(charactersIn: ".…⋯ \n\t")
        return [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
            guard let text = AX.string(element, attribute) else { return false }
            return labels.contains(text.lowercased().trimmingCharacters(in: punctuation))
        }
    }

    private static func isPasswordsLockedHeading(_ element: AXUIElement) -> Bool {
        guard AX.role(element) == kAXStaticTextRole as String else { return false }
        return [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
            guard let text = AX.string(element, attribute) else { return false }
            let heading = text.lowercased().components(separatedBy: headingSeparators).joined()
            return passwordsLockedHeadings.contains(where: heading.hasPrefix)
        }
    }

    private func fill(_ target: Target, approved: Prompt) {
        busy = true
        guard canFill, let prompt = Self.currentPrompt(for: target), prompt.matches(approved) else {
            finish("认证窗口已变化，未填写")
            return
        }
        switch prompt {
        case .password(let field, let submit):
            prepareToWrite(field: field, submit: submit, target: target)
        case .usePassword(let button):
            guard AX.press(button) == .success else {
                fail("请在系统提示中点击「使用密码」")
                return
            }
            waitForPassword(in: target, deadline: Date().addingTimeInterval(3))
        }
    }

    private func waitForPassword(in target: Target, deadline: Date) {
        guard canFill else {
            finish("状态已变化，未填写")
            return
        }
        if let prompt = Self.currentPrompt(for: target), case .password(let field, let submit) = prompt {
            handled.append((target, prompt))
            prepareToWrite(field: field, submit: submit, target: target)
            return
        }
        guard Date() < deadline else {
            fail("未能确认切换后的密码框")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.waitForPassword(in: target, deadline: deadline)
        }
    }

    private func prepareToWrite(field: AXUIElement, submit: AXUIElement?, target: Target) {
        guard target.host == .passwords, submit == nil else {
            writePassword(to: field, submit: submit, target: target)
            return
        }

        // 独立锁定页用回车提交。确认浮窗刚获得焦点，先把焦点还给该安全输入框。
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
        waitForFocus(on: field, in: target, deadline: Date().addingTimeInterval(1))
    }

    private func waitForFocus(on field: AXUIElement, in target: Target, deadline: Date) {
        guard canFill, let prompt = Self.currentPrompt(for: target),
              prompt.matches(.password(field: field, submit: nil)) else {
            finish("认证窗口已变化，未填写")
            return
        }
        if Self.isFocused(field) {
            writePassword(to: field, submit: nil, target: target)
            return
        }
        guard Date() < deadline else {
            fail("无法聚焦「密码」App 的解锁框，请手动输入")
            return
        }
        AX.focus(field)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForFocus(on: field, in: target, deadline: deadline)
        }
    }

    private func writePassword(to field: AXUIElement, submit: AXUIElement?, target: Target) {
        let userTyped = AX.fieldHasText(field)
        if !userTyped {
            guard var password = KeychainStore.shared.load(), !password.isEmpty else {
                finish("请先设置登录密码")
                return
            }
            defer { KeychainStore.zeroString(&password) }

            if AX.setValue(field, password) != .success {
                AX.focus(field)
                guard Injector.shared.typeText(password, perCharDelayMS: 12, whileFocused: {
                    Self.isFocused(field)
                }) else {
                    fail("无法写入这个认证窗口，请手动输入")
                    return
                }
            }
        }

        let pressed = submit.map { AX.press($0) == .success } ?? false
        if !pressed {
            guard !userTyped, Self.isFocused(field) else {
                finish(userTyped ? "请在系统窗口中提交" : "已填写，请在系统窗口中提交")
                return
            }
            Injector.shared.pressReturn()
        }
        ConfirmPanel.shared.updateStatus("等待系统验证…")
        verifySubmission(in: target, field: field, deadline: Date().addingTimeInterval(4))
    }

    private static func isFocused(_ field: AXUIElement) -> Bool {
        guard let focused = AX.focusedElement() else { return false }
        return CFEqual(field, focused)
    }

    private func verifySubmission(in target: Target, field: AXUIElement, deadline: Date) {
        guard case .password(let current, _)? = Self.currentPrompt(for: target), CFEqual(field, current) else {
            finish("已提交")
            return
        }
        guard Date() < deadline else {
            fail("认证窗口仍在，请检查密码或手动完成")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.verifySubmission(in: target, field: field, deadline: deadline)
        }
    }

    private func finish(_ status: String) {
        busy = false
        ConfirmPanel.shared.updateStatus(status)
        ConfirmPanel.shared.finish()
    }

    private func fail(_ reason: String) {
        cooldownUntil = Date().addingTimeInterval(Settings.shared.authCooldown)
        Log.warn("授权弹窗填写终止：\(reason)")
        finish(reason)
    }
}
