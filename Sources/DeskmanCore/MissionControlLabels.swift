import CoreGraphics

/// Mission Control の画面の上端に出す名前と位置。座標はアクセシビリティと同じ左上原点。
public struct MissionControlLabel: Equatable, Sendable {
    public let name: String
    public let frame: CGRect
    /// そのディスプレイで表示中のデスクトップか
    public let current: Bool

    public init(name: String, frame: CGRect, current: Bool) {
        self.name = name
        self.frame = frame
        self.current = current
    }
}

/// Dock から読んだボタンの並びを、デスクトップと名前に対応付ける。
/// 実測（VM macOS 26.6.2）は設計資料の「Mission Control に名前を出す検証」を参照。
public enum MissionControlLabels {
    /// ノッチの高さ。折りたたまれたバーの元の名前と表示中のハイライト（上端から約 34pt まで）を覆う。
    /// バーが開いているときは、上端から 28pt 下に並ぶサムネイル（VM で実測）に少し重なる。
    public static let height: CGFloat = 34
    /// 隣のノッチとの隙間
    public static let gap: CGFloat = 4
    /// 折りたたまれたバーをまだ見ていないときの幅（VM では折りたたまれたバーから 94pt）
    public static let fallbackWidth: CGFloat = 90

    /// ノッチの幅。折りたたまれたバーで隣と重ならない最大の幅（ボタンの中心の間隔の最小から隙間を引く）。
    /// 開いているときも同じ幅を使い、開閉では位置だけが動く。折りたたまれていなければ nil。
    public static func width(buttons: [CGRect]) -> CGFloat? {
        guard let first = buttons.first, first.height < 40 else { return nil }
        let centers = buttons.map(\.midX).sorted()
        let spacing = zip(centers, centers.dropFirst()).map { $1 - $0 }.min()
        // デスクトップが 1 つなら、ボタンと表示中のハイライト（左右 10pt）を覆う幅
        return spacing.map { $0 - gap } ?? first.width + 20
    }

    /// 1つのディスプレイの Spaces Bar について、フルスクリーン以外のデスクトップの名前を返す。
    /// 名前は画面の上端に、各デスクトップのボタンの中心の真上に置く（ノッチの形で上から降りてくる）。
    /// 名前を付けていないデスクトップは、メニューと同じく「Desktop 番号」。
    /// buttons はデスクトップのボタンの枠（並び順）、top は画面の上端の y、width は幅（width(buttons:) を覚えたもの）。
    /// ボタンの数とデスクトップの数が合わないときは、取り違えを避けて何も返さない。
    public static func make(buttons: [CGRect], top: CGFloat, width: CGFloat, spaces: [Space],
                            names: [String: String]) -> [MissionControlLabel] {
        guard buttons.count == spaces.count else { return [] }
        return zip(buttons, spaces).compactMap { button, space in
            guard !space.isFullscreen else { return nil }
            let name = names[space.uuid].flatMap { $0.isEmpty ? nil : $0 } ?? "Desktop \(space.index)"
            let frame = CGRect(x: button.midX - width / 2, y: top, width: width, height: height)
            return MissionControlLabel(name: name, frame: frame, current: space.isVisible)
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
