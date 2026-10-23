// Log.swift — 环形缓冲 + 落盘日志 + 明文过滤
import Foundation

enum LogLevel: String {
    case debug = "DBG"
    case info = "INF"
    case warn = "WRN"
    case error = "ERR"
}

struct LogEntry {
    let time: Date
    let level: LogLevel
    let text: String

    var line: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return "\(f.string(from: time)) [\(level.rawValue)] \(text)"
    }
}

final class Log {
    static let shared = Log()

    /// 界面上最多保留的条目数
    private let capacity = 500
    private var buffer: [LogEntry] = []
    private let queue = DispatchQueue(label: "com.lcg.nearbypass.log")
    private let fileURL: URL
    private var handle: FileHandle?

    /// UI 刷新回调（主线程调用）
    var onAppend: ((LogEntry) -> Void)?

    /// 需要从日志里抹掉的敏感串（密码会被登记到这里）
    private var secrets: Set<String> = []

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NearbyPass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("nearbypass.log")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    /// 登记一个敏感串，之后所有日志都会把它替换成 ***
    func registerSecret(_ s: String) {
        guard !s.isEmpty else { return }
        queue.sync { _ = secrets.insert(s) }
    }

    func clearSecret(_ s: String) {
        queue.sync { _ = secrets.remove(s) }
    }

    private func scrub(_ s: String) -> String {
        var out = s
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "***")
        }
        return out
    }

    private func append(_ level: LogLevel, _ text: String) {
        let clean = scrub(text)
        let entry = LogEntry(time: Date(), level: level, text: clean)

        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            if let data = (entry.line + "\n").data(using: .utf8) {
                self.handle?.write(data)
            }
            DispatchQueue.main.async {
                self.onAppend?(entry)
            }
        }
    }

    static func debug(_ s: String) { shared.append(.debug, s) }
    static func info(_ s: String) { shared.append(.info, s) }
    static func warn(_ s: String) { shared.append(.warn, s) }
    static func error(_ s: String) { shared.append(.error, s) }

    /// 取最近 N 条快照
    func snapshot(_ n: Int = 200) -> [LogEntry] {
        queue.sync { Array(buffer.suffix(n)) }
    }

    var logFilePath: String { fileURL.path }

    func clearFile() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.removeAll()
            try? self.handle?.truncate(atOffset: 0)
        }
    }
}
