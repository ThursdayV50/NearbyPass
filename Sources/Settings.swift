// Settings.swift — 用户配置（UserDefaults）
import Foundation

final class Settings {
    static let shared = Settings()

    private let d = UserDefaults.standard

    /// 阈值允许的范围（dBm，越接近 0 越强）
    static let thresholdMin = -95
    static let thresholdMax = -40
    /// 两个阈值之间至少保留的死区，防止互相追尾
    static let minHysteresis = 5

    private enum K {
        static let unlockThreshold      = "unlockThreshold"
        static let lockThreshold        = "lockThreshold"
        static let autoUnlockEnabled    = "autoUnlockEnabled"
        static let autoLockEnabled      = "autoLockEnabled"
        static let authFillEnabled      = "authFillEnabled"
        static let autoLockDelay        = "autoLockDelay"
        static let authCooldown         = "authCooldown"
        static let trustedDeviceIDs     = "trustedDeviceIDs"
        static let primaryDeviceID      = "primaryDeviceID"
        static let paused               = "paused"
        static let hasCompletedOnboard  = "hasCompletedOnboard"
        static let deviceAliases        = "deviceAliases"
        static let learnedNames         = "learnedNames"
        static let showInMenuBar        = "showInMenuBar"
    }

    private init() {
        d.register(defaults: [
            K.unlockThreshold: -60,
            K.lockThreshold: -85,
            K.autoUnlockEnabled: true,
            K.autoLockEnabled: true,
            K.authFillEnabled: true,
            K.autoLockDelay: 45.0,
            K.authCooldown: 15.0,
            K.trustedDeviceIDs: [String](),
            K.paused: false,
            K.hasCompletedOnboard: false
        ])
    }

    // MARK: - 双阈值

    /// 解锁强度：信号 ≥ 此值才允许自动解锁（默认 -60）
    var unlockThreshold: Int {
        get { d.integer(forKey: K.unlockThreshold) }
        set {
            let v = min(max(newValue, Settings.thresholdMin), Settings.thresholdMax)
            d.set(v, forKey: K.unlockThreshold)
            // 解锁阈值必须严格强于锁屏阈值
            if lockThreshold > v - Settings.minHysteresis {
                d.set(max(Settings.thresholdMin, v - Settings.minHysteresis), forKey: K.lockThreshold)
            }
        }
    }

    /// 锁屏强度：信号 ≤ 此值持续一段时间才自动锁屏（默认 -85）
    var lockThreshold: Int {
        get { d.integer(forKey: K.lockThreshold) }
        set {
            let v = min(max(newValue, Settings.thresholdMin), Settings.thresholdMax)
            d.set(v, forKey: K.lockThreshold)
            if unlockThreshold < v + Settings.minHysteresis {
                d.set(min(Settings.thresholdMax, v + Settings.minHysteresis), forKey: K.unlockThreshold)
            }
        }
    }

    // MARK: - 开关

    var autoUnlockEnabled: Bool {
        get { d.bool(forKey: K.autoUnlockEnabled) }
        set { d.set(newValue, forKey: K.autoUnlockEnabled) }
    }

    var autoLockEnabled: Bool {
        get { d.bool(forKey: K.autoLockEnabled) }
        set { d.set(newValue, forKey: K.autoLockEnabled) }
    }

    var authFillEnabled: Bool {
        get { d.bool(forKey: K.authFillEnabled) }
        set { d.set(newValue, forKey: K.authFillEnabled) }
    }

    /// 全局暂停（菜单栏一键）
    /// 是否在菜单栏显示图标。关掉后后台功能照常，靠重新打开 App 进设置。
    var showInMenuBar: Bool {
        get {
            if UserDefaults.standard.object(forKey: K.showInMenuBar) == nil { return true }
            return UserDefaults.standard.bool(forKey: K.showInMenuBar)
        }
        set { UserDefaults.standard.set(newValue, forKey: K.showInMenuBar) }
    }

    var paused: Bool {
        get { d.bool(forKey: K.paused) }
        set { d.set(newValue, forKey: K.paused) }
    }

    // MARK: - 时间参数

    /// 远离后多久锁屏（秒），15–300
    var autoLockDelay: Double {
        get { max(15, min(300, d.double(forKey: K.autoLockDelay))) }
        set { d.set(max(15, min(300, newValue)), forKey: K.autoLockDelay) }
    }

    /// 授权弹窗填充的冷却（秒）
    var authCooldown: Double {
        get { max(3, min(120, d.double(forKey: K.authCooldown))) }
        set { d.set(max(3, min(120, newValue)), forKey: K.authCooldown) }
    }

    // MARK: - 设备

    /// 信任设备（CBPeripheral.identifier.uuidString）—— 任一在场即视为"人在"
    var trustedDeviceIDs: [String] {
        get { d.stringArray(forKey: K.trustedDeviceIDs) ?? [] }
        set { d.set(newValue, forKey: K.trustedDeviceIDs) }
    }

    /// 解锁主设备 —— 只有它能触发自动解锁
    var primaryDeviceID: String? {
        get { d.string(forKey: K.primaryDeviceID) }
        set { d.set(newValue, forKey: K.primaryDeviceID) }
    }

    /// 用户给设备起的名字（key = CBPeripheral UUID）
    /// 设备自己广播过的好名字（安卓会周期性轮换成随机串，所以记下来，别丢）
    var learnedNames: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: K.learnedNames) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: K.learnedNames) }
    }

    func learnedName(_ deviceID: String) -> String? { learnedNames[deviceID] }

    func setLearnedName(_ deviceID: String, _ name: String) {
        guard !name.isEmpty else { return }
        var d = learnedNames
        if d[deviceID] == name { return }
        d[deviceID] = name
        learnedNames = d
    }

    var deviceAliases: [String: String] {
        get { d.dictionary(forKey: K.deviceAliases) as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: K.deviceAliases) }
    }

    func alias(_ deviceID: String) -> String? {
        let a = deviceAliases[deviceID]
        return (a?.isEmpty == false) ? a : nil
    }

    func setAlias(_ deviceID: String, _ name: String?) {
        var m = deviceAliases
        if let n = name, !n.isEmpty { m[deviceID] = n } else { m.removeValue(forKey: deviceID) }
        deviceAliases = m
    }

    var hasCompletedOnboard: Bool {
        get { d.bool(forKey: K.hasCompletedOnboard) }
        set { d.set(newValue, forKey: K.hasCompletedOnboard) }
    }

    // MARK: - 辅助

    func isTrusted(_ deviceID: String) -> Bool {
        trustedDeviceIDs.contains(deviceID)
    }

    func setTrusted(_ deviceID: String, _ trusted: Bool) {
        var list = trustedDeviceIDs
        if trusted {
            if !list.contains(deviceID) { list.append(deviceID) }
        } else {
            list.removeAll { $0 == deviceID }
            if primaryDeviceID == deviceID { primaryDeviceID = list.first }
        }
        trustedDeviceIDs = list
    }

    var isConfigured: Bool {
        !trustedDeviceIDs.isEmpty && primaryDeviceID != nil
    }

    /// 早期版本会把 GATT 读到的型号（如 "iPhone18,3 · Apple Inc."）自动写成别名，
    /// 那样会盖住用户自己在设备上起的广播名。这里清一次。
    func migrateAutoAliasesIfNeeded() {
        let key = "aliasMigrationV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard let re = try? NSRegularExpression(pattern: "^[A-Za-z0-9_,.]+ · .+$") else { return }
        var dict = deviceAliases
        var changed = false
        for (id, name) in dict {
            if re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                dict.removeValue(forKey: id)
                changed = true
                Log.info("清理自动生成的后台设备名：\(name)")
            }
        }
        if changed { deviceAliases = dict }
    }
}
