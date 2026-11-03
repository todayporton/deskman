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
}
