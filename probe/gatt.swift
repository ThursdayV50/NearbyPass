// gatt.swift — 连上一个 BLE 设备，枚举全部服务/特征，读能读的值。
// 用法: gatt [名字片段或UUID前缀] [超时秒]
import Foundation
import CoreBluetooth

let needle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].lowercased() : ""
let timeout = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 20.0

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var found = false
    var done = false

    func start() {
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !found else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let id = p.identifier.uuidString
        let hay = (name + " " + id).lowercased()
        guard needle.isEmpty ? true : hay.contains(needle) else { return }
        found = true
        target = p
        c.stopScan()
        print("连接 \(name) [\(id)] rssi=\(RSSI)")
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("已连接，开始发现服务")
        p.delegate = self
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("连接失败: \(String(describing: error))")
        done = true
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { print("discoverServices 错误: \(e)") }
        let svcs = p.services ?? []
        print("服务数 = \(svcs.count)")
        for s in svcs { print("  S \(s.uuid)") }
        if svcs.isEmpty { done = true; return }
        for s in svcs { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("  S \(s.uuid)  C \(ch.uuid)  props=\(ch.properties.rawValue)")
            if ch.properties.contains(.read) { p.readValue(for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let d = ch.value, !d.isEmpty {
            let hex = d.map { String(format: "%02x", $0) }.joined()
            let txt = String(data: d, encoding: .utf8) ?? ""
            print("    值 \(ch.uuid) = \(txt.isEmpty ? "-" : txt)  [\(hex)]")
        }
    }
}

let p = Probe()
p.start()
let deadline = Date().addingTimeInterval(timeout)
while Date() < deadline && !p.done {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
if let t = p.target { p.central.cancelPeripheralConnection(t) }
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
print("结束")
