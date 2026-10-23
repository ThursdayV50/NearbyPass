// AutoLockHandler.swift — F3：人离开（蓝牙变弱）后自动锁屏
import Foundation
import CoreGraphics
import Carbon.HIToolbox

final class AutoLockHandler {

    static let shared = AutoLockHandler()

    private var absentSince: Date?
    private var timer: Timer?
    private var busy = false

    private init() {}

    func start() {
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("自动锁屏已启用（延迟 \(Int(Settings.shared.autoLockDelay)) 秒）")
    }

    private func tick() {
        let s = Settings.shared
        guard s.autoLockEnabled, !s.paused else { clear(); return }
        guard SessionMonitor.shared.state == .unlocked else { clear(); return }
        guard !busy else { return }

        // presence == .unknown 表示蓝牙关了或没配设备 —— 这种情况绝不锁屏
        guard PresenceMonitor.shared.presence == .absent else {
            if absentSince != nil {
                Log.info("人又回来了，取消锁屏倒计时")
            }
            clear()
            return
        }

        if absentSince == nil {
            absentSince = Date()
            Log.info("检测到人已离开，\(Int(s.autoLockDelay)) 秒后锁屏")
            return
        }

        let elapsed = Date().timeIntervalSince(absentSince!)
        if elapsed >= s.autoLockDelay {
            clear()
            fire()
        }
    }

    private func clear() {
        absentSince = nil
    }

    private func fire() {
        busy = true
        LockReasonTracker.shared.markSelfLock()
        Log.info("自动锁屏触发")
        postLockShortcut()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            if SessionMonitor.screenIsLocked {
                Log.info("锁屏成功")
                self.busy = false
                return
            }
            Log.warn("Ctrl+Cmd+Q 未生效，尝试 osascript 退路")
            self.lockViaOsascript()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if SessionMonitor.screenIsLocked {
                    Log.info("锁屏成功（osascript）")
                } else {
                    Log.error("锁屏失败，最后尝试 displaysleepnow")
                    self.lockViaDisplaySleep()
                }
                self.busy = false
            }
        }
    }

    /// Ctrl+Cmd+Q —— keyDown 与 keyUp 都必须带 flags
    private func postLockShortcut() {
        let src = CGEventSource(stateID: .hidSystemState)
        let q = CGKeyCode(kVK_ANSI_Q)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: true) {
            down.flags = [.maskCommand, .maskControl]
            down.post(tap: .cghidEventTap)
        }
        usleep(20000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: q, keyDown: false) {
            up.flags = [.maskCommand, .maskControl]
            up.post(tap: .cghidEventTap)
        }
    }

    private func lockViaOsascript() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to key code 12 using {command down, control down}"]
        try? p.run()
    }

    private func lockViaDisplaySleep() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}
