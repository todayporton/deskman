import CoreGraphics

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ c: Int32) -> CFArray
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ c: Int32) -> Int
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ c: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
@_silgen_name("CGSGetSymbolicHotKeyValue")
private func CGSGetSymbolicHotKeyValue(_ hotKey: Int32, _ character: UnsafeMutablePointer<UInt16>?,
                                       _ keyCode: UnsafeMutablePointer<UInt16>?,
                                       _ modifiers: UnsafeMutablePointer<UInt32>?) -> Int32
@_silgen_name("CGSIsSymbolicHotKeyEnabled") private func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

public enum SystemSpaces {
    public static func current() -> [Space] {
        let c = CGSMainConnectionID()
        let raw = CGSCopyManagedDisplaySpaces(c) as? [[String: Any]] ?? []
        return SpaceParser.parse(raw, activeID: CGSGetActiveSpace(c))
    }

    /// ウィンドウがあるスペースの数値 ID（Space.managedID と同じ）。7 はすべての種類のスペース。
    public static func spaceIDs(ofWindow id: CGWindowID) -> [Int] {
        CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [id] as CFArray) as? [Int] ?? []
    }

    /// システムのショートカット（AppleSymbolicHotKeys の番号）に WindowServer が割り当てているキー。
    /// 設定ファイルではなく WindowServer から読むので、オフのショートカットや既定のままの項目も、実際に使われるキーが分かる。
    public static func symbolicHotKey(_ id: Int32) -> (keyCode: UInt16, modifiers: UInt32, enabled: Bool)? {
        var character: UInt16 = 0
        var keyCode: UInt16 = 0
        var modifiers: UInt32 = 0
        guard CGSGetSymbolicHotKeyValue(id, &character, &keyCode, &modifiers) == 0 else { return nil }
        return (keyCode, modifiers, CGSIsSymbolicHotKeyEnabled(id))
    }

    /// ショートカットのオンとオフを、このログインの間だけ切り替える（設定ファイルは変わらない）。
    @discardableResult
    public static func setSymbolicHotKey(_ id: Int32, enabled: Bool) -> Bool {
        CGSSetSymbolicHotKeyEnabled(id, enabled) == 0
    }
}
