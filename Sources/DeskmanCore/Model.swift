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
        case .serverNotRunning: "Deskman.app is not running. It must be running to switch desktops: open /Applications/Deskman.app"
        case .remote(_, let message): message
        case .nameNotFound(let q): "Not found: \(q)"
        case .noNeighbor(let offset): offset > 0 ? "There is no desktop to the right." : "There is no desktop to the left."
        case .notInList(let q): "\(q) is not in the current list. Its display may be disconnected."
        case .notTrusted: "Accessibility permission is required. Allow Deskman.app in System Settings > Privacy & Security > Accessibility."
        case .switchNotConfirmed: "Could not confirm the switch."
        case .duplicateName(let n): "Name already in use: \(n)"
        case .fullscreenNotNameable: "Full-screen desktops cannot be named."
        case .noUUID: "This desktop has no UUID yet, so it cannot be named. Adding a desktop may assign one."
        case .hasLiveSpace(let n): "\(n) is in the current list, so it cannot be forgotten. To remove the name, use rename <target> \"\"."
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
