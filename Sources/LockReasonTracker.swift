// LockReasonTracker.swift — 判定这次锁屏是"人走了"还是"人还在但主动锁的"
//
// 解决的问题：用户主动锁屏但手机就放在桌上，如果无脑自动解锁，
// 等于把锁屏功能废掉。规则：
//   · 锁屏瞬间「最近 10 秒内设备在场」→ .manual（不自动解锁）
//   · 否则 → .auto（可以自动解锁）
//   · .manual 必须等到设备「先离开、再回来」才解除
import Foundation

enum LockReason: String {
    case auto   = "人已离开"
    case manual = "人还在（主动锁屏）"
    case none   = "无"
}

final class LockReasonTracker {

    static let shared = LockReasonTracker()

    private(set) var reason: LockReason = .none

    /// 最近 15 秒的在场采样
    private var samples: [(time: Date, state: PresenceState)] = []

    /// AutoLockHandler 主动锁屏时置位，锁屏判定时直接用 .auto
    private var selfLockRequested = false

    /// .manual 状态下是否已经观察到设备离开
    private var sawAbsentSinceManual = false

    private init() {}

    /// 当前是否允许自动解锁
    var canAutoUnlock: Bool {
        reason == .auto || reason == .none
    }

    // MARK: - 事件

    func onPresenceChange(_ state: PresenceState) {
        let now = Date()
        samples.append((now, state))
        samples.removeAll { now.timeIntervalSince($0.time) > 15 }

        guard reason == .manual else { return }
        if state == .absent {
            if !sawAbsentSinceManual {
                sawAbsentSinceManual = true
                Log.debug("手动锁屏期间检测到设备离开")
            }
        } else if state == .present && sawAbsentSinceManual {
            reason = .auto
            sawAbsentSinceManual = false
            Log.info("设备先离开又回来，解除手动锁屏保护")
        }
    }

    /// 标记"这次锁屏是 NearbyPass 自己触发的"
    func markSelfLock() {
        selfLockRequested = true
        Log.debug("已标记自主锁屏")
    }

    /// 锁屏瞬间调用
    func evaluateOnLock(nowPresence: PresenceState) {
        if selfLockRequested {
            selfLockRequested = false
            reason = .auto
            Log.info("锁屏原因: \(reason.rawValue)（由 NearbyPass 触发）")
            return
        }

        let cutoff = Date().addingTimeInterval(-10)
        let seenRecent = samples
            .filter { $0.time >= cutoff }
            .map { $0.state }
        let wasPresent = seenRecent.contains(.present) || nowPresence == .present

        reason = wasPresent ? .manual : .auto
        sawAbsentSinceManual = false
        Log.info("锁屏原因: \(reason.rawValue)（锁屏前 10 秒采样: \(seenRecent.map { $0.rawValue }.joined(separator: ","))）")
    }

    /// 解锁成功后清空
    func reset() {
        reason = .none
        sawAbsentSinceManual = false
        selfLockRequested = false
        samples.removeAll()
    }
}
