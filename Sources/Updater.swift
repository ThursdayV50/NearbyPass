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
                }
            } catch {
                state = .failed(error.localizedDescription)
                Log.warn("检查更新失败: \(error.localizedDescription)")
            }
        }
    }

    /// 两条路：先问 API（准确、立即反映新发布），失败（限流/网络）再退回
    /// releases/latest 的 302 跳转。后者不走 API 配额，但 CDN 可能滞后几十分钟。
    private func fetchLatest() async throws -> Release {
        do {
            return try await apiRelease()
        } catch {
            let apiError = error.localizedDescription
            Log.warn("API 查询失败（\(apiError)），改用页面跳转方式")
            do {
                return try await atomRelease()
            } catch {
                let atomError = error.localizedDescription
                Log.warn("Atom 查询也失败（\(atomError)），最后试页面跳转")
                do {
                    return try await redirectRelease()
                } catch {
                    throw NSError(domain: "NearbyPass", code: 9,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "查询失败：\(apiError)；\(atomError)；\(error.localizedDescription)"])
                }
            }
        }
    }

    private func apiRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NearbyPass/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? -1
        guard code == 200 else {
            // 403 基本都是未认证配额用尽（60 次/小时）。把配额现场一起记下来，
            // 否则日志里只有一个「API 返回 403」，下次分不清是限流还是别的原因。
            var detail = ""
            if let h = http {
                let remaining = h.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "-"
                let limit = h.value(forHTTPHeaderField: "x-ratelimit-limit") ?? "-"
                let resource = h.value(forHTTPHeaderField: "x-ratelimit-resource") ?? "-"
                let retryAfter = h.value(forHTTPHeaderField: "retry-after") ?? "-"
                detail = "，配额 \(remaining)/\(limit) \(resource)，retry-after \(retryAfter)"
            }
            throw NSError(domain: "NearbyPass", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "API 返回 \(code)\(detail)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NearbyPass", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "返回内容无法解析"])
        }
        let tag = (json["tag_name"] as? String) ?? ""
        var ver = tag
        if ver.hasPrefix("v") { ver.removeFirst() }
        guard !ver.isEmpty else {
            throw NSError(domain: "NearbyPass", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "版本号为空"])
        }
        let page = URL(string: (json["html_url"] as? String) ?? "https://github.com/\(repo)")!

        // 附件名以 API 给的为准；找不到 .dmg 就按约定拼
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let dmgURL = assets.compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repo)/releases/download/\(tag)/NearbyPass-\(ver).dmg")!

        return Release(version: ver, dmg: dmgURL, pageURL: page,
                       notes: (json["notes"] as? String) ?? (json["body"] as? String) ?? "")
    }

    /// releases.atom 不走 API 配额，而且发布后立刻可见，是限流时的主力后备
    private func atomRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://github.com/\(repo)/releases.atom")!)
        req.setValue("NearbyPass/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let xml = String(data: data, encoding: .utf8),
              let entry = xml.range(of: "<entry>"),
              let rest = xml[entry.lowerBound...].range(of: "</entry>") else {
            throw NSError(domain: "NearbyPass", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Atom 内容异常"])
        }
        let block = String(xml[entry.lowerBound..<rest.upperBound])

        guard let hrefRange = block.range(of: "/releases/tag/") else {
            throw NSError(domain: "NearbyPass", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Atom 里没有版本链接"])
        }
        let tail = block[hrefRange.upperBound...]
        let tag = String(tail.prefix(while: { $0 != "\"" && $0 != "<" }))
        var ver = tag
        if ver.hasPrefix("v") { ver.removeFirst() }
        guard !ver.isEmpty else {
            throw NSError(domain: "NearbyPass", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "版本号为空"])
        }
        let dmg = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/NearbyPass-\(ver).dmg")!
        let page = URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!
        return Release(version: ver, dmg: dmg, pageURL: page, notes: Self.plainText(block))
    }

    private static func plainText(_ html: String) -> String {
        guard let c = html.range(of: "<content"),
              let gt = html[c.upperBound...].firstIndex(of: ">"),
              let end = html.range(of: "</content>") else { return "" }
        var t = String(html[html.index(after: gt)..<end.lowerBound])
        t = t.replacingOccurrences(of: "&lt;", with: "<")
             .replacingOccurrences(of: "&gt;", with: ">")
             .replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&quot;", with: "\"")
        // 去掉所有标签
        while let a = t.firstIndex(of: "<"), let b = t[a...].firstIndex(of: ">") {
            t.removeSubrange(a...b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func redirectRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        req.setValue("NearbyPass/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let finalURL = resp.url?.absoluteString,
              let range = finalURL.range(of: "/releases/tag/") else {
            throw NSError(domain: "NearbyPass", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法解析最新版本地址"])
        }
        let tag = String(finalURL[range.upperBound...])
            .split(separator: "?").first.map(String.init) ?? ""
        var ver = tag
        if ver.hasPrefix("v") { ver.removeFirst() }
        guard !ver.isEmpty else {
            throw NSError(domain: "NearbyPass", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "版本号为空"])
        }
        let dmg = URL(string: "https://github.com/\(repo)/releases/download/\(tag)/NearbyPass-\(ver).dmg")!
        let page = URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!
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
        // 已经在检查中就别再挂一遍回调：连点菜单项 + 设置页按钮时，
        // 第二次的 prev 会指向上一次的劫持闭包，恢复后留下一个惰性闭包。
        guard !checking else { return }
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
                try launchInstaller(dmg: dmg, expectVersion: rel.version)
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
        guard req.contains("identifier \"com.lcg.nearbypass\""),
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

    private func launchInstaller(dmg: URL, expectVersion: String, dryRun: Bool = false) throws {
        let script = """
        #!/bin/bash
        DMG="$1"
        EXPECT_VERSION="$2"
        EXPECTED_LEAF="$3"
        # 等 NearbyPass 退出
        for i in $(seq 1 60); do
          pgrep -x NearbyPass >/dev/null || break
          sleep 0.5
        done
        sleep 0.5
        MNT="/tmp/nearbypass_update_mnt"
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null
        mkdir -p "$MNT"
        /usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet || exit 1
        APP="$MNT/NearbyPass.app"
        [ -d "$APP" ] || exit 1
        /usr/bin/codesign -v --strict "$APP" || exit 1
        REQ=$(/usr/bin/codesign -d -r- "$APP" 2>&1)
        [[ "$REQ" == *'identifier "com.lcg.nearbypass"'* ]] || exit 1
        [[ "$REQ" == *"$EXPECTED_LEAF"* ]] || exit 1
        VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") || exit 1
        [ "$VERSION" = "$EXPECT_VERSION" ] || exit 1
        BK="/tmp/NearbyPass.app.bak"
        rm -rf "$BK"
        if [ -d "/Applications/NearbyPass.app" ]; then
          mv "/Applications/NearbyPass.app" "$BK" || exit 1
        fi
        if /usr/bin/ditto "$APP" "/Applications/NearbyPass.app"; then
          rm -rf "$BK"
        else
          # 装失败就把旧的放回去，别让人没 App 用
          rm -rf "/Applications/NearbyPass.app"
          [ -d "$BK" ] && mv "$BK" "/Applications/NearbyPass.app"
        fi
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null
        /usr/bin/open -a "/Applications/NearbyPass.app"
        rm -f "$DMG"
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
        p.arguments = [path, dmg.path, expectVersion, expectedCertLeaf]
        try p.run()
    }

    /// 调试：`--force-install` 忽略版本比较，强制走一遍下载→验签→替换→重启
    func debugForceInstall() {
        Task {
            do {
                let r = try await fetchLatest()
                print("强制安装 \(r.version)  dmg=\(r.dmg.lastPathComponent)")
                downloadAndInstall(r)
            } catch {
                print("失败: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// 调试：把安装脚本写出来并做语法检查
    func debugInstallScript() {
        let dmg = URL(fileURLWithPath: "/tmp/fake.dmg")
        do {
            try launchInstaller(dmg: dmg, expectVersion: Self.currentVersion, dryRun: true)
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
    func debugCheck(simulateVersion: String? = nil) async {
        let cur = simulateVersion ?? Self.currentVersion
        print("当前版本: \(cur)")
        do {
            let r = try await fetchLatest()
            print("最新版本: \(r.version)  dmg=\(r.dmg.lastPathComponent)")
            print(Self.isNewer(r.version, than: cur) ? "→ 有更新" : "→ 已是最新")
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
