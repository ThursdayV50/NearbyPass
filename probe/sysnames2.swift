// sysnames2.swift — 验证 CBPeripheral.BDAddress 返回值 与 IOBluetoothDeviceInquiry 名字源
import Foundation
import CoreBluetooth
import IOBluetooth

final class Inquiry: NSObject, IOBluetoothDeviceInquiryDelegate {
    let inquiry = IOBluetoothDeviceInquiry()
    func start() {
        inquiry.delegate = self
        inquiry.updateNewDeviceNames = true
        inquiry.start()
    }
    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry) {}
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        print("  INQ name=\(device.name ?? "?") addr=\(device.addressString ?? "?")")
    }
    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: Error) {
        print("  INQ 结束 err=\(error)")
    }
}

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var reported = Set<String>()
    func start() {
        central = CBCentralManager(delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { print("BT state=\(c.state.rawValue)"); return }
        c.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = p.identifier.uuidString
        guard !reported.contains(id) else { return }
        reported.insert(id)
        // 私有 SPI：BDAddress
        var bd = "n/a"
        let sel = NSSelectorFromString("BDAddress")
        if p.responds(to: sel) {
            let unmanaged = p.perform(sel)
            if let obj = unmanaged?.takeUnretainedValue() {
                bd = String(describing: obj) + " (\(type(of: obj)))"
            } else { bd = "nil" }
        } else { bd = "selector 不存在" }
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        print("  DEV id=\(id) name=\(p.name ?? "nil") adv=\(advName ?? "nil") BDAddress=\(bd)")
    }
}

let s = Scanner(); s.start()
let inq = Inquiry()
print("== IOBluetoothDeviceInquiry ==")
inq.start()
print("== CoreBluetooth (BDAddress) ==")
RunLoop.main.run(until: Date().addingTimeInterval(15))
inq.inquiry.stop()
print("== 结束 ==")
