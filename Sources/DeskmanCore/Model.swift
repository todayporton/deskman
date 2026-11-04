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

/// ウィンドウを運べない理由。
public enum MoveRefusal: Equatable, Sendable {
    case noWindow
    case noTitleBar
    case fullscreen
    case toFullscreen
    case otherDisplay
    case noShortcut
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
    case serverTooOld
    case cannotMoveWindow(MoveRefusal)
    case moveNotConfirmed
    case windowNotCarried
    case remote(code: Int32, message: String)

    public var exitCode: Int32 {
        switch self {
        case .serverNotRunning, .serverTooOld: 7
        case .remote(let code, _): code
        case .nameNotFound, .noNeighbor: 2
        case .notInList: 3
        case .notTrusted: 4
        case .switchNotConfirmed, .moveNotConfirmed, .windowNotCarried: 5
        case .cannotMoveWindow: 8
        case .duplicateName: 6
        case .fullscreenNotNameable, .noUUID, .hasLiveSpace: 1
        }
    }

    public var message: String {
        switch self {
        case .serverNotRunning: "Deskman.app is not running. It must be running to switch desktops: open /Applications/Deskman.app"
        case .serverTooOld: "The running Deskman.app is an older version that cannot move windows. Quit it and open the new version."
        case .remote(_, let message): message
        case .nameNotFound(let q): "Not found: \(q)"
        case .noNeighbor(let offset): offset > 0 ? "There is no desktop to the right." : "There is no desktop to the left."
        case .notInList(let q): "\(q) is not in the current list. Its display may be disconnected."
        case .notTrusted: "Accessibility permission is required. Allow Deskman.app in System Settings > Privacy & Security > Accessibility."
        case .switchNotConfirmed: "Could not confirm the switch."
        case .moveNotConfirmed: "The desktop did not change while holding the window. Moving a window uses the \"Move left/right a space\" shortcuts (System Settings > Keyboard > Keyboard Shortcuts > Mission Control); check that they work."
        case .windowNotCarried: "The desktop changed, but the window did not come along. Its title bar may not be draggable where Deskman holds it, between the red and yellow buttons."
        case .cannotMoveWindow(let reason):
            switch reason {
            case .noWindow: "There is no focused window to move."
            case .noTitleBar: "This window has no title bar to hold, so it cannot be moved."
            case .fullscreen: "Full-screen windows cannot be moved."
            case .toFullscreen: "Windows cannot be moved to a full-screen desktop."
            case .otherDisplay: "Windows can only be moved to a desktop on the same display."
            case .noShortcut: "Assign keys to the \"Move left a space\" and \"Move right a space\" shortcuts in System Settings > Keyboard > Keyboard Shortcuts > Mission Control. Deskman uses them to move windows; they may stay turned off."
            }
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
