// SessionMonitor.swift — 会话锁屏状态
//
// Phase 0 已验证的判据：
//   CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]
//   未锁屏时该键【不存在】，锁屏时 = true
import Foundation
import CoreGraphics
import AppKit

enum SessionState: String {
    case locked   = "已锁屏"
    case unlocked = "已解锁"
    case unknown  = "未知"
}

final class SessionMonitor {

    static let shared = SessionMonitor()

    private(set) var state: SessionState = .unknown

    /// 状态变化（含首次）
    var onChange: ((SessionState) -> Void)?
    /// 刚刚锁屏
    var onLock: (() -> Void)?
    /// 刚刚解锁
    var onUnlock: (() -> Void)?

    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []

    private init() {}

    // MARK: - 静态查询

    static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static var isOnConsole: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["kCGSSessionOnConsoleKey"] as? Bool) ?? false
    }

    static var displayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 唤醒显示器（黑屏时锁屏界面不接收合成键盘事件）
    static func wakeDisplay() {
        guard displayAsleep else { return }
        Log.info("显示器休眠，发送唤醒")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "1"]
        try? p.run()
    }

    // MARK: - 生命周期

    func start() {
        // 初始状态静默设置，不触发回调
        state = SessionMonitor.screenIsLocked ? .locked : .unlocked
        Log.info("会话初始状态: \(state.rawValue)（屏幕锁=\(SessionMonitor.screenIsLocked)）")

        let center = DistributedNotificationCenter.default()
        for (name, isLock) in [("com.apple.screenIsLocked", true),
                               ("com.apple.screenIsUnlocked", false)] {
            let t = center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Log.debug("收到分布式通知 \(name)")
                self?.apply(locked: isLock)
            }
            tokens.append(t)
        }

        // 通知不一定可靠，500ms 轮询兜底
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let center = DistributedNotificationCenter.default()
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    // MARK: - 内部

    private func refresh() {
        apply(locked: SessionMonitor.screenIsLocked)
    }

    private func apply(locked: Bool) {
        let new: SessionState = locked ? .locked : .unlocked
        guard new != state else { return }
        let old = state
        state = new
        Log.info("会话状态: \(old.rawValue) → \(new.rawValue)")

        if new == .locked { onLock?() }
        if old == .locked && new == .unlocked { onUnlock?() }
        onChange?(new)
    }
}
