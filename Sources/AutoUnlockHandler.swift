// AutoUnlockHandler.swift — F2：锁屏后设备在附近则全自动解锁（无确认）
//
// Phase 0 已验证：
//   · 锁屏宿主 = loginwindow (pid)，密码框 AXTextField + AXSubrole=AXSecureTextField，锁屏后约 1.2s 自动 focused
//   · AX setValue 与 CGEventPost 都能写入，提交靠 CGEventPost 的 Return
//   · 锁屏判据 = CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]
//
// 安全收紧：绝不重试。macOS 连续输错会锁账户。
import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class AutoUnlockHandler {

    static let shared = AutoUnlockHandler()

    /// 达到解锁强度后需要持续的秒数
    private let requireStrongFor: TimeInterval = 5
    /// 唤醒显示器后等待锁屏界面就绪
    private let wakeSettleMS = 1800
    /// 提交后等待验证
    private let verifyDelay = 1.5

    private var strongSince: Date?
    private var timer: Timer?
    /// 本次锁屏会话内是否已经尝试过（无论成败）
    private var attemptedThisSession = false
    /// 密码疑似错误 —— 本会话内不再尝试
    private var passwordSuspect = false
    private var busy = false
    /// 界面没就绪（屏保没退、密码框还没出来）导致的重试次数
    private var transientRetries = 0
    private let maxTransientRetries = 3
    /// 锁屏界面真正的提交按钮叫 login（挂在 AXDescription 上），
    /// Return 在锁屏界面并不一定触发提交，所以优先按按钮。
    private static let submitLabels = ["login", "登录", "解锁", "Unlock", "unlock", "好", "确定"]

    private init() {}

    func start() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("自动解锁已启用（需 ≥\(Settings.shared.unlockThreshold)dBm 持续 \(Int(requireStrongFor)) 秒）")
    }

    /// 每次锁屏开始时重置会话内状态
    func onSessionLocked() {
        attemptedThisSession = false
        passwordSuspect = false
        transientRetries = 0
        strongSince = nil
    }

    private func tick() {
        let s = Settings.shared
        guard s.autoUnlockEnabled, !s.paused else { reset(); return }
        guard SessionMonitor.shared.state == .locked else { reset(); return }
        guard !attemptedThisSession, !passwordSuspect, !busy else { return }

        // F2 只认「解锁主设备」
        guard let primary = s.primaryDeviceID else { return }
        guard let rssi = PresenceMonitor.shared.liveRSSI(primary),
              rssi >= s.unlockThreshold else {
            strongSince = nil
            return
        }

        guard LockReasonTracker.shared.canAutoUnlock else {
            // 手动锁屏保护中
            strongSince = nil
            return
        }

        if strongSince == nil {
            strongSince = Date()
            Log.info("主设备信号 \(rssi)dBm 达到解锁强度，\(Int(requireStrongFor)) 秒后自动解锁")
            return
        }

        if Date().timeIntervalSince(strongSince!) >= requireStrongFor {
            strongSince = nil
            fire()
        }
    }

    private func reset() {
        strongSince = nil
    }

    private func fire() {
        guard let password = KeychainStore.shared.load() else {
            Log.error("未设置密码，无法自动解锁")
            attemptedThisSession = true
            return
        }
        busy = true
        attemptedThisSession = true
        Log.info("开始自动解锁")

        SessionMonitor.wakeDisplay()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(wakeSettleMS)) { [weak self] in
            guard let self = self else { return }
            guard SessionMonitor.screenIsLocked else {
                Log.info("锁屏已消失（可能已手动解锁），流程结束")
                self.finish(password: password, success: true)
                return
            }
            self.injectPassword(password)
        }
    }

    /// 返回 loginwindow 的 pid
    private func loginWindowPid() -> pid_t? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "loginwindow"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 取第一个 pid（锁屏主界面那个）
        for line in text.split(separator: "\n") {
            if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)) { return pid }
        }
        return nil
    }

    private func injectPassword(_ password: String) {
        guard let pid = loginWindowPid() else {
            // loginwindow 还没起来，等一下再说，不算失败
            abortTransient("loginwindow 还没就绪")
            return
        }

        // 屏保挡在锁屏界面前面时，Return 会打给屏保而不是密码框，
        // 先合成一次 Shift 把屏保退掉（Shift 在密码框里没有副作用）。
        if screensaverRunning() {
            Log.info("检测到屏保正在运行，先退出屏保")
            nudgeUserInput()
            usleep(1600000)
        }

        // 空闲锁屏后密码框常常要好几秒才出来，给足 25 秒
        findSecureField(pid: pid, deadline: Date().addingTimeInterval(25)) { [weak self] field in
            guard let self = self else { return }
            guard let field = field else {
                self.abortTransient("锁屏界面里找不到密码框")
                return
            }

            let injector = Injector.shared
            let all = AX.secureFields(pid: pid)
            let focusErr = AX.focus(field)
            usleep(300000)

            // AX 直接写值最稳：不依赖键盘焦点、不受输入法/布局影响。
            // Phase 0 实测 AX 写值和 CGEventPost 都能进 Secure Input 的框。
            let setErr = AX.setValue(field, password)
            Log.info("密码框 \(all.count) 个，聚焦 err=\(focusErr.rawValue)，写值 err=\(setErr.rawValue)")

            if setErr != .success {
                Log.warn("AX 写值失败，回退到合成键盘输入")
                let ok = injector.typeText(password, perCharDelayMS: 12)
                if !ok { Log.error("合成键盘输入也失败了") }
            }
            usleep(300000)

            var submitted = false
            for label in Self.submitLabels {
                if AX.pressButton(pid: pid, label: label) {
                    submitted = true
                    Log.info("已点击「\(label)」提交")
                    break
                }
            }
            if !submitted {
                injector.pressReturn()
                Log.info("未找到提交按钮，已发送 Return")
            }
            Log.info("已提交密码，等待验证")

            DispatchQueue.main.asyncAfter(deadline: .now() + self.verifyDelay) {
                self.verifyUnlocked(attempt: 0, password: password)
            }
        }
    }

    private func findSecureField(
        pid: pid_t,
        deadline: Date,
        attempt: Int = 0,
        completion: @escaping (AXUIElement?) -> Void
    ) {
        let fields = AX.secureFields(pid: pid)
        if let f = fields.first(where: { AX.isFocused($0) }) ?? fields.first {
            completion(f)
            return
        }
        guard Date() < deadline else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.findSecureField(pid: pid, deadline: deadline, attempt: attempt + 1, completion: completion)
        }
    }

    /// 密码提交后确认解锁；多等两轮，避免把"界面慢"误判成"密码错"
    private func verifyUnlocked(attempt: Int, password: String) {
        if !SessionMonitor.screenIsLocked {
            Log.info("自动解锁成功 ✅")
            finish(password: password, success: true)
            return
        }
        if attempt >= 2 {
            Log.error("自动解锁失败：仍处于锁屏状态")
            fail(password: password, reason: "密码被拒绝或界面未响应")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.verifyUnlocked(attempt: attempt + 1, password: password)
        }
    }

    /// 屏保进程是否在跑
    private func screensaverRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "ScreenSaverEngine"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 合成一次 Shift 按键：任何真实输入都能让屏保退出
    private func nudgeUserInput() {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Shift), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Shift), keyDown: false)
        down?.post(tap: .cghidEventTap)
        usleep(30000)
        up?.post(tap: .cghidEventTap)
    }

    /// 界面没就绪这类失败：不算密码错，稍后重新走一遍
    private func abortTransient(_ reason: String) {
        busy = false
        attemptedThisSession = false
        transientRetries += 1
        if transientRetries >= maxTransientRetries {
            passwordSuspect = true
            Log.error("自动解锁放弃：\(reason)（已尝试 \(transientRetries) 次）")
            Notifier.post(title: "自动解锁未完成", body: "\(reason)。请手动解锁。")
        } else {
            Log.warn("自动解锁推迟：\(reason)，稍后重试")
        }
    }

    private func fail(password: String, reason: String) {
        // 疑似密码错误：本会话锁定，绝不重试
        passwordSuspect = true
        busy = false
        var p = password
        KeychainStore.zeroString(&p)
        Log.error("自动解锁终止：\(reason)。本次锁屏不再尝试。")
        Notifier.post(title: "自动解锁失败", body: "\(reason)。已暂停自动解锁，请手动解锁。")
    }

    private func finish(password: String, success: Bool) {
        busy = false
        var p = password
        KeychainStore.zeroString(&p)
        if success {
            LockReasonTracker.shared.reset()
        }
    }
}

// MARK: - 通知

enum Notifier {
    static func post(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let script = "display notification \"\(body.replacingOccurrences(of: "\"", with: "\\\""))\" with title \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
        p.arguments = ["-e", script]
        try? p.run()
    }
}
