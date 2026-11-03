import Foundation

public struct GoRequest: Codable, Equatable, Sendable {
    public let query: String
    public let restoreCursor: Bool
    /// 指定があれば query を使わず、今のデスクトップから offset 個先へ移動する。
    /// 処理する時点の並びで計算するので、連続で呼んでもその回数だけ進む。
    public let offset: Int?
    public let wrap: Bool?
    /// offset を数えるディスプレイを、フォーカスではなくカーソルのある側にする。
    public let byCursor: Bool?
    /// 移動でキーボードのフォーカスが他のアプリへ移ったら、移動前のウィンドウへ戻す。
    public let restoreFocus: Bool?

    public init(query: String, restoreCursor: Bool, offset: Int? = nil, wrap: Bool? = nil,
                byCursor: Bool? = nil, restoreFocus: Bool? = nil) {
        self.query = query
        self.restoreCursor = restoreCursor
        self.offset = offset
        self.wrap = wrap
        self.byCursor = byCursor
        self.restoreFocus = restoreFocus
    }
}

public struct GoReply: Codable, Equatable, Sendable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
}

/// CLI と常駐アプリの通信。権限を Deskman.app だけに持たせるため、移動は常駐アプリが行う。
public enum GoSocket {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/deskman/deskman.sock").path
    }

    private static func connectFD(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        ignoreSigpipe(fd)
        var address = makeAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// 相手が先に閉じたソケットへ書き込んでも、プロセスごと落ちないようにする。
    private static func ignoreSigpipe(_ fd: Int32) {
        // AF_UNIX では SO_NOSIGPIPE で防げなかったので、プロセス全体で無視する
        _ = fd
        signal(SIGPIPE, SIG_IGN)
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return data }
            data.append(contentsOf: buffer[0..<n])
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    public static func isServerRunning(path: String = defaultPath) -> Bool {
        guard let fd = connectFD(path) else { return false }
        close(fd)
        return true
    }

    /// 移動の結果を受け取るまで待つ。失敗はそのまま DeskmanError として投げる。
    public static func send(_ request: GoRequest, path: String = defaultPath) throws {
        guard let fd = connectFD(path) else { throw DeskmanError.serverNotRunning }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        writeAll(fd, try JSONEncoder().encode(request))
        shutdown(fd, SHUT_WR)
        guard let reply = try? JSONDecoder().decode(GoReply.self, from: readAll(fd)) else {
            throw DeskmanError.switchNotConfirmed
        }
        if reply.code != 0 {
            throw DeskmanError.remote(code: reply.code, message: reply.message)
        }
    }

    /// 要求を1つずつ順番に処理する。
    public static func serve(
        path: String = defaultPath,
        handler: @escaping @Sendable (GoRequest) -> GoReply
    ) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 16) == 0 else {
            close(listener)
            throw POSIXError(.EIO)
        }
        DispatchQueue.global(qos: .userInteractive).async {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                ignoreSigpipe(client)
                let reply: GoReply
                if let request = try? JSONDecoder().decode(GoRequest.self, from: readAll(client)) {
                    reply = handler(request)
                } else {
                    reply = GoReply(code: 1, message: "Could not read the request.")
                }
                if let data = try? JSONEncoder().encode(reply) { writeAll(client, data) }
                close(client)
            }
        }
    }

    /// 常駐アプリが要求を処理する本体。
    @Sendable public static func handle(_ request: GoRequest) -> GoReply {
        handle(request, onError: { _ in })
    }

    /// onError には、移動できなかったときの DeskmanError が渡される。返す内容は変わらない。
    public static func handle(_ request: GoRequest,
                              onError: (DeskmanError) -> Void) -> GoReply {
        do {
            let spaces = SystemSpaces.current()
            let target = if let offset = request.offset {
                try SpaceResolver.neighbor(
                    offset, wrap: request.wrap ?? false, spaces: spaces,
                    display: request.byCursor == true ? SpaceSwitcher.cursorDisplayID() : nil)
            } else {
                try SpaceResolver.resolve(request.query, spaces: spaces, names: NameStore().names)
            }
            try SpaceSwitcher.go(to: target, restoreCursor: request.restoreCursor,
                                 restoreFocus: request.restoreFocus ?? false)
            return GoReply(code: 0, message: "")
        } catch let error as DeskmanError {
            onError(error)
            return GoReply(code: error.exitCode, message: error.message)
        } catch {
            return GoReply(code: 1, message: "\(error)")
        }
    }
}
