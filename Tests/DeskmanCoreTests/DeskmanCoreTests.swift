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
    func testAlertSoundOnlyWhenTargetIsUnreachable() {
        XCTAssertTrue(DeskmanError.noNeighbor(1).playsAlertSound)
        XCTAssertTrue(DeskmanError.notInList("資料").playsAlertSound)
        XCTAssertFalse(DeskmanError.nameNotFound("typo").playsAlertSound)
        XCTAssertFalse(DeskmanError.notTrusted.playsAlertSound)
        XCTAssertFalse(DeskmanError.switchNotConfirmed.playsAlertSound)
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

final class VisibleOnDisplayTests: XCTestCase {
    private let spaces = SpaceParser.parse(Fixtures.connected, activeID: 6)

    func testVisibleSpaceOfCursorDisplay() {
        // フォーカスは MAIN の m2 でも、カーソルが EXT にあれば e1
        XCTAssertEqual(SpaceResolver.visible(onDisplay: "EXT", spaces: spaces)?.uuid, "e1")
        XCTAssertEqual(SpaceResolver.visible(onDisplay: "ext", spaces: spaces)?.uuid, "e1")
        XCTAssertEqual(SpaceResolver.visible(onDisplay: "MAIN", spaces: spaces)?.uuid, "m2")
    }
    func testUnknownDisplayFallsBackToFocus() {
        XCTAssertEqual(SpaceResolver.visible(onDisplay: "Main", spaces: spaces)?.uuid, "m2")
        XCTAssertEqual(SpaceResolver.visible(onDisplay: nil, spaces: spaces)?.uuid, "m2")
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
        XCTAssertNil(r.restoreFocus)
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
    func testNewServerAnswersPingWithoutMoving() throws {
        let p = path()
        defer { unlink(p) }
        // 本物の handle を使う。ping は一覧も名前も読まずに成功を返す
        try GoSocket.serve(path: p, handler: GoSocket.handle)
        XCTAssertNoThrow(try GoSocket.requireMoveSupport(path: p))
    }
    func testOldServerIsRefusedBeforeMoving() throws {
        let p = path()
        defer { unlink(p) }
        // 0.3.0 の常駐アプリは ping を知らず、空の名前の移動として「見つからない」を返す
        try GoSocket.serve(path: p) { request in
            request.query.isEmpty && request.offset == nil
                ? GoReply(code: 2, message: "Not found: ")
                : GoReply(code: 0, message: "")
        }
        XCTAssertThrowsError(try GoSocket.requireMoveSupport(path: p)) {
            XCTAssertEqual($0 as? DeskmanError, .serverTooOld)
            XCTAssertEqual(($0 as? DeskmanError)?.exitCode, 7)
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

/// macOS 27 用の形式。期待値は Raycast 2.10.1 の逆アセンブルから読んだもの。
final class MacOS27SwipeTests: XCTestCase {
    typealias M = SpaceSwitcher.MacOS27

    func testIOFixed() {
        XCTAssertEqual(M.ioFixed(0.1), 0x1999)
        XCTAssertEqual(M.ioFixed(1), 65536)
        XCTAssertEqual(M.ioFixed(0), 0)
        // 0.000016 × 65536 ≈ 1.05 は切り捨てて 1
        XCTAssertEqual(M.ioFixed(0.000016), 1)
        XCTAssertEqual(M.ioFixed(-0.000016), -1)
        // 0 に丸められても 0 でない値は ±1
        XCTAssertEqual(M.ioFixed(1e-9), 1)
        XCTAssertEqual(M.ioFixed(-1e-9), -1)
        XCTAssertEqual(M.ioFixed(1e10), .max)
        XCTAssertEqual(M.ioFixed(-1e10), .min)
    }

    func testHIDPayload() {
        let d = M.hidPayload(phase: 2, progress: -0.000016, timestamp: 0x1122334455667788)
        XCTAssertEqual(d.count, 68)
        XCTAssertEqual([UInt8](d), [
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // timestamp
            0, 0, 0, 0, 0, 0, 0, 0,  // senderID
            0, 0, 0, 0,  // options
            0, 0, 0, 0,  // 属性の長さ
            1, 0, 0, 0,  // イベントの数
            40, 0, 0, 0,  // size
            23, 0, 0, 0,  // type
            0, 0, 0, 2,  // options: 段階 << 24
            0, 0, 0, 0,  // depth, reserved
            0x99, 0x19, 0, 0,  // 0.1
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            1, 0, 3, 0,
            0xff, 0xff, 0xff, 0xff,  // 進捗 −1/65536
        ])
    }

    func testAppendRecord() {
        var data = Data([0xaa])
        M.appendRecord(tag: 4205, payload: Data([1, 2, 3]), to: &data)
        XCTAssertEqual([UInt8](data), [0xaa, 0x00, 0x03, 0x10, 0x6d, 1, 2, 3])
    }

    /// 足したイベントを CoreGraphics が読み戻せること。送信はしない。
    func testEventRoundTrips() throws {
        let e = try XCTUnwrap(M.event(phase: 1, direction: 1))
        XCTAssertEqual(e.getIntegerValueField(CGEventField(rawValue: 55)!), 30)
        XCTAssertEqual(e.getIntegerValueField(CGEventField(rawValue: 132)!), 1)
        XCTAssertEqual(e.getDoubleValueField(CGEventField(rawValue: 124)!), 0.000016, accuracy: 1e-12)
    }
}

final class MissionControlLabelsTests: XCTestCase {
    private let spaces = SpaceParser.parse(Fixtures.connected, activeID: 6)
    private var main: [Space] { spaces.filter { $0.displayID == "MAIN" } }

    // VM の実測: 折りたたまれているとき、ボタンは名前そのもの（65x24 前後、y は表示より 40pt 上）
    private let collapsed = [CGRect(x: 441, y: -32, width: 65, height: 24), CGRect(x: 538, y: -32, width: 65, height: 24),
                             CGRect(x: 635, y: -32, width: 67, height: 24)]
    // バーが開いているとき、ボタンはサムネイル（144x90）で、上端から 28pt 下
    private let expanded = [CGRect(x: 384, y: 28, width: 144, height: 90), CGRect(x: 560, y: 28, width: 144, height: 90),
                            CGRect(x: 736, y: 28, width: 144, height: 90)]

    func testWidthIsTheLargestThatDoesNotOverlapWhenCollapsed() {
        // 中心の間隔は 97 と 98。小さい方から隙間 4 を引く
        XCTAssertEqual(MissionControlLabels.width(buttons: collapsed), 93)
        XCTAssertNil(MissionControlLabels.width(buttons: expanded))
        XCTAssertEqual(MissionControlLabels.width(buttons: [collapsed[0]]), 85)
    }
    func testSameSizeAtTopInBothStates() {
        // MAIN: m1, m2（表示中）。名前は m2 だけ
        let a = MissionControlLabels.make(buttons: Array(collapsed.prefix(2)), top: 0, width: 93, spaces: main,
                                          names: ["m2": "資料"])
        let b = MissionControlLabels.make(buttons: Array(expanded.prefix(2)), top: 0, width: 93, spaces: main,
                                          names: ["m2": "資料"])
        XCTAssertEqual(a.map(\.name), ["Desktop 1", "資料"])
        XCTAssertEqual(a.map(\.current), [false, true])
        XCTAssertEqual(a[1].frame, CGRect(x: 570.5 - 46.5, y: 0, width: 93, height: 34))
        // 開いても大きさは同じで、サムネイルの中心の真上へ動く
        XCTAssertEqual(b[1].frame, CGRect(x: 632 - 46.5, y: 0, width: 93, height: 34))
    }
    func testSecondDisplayUsesItsOwnTop() {
        let labels = MissionControlLabels.make(buttons: Array(expanded.prefix(2)), top: -200, width: 93,
                                               spaces: main, names: [:])
        XCTAssertEqual(labels.first?.frame.minY, -200)
    }
    func testFullscreenIsLeftAlone() {
        let s = SpaceParser.parse([Fixtures.display("MAIN", current: 1, [
            Fixtures.space(1, "m1"), Fixtures.space(2, "f", type: 4)])], activeID: 1)
        let labels = MissionControlLabels.make(buttons: Array(expanded.prefix(2)), top: 0, width: 93, spaces: s, names: [:])
        XCTAssertEqual(labels.map(\.name), ["Desktop 1"])
    }
    func testCountMismatchShowsNothing() {
        let labels = MissionControlLabels.make(buttons: [expanded[0]], top: 0, width: 93, spaces: main, names: [:])
        XCTAssertEqual(labels, [])
    }
    func testSpacesOfDisplay() {
        XCTAssertEqual(MissionControlLabels.spaces(onDisplay: "ext", in: spaces).map(\.uuid), ["e1", "e2"])
        // 2台あって一致しないときは、取り違えを避けて空にする
        XCTAssertEqual(MissionControlLabels.spaces(onDisplay: "OTHER", in: spaces), [])
        // ディスプレイごとに分けない設定（Display Identifier が Main）なら全部
        let single = SpaceParser.parse([Fixtures.display("Main", current: 3, [Fixtures.space(3, "m1")])], activeID: 3)
        XCTAssertEqual(MissionControlLabels.spaces(onDisplay: "UUID-X", in: single).map(\.uuid), ["m1"])
        XCTAssertEqual(MissionControlLabels.spaces(onDisplay: nil, in: single).map(\.uuid), ["m1"])
    }
}

final class MovePlanTests: XCTestCase {
    /// MAIN: m1, m2, f(フルスクリーン), m3。EXT: e1。フォーカスは m1
    private func spaces(activeID: Int = 1) -> [Space] {
        SpaceParser.parse([
            Fixtures.display("MAIN", current: activeID == 21 ? 1 : activeID, [
                Fixtures.space(1, "m1"), Fixtures.space(2, "m2"), Fixtures.space(3, "f", type: 4),
                Fixtures.space(4, "m3"),
            ]),
            Fixtures.display("EXT", current: 21, [Fixtures.space(21, "e1")]),
        ], activeID: activeID)
    }
    private func target(_ uuid: String, _ s: [Space]) -> Space { s.first { $0.uuid == uuid }! }

    func testPathGoesThroughEachStep() throws {
        let s = spaces()
        let plan = try MovePlan.make(to: target("m3", s), spaces: s)
        XCTAssertEqual(plan.origin.uuid, "m1")
        // フルスクリーンも 1 ステップとして通る
        XCTAssertEqual(plan.path.map(\.uuid), ["m2", "f", "m3"])
    }
    func testPathToTheLeft() throws {
        let s = spaces(activeID: 4)
        XCTAssertEqual(try MovePlan.make(to: target("m1", s), spaces: s).path.map(\.uuid), ["f", "m2", "m1"])
    }
    func testAlreadyThere() throws {
        let s = spaces()
        XCTAssertEqual(try MovePlan.make(to: target("m1", s), spaces: s).path, [])
    }
    func testRefusesOtherDisplay() {
        let s = spaces()
        XCTAssertThrowsError(try MovePlan.make(to: target("e1", s), spaces: s)) {
            XCTAssertEqual($0 as? DeskmanError, .cannotMoveWindow(.otherDisplay))
            XCTAssertEqual(($0 as? DeskmanError)?.exitCode, 8)
        }
    }
    func testRefusesFullscreenTarget() {
        let s = spaces()
        XCTAssertThrowsError(try MovePlan.make(to: target("f", s), spaces: s)) {
            XCTAssertEqual($0 as? DeskmanError, .cannotMoveWindow(.toFullscreen))
        }
    }
    func testRefusesFromFullscreen() {
        let s = spaces(activeID: 3)
        XCTAssertThrowsError(try MovePlan.make(to: target("m1", s), spaces: s)) {
            XCTAssertEqual($0 as? DeskmanError, .cannotMoveWindow(.fullscreen))
        }
    }
    func testMoveRequestDecodesWithoutNewFields() throws {
        // 古い CLI の要求（moveWindow なし）も読める
        let old = #"{"query":"資料","restoreCursor":false}"#
        let request = try JSONDecoder().decode(GoRequest.self, from: Data(old.utf8))
        XCTAssertNil(request.moveWindow)
        XCTAssertNil(request.stay)
    }
}

final class SpaceShortcutsTests: XCTestCase {
    func testNoKeyAssigned() {
        XCTAssertNil(SpaceShortcut(keyCode: UInt16(0xFFFF), modifiers: UInt32(0x840000)))
    }
    func testArrowKeysGetTheNumericPadFlag() {
        // 実機の設定: Control+Option+→（WindowServer から読んだ値）
        let s = SpaceShortcut(keyCode: UInt16(124), modifiers: UInt32(0x8C0000))
        XCTAssertEqual(s?.keyCode, 124)
        XCTAssertEqual(s?.flags, [.maskSecondaryFn, .maskControl, .maskAlternate, .maskNumericPad])
    }
    func testOtherKeysAreSentAsIs() {
        let s = SpaceShortcut(keyCode: UInt16(0), modifiers: UInt32(0x40000))
        XCTAssertEqual(s?.flags, [.maskControl])
    }
}
