import DeskmanCore
import Foundation

func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func runCLI(_ arguments: [String]) throws {
    var args = arguments
    let command = args.removeFirst()
    func flag(_ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }
    var store = try NameStore()
    let spaces = SystemSpaces.current()

    switch command {
    case "list":
        let asJSON = flag("--json")
        let rows = SpaceRow.make(spaces: spaces, names: store.names, includeAbsent: flag("--all"))
        if asJSON {
            print(try json(rows))
            return
        }
        for r in rows {
            let mark = r.active ? "*" : (r.visible ? "+" : " ")
            let index = r.index.map(String.init) ?? "-"
            let note = !r.present ? "（一覧になし）" : (r.fullscreen ? "（フルスクリーン）" : "")
            print("\(mark) \(index)\t\(r.name ?? "-")\t\(r.display ?? "-")\t\(r.uuid.isEmpty ? "(UUIDなし)" : r.uuid)\(note)")
        }
    case "current":
        let asJSON = flag("--json")
        guard let s = spaces.first(where: \.isActive) else {
            throw DeskmanError.nameNotFound("current")
        }
        let row = SpaceRow.make(spaces: [s], names: store.names, includeAbsent: false)[0]
        if asJSON {
            print(try json(row))
        } else {
            print(row.name ?? (row.uuid.isEmpty ? String(s.index) : row.uuid))
        }
    case "go":
        let restoreCursor = flag("--restore-cursor")
        let restoreFocus = flag("--restore-focus")
        guard let query = args.first else { usage() }
        // 間違った名前なら順番待ちせずに失敗させる
        _ = try SpaceResolver.resolve(query, spaces: spaces, names: store.names)
        let queue = GoQueue()
        let ticket = try queue.takeTicket()
        try queue.withRunLock {
            guard try queue.isLatest(ticket) else { return }
            try GoSocket.send(GoRequest(query: query, restoreCursor: restoreCursor,
                                        restoreFocus: restoreFocus))
        }
    case "next", "prev":
        let wrap = flag("--wrap")
        let byCursor = flag("--cursor")
        let restoreCursor = flag("--restore-cursor")
        let restoreFocus = flag("--restore-focus")
        guard args.isEmpty else { usage() }
        // 移動先は常駐アプリが処理する時点の並びで決める。連続で呼ばれた回数だけ進めたいので、
        // go と違って古い要求を捨てずに順番に送る。札は取って、待っている go を取り消す。
        let queue = GoQueue()
        _ = try queue.takeTicket()
        try queue.withRunLock {
            try GoSocket.send(GoRequest(query: "", restoreCursor: restoreCursor,
                                        offset: command == "next" ? 1 : -1, wrap: wrap,
                                        byCursor: byCursor, restoreFocus: restoreFocus))
        }
    case "rename":
        if flag("--forget") {
            guard let name = args.first else { usage() }
            try store.forget(name: name, liveUUIDs: Set(spaces.map(\.uuid)))
            return
        }
        guard args.count == 2 else { usage() }
        let target = try SpaceResolver.resolve(args[0], spaces: spaces, names: store.names)
        if target.isFullscreen { throw DeskmanError.fullscreenNotNameable }
        if target.uuid.isEmpty { throw DeskmanError.noUUID }
        try store.set(name: args[1], for: target.uuid)
    default:
        usage()
    }
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    使い方:
      deskman                         メニューバーアプリとして起動
      deskman list [--json] [--all]
      deskman current [--json]
      deskman go [--restore-cursor] [--restore-focus] <名前|番号|UUID>
      deskman next [--wrap] [--cursor] [--restore-cursor] [--restore-focus]
                                      右隣へ。--cursor はカーソルのあるディスプレイで数える
      deskman prev [--wrap] [--cursor] [--restore-cursor] [--restore-focus]
                                      左隣へ
      deskman rename <対象> <名前>     "" で解除
      deskman rename --forget <名前>

    """.utf8))
    exit(64)
}
