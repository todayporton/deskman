import Foundation

/// 連続で呼ばれたときに最後の指定だけを実行するための番号札。プロセスをまたぐので flock を使う。
public struct GoQueue {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/deskman/go-ticket")
    }

    private let url: URL

    public init(url: URL = GoQueue.defaultURL) {
        self.url = url
    }

    public func takeTicket() throws -> Int {
        try locked(url.path) { fd in
            let next = readNumber(fd) + 1
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
            let bytes = Array(String(next).utf8)
            _ = write(fd, bytes, bytes.count)
            return next
        }
    }

    public func isLatest(_ ticket: Int) throws -> Bool {
        try locked(url.path) { readNumber($0) == ticket }
    }

    public func withRunLock(_ body: () throws -> Void) throws {
        try locked(url.path + ".lock") { _ in try body() }
    }

    private func locked<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body(fd)
    }

    private func readNumber(_ fd: Int32) -> Int {
        lseek(fd, 0, SEEK_SET)
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = read(fd, &buffer, 32)
        return n > 0 ? Int(String(decoding: buffer[0..<n], as: UTF8.self)) ?? 0 : 0
    }
}
