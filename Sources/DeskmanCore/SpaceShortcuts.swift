import CoreGraphics
import Foundation

/// 「左／右の操作スペースに移動」のキーボードショートカット。ウィンドウを運ぶときに使う。
public struct SpaceShortcut: Equatable, Sendable {
    public let keyCode: CGKeyCode
    /// CGEventFlags と同じビット
    public let modifiers: UInt64

    public init(keyCode: CGKeyCode, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// キーが割り当てられていなければ nil（キーコード 0xFFFF は「なし」）
    public init?(keyCode: UInt16, modifiers: UInt32) {
        guard keyCode != 0xFFFF else { return nil }
        self.init(keyCode: CGKeyCode(keyCode), modifiers: UInt64(modifiers))
    }

    /// 送るときのフラグ。矢印キーはテンキーの印も付いた状態で届く。
    public var flags: CGEventFlags {
        var flags = CGEventFlags(rawValue: modifiers)
        if (123...126).contains(keyCode) { flags.insert(.maskNumericPad) }
        return flags
    }
}

/// システム設定 > キーボード > キーボードショートカット > Mission Control の
/// 「左の操作スペースに移動」（79）と「右の操作スペースに移動」（81）。
///
/// Raycast の「Move to Next/Previous Desktop」と同じく、キーは WindowServer から読み、
/// オフなら運ぶ間だけオンにして元に戻す。ユーザーがオフにしていても使える（VM で確認）。
/// 同じ組の 80 と 82 は、オンにしてキーを割り当てても切り替わらなかった（VM macOS 26.6.2）ので使わない。
public enum SpaceShortcuts {
    static func id(right: Bool) -> Int32 { right ? 81 : 79 }

    /// 割り当てられたキーと、今オンかどうか。キーがなければ nil。
    public static func current(right: Bool) -> (shortcut: SpaceShortcut, enabled: Bool)? {
        guard let value = SystemSpaces.symbolicHotKey(id(right: right)),
              let shortcut = SpaceShortcut(keyCode: value.keyCode, modifiers: value.modifiers) else { return nil }
        return (shortcut, value.enabled)
    }

    /// オフのショートカットを body の間だけオンにする。失敗しても元に戻す。
    /// 進む向きの片方だけをオンにしてすぐ送ると、実機（ディスプレイ 2 台）で左が効かなかった。
    /// 設定でオンにしておくと効いたので、両方をオンにし、反映を待ってから送る。
    public static func whileEnabled<T>(_ body: () throws -> T) rethrows -> T {
        let off = [id(right: false), id(right: true)].filter { SystemSpaces.symbolicHotKey($0)?.enabled == false }
        guard !off.isEmpty else { return try body() }
        for id in off { SystemSpaces.setSymbolicHotKey(id, enabled: true) }
        defer { for id in off { SystemSpaces.setSymbolicHotKey(id, enabled: false) } }
        usleep(settleDelay)
        return try body()
    }

    /// オンにしてから Dock に届くまで待つ時間
    static let settleDelay: useconds_t = 50_000
}
