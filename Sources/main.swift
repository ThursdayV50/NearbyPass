
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

// 调试：只查一次更新然后退出（不受单实例锁影响）
if CommandLine.arguments.contains("--check-update") {
    Task {
        let sim = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
        await Updater.shared.debugCheck(simulateVersion: sim)
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--force-install") {
    Updater.shared.debugForceInstall()
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--print-install-script") {
    Updater.shared.debugInstallScript()
    exit(0)
}

if CommandLine.arguments.contains("--download-and-verify") {
    Task {
        await Updater.shared.debugDownloadAndVerify()
        exit(0)
    }
    RunLoop.main.run()
}

// MARK: - 单实例锁
let supportDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/NearbyPass", isDirectory: true)
try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

let lockURL = supportDir.appendingPathComponent("nearbypass.lock")
let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
if lockFD >= 0 {
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.lcg.nearbypass.showSettings"), object: nil)
        usleep(150_000)
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
