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

    /// 达到解锁强度后需要持续的秒数（擦边过线）
    private let requireStrongFor: TimeInterval = 5
    /// 强信号只需持续这么久就放行（人贴着设备回来）
    private let fastStrongFor: TimeInterval = 1.0
    /// 比解锁阈值高多少算"强信号"
    private let strongMargin = 8
    /// 提交后第一次验证的延迟
    private let verifyDelay: TimeInterval = 0.15
    /// 验证轮询间隔
    private let verifyPoll: TimeInterval = 0.15
    /// 验证轮询次数：60 × 0.15s ≈ 9 秒。
    /// 冷唤醒时 loginwindow 建 AX 树、动画、密码校验都可能超过 3 秒。
    private let verifyPolls = 60

    private var strongSince: Date?
    /// 强信号计时
    private var fastSince: Date?
    /// 本次解锁流程开始时刻（用于统计耗时）
    private var unlockStartedAt: Date?
    private var timer: Timer?
    /// 本次锁屏会话内是否已经尝试过（无论成败）
    private var attemptedThisSession = false
    /// 密码疑似错误 —— 本会话内不再尝试
    private var passwordSuspect = false
    /// 界面始终没就绪、重试用尽 —— 本会话内不再尝试。
    /// 和 passwordSuspect 分开：那不是密码错，不能让日志和通知说成密码错。
    private var gaveUpThisSession = false
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
        gaveUpThisSession = false
        transientRetries = 0
        strongSince = nil
        fastSince = nil
        unlockStartedAt = nil
    }

    private func tick() {
        let s = Settings.shared
        guard s.autoUnlockEnabled, !s.paused else { reset(); return }
        guard SessionMonitor.shared.state == .locked else { reset(); return }
        guard !attemptedThisSession, !passwordSuspect, !gaveUpThisSession, !busy else { return }

        // F2 只认「解锁主设备」
        guard let primary = s.primaryDeviceID else { reset(); return }
        guard let rssi = PresenceMonitor.shared.liveRSSI(primary),
              rssi >= s.unlockThreshold else {
            reset()
            return
        }

        /// presence 已经用 5dBm 迟滞带判过一轮，这里再要求"在场"是为了对齐两条判据：
        /// 迟滞带允许 ema 停在 [-65,-60) 仍算「离开」，而 F2 用的是取整后的 -60，
        /// 于是自动锁屏后可能立刻又被解开。要求 .present 后两条判据在同一时刻翻转。
        guard PresenceMonitor.shared.presence == .present else {
            reset()
            return
        }

        guard LockReasonTracker.shared.canAutoUnlock else {
            // 手动锁屏保护中
            reset()
            return
        }

        // 强信号快通道：信号明显强于阈值，说明人已经贴回来，1 秒即可
        if rssi >= s.unlockThreshold + strongMargin {
            if fastSince == nil {
                fastSince = Date()
                Log.info("主设备信号 \(rssi)dBm 属于强信号，\(fastStrongFor) 秒后解锁")
            }
            if strongSince == nil { strongSince = Date() }
            if Date().timeIntervalSince(fastSince!) >= fastStrongFor {
                strongSince = nil
                fastSince = nil
                fire()
                return
            }
        } else {
            fastSince = nil
        }

        if strongSince == nil {
            strongSince = Date()
            Log.info("主设备信号 \(rssi)dBm 达到解锁强度，\(Int(requireStrongFor)) 秒后自动解锁")
            return
        }

        if Date().timeIntervalSince(strongSince!) >= requireStrongFor {
            strongSince = nil
            fastSince = nil
            fire()
        }
    }

    private func reset() {
        strongSince = nil
        fastSince = nil
    }

    private func fire() {
        guard let password = KeychainStore.shared.load() else {
            Log.error("未设置密码，无法自动解锁")
            attemptedThisSession = true
            return
        }
        busy = true
        attemptedThisSession = true
        unlockStartedAt = Date()
        Log.info("开始自动解锁")

        // 不再固定等待：唤醒后立刻开始轮询密码框，出现就写
        SessionMonitor.wakeDisplay()
        injectPassword(password)
    }

    /// 所有 loginwindow 进程。锁屏界面和登录窗口前置 UI 可能各有一个，
    /// 只取第一个会偶发「锁屏界面里找不到密码框」——那次拿到的那个进程并没有锁屏密码框。
    private func loginWindowPids() -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "loginwindow"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func injectPassword(_ password: String) {
        let pids = loginWindowPids()
        guard !pids.isEmpty else {
            // loginwindow 还没起来，等一下再说，不算失败
            abortTransient("loginwindow 还没就绪")
            return
        }

        // 屏保挡在锁屏界面前面时，Return 会打给屏保而不是密码框，
        // 先合成一次 Shift 把屏保退掉（Shift 在密码框里没有副作用）。
        // 等待时间随重试次数放大：刚唤醒时锁屏 UI 建 AX 树可能比 6 秒慢。
        var fieldDeadline = Date().addingTimeInterval(6 + Double(transientRetries) * 4)
        if screensaverRunning() {
            Log.info("检测到屏保正在运行，先退出屏保")
            nudgeUserInput()
            fieldDeadline = Date().addingTimeInterval(8 + Double(transientRetries) * 4)
        }

        findSecureField(pids: pids, deadline: fieldDeadline) { [weak self] found in
            guard let self = self else { return }
            guard let (field, pid) = found else {
                // 等密码框的这几秒里可能被手动解锁了，先确认再判失败
                if !SessionMonitor.screenIsLocked {
                    Log.info("已解锁（等待密码框期间确认）")
                    self.finish(password: password, success: true)
                    return
                }
                if !AX.isTrusted {
                    Log.error("辅助功能权限失效，无法读取锁屏密码框")
                    self.fail(password: password, reason: "辅助功能权限已失效")
                    return
                }
                self.abortTransient("锁屏界面里找不到密码框")
                return
            }

            let injector = Injector.shared
            let all = AX.secureFields(pid: pid)
            let focusErr = AX.focus(field)
            // 只等焦点真正到位，最多 200ms，不再盲睡
            let focusDeadline = Date().addingTimeInterval(0.2)
            while Date() < focusDeadline && !AX.isFocused(field) { usleep(20_000) }
            let focusedElement = AX.focusedElement()
            let canTypeSafely = AX.isFocused(field)
                && focusedElement.map { AX.pidOf($0) == pid && CFEqual($0, field) } == true

            // AX 直接写值最稳：不依赖键盘焦点、不受输入法/布局影响。
            // Phase 0 实测 AX 写值和 CGEventPost 都能进 Secure Input 的框。
            let setErr = AX.setValue(field, password)
            Log.info("密码框 \(all.count) 个，聚焦 err=\(focusErr.rawValue)，写值 err=\(setErr.rawValue)")

            if setErr != .success {
                guard canTypeSafely else {
                    Log.error("AX 写值失败且未确认密码框焦点，取消本次注入")
                    self.abortTransient("无法确认锁屏密码框焦点")
                    return
                }
                Log.warn("AX 写值失败，回退到合成键盘输入")
                guard injector.typeText(password, perCharDelayMS: 12) else {
                    self.fail(password: password, reason: "密码未能完整写入，已取消提交")
                    return
                }
            }
            // 按钮可能晚几十毫秒才可用，最多等 300ms
            var submitted = false
            let submitDeadline = Date().addingTimeInterval(0.3)
            while Date() < submitDeadline {
                for label in Self.submitLabels {
                    if AX.pressButton(pid: pid, label: label) {
                        submitted = true
                        Log.info("已点击「\(label)」提交")
                        break
                    }
                }
                if submitted { break }
                usleep(50_000)
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

    /// 在所有 loginwindow 进程里找密码框，返回「元素 + 它所属的 pid」。
    /// 优先已聚焦的那个；找不到就等到 deadline。
    private func findSecureField(
        pids: [pid_t],
        deadline: Date,
        attempt: Int = 0,
        completion: @escaping ((AXUIElement, pid_t)?) -> Void
    ) {
        for pid in pids {
            let fields = AX.secureFields(pid: pid)
            if let f = fields.first(where: { AX.isFocused($0) }) ?? fields.first {
                completion((f, pid))
                return
            }
        }
        guard Date() < deadline else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.findSecureField(pids: pids, deadline: deadline, attempt: attempt + 1, completion: completion)
        }
    }

    /// 密码提交后确认解锁；多等两轮，避免把"界面慢"误判成"密码错"
    private func verifyUnlocked(attempt: Int, password: String) {
        if !SessionMonitor.screenIsLocked {
            let cost = unlockStartedAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?"
            Log.info("自动解锁成功 ✅ 耗时 \(cost) 秒")
            finish(password: password, success: true)
            return
        }
        if attempt >= verifyPolls {
            // 绝不在这里判「密码错」：界面慢和密码错是两件事。
            // 判成密码错会让整个锁屏会话直接放弃自动解锁，而判错的代价用户要自己输密码。
            // 界面慢只是这一轮没赶上——放弃本次会话、不重试（避免重复提交同一个密码），
            // 真正密码错的情况由系统自己弹提示，用户手动处理。
            gaveUpThisSession = true
            busy = false
            var p = password
            KeychainStore.zeroString(&p)
            let secs = Int(Double(verifyPolls) * verifyPoll)
            Log.error("自动解锁未完成：提交后约 \(secs) 秒仍处于锁屏状态，界面可能还没响应。本次锁屏不再尝试。")
            Notifier.post(title: "自动解锁未完成", body: "提交后界面没有响应，请手动解锁。")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyPoll) { [weak self] in
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
            // 用尽重试也不等于密码错：只封本次锁屏会话，不动 passwordSuspect
            gaveUpThisSession = true
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
