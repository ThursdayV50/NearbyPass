// sysnames.swift — 对照系统蓝牙列表，找 CBPeripheral ↔ 系统名字 的关联通道
// 用法: sysnames [扫描秒数，默认 20]
// 输出: IOBluetooth 配对表 / CoreBluetooth 扫描明细 / CBPeripheral 可用方法 / system_profiler 列表
import Foundation
import CoreBluetooth
import IOBluetooth
import ObjectiveC

let scanSeconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 20.0) : 20.0

// ---------- A. IOBluetooth 配对设备（名字+MAC） ----------
print("== A. IOBluetoothDevice.pairedDevices ==")
if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
    for d in paired {
        print("  PAIRED name=\(d.name ?? "?") addr=\(d.addressString ?? "?") connected=\(d.isConnected())")
    }
    if paired.isEmpty { print("  (空)") }
} else {
    print("  (取不到)")
}

// ---------- B. CBPeripheral 上有没有地址类的私有方法 ----------
print("== B. CBPeripheral/CBPeer 方法中含 address/addr/mac 的 selector ==")
func dumpSelectors(_ cls: AnyClass?) {
    guard let cls = cls else { return }
    var count: UInt32 = 0
    if let list = class_copyMethodList(cls, &count) {
        for i in 0..<Int(count) {
            let sel = method_getName(list[i])
            let n = NSStringFromSelector(sel).lowercased()
            if n.contains("address") || n.contains("addr") || n.contains("mac") {
                print("  \(NSStringFromClass(cls)) -> \(NSStringFromSelector(sel))")
            }
        }
        free(UnsafeMutableRawPointer(list))
    }
}
dumpSelectors(NSClassFromString("CBPeripheral"))
dumpSelectors(NSClassFromString("CBPeer"))
dumpSelectors(NSClassFromString("CBDevice"))   // macOS 13+ 有 CBDevice，可能带地址
dumpSelectors(NSClassFromString("CBClassicPeer"))

// ---------- C. CoreBluetooth 扫描 ----------
final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen = 0
    func start() {
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        print("== C. CoreBluetooth 扫描 (state=\(c.state.rawValue)) ==")
        guard c.state == .poweredOn else {
            print("  蓝牙未就绪: \(c.state.rawValue) (2=unauthorized 4=poweredOff)")
            done = true
            return
        }
        c.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        seen += 1
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let uuids = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
            .map { $0.uuidString.lowercased() }
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let mfgHex = mfg.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-"
        print("  DEV id=\(p.identifier.uuidString) periph.name=\(p.name ?? "nil") advName=\(advName ?? "nil") rssi=\(RSSI) svc=[\(uuids.joined(separator: ","))] mfg=\(mfgHex)")
    }
}

// ---------- D. system_profiler 系统列表 ----------
func systemList() {
    print("== D. system_profiler SPBluetoothDataType ==")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPBluetoothDataType", "-json"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let groups = obj["SPBluetoothDataType"] as? [[String: Any]],
          let first = groups.first else { print("  (解析失败)"); return }
    for key in ["device_connected", "device_not_connected"] {
        guard let arr = first[key] as? [[String: Any]] else { continue }
        for entry in arr {
            for (name, info) in entry {
                guard let info = info as? [String: Any] else { continue }
                print("  \(key): name=\(name) addr=\(info["device_address"] ?? "?") rssi=\(info["device_rssi"] ?? "-") minor=\(info["device_minorType"] ?? "-")")
            }
        }
    }
}

var done = false
let s = Scanner()
s.start()
systemList()
RunLoop.main.run(until: Date().addingTimeInterval(scanSeconds))
print("== 结束，共发现 \(s.seen) 台 ==")
