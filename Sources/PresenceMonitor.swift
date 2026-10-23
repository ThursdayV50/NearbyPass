// PresenceMonitor.swift — 蓝牙在场引擎
//
// 常驻扫描 BLE 广播，维护每个设备的实时 RSSI（EMA 平滑 + 60 秒历史），
// 并根据双阈值（解锁强度 / 锁屏强度）输出在场状态。
//
// 设备名解析优先级：用户别名 > GATT Device Name(0x2A00) > 广播名（若不像随机串）> "未知设备"
// 很多 Android 设备（例如小米）广播的是随机串（NGMeCvX2Lpr6xumgxKmaOTmRY），
// 必须在连上之后读 GATT 0x2A00 才能拿到真实机名。
import Foundation
import CoreBluetooth

/// 单个设备的实时读数
struct DeviceReading {
    let id: String                 // CBPeripheral.identifier.uuidString
    var name: String               // 广播里带来的名字（可能是随机串）
    var rawRSSI: Int               // 最近一次原始 RSSI
    var emaRSSI: Double            // 指数滑动平均
    var lastSeen: Date
    var history: [Int?]            // 最近 60 秒，每秒一个采样；nil = 该秒无信号
}

/// 在场状态（四态，含死区）
enum PresenceState: String {
    case present  = "在场"
    case deadzone = "过渡"
    case absent   = "离开"
    case unknown  = "未知"

    var symbol: String {
        switch self {
        // 用 Geometric Shapes 区的实心圆，不用 emoji：
        // 任何 emoji 都会让 CoreText 把 180MB 的 Apple Color Emoji 字体私有化进本进程。
        case .present:  return "●"
        case .deadzone: return "●"
        case .absent:   return "●"
        case .unknown:  return "●"
        }
    }
}

final class PresenceMonitor: NSObject {

    static let shared = PresenceMonitor()

    /// EMA 平滑系数
    private let alpha = 0.3
    /// 设备行显示「实时 dBm」和「N 秒前」的窗口。
    /// 手机/手环的 BLE 广播间隔常有 10–20 秒（iPhone 的 Continuity 广播尤其稀疏），
    /// 取太短会让界面上数字不停闪成「—」。
    private let freshWindow: TimeInterval = 20
    /// 判定在场 / 离开所用的「最近广播」窗口。只要窗口内有过广告，
    /// 就用平滑后的 RSSI 判强弱；窗口远宽于广播间隔，状态便不会在两包之间来回跳。
    private let presenceWindow: TimeInterval = 45
    /// 超过这个秒数完全没收到任何广播，判定为离开（关机 / 走远到扫不到）。
    let staleThreshold: TimeInterval = 60

    /// 启动/新勾选设备后的「宽限期」：这段时间内没见过广播仍算「未知」，
    /// 给蓝牙扫描留出时间，避免一启动就判离开而触发锁屏。
    /// 超过宽限期仍没见过 → 判「离开」，否则 App 重启后只要设备一直不广播，
    /// 状态就会永远停在「未知」，自动锁屏彻底失效。
    private let unknownGracePeriod: TimeInterval = 30
    private let startedAt = Date()
    private let historyLength = 60

    private var central: CBCentralManager!
    private var devices: [String: DeviceReading] = [:]
    private var sampleTimer: Timer?
    private var tickCount = 0

    // 名字解析
    private var peripherals: [String: CBPeripheral] = [:]
    private var gattNames: [String: String] = [:]      // 读到过的不易失名字
    private var resolving: Set<String> = []
    private var gattParts: [String: [String: String]] = [:]
    private var gattReads: [String: Int] = [:]
    private var gattSvcPending: [String: Int] = [:]            // 正在连接读取
    private var nameFailed: Set<String> = []           // 读失败过的不再自动重试

    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var presence: PresenceState = .unknown

    /// 设备表或 RSSI 发生变化（主线程）
    var onUpdate: (() -> Void)?
    /// 在场状态发生跃变（主线程）
    var onPresenceChange: ((PresenceState) -> Void)?

    private override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleTick()
        }
        RunLoop.main.add(t, forMode: .common)
        sampleTimer = t
    }

    // MARK: - 名字

    /// 广播名是否像随机串（长度很长 / 无空格无分隔的混合大小写）
    static func looksRandom(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s == "未知设备" { return true }
        let hasCJK = s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        if hasCJK { return false }
        if s.contains(" ") || s.contains("-") || s.contains("_") || s.contains(".") { return false }
        // 纯字母数字且长度 ≥ 16，基本就是随机串
        let alnum = s.allSatisfy { $0.isLetter || $0.isNumber }
        if alnum && s.count >= 16 { return true }
        return false
    }

    /// 界面上应显示的名字。识别不出真名时带上 identifier 前缀，方便区分多个"未知设备"
    func displayName(_ id: String) -> String {
        // 优先级：本 App 里手动改的名 > 设备自己广播的名字 > GATT 读到的型号
        // 广播名是用户在设备设置里起的（比如把 iPhone 改名成 xiaomi17），
        // 比 GATT 的 "iPhone18,3 · Apple Inc." 更贴近用户认知，所以排在前面。
        if let a = Settings.shared.alias(id) { return a }
        if let d = devices[id], !Self.looksRandom(d.name) { return d.name }
        if let g = gattNames[id] { return g }
        return "未知设备 · " + String(id.prefix(8))
    }

    /// 名字是否还是占位（用于界面配色与"命名"按钮）
    func isUnknownName(_ id: String) -> Bool {
        if Settings.shared.alias(id) != nil { return false }
        if let d = devices[id], !Self.looksRandom(d.name) { return false }
        if gattNames[id] != nil { return false }
        return true
    }

    /// 名字是否还需要解析（用来在界面上显示"识别中…"）
    func isResolvingName(_ id: String) -> Bool { resolving.contains(id) }

    /// 名字是否是真正可读的名字（而不是占位）
    func hasRealName(_ id: String) -> Bool { !isUnknownName(id) }

    /// 主动连上去读 GATT Device Name。只在需要时调用一次，读完立刻断开。
    func requestRealName(_ id: String) {
        guard bluetoothState == .poweredOn else { return }
        guard gattNames[id] == nil, Settings.shared.alias(id) == nil else { return }
        guard !resolving.contains(id), !nameFailed.contains(id) else { return }
        // 同时只连一个：连接期间扫描会受影响，而且多数设备本来就不让随便连
        guard resolving.isEmpty else { return }
        guard let p = peripherals[id] else { return }

        resolving.insert(id)
        onUpdate?()
        p.delegate = self
        central.connect(p, options: nil)

        // 6 秒超时
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self = self, self.resolving.contains(id) else { return }
            self.resolving.remove(id)
            self.nameFailed.insert(id)
            self.central.cancelPeripheralConnection(p)
            Log.debug("读取设备名超时: \(id.prefix(8))")
            self.onUpdate?()
        }
    }

    // MARK: - 对外查询

    /// 所有扫到过的设备，按"最近出现 + 信号强弱"排序
    func allDevices() -> [DeviceReading] {
        devices.values.sorted { a, b in
            let af = Date().timeIntervalSince(a.lastSeen) < freshWindow
            let bf = Date().timeIntervalSince(b.lastSeen) < freshWindow
            if af != bf { return af }
            return a.emaRSSI > b.emaRSSI
        }
    }

    func device(_ id: String) -> DeviceReading? { devices[id] }

    /// 设备当前是否新鲜（5 秒内有过广播）
    func isFresh(_ id: String) -> Bool {
        guard let d = devices[id] else { return false }
        return Date().timeIntervalSince(d.lastSeen) < freshWindow
    }

    /// 某设备当前可用的平滑 RSSI；不新鲜则返回 nil
    func liveRSSI(_ id: String) -> Int? {
        guard let d = devices[id], isFresh(id) else { return nil }
        return Int(d.emaRSSI.rounded())
    }

    /// 信任设备中最强的实时 RSSI（用于菜单栏显示）
    func bestTrustedRSSI() -> Int? {
        let trusted = Settings.shared.trustedDeviceIDs
        var best: Int? = nil
        for id in trusted {
            if let v = liveRSSI(id) { best = max(best ?? v, v) }
        }
        return best
    }

    var isConfigured: Bool { !Settings.shared.trustedDeviceIDs.isEmpty }

    // MARK: - 采样与判定

    private func sampleTick() {
        let now = Date()
        let trustedNow = Set(Settings.shared.trustedDeviceIDs)
        for (id, var d) in devices {
            let age = now.timeIntervalSince(d.lastSeen)
            // 长时间没广播、又不是信任设备 → 直接从列表里移除。
            // 否则关掉手机蓝牙后，那个旧信号会一直挂在列表上误导人。
            if age > 150, !trustedNow.contains(id) {
                devices.removeValue(forKey: id)
                continue
            }
            let fresh = age < freshWindow
            d.history.append(fresh ? Int(d.emaRSSI.rounded()) : nil)
            if d.history.count > historyLength {
                d.history.removeFirst(d.history.count - historyLength)
            }
            devices[id] = d
        }
        recomputePresence()

        // 锁屏时每 15 秒打一次心跳，方便排查锁屏后蓝牙是否还在采样；
        // 平时 5 分钟一次，避免日志被刷爆
        let locked = SessionMonitor.screenIsLocked
        if tickCount % (locked ? 15 : 300) == 0 {
            let sid = Settings.shared.primaryDeviceID ?? Settings.shared.trustedDeviceIDs.first
            if let sid, let d = devices[sid] {
                let age = now.timeIntervalSince(d.lastSeen)
                Log.debug(String(format: "心跳 %@ %.0f dBm，%@秒前收到广播",
                                  String(sid.prefix(8)), d.emaRSSI, age < 1 ? "0" : String(Int(age))))
            } else {
                Log.debug("心跳：主设备没有任何广播数据")
            }
        }
        tickCount += 1

        onUpdate?()
    }

    private func recomputePresence() {
        let s = Settings.shared

        guard bluetoothState == .poweredOn else {
            setPresence(.unknown)
            return
        }
        let trusted = s.trustedDeviceIDs
        guard !trusted.isEmpty else {
            setPresence(.unknown)
            return
        }

        let now = Date()
        var bestEMA: Double? = nil
        var mostRecentAge: TimeInterval = .infinity

        for id in trusted {
            guard let d = devices[id] else { continue }
            let age = now.timeIntervalSince(d.lastSeen)
            mostRecentAge = min(mostRecentAge, age)
            if age < presenceWindow {
                bestEMA = max(bestEMA ?? -999, d.emaRSSI)
            }
        }

        if let ema = bestEMA {
            let enter = Double(s.unlockThreshold)
            let exit = Double(s.lockThreshold)
            // 迟滞带：已经处在某一侧时允许 5dBm 的回退余量。
            // 否则信号在阈值附近 ±3dBm 的自然波动会让状态每秒来回跳，
            // 进而让「自动锁屏」「授权弹窗填写」随机触发。
            let h = Double(Settings.minHysteresis)

            var next: PresenceState
            if ema >= enter {
                next = .present
            } else if ema <= exit {
                next = .absent
            } else if presence == .present && ema >= enter - h {
                next = .present          // 仍在迟滞带内，保持「在场」
            } else if presence == .absent && ema <= exit + h {
                next = .absent           // 仍在迟滞带内，保持「离开」
            } else {
                next = .deadzone
            }
            setPresence(next)
            return
        }

        // 没有任何新鲜读数
        // 从没见过任何信任设备的广播（刚启动 / 刚勾选）→ 未知，而不是「离开」，
        // 否则每次启动都会立刻触发一次自动锁屏倒计时。
        if mostRecentAge == .infinity {
            if Date().timeIntervalSince(startedAt) < unknownGracePeriod {
                setPresence(.unknown)
            } else {
                setPresence(.absent)
            }
            return
        }
        if mostRecentAge >= staleThreshold {
            setPresence(.absent)
        }
        // 否则是短暂丢失，保持上一次状态，避免抖动
    }

    private func setPresence(_ p: PresenceState) {
        guard p != presence else { return }
        let old = presence
        presence = p
        Log.info("在场状态: \(old.rawValue) → \(p.rawValue)\(bestTrustedRSSI().map { " @\($0)dBm" } ?? "")")
        onPresenceChange?(p)
    }

    // MARK: - 手动重扫

    /// 清空设备表并重启扫描（设置界面上的「重新扫描」）
    func rescan() {
        devices.removeAll()
        peripherals.removeAll()
        onUpdate?()
        guard bluetoothState == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        Log.info("已清空设备表并重新开始扫描")
    }
}

// MARK: - CBCentralManagerDelegate

extension PresenceMonitor: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        switch central.state {
        case .poweredOn:
            Log.info("蓝牙已就绪，开始扫描")
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff:
            Log.warn("蓝牙已关闭")
            setPresence(.unknown)
        case .unauthorized:
            Log.error("蓝牙未授权")
            setPresence(.unknown)
        case .unsupported:
            Log.error("本机不支持蓝牙")
            setPresence(.unknown)
        default:
            Log.info("蓝牙状态: \(central.state.rawValue)")
        }
        onUpdate?()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        // 127 是 CoreBluetooth 表示"不可用"的哨兵值
        guard rssi != 127, rssi < 0 else { return }

        let id = peripheral.identifier.uuidString
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (advName?.isEmpty == false ? advName! : (peripheral.name ?? "未知设备"))

        peripherals[id] = peripheral

        let now = Date()
        if var existing = devices[id] {
            existing.rawRSSI = rssi
            existing.emaRSSI = alpha * Double(rssi) + (1 - alpha) * existing.emaRSSI
            existing.lastSeen = now
            // 设备改名后广播名会变，只要新名字不是随机串就跟着更新
            if name != "未知设备", !Self.looksRandom(name) { existing.name = name }
            devices[id] = existing
        } else {
            devices[id] = DeviceReading(
                id: id,
                name: name,
                rawRSSI: rssi,
                emaRSSI: Double(rssi),
                lastSeen: now,
                history: Array(repeating: nil, count: historyLength)
            )
            Log.debug("发现新设备 \(name) (\(id.prefix(8))) rssi=\(rssi)")
        }

        // 新设备出现可能立刻改变在场判定
        recomputePresence()
        onUpdate?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // 不要只找 1800：Android / iOS 设备常常没有 GAP 服务，
        // 但几乎都会暴露 Device Information (180A) 的 Model Number / Manufacturer。
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier.uuidString
        resolving.remove(id)
        nameFailed.insert(id)
        onUpdate?()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let id = peripheral.identifier.uuidString
        if resolving.remove(id) != nil { onUpdate?() }
    }
}

// MARK: - CBPeripheralDelegate（读 GAP Device Name / Device Information）

extension PresenceMonitor: CBPeripheralDelegate {

    private static let nameServices: Set<String> = ["1800", "180A", "180F"]
    private static let nameChars: Set<String> = [
        "2A00", "2A24", "2A25", "2A26", "2A27", "2A28", "2A29"
    ]

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier.uuidString
        let targets = (peripheral.services ?? []).filter {
            Self.nameServices.contains($0.uuid.uuidString.uppercased())
        }
        guard !targets.isEmpty else {
            finishName(id, peripheral: peripheral)
            return
        }
        gattSvcPending[id] = targets.count
        for s in targets { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let id = peripheral.identifier.uuidString
        for ch in service.characteristics ?? [] {
            let u = ch.uuid.uuidString.uppercased()
            guard Self.nameChars.contains(u), ch.properties.contains(.read) else { continue }
            gattReads[id, default: 0] += 1
            peripheral.readValue(for: ch)
        }
        let left = max(0, (gattSvcPending[id] ?? 1) - 1)
        gattSvcPending[id] = left
        if left == 0 && (gattReads[id] ?? 0) == 0 {
            finishName(id, peripheral: peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let id = peripheral.identifier.uuidString
        let u = characteristic.uuid.uuidString.uppercased()
        if let d = characteristic.value,
           let txt = String(data: d, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !txt.isEmpty {
            gattParts[id, default: [:]][u] = txt
        }
        let left = max(0, (gattReads[id] ?? 1) - 1)
        gattReads[id] = left
        if left == 0 { finishName(id, peripheral: peripheral) }
    }

    private func finishName(_ id: String, peripheral: CBPeripheral) {
        let parts = gattParts[id] ?? [:]
        var chosen: String?
        if let n = parts["2A00"], n.count > 1 { chosen = n }
        if chosen == nil {
            var bits: [String] = []
            if let m = parts["2A24"] { bits.append(m) }
            if let mf = parts["2A29"] { bits.append(mf) }
            if bits.isEmpty, let sn = parts["2A25"] { bits.append("SN " + sn) }
            if !bits.isEmpty { chosen = bits.joined(separator: " · ") }
        }
        if let name = chosen {
            gattNames[id] = name
            // 持久化：GATT 读到的型号名写入别名表，重启后不必再连一次。用户手动命名过的保持不动。
            if Settings.shared.alias(id) == nil {
                // 只放在内存里的 gattNames，不写进 Settings.alias ——
                // 那是给用户手动命名用的，自动填充会盖住设备自己广播的名字。
            }
            Log.info("识别设备: \(name) (\(id.prefix(8)))")
        } else {
            nameFailed.insert(id)
            Log.debug("设备未暴露名称特征: \(id.prefix(8))")
        }
        gattParts[id] = nil
        gattReads[id] = nil
        gattSvcPending[id] = nil
        resolving.remove(id)
        central.cancelPeripheralConnection(peripheral)
        onUpdate?()
    }
}
