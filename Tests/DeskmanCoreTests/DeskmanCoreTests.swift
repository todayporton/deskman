import XCTest
@testable import DeskmanCore

/// 実機で外部ディスプレイを抜き差しした結果を縮めたもの。
enum Fixtures {
    static func space(_ id: Int, _ uuid: String, type: Int = 0) -> [String: Any] {
        ["id64": id, "type": type, "uuid": uuid]
    }
    static func display(_ id: String, current: Int, _ spaces: [[String: Any]]) -> [String: Any] {
        ["Display Identifier": id, "Current Space": ["id64": current], "Spaces": spaces]
    }
    /// 接続中
    static var connected: [[String: Any]] {
        [
            display("MAIN", current: 6, [space(3, "m1"), space(6, "m2")]),
            display("EXT", current: 16, [space(16, "e1"), space(14, "e2")]),
        ]
    }
    /// 抜いた後: e1 が消え、e2 がメインへ移る
    static var unplugged: [[String: Any]] {
        [display("MAIN", current: 6, [space(3, "m1"), space(6, "m2"), space(14, "e2")])]
    }
    /// 再接続後: e1 の UUID は同じで数値 ID だけ変わる
    static var replugged: [[String: Any]] {
        [
            display("MAIN", current: 6, [space(3, "m1"), space(6, "m2")]),
            display("EXT", current: 2465, [space(2465, "e1"), space(14, "e2")]),
        ]
    }
}

final class SpaceParserTests: XCTestCase {
    func testNumbersAcrossDisplays() {
        let s = SpaceParser.parse(Fixtures.connected, activeID: 6)
        XCTAssertEqual(s.map(\.uuid), ["m1", "m2", "e1", "e2"])
        XCTAssertEqual(s.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(s[2].displayID, "EXT")
    }
    func testVisibleAndActive() {
        let s = SpaceParser.parse(Fixtures.connected, activeID: 6)
        XCTAssertEqual(s.filter(\.isVisible).map(\.uuid), ["m2", "e1"])
        XCTAssertEqual(s.filter(\.isActive).map(\.uuid), ["m2"])
    }
    func testFullscreenFlag() {
        let raw = [Fixtures.display("MAIN", current: 1, [
            Fixtures.space(1, "a"),
            Fixtures.space(2, "f", type: 4),
            ["id64": 3, "type": 0, "uuid": "t", "TileLayoutManager": [String: Any]()],
        ])]
        XCTAssertEqual(SpaceParser.parse(raw, activeID: 1).map(\.isFullscreen), [false, true, true])
    }
    func testEmptyUUIDKeepsNumbering() {
        // VM の実測: 先頭のデスクトップの UUID が空だった
        let raw = [Fixtures.display("MAIN", current: 1, [Fixtures.space(1, ""), Fixtures.space(2, "b")])]
        let s = SpaceParser.parse(raw, activeID: 1)
        XCTAssertEqual(s.map(\.index), [1, 2])
        XCTAssertEqual(s[0].isVisible, true)
        XCTAssertEqual(s[1].isVisible, false)
    }
    func testUUIDSurvivesReplugWithNewNumericID() {
        let before = SpaceParser.parse(Fixtures.connected, activeID: 6).first { $0.uuid == "e1" }!
        let after = SpaceParser.parse(Fixtures.replugged, activeID: 6).first { $0.uuid == "e1" }!
        XCTAssertNotEqual(before.managedID, after.managedID)
        XCTAssertEqual(before.index, after.index)
    }
}

final class NameStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("names.json")
    }
    func testRoundTrip() throws {
        var s = try NameStore(url: url)
        try s.set(name: "仕事", for: "u1")
        XCTAssertEqual(try NameStore(url: url).names, ["u1": "仕事"])
    }
    func testDuplicateRejected() throws {
        var s = try NameStore(url: url)
        try s.set(name: "仕事", for: "u1")
        XCTAssertThrowsError(try s.set(name: "仕事", for: "u2")) {
            XCTAssertEqual($0 as? DeskmanError, .duplicateName("仕事"))
        }
    }
    func testRenameSameSpaceToSameName() throws {
        var s = try NameStore(url: url)
        try s.set(name: "仕事", for: "u1")
        XCTAssertNoThrow(try s.set(name: "仕事", for: "u1"))
    }
    func testEmptyNameClears() throws {
        var s = try NameStore(url: url)
        try s.set(name: "仕事", for: "u1")
        try s.set(name: "", for: "u1")
        XCTAssertEqual(s.names, [:])
    }
    func testForgetRefusesLiveSpace() throws {
        var s = try NameStore(url: url)
        try s.set(name: "仕事", for: "u1")
        XCTAssertThrowsError(try s.forget(name: "仕事", liveUUIDs: ["u1"]))
        XCTAssertNoThrow(try s.forget(name: "仕事", liveUUIDs: []))
        XCTAssertEqual(s.names, [:])
    }
    func testForgetUnknownName() throws {
        var s = try NameStore(url: url)
        XCTAssertThrowsError(try s.forget(name: "無い", liveUUIDs: [])) {
            XCTAssertEqual($0 as? DeskmanError, .nameNotFound("無い"))
        }
    }
    func testCorruptFileIsReportedNotOverwritten() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try NameStore(url: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}

final class SpaceResolverTests: XCTestCase {
    private let names = ["m1": "仕事", "e1": "資料", "e2": "3"]

    private func resolve(_ q: String, _ raw: [[String: Any]] = Fixtures.connected) throws -> String {
        try SpaceResolver.resolve(q, spaces: SpaceParser.parse(raw, activeID: 6), names: names).uuid
    }
    func testByName() throws { XCTAssertEqual(try resolve("仕事"), "m1") }
    func testByUUID() throws { XCTAssertEqual(try resolve("m2"), "m2") }
    func testByIndex() throws { XCTAssertEqual(try resolve("2"), "m2") }
    func testNameBeatsIndex() throws { XCTAssertEqual(try resolve("3"), "e2") }
    func testNameFollowsSpaceAfterUnplug() throws {
        XCTAssertEqual(try resolve("3", Fixtures.unplugged), "e2")
    }
    func testNameFollowsSpaceAfterReplug() throws {
        XCTAssertEqual(try resolve("資料", Fixtures.replugged), "e1")
    }
    func testUnknown() {
        XCTAssertThrowsError(try resolve("無い")) {
            XCTAssertEqual($0 as? DeskmanError, .nameNotFound("無い"))
        }
    }
    func testNamedButAbsentAfterUnplug() {
        XCTAssertThrowsError(try resolve("資料", Fixtures.unplugged)) {
            XCTAssertEqual($0 as? DeskmanError, .notInList("資料"))
        }
    }
    func testIndexOutOfRange() {
        XCTAssertThrowsError(try resolve("99")) {
            XCTAssertEqual($0 as? DeskmanError, .nameNotFound("99"))
        }
    }
    func testEmptyQueryDoesNotMatchEmptyUUID() {
        let raw = [Fixtures.display("MAIN", current: 1, [Fixtures.space(1, "")])]
        XCTAssertThrowsError(try resolve("", raw))
    }
}

final class NeighborTests: XCTestCase {
    private func neighbor(_ offset: Int, wrap: Bool = false, activeID: Int = 6,
                          display: String? = nil) throws -> String {
        try SpaceResolver.neighbor(
            offset, wrap: wrap, spaces: SpaceParser.parse(Fixtures.connected, activeID: activeID),
            display: display).uuid
    }
    func testPrevious() throws { XCTAssertEqual(try neighbor(-1), "m1") }
    func testStopsAtEdgeOfDisplay() {
        // m2 は MAIN の右端。EXT の e1 へは進まない
        XCTAssertThrowsError(try neighbor(1)) {
            XCTAssertEqual($0 as? DeskmanError, .noNeighbor(1))
            XCTAssertEqual(($0 as? DeskmanError)?.exitCode, 2)
        }
    }
    func testWrapsWithinDisplay() throws {
        XCTAssertEqual(try neighbor(1, wrap: true), "m1")
        XCTAssertEqual(try neighbor(-1, wrap: true, activeID: 3), "m2")
    }
    func testUsesDisplayWithFocus() throws {
        XCTAssertEqual(try neighbor(1, activeID: 16), "e2")
    }
    func testCountsFromVisibleSpaceOfGivenDisplay() throws {
        // フォーカスは MAIN の m2、カーソルは EXT（表示中は e1）
        XCTAssertEqual(try neighbor(1, display: "EXT"), "e2")
        XCTAssertEqual(try neighbor(-1, wrap: true, display: "EXT"), "e2")
    }
    func testUnknownDisplayFallsBackToFocus() throws {
        // 分離されていない構成では Display Identifier が UUID と一致しないことがある
        XCTAssertEqual(try neighbor(-1, display: "Main"), "m1")
    }
    func testNoActiveSpace() {
        XCTAssertThrowsError(try neighbor(1, activeID: 999)) {
            XCTAssertEqual($0 as? DeskmanError, .nameNotFound("current"))
        }
    }
}

final class SwitchPlanTests: XCTestCase {
    private let spaces = SpaceParser.parse(Fixtures.connected, activeID: 6)

    private func target(_ uuid: String) -> Space { spaces.first { $0.uuid == uuid }! }

    func testAlreadyThere() {
        XCTAssertEqual(SwitchPlan.make(target("m2"), in: spaces), .alreadyThere)
    }
    func testSameDisplayLeft() {
        XCTAssertEqual(SwitchPlan.make(target("m1"), in: spaces),
                       .swipe(displayID: "MAIN", steps: -1, changeDisplay: false))
    }
    func testOtherDisplayCountsFromThatDisplaysVisibleSpace() {
        XCTAssertEqual(SwitchPlan.make(target("e2"), in: spaces),
                       .swipe(displayID: "EXT", steps: 1, changeDisplay: true))
    }
    func testOtherDisplayAlreadyVisibleOnlyMovesFocus() {
        XCTAssertEqual(SwitchPlan.make(target("e1"), in: spaces),
                       .swipe(displayID: "EXT", steps: 0, changeDisplay: true))
    }
}

final class GoQueueTests: XCTestCase {
    func testOnlyLatestTicketRuns() throws {
        let queue = GoQueue(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let first = try queue.takeTicket()
        let second = try queue.takeTicket()
        XCTAssertFalse(try queue.isLatest(first))
        XCTAssertTrue(try queue.isLatest(second))
    }
    func testRunLockRunsBody() throws {
        let queue = GoQueue(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        var ran = false
        try queue.withRunLock { ran = true }
        XCTAssertTrue(ran)
    }
}

final class GoSocketTests: XCTestCase {
    private func path() -> String { "/tmp/dm-\(UUID().uuidString.prefix(8)).sock" }

    func testNoServer() {
        XCTAssertThrowsError(try GoSocket.send(GoRequest(query: "a", restoreCursor: false), path: path())) {
            XCTAssertEqual($0 as? DeskmanError, .serverNotRunning)
            XCTAssertEqual(($0 as? DeskmanError)?.exitCode, 7)
        }
    }
    func testOldRequestWithoutOffsetStillDecodes() throws {
        let r = try JSONDecoder().decode(GoRequest.self, from: Data(#"{"query":"a","restoreCursor":false}"#.utf8))
        XCTAssertEqual(r, GoRequest(query: "a", restoreCursor: false))
        XCTAssertNil(r.offset)
        XCTAssertNil(r.byCursor)
    }
    func testSuccessAndRemoteFailureCarryExitCode() throws {
        let p = path()
        defer { unlink(p) }
        try GoSocket.serve(path: p) { request in
            request.query == "ok" && request.restoreCursor
                ? GoReply(code: 0, message: "")
                : GoReply(code: 3, message: "一覧にありません")
        }
        XCTAssertTrue(GoSocket.isServerRunning(path: p))
        XCTAssertNoThrow(try GoSocket.send(GoRequest(query: "ok", restoreCursor: true), path: p))
        XCTAssertThrowsError(try GoSocket.send(GoRequest(query: "x", restoreCursor: false), path: p)) {
            XCTAssertEqual(($0 as? DeskmanError)?.exitCode, 3)
            XCTAssertEqual(($0 as? DeskmanError)?.message, "一覧にありません")
        }
    }
}

final class SpaceRowTests: XCTestCase {
    func testAbsentNamesAreListedAfterLiveSpaces() {
        let s = SpaceParser.parse(Fixtures.unplugged, activeID: 6)
        let rows = SpaceRow.make(spaces: s, names: ["m1": "仕事", "e1": "資料"], includeAbsent: true)
        XCTAssertEqual(rows.map(\.uuid), ["m1", "m2", "e2", "e1"])
        XCTAssertEqual(rows.last?.name, "資料")
        XCTAssertNil(rows.last?.index)
        XCTAssertEqual(rows.last?.present, false)
    }
    func testAbsentHiddenByDefault() {
        let s = SpaceParser.parse(Fixtures.unplugged, activeID: 6)
        XCTAssertEqual(SpaceRow.make(spaces: s, names: ["e1": "資料"], includeAbsent: false).count, 3)
    }
}
