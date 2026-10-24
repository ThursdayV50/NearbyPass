import Foundation

/// 设备类别。
///
/// 在场判定的前提是「设备跟着人走」。鼠标、键盘、台灯、插座这类设备不该进选择列表：
/// 键盘永远躺在桌上 = 永远在场，F3 于是永远不锁屏；邻居的插座广播也不该影响你的状态。
/// 所以这里按「能不能随身」把扫描到的设备分成四类，列表默认只给随身的那一类。
enum DeviceKind: String, Equatable {
    case wearable   = "随身"
    case peripheral = "外设"
    case appliance  = "家居"
    case unknown    = "其他"

    /// 是否适合用来判定在场
    var isPresenceCapable: Bool { self == .wearable }

    var badge: String { rawValue }
}

enum DeviceClassifier {

    // BLE 标准服务号，比较的是 CBUUID.uuidString.lowercased()
    // 16 位服务号在 CoreBluetooth 里就是 "1812" 这种短格式。
    private static let hidServices: Set<String> = ["1812"]
    private static let audioServices: Set<String> = [
        "1108", "110a", "110b", "110c", "110d", "110e",
        "1112", "111e", "111f", "1844", "1845",
    ]
    private static let bodyServices: Set<String> = [
        "1809",  // Health Thermometer
        "180d",  // Heart Rate
        "1813",  // Phone Alert Status
        "1814",  // Blood Pressure
        "1816",  // Cycling Speed and Cadence
        "1826",  // Fitness Machine
        "fe95",  // Xiaomi MiBeacon
        "fe9f",  // Xiaomi
    ]

    private static let wearableWords: [String] = [
        "band", "watch", "手环", "手表", "腕表", "手錶", "手机",
        "phone", "iphone", "android", "xiaomi", "redmi", "poco",
        "huawei", "honor", "galaxy", "pixel", "oneplus", "oppo", "vivo",
        "realme", "meizu", "amazfit", "garmin", "fitbit", "keepb",
        "smart band", "miband",
    ]

    private static let peripheralWords: [String] = [
        "mouse", "keyboard", "trackpad", "mago", "mchose", "logitech",
        "罗技", "razer", "雷蛇", "keychron", "妙控", "magic keyboard",
        "magic mouse", "airpods", "buds", "headset", "headphone", "耳机",
    ]

    private static let applianceWords: [String] = [
        "light", "lamp", "bulb", "plug", "socket", "switch", "sensor",
        "scale", "midea", "美的", "philips", "飞利浦", "lemesh", "mijia",
        "米家", "esp32", "magcooler", "u-ac", "znkzq", "sw0a04", "demo",
        "aircon", "空调", "灯泡", "插座", "体脂",
    ]

    /// 分类。判定顺序：服务号（最可靠）→ 名字关键词 → 未知。
    static func classify(name: String, serviceUUIDs: Set<String>) -> DeviceKind {
        let n = name.lowercased()
        let svc = Set(serviceUUIDs.map { $0.lowercased() })

        if !svc.isDisjoint(with: hidServices) { return .peripheral }
        if !svc.isDisjoint(with: audioServices) { return .peripheral }
        if !svc.isDisjoint(with: bodyServices) { return .wearable }

        if contains(n, peripheralWords) { return .peripheral }
        if contains(n, applianceWords) { return .appliance }
        if contains(n, wearableWords) { return .wearable }
        return .unknown
    }

    private static func contains(_ name: String, _ words: [String]) -> Bool {
        for w in words where name.contains(w) { return true }
        return false
    }
}
