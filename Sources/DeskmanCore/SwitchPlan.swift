public enum SwitchPlan: Equatable {
    case alreadyThere
    /// steps が正なら右、負なら左。
    case swipe(displayID: String, steps: Int, changeDisplay: Bool)

    public static func make(_ target: Space, in spaces: [Space]) -> SwitchPlan {
        if target.isActive { return .alreadyThere }
        let visible = spaces.first { $0.displayID == target.displayID && $0.isVisible }
        let steps = target.index - (visible?.index ?? target.index)
        let activeDisplay = spaces.first(where: \.isActive)?.displayID
        return .swipe(displayID: target.displayID, steps: steps,
                      changeDisplay: activeDisplay != target.displayID)
    }
}
