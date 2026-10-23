
// 自更新安装：把自己复制到 /Applications（App 自身不受 DSH 沙盒限制）
if CommandLine.arguments.contains("--install-to-applications") {
    let src = Bundle.main.bundleURL
    let dst = URL(fileURLWithPath: "/Applications/NearbyPass.app")
    let fm = FileManager.default
    try? fm.removeItem(at: dst)
    do {
        try fm.copyItem(at: src, to: dst)
        print("已安装到 \(dst.path)")
        exit(0)
    } catch {
        print("安装失败: \(error)")
        exit(1)
    }
}

// main.swift — 入口
import AppKit

// MARK: - 单实例锁
let supportDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/NearbyPass", isDirectory: true)
try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

let lockURL = supportDir.appendingPathComponent("nearbypass.lock")
let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 {
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write(
            "NearbyPass 已在运行，本实例退出。\n".data(using: .utf8)!
        )
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
