/// `--json` の出力形式。Herdr モッドが読むので、変更するときは互換性に注意する。
public struct SpaceRow: Codable, Equatable, Sendable {
    public let uuid: String
    public let name: String?
    public let index: Int?
    public let display: String?
    public let visible: Bool
    public let active: Bool
    public let fullscreen: Bool
    public let present: Bool

    public static func make(spaces: [Space], names: [String: String], includeAbsent: Bool) -> [SpaceRow] {
        var rows = spaces.map {
            SpaceRow(uuid: $0.uuid, name: names[$0.uuid], index: $0.index, display: $0.displayID,
                     visible: $0.isVisible, active: $0.isActive, fullscreen: $0.isFullscreen,
                     present: true)
        }
        if includeAbsent {
            let live = Set(spaces.map(\.uuid))
            for (uuid, name) in names.sorted(by: { $0.value < $1.value }) where !live.contains(uuid) {
                rows.append(SpaceRow(uuid: uuid, name: name, index: nil, display: nil, visible: false,
                                     active: false, fullscreen: false, present: false))
            }
        }
        return rows
    }
}
