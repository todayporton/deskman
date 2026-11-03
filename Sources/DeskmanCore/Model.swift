public struct Space: Equatable, Sendable {
    /// 空の場合がある（既定のデスクトップなど）。空なら名前を付けられない。
    public let uuid: String
    /// 一時的な値。保存してはいけない（再接続で変わることを実測済み）。
    public let managedID: Int
    public let displayID: String
    /// 全ディスプレイを通した1始まりの番号。
    public let index: Int
    public let isFullscreen: Bool
    /// そのディスプレイで表示中か。
    public let isVisible: Bool
    /// キーボードフォーカスのあるデスクトップか。
    public let isActive: Bool

    public init(uuid: String, managedID: Int, displayID: String, index: Int,
                isFullscreen: Bool, isVisible: Bool, isActive: Bool) {
        self.uuid = uuid
        self.managedID = managedID
        self.displayID = displayID
        self.index = index
        self.isFullscreen = isFullscreen
        self.isVisible = isVisible
        self.isActive = isActive
    }
}

public enum DeskmanError: Error, Equatable {
    case nameNotFound(String)
    case noNeighbor(Int)
    case notInList(String)
    case notTrusted
    case switchNotConfirmed
    case duplicateName(String)
    case fullscreenNotNameable
    case noUUID
    case hasLiveSpace(String)
    case serverNotRunning
    case remote(code: Int32, message: String)

    public var exitCode: Int32 {
        switch self {
        case .serverNotRunning: 7
        case .remote(let code, _): code
        case .nameNotFound, .noNeighbor: 2
        case .notInList: 3
        case .notTrusted: 4
        case .switchNotConfirmed: 5
        case .duplicateName: 6
        case .fullscreenNotNameable, .noUUID, .hasLiveSpace: 1
        }
    }

    public var message: String {
        switch self {
        case .serverNotRunning: "Deskman.app が起動していません。移動には起動が必要です: open /Applications/Deskman.app"
        case .remote(_, let message): message
        case .nameNotFound(let q): "見つかりません: \(q)"
        case .noNeighbor(let offset): offset > 0 ? "これより右にデスクトップはありません。" : "これより左にデスクトップはありません。"
        case .notInList(let q): "\(q) は今の一覧にありません。ディスプレイが外れている可能性があります。"
        case .notTrusted: "アクセシビリティ権限が必要です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で Deskman.app を許可してください。"
        case .switchNotConfirmed: "移動を確認できませんでした。"
        case .duplicateName(let n): "すでに使われている名前です: \(n)"
        case .fullscreenNotNameable: "フルスクリーンのデスクトップには名前を付けられません。"
        case .noUUID: "このデスクトップにはまだ UUID がないので、名前を付けられません。デスクトップを追加すると割り当てられることがあります。"
        case .hasLiveSpace(let n): "\(n) は今の一覧にあるので消せません。解除するには rename <対象> \"\" を使ってください。"
        }
    }

    /// 指定は正しいが行き先がなくて移動できなかったとき。常駐アプリが通知音を鳴らす。
    /// 打ち間違いや権限の問題は、音ではなくメッセージで知らせる。
    public var playsAlertSound: Bool {
        switch self {
        case .noNeighbor, .notInList: true
        default: false
        }
    }
}
