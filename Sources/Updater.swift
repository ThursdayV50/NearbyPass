// Updater.swift — 自动检查更新 + 应用内安装
//
// 没有用 Sparkle：我们是手工 swiftc 构建、没有 Xcode 工程，
// 嵌 framework 加 XPC 服务的代价太大。自己实现的流程：
//   查 GitHub Releases → 下载 dmg → 验签 → 交给一个游离脚本
//   等主进程退出后替换 /Applications 里的 App 并重新打开。

import AppKit
import Foundation
import Security

final class Updater {

    static let shared = Updater()

    struct Release {
        let version: String
        let dmg: URL
        let pageURL: URL
        let notes: String
    }

    enum State {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(self.state) } }
    }

    var onStateChange: ((State) -> Void)?

    private let repo = "ThursdayV50/NearbyPass"
    private let expectedCertLeaf = "77b8e60aac8b0186b70acca3ecab606a1c166128"
    private var checking = false
    private var timer: Timer?

    private init() {}

    // MARK: - 定时检查

    func startScheduling() {
        // 启动 10 秒后查一次，之后每 24 小时一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.check(silent: true)
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(silent: true)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - 检查

    func check(silent: Bool) {
        guard !checking else { return }
        checking = true
        state = .checking

        Task {
            defer { checking = false }
            do {
                let rel = try await fetchLatest()
                if Self.isNewer(rel.version, than: Self.currentVersion) {
                    state = .available(rel)
                    Log.info("发现新版本 \(rel.version)（当前 \(Self.currentVersion)）")
                    if silent {
                        Notifier.post(title: "NearbyPass \(rel.version) 可用",
                                      body: "打开设置或点菜单栏图标即可更新")
                    }
                } else {
                    state = .upToDate
                    Log.info("已是最新版本 \(Self.currentVersion)")
                    if !silent { Dialogs.info("已是最新版本", "当前 \(Self.currentVersion)") }
                }
            } catch {
                state = .failed(error.localizedDescription)
                Log.warn("检查更新失败: \(error.localizedDescription)")
                if !silent {
                    Dialogs.info("检查更新失败", error.localizedDescription)
                }
            }
        }
    }

    /// 不查 GitHub API（未认证的 60 次/小时太容易被限流），
    /// 直接跟随 releases/latest 的 302 跳转拿到 tag，再拼附件地址。
    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        req.setValue("NearbyPass/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let finalURL = resp.url?.absoluteString,
              let range = finalURL.range(of: "/releases/tag/") else {
            throw NSError(domain: "NearbyPass", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析最新版本地址"])
        }
        let tag = String(finalURL[range.upperBound...])
            .split(separator: "?").first.map(String.init) ?? ""
        var ver = tag
        if ver.hasPrefix("v") { ver.removeFirst() }
        guard !ver.isEmpty else {
            throw NSError(domain: "NearbyPass", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "版本号为空"])
        }

        let dmg = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/NearbyPass-\(ver).dmg")!
        let page = URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!

        // 确认附件真的存在，避免拿到 404 页面
        var head = URLRequest(url: dmg)
        head.httpMethod = "HEAD"
        head.setValue("NearbyPass/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (_, hresp) = try await URLSession.shared.data(for: head)
        let code = (hresp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw NSError(domain: "NearbyPass", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "该版本没有 NearbyPass-\(ver).dmg 附件（HTTP \(code)）"])
        }
        return Release(version: ver, dmg: dmg, pageURL: page, notes: "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - 交互式入口（菜单 / 设置页按钮）

    func checkInteractive() {
        var handled = false
        let prev = onStateChange
        onStateChange = { [weak self] st in
            prev?(st)
            guard let self, !handled else { return }
            switch st {
            case .upToDate:
                handled = true
                self.onStateChange = prev
                Dialogs.info("已是最新版本", "当前 \(Self.currentVersion)")
            case .available(let r):
                handled = true
                self.onStateChange = prev
                self.promptInstall(r)
            case .failed(let m):
                handled = true
                self.onStateChange = prev
                Dialogs.info("检查更新失败", m)
            default:
                break
            }
        }
        check(silent: false)
    }

    private func promptInstall(_ r: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "有新版本 \(r.version)"
        a.informativeText = "当前 \(Self.currentVersion)。下载后会自动安装并重启，不需要你手动替换。"
        a.addButton(withTitle: "下载并安装")
        a.addButton(withTitle: "稍后")
        a.addButton(withTitle: "查看发布说明")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            downloadAndInstall(r)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(r.pageURL)
        default:
            break
        }
    }

    // MARK: - 下载并安装

    func downloadAndInstall(_ rel: Release) {
        // 只有装在 /Applications 才能自我替换
        let installed = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard installed.path.hasPrefix("/Applications/") else {
            state = .failed("需要先安装到「应用程序」文件夹")
            Dialogs.info("无法就地更新",
                         "当前运行的是 \(installed.path)。\n把它拖到「应用程序」文件夹里再更新。")
            return
        }

        Task {
            do {
                let dmg = try await download(rel)
                guard try verify(dmg: dmg, expectVersion: rel.version) else {
                    state = .failed("下载的安装包校验失败")
                    Dialogs.info("更新已中止", "安装包签名或版本不对，已删除，未做任何改动。")
                    try? FileManager.default.removeItem(at: dmg)
                    return
                }
                state = .installing
                try launchInstaller(dmg: dmg)
                Log.info("更新脚本已启动，准备退出主进程")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSApp.terminate(nil)
                }
            } catch {
                state = .failed(error.localizedDescription)
                Log.error("更新失败: \(error.localizedDescription)")
            }
        }
    }

    private func download(_ rel: Release) async throws -> URL {
        state = .downloading(0)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NearbyPass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("NearbyPass-\(rel.version).dmg")
        try? FileManager.default.removeItem(at: dst)

        var req = URLRequest(url: rel.dmg)
        req.setValue("NearbyPass/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "NearbyPass", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "下载失败"])
        }
        try FileManager.default.moveItem(at: tmp, to: dst)
        state = .downloading(1.0)
        Log.info("已下载 \(dst.lastPathComponent)")
        return dst
    }

    /// 挂载，检查 bundle id、证书指纹、版本号
    private func verify(dmg: URL, expectVersion: String) throws -> Bool {
        let mnt = "/tmp/nearbypass_update_mnt"
        try? FileManager.default.removeItem(atPath: mnt)
        try? FileManager.default.createDirectory(atPath: mnt,
                                                 withIntermediateDirectories: true)

        guard run("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-nobrowse", "-readonly",
                   "-mountpoint", mnt, "-quiet"]) == 0 else { return false }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mnt, "-quiet"]) }

        let app = mnt + "/NearbyPass.app"
        guard FileManager.default.fileExists(atPath: app) else { return false }

        // 1) 签名有效
        guard run("/usr/bin/codesign", ["-v", "--strict", app]) == 0 else {
            Log.warn("更新校验：签名无效")
            return false
        }
        // 2) 身份对得上：读 designated requirement，比对 identifier + 证书指纹
        let req = capture("/usr/bin/codesign", ["-d", "-r-", app]) ?? ""
        guard req.contains("com.lcg.nearbypass"),
              req.contains(expectedCertLeaf) else {
            Log.warn("更新校验：签名身份不匹配 —— \(req)")
            return false
        }
        // 3) 版本号一致
        let plist = app + "/Contents/Info.plist"
        let v = capture("/usr/libexec/PlistBuddy",
                        ["-c", "Print :CFBundleShortVersionString", plist])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard v == expectVersion else {
            Log.warn("更新校验：版本号 \(v) ≠ \(expectVersion)")
            return false
        }
        Log.info("更新校验通过：\(v)")
        return true
    }

    // MARK: - 游离安装脚本

    private func launchInstaller(dmg: URL, dryRun: Bool = false) throws {
        let script = """
        #!/bin/bash
        # 等 NearbyPass 退出
        for i in $(seq 1 60); do
          pgrep -x NearbyPass >/dev/null || break
          sleep 0.5
        done
        sleep 0.5
        MNT="/tmp/nearbypass_update_mnt"
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null
        mkdir -p "$MNT"
        /usr/bin/hdiutil attach "\(dmg.path)" -nobrowse -readonly -mountpoint "$MNT" -quiet || exit 1
        BK="/tmp/NearbyPass.app.bak"
        rm -rf "$BK"
        if [ -d "/Applications/NearbyPass.app" ]; then
          mv "/Applications/NearbyPass.app" "$BK" || exit 1
        fi
        if /usr/bin/ditto "$MNT/NearbyPass.app" "/Applications/NearbyPass.app"; then
          rm -rf "$BK"
        else
          # 装失败就把旧的放回去，别让人没 App 用
          rm -rf "/Applications/NearbyPass.app"
          [ -d "$BK" ] && mv "$BK" "/Applications/NearbyPass.app"
        fi
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null
        /usr/bin/open -a "/Applications/NearbyPass.app"
        rm -f "\(dmg.path)"
        rm -f "$0"
        """
        let path = "/tmp/nearbypass-update-\(UUID().uuidString.prefix(8)).sh"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        if dryRun {
            let syntax = run("/bin/bash", ["-n", path])
            print("脚本语法检查: \(syntax == 0 ? "OK" : "FAIL")")
            print("---- 脚本正文 ----")
            print((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        _ = run("/bin/chmod", ["+x", path])

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path]
        try p.run()
    }

    /// 调试：把安装脚本写出来并做语法检查
    func debugInstallScript() {
        let dmg = URL(fileURLWithPath: "/tmp/fake.dmg")
        do {
            try launchInstaller(dmg: dmg, dryRun: true)
        } catch {
            print("失败: \(error.localizedDescription)")
        }
    }

    /// 供命令行调试：`NearbyPass --download-and-verify`
    func debugDownloadAndVerify() async {
        do {
            let r = try await fetchLatest()
            print("目标版本 \(r.version)，开始下载…")
            let dmg = try await download(r)
            print("已下载 \(dmg.path)  \(fileSize(dmg)) bytes")
            let ok = try verify(dmg: dmg, expectVersion: r.version)
            print(ok ? "✅ 验签通过" : "❌ 验签失败")
            try? FileManager.default.removeItem(at: dmg)
        } catch {
            print("失败: \(error.localizedDescription)")
        }
    }

    private func fileSize(_ u: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
    }

    /// 供命令行调试：`NearbyPass --check-update`
    func debugCheck() async {
        print("当前版本: \(Self.currentVersion)")
        do {
            let r = try await fetchLatest()
            print("最新版本: \(r.version)  dmg=\(r.dmg.lastPathComponent)")
            print(Self.isNewer(r.version, than: Self.currentVersion) ? "→ 有更新" : "→ 已是最新")
        } catch {
            print("失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 小工具

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch { return -1 }
    }

    private func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}
