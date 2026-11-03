import CoreGraphics

/// Mission Control のデスクトップ名の上に重ねる名前と位置。座標はアクセシビリティと同じ左上原点。
public struct MissionControlLabel: Equatable, Sendable {
    public let name: String
    public let frame: CGRect
    /// 上部のバーが折りたたまれていて、名前だけが並んでいるか
    public let collapsed: Bool
    /// そのディスプレイで表示中のデスクトップか
    public let current: Bool

    public init(name: String, frame: CGRect, collapsed: Bool, current: Bool) {
        self.name = name
        self.frame = frame
        self.collapsed = collapsed
        self.current = current
    }
}

/// Dock から読んだボタンの並びを、デスクトップと名前に対応付ける。
/// 実測（VM macOS 26.6.2）は設計資料の「Mission Control に名前を出す検証」を参照。
public enum MissionControlLabels {
    /// 折りたたまれたバーで、表示中のデスクトップのハイライトがボタンから左右にはみ出す幅（VM で実測）。
    /// どの名前もこの幅まで覆うと、ハイライトが見切れず、幅もそろう。
    public static let collapsedPadding: CGFloat = 10

    /// 1つのディスプレイの Spaces Bar について、名前を付けたデスクトップの分だけ返す。
    /// buttons はデスクトップのボタンの枠（並び順）、bar はそれを並べたリストの枠。
    /// ボタンの数とデスクトップの数が合わないときは、取り違えを避けて何も返さない。
    public static func make(buttons: [CGRect], bar: CGRect, spaces: [Space],
                            names: [String: String]) -> [MissionControlLabel] {
        guard buttons.count == spaces.count else { return [] }
        return zip(buttons, spaces).compactMap { button, space in
            guard !space.uuid.isEmpty, let name = names[space.uuid], !name.isEmpty else { return nil }
            // バーが開いているとき、ボタンの枠はサムネイルで、名前はその下に描かれる。
            // 折りたたまれているときはボタンが名前そのものだが、y が表示とずれる（VM で 40pt 上）ので、
            // バーの縦の中央に置く。
            let collapsed = button.height < 40
            let frame = collapsed
                ? CGRect(x: button.minX - collapsedPadding, y: bar.minY + (bar.height - button.height) / 2,
                         width: button.width + collapsedPadding * 2, height: button.height)
                : CGRect(x: button.minX, y: button.maxY + 2, width: button.width, height: 20)
            return MissionControlLabel(name: name, frame: frame, collapsed: collapsed, current: space.isVisible)
        }
    }

    /// Mission Control のディスプレイに並ぶデスクトップ。
    /// ディスプレイごとにデスクトップを分けない設定では Display Identifier が UUID と一致しないので、
    /// 一覧のディスプレイが1つだけならそれを使う。
    public static func spaces(onDisplay uuid: String?, in all: [Space]) -> [Space] {
        if let uuid {
            let matched = all.filter { $0.displayID.caseInsensitiveCompare(uuid) == .orderedSame }
            if !matched.isEmpty { return matched }
        }
        return Set(all.map(\.displayID)).count == 1 ? all : []
    }
}
