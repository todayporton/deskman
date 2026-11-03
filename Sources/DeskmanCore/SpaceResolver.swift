public enum SpaceResolver {
    /// 優先順位は 名前 → UUID → 番号。数字の名前は番号より優先される。
    public static func resolve(_ query: String, spaces: [Space], names: [String: String]) throws -> Space {
        if let uuid = names.first(where: { $0.value == query })?.key {
            guard let s = spaces.first(where: { $0.uuid == uuid }) else {
                throw DeskmanError.notInList(query)
            }
            return s
        }
        if !query.isEmpty, let s = spaces.first(where: { $0.uuid == query }) { return s }
        if let n = Int(query), let s = spaces.first(where: { $0.index == n }) { return s }
        throw DeskmanError.nameNotFound(query)
    }

    /// 指定したディスプレイ（nil ならフォーカスのあるディスプレイ）の中で、
    /// 表示中のデスクトップから offset 個先を返す。
    /// 他のディスプレイへは進まない。フルスクリーンも Mission Control の並びどおりに数える。
    public static func neighbor(_ offset: Int, wrap: Bool, spaces: [Space],
                                display: String? = nil) throws -> Space {
        guard let active = spaces.first(where: \.isActive) else {
            throw DeskmanError.nameNotFound("current")
        }
        // 一覧にないディスプレイなら、フォーカスのあるディスプレイを使う
        let base = spaces.first {
            $0.isVisible && $0.displayID.caseInsensitiveCompare(display ?? "") == .orderedSame
        } ?? active
        let row = spaces.filter { $0.displayID == base.displayID }
        let here = row.firstIndex { $0.managedID == base.managedID }!
        var i = here + offset
        if wrap {
            i = ((i % row.count) + row.count) % row.count
        } else if !row.indices.contains(i) {
            throw DeskmanError.noNeighbor(offset)
        }
        return row[i]
    }
}
