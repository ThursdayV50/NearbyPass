// AppModel.swift — SwiftUI 的数据桥
//
// 引擎是纯 AppKit/Foundation 的老代码，这里每秒取一次快照喂给 SwiftUI，
// 不侵入原有逻辑。

import SwiftUI
import AppKit
import Combine

struct DeviceVM: Identifiable, Equatable {
    let id: String
    var name: String
    var rssi: Int?
    var age: TimeInterval
    var trusted: Bool
    var primary: Bool
    var unknownName: Bool
    var resolving: Bool
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // 顶部
    @Published var presenceText: String = "未知"
    @Published var presenceDot: Color = .gray
    @Published var bestRSSI: Int? = nil
    @Published var paused = false

    // 信号
    @Published var history: [Int?] = Array(repeating: nil, count: 60)

    // 设备
    @Published var devices: [DeviceVM] = []
    @Published var trustedCount = 0

    // 阈值
    @Published var unlockThreshold = Settings.shared.unlockThreshold
    @Published var lockThreshold = Settings.shared.lockThreshold

    // 行为
    @Published var autoFill = Settings.shared.authFillEnabled
    @Published var autoUnlock = Settings.shared.autoUnlockEnabled
    @Published var autoLock = Settings.shared.autoLockEnabled
    @Published var cooldown: Double = Settings.shared.authCooldown
    @Published var delay: Double = Settings.shared.autoLockDelay

    // 权限 / 状态
    @Published var axTrusted = false
    @Published var hasPassword = false
    @Published var bluetoothOn = false

    private var timer: Timer?

    private init() {}

    func start() {
        refresh()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let s = Settings.shared
        let p = PresenceMonitor.shared

        presenceText = p.presence.rawValue
        presenceDot = Self.dot(for: p.presence)
        bestRSSI = p.bestTrustedRSSI()
        paused = s.paused
        bluetoothOn = (p.bluetoothState == .poweredOn)

        // 曲线：取主设备（没有就取最强信任设备）
        let mainID = s.primaryDeviceID ?? s.trustedDeviceIDs.first
        if let id = mainID, let d = p.device(id) {
            history = d.history
        } else {
            history = Array(repeating: nil, count: 60)
        }

        devices = p.allDevices().map { d in
            let age = Date().timeIntervalSince(d.lastSeen)
            let live = p.isFresh(d.id) ? d.rawRSSI : nil
            let shown: Int? = live ?? (age < p.staleThreshold ? Int(d.emaRSSI.rounded()) : nil)
            return DeviceVM(
                id: d.id,
                name: p.displayName(d.id),
                rssi: shown,
                age: age,
                trusted: s.isTrusted(d.id),
                primary: s.primaryDeviceID == d.id,
                unknownName: p.isUnknownName(d.id),
                resolving: p.isResolvingName(d.id)
            )
        }
        trustedCount = s.trustedDeviceIDs.count

        unlockThreshold = s.unlockThreshold
        lockThreshold = s.lockThreshold
        autoFill = s.authFillEnabled
        autoUnlock = s.autoUnlockEnabled
        autoLock = s.autoLockEnabled
        cooldown = s.authCooldown
        delay = s.autoLockDelay

        axTrusted = AX.isTrusted
        hasPassword = KeychainStore.shared.hasPassword()
    }

    private static func dot(for p: PresenceState) -> Color {
        switch p {
        case .present:  return Color(white: 0.92)
        case .deadzone: return Color(white: 0.62)
        case .absent:   return Color(white: 0.42)
        case .unknown:  return .gray
        }
    }

    // MARK: - 动作

    func toggleTrust(_ id: String) {
        let s = Settings.shared
        let next = !s.isTrusted(id)
        s.setTrusted(id, next)
        if next && s.primaryDeviceID == nil { s.primaryDeviceID = id }
        if next { PresenceMonitor.shared.requestRealName(id) }
        refresh()
    }

    func setPrimary(_ id: String) {
        Settings.shared.primaryDeviceID = id
        if !Settings.shared.isTrusted(id) { Settings.shared.setTrusted(id, true) }
        refresh()
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.setAlias(id, trimmed.isEmpty ? nil : trimmed)
        refresh()
    }

    func setThresholds(low: Int, high: Int) {
        let s = Settings.shared
        s.lockThreshold = low
        s.unlockThreshold = high
        refresh()
    }

    func setAutoFill(_ v: Bool) { Settings.shared.authFillEnabled = v; refresh() }
    func setAutoUnlock(_ v: Bool) { Settings.shared.autoUnlockEnabled = v; refresh() }
    func setAutoLock(_ v: Bool) { Settings.shared.autoLockEnabled = v; refresh() }
    func setCooldown(_ v: Double) { Settings.shared.authCooldown = v; refresh() }
    func setDelay(_ v: Double) { Settings.shared.autoLockDelay = v; refresh() }
    func setPaused(_ v: Bool) { Settings.shared.paused = v; refresh() }
    func rescan() { PresenceMonitor.shared.rescan(); refresh() }

    /// 现在这一刻如果锁屏，会不会自动解锁
    var unlockPrediction: (text: String, ok: Bool) {
        guard let best = bestRSSI else {
            return ("还没收到任何信任设备的信号", false)
        }
        if best >= unlockThreshold {
            return ("此刻若锁屏 → 会自动解锁（当前 \(best) dBm ≥ \(unlockThreshold)）", true)
        }
        return ("此刻若锁屏 → 不会自动解锁（当前 \(best) dBm < \(unlockThreshold)）", false)
    }
}
