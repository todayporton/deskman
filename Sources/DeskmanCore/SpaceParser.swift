public enum SpaceParser {
    public static func parse(_ raw: [[String: Any]], activeID: Int) -> [Space] {
        var result: [Space] = []
        for display in raw {
            let displayID = display["Display Identifier"] as? String ?? ""
            let current = display["Current Space"] as? [String: Any]
            let currentID = current.flatMap(numericID)
            for s in display["Spaces"] as? [[String: Any]] ?? [] {
                let id = numericID(s) ?? 0
                result.append(Space(
                    // UUID が空でも番号がずれないよう、読み飛ばさずに残す
                    uuid: s["uuid"] as? String ?? "",
                    managedID: id,
                    displayID: displayID,
                    index: result.count + 1,
                    // フルスクリーンでも type が 0 の場合がある（spacelabel の知見）
                    isFullscreen: (s["type"] as? Int ?? 0) != 0 || s["TileLayoutManager"] != nil,
                    isVisible: id == currentID,
                    isActive: id == activeID))
            }
        }
        return result
    }

    private static func numericID(_ s: [String: Any]) -> Int? {
        (s["id64"] as? Int) ?? (s["ManagedSpaceID"] as? Int)
    }
}
