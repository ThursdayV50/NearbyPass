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
            Log.error("找不到 loginwindow 进程")
            fail(password: password, reason: "找不到 loginwindow")
            return
        }

        // 密码框可能还没就绪，最多等 5 秒
        findSecureField(pid: pid, deadline: Date().addingTimeInterval(5)) { [weak self] field in
            guard let self = self else { return }
            guard let field = field else {
                Log.error("loginwindow 中找不到密码框")
                self.fail(password: password, reason: "找不到密码框")
                return
            }

            _ = AX.focus(field)
            usleep(80000)

            // 真实键盘路径（Phase 0 已验证可穿透 Secure Input）
            let injector = Injector.shared
            let ok = injector.typeText(password, perCharDelayMS: 12)
            if !ok {
                Log.warn("部分字符投递失败，尝试用 AX 直接写值")
                AX.setValue(field, password)
            }
            usleep(200000)
            injector.pressReturn()
            Log.info("已提交密码，等待验证")

            DispatchQueue.main.asyncAfter(deadline: .now() + self.verifyDelay) {
                if SessionMonitor.screenIsLocked {
                    Log.error("自动解锁失败：仍处于锁屏状态")
                    self.fail(password: password, reason: "密码被拒绝或界面未响应")
                } else {
                    Log.info("自动解锁成功 ✅")
                    self.finish(password: password, success: true)
                }
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
