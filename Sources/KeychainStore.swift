// KeychainStore.swift — 登录密码的本地存储
//
// 为什么不用钥匙串：
//   本 App 的 F2（锁屏自动解锁）必须**完全无人值守**。而钥匙串项如果尚未被本 App
//   授权，`SecItemCopyMatching` 会弹出「SecurityAgent：NearbyPass 想要访问你的钥匙串…」
//   这种需要人工输入登录密码的系统对话框 —— 锁屏状态下没人能点，读密码就会永久卡住，
//   自动解锁直接失效。因此密码改存本机文件，权限 0600（仅当前用户可读），
//   这也是 `~/.ssh/id_rsa` 一类机密的常规做法。
//
//   如果将来想要更高等级保护，可以在「设置」里改成钥匙串后端 + 首次手动授权。

import Foundation

final class KeychainStore {
    static let shared = KeychainStore()

    private let fileName = "secret.bin"

    private init() {}

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NearbyPass", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    /// 写入密码。返回是否成功。
    @discardableResult
    func save(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var data = Data(password.utf8)
            defer { KeychainStore.zeroData(&data) }
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            Log.error("保存密码失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 读取密码；没有则返回 nil。
    func load() -> String? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        var copy = data
        defer { KeychainStore.zeroData(&copy) }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return !data.isEmpty
    }

    @discardableResult
    func delete() -> Bool {
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }

    /// 把内存里的密码字节清零，尽量缩短明文在进程内停留的时间。
    static func zeroData(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset_s(base, raw.count, 0, raw.count)
        }
    }

    static func zeroString(_ s: inout String) {
        guard !s.isEmpty else { return }
        var chars = Array(s.utf8)
        chars.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset_s(base, raw.count, 0, raw.count)
        }
        s = ""
    }
}
