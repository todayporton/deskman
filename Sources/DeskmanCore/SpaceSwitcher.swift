import ApplicationServices
import ColorSync
import CoreGraphics
import Foundation
import os

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Dock スワイプを合成してデスクトップを移動する。
///
/// 進捗をほぼ 0 にしてアニメーションする距離をなくす手法は InstantSpaceSwitcher (MIT) を参考にした。
/// VM (macOS 26.6.2) の実測では、3つ先への移動も途中を経由せず約 50ms で完了した。
/// macOS 27 では形式が変わるため、別の組み立て方（`MacOS27`）で送る。
public enum SpaceSwitcher {
    private static let progress = 0.000016
    private static let velocity = 2000.0
    private static let confirmTimeout: TimeInterval = 1
    /// 移動の後、macOS がフォーカスを移すのを待つ時間。移ったのを見つけたらすぐに戻す。
    /// 待ちは裏で行うので、移動の速さには影響しない。
    private static let focusWatch: TimeInterval = 0.5
    /// フォーカス復元の各段階を info レベルで出す。実機ではフォーカスが移るまで 150〜175ms かかった。
    /// 確認方法: /usr/bin/log show --info --last 5m --predicate 'subsystem == "online.todayporton.deskman"'
    private static let log = Logger(subsystem: "online.todayporton.deskman", category: "focus")

    private static let focusQueue = DispatchQueue(label: "deskman.focus", qos: .userInitiated)
    private static let generationLock = NSLock()
    nonisolated(unsafe) private static var generation = 0

    /// 新しい移動が始まったら、前の移動のフォーカス復元を捨てるための番号。
    private static func nextGeneration() -> Int {
        generationLock.withLock {
            generation += 1
            return generation
        }
    }

    private static func isCurrent(_ g: Int) -> Bool {
        generationLock.withLock { generation == g }
    }

    public static func go(to target: Space, restoreCursor: Bool = false, restoreFocus: Bool = false) throws {
        let gen = nextGeneration()
        let spaces = SystemSpaces.current()
        // 順番待ちの間に並びが変わった場合に備えて、最新の一覧で計算する
        guard let fresh = spaces.first(where: { $0.managedID == target.managedID }) else {
            throw DeskmanError.notInList(target.uuid)
        }
        guard case let .swipe(displayID, steps, changeDisplay) = SwitchPlan.make(fresh, in: spaces) else {
            return
        }
        guard AXIsProcessTrusted() else { throw DeskmanError.notTrusted }
        let focus = restoreFocus ? Focus.current() : nil
        if restoreFocus {
            if let focus {
                log.info("記録: pid=\(focus.pid, privacy: .public) window=\(focus.windowID.map(String.init) ?? "nil", privacy: .public) element=\(focus.window != nil, privacy: .public)")
            } else {
                log.info("記録できず: フォーカスのあるアプリを取れない")
            }
        }
        // スワイプはカーソルのあるディスプレイに効くので、カーソルが別のディスプレイにあれば先に移す。
        // フォーカスのあるディスプレイ内の移動でも、カーソルが他のディスプレイにあれば移す必要がある。
        let original = CGEvent(source: nil)?.location
        let warp = cursorDisplayID().map { $0.caseInsensitiveCompare(displayID) != .orderedSame }
            ?? changeDisplay
        defer {
            if restoreCursor, warp, let original {
                CGWarpMouseCursorPosition(original)
            }
        }
        if warp, let point = center(ofDisplay: displayID) {
            CGWarpMouseCursorPosition(point)
        }
        postSwipes(steps)
        try confirm(fresh.managedID)
        // 待ちは返信の後に別のキューで行い、次の移動を遅らせない
        if let focus {
            focusQueue.async { restore(focus, generation: gen) }
        }
    }

    /// キーボードのフォーカスがあるアプリとウィンドウ。
    struct Focus: @unchecked Sendable {
        let pid: pid_t
        let window: AXUIElement?
        let windowID: CGWindowID?

        static func current() -> Focus? {
            var app: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                kAXFocusedApplicationAttribute as CFString, &app) == .success,
                  let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
            let appElement = app as! AXUIElement
            var pid: pid_t = 0
            guard AXUIElementGetPid(appElement, &pid) == .success else { return nil }
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
            let window = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            var id: CGWindowID = 0
            let windowID = window.flatMap { _AXUIElementGetWindow($0, &id) == .success ? id : nil }
            return Focus(pid: pid, window: window, windowID: windowID)
        }

        func isSame(_ other: Focus?) -> Bool {
            other?.pid == pid && other?.windowID == windowID
        }
    }

    /// 移動の後にフォーカスが移ったら、移動前のウィンドウへ戻す。
    /// 戻すウィンドウが画面に出ていないときは戻さない（前に出すと macOS がデスクトップを戻してしまう）。
    /// 次の移動が始まっていたら何もしない。
    private static func restore(_ before: Focus, generation gen: Int) {
        let start = Date()
        let deadline = start.addingTimeInterval(focusWatch)
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        var now = Focus.current()
        while before.isSame(now) {
            guard isCurrent(gen) else { return log.info("中止: 次の移動が始まった (\(ms())ms)") }
            guard Date() < deadline else { return log.info("フォーカスは移らなかった (\(ms())ms)") }
            usleep(5000)
            now = Focus.current()
        }
        log.info("移った: pid=\(now?.pid ?? -1, privacy: .public) window=\(now?.windowID.map(String.init) ?? "nil", privacy: .public) (\(ms())ms)")
        // 画面に出ていないウィンドウを前に出すと、macOS がデスクトップを戻してしまう。
        // ウィンドウ ID が取れないアプリは、そのアプリのウィンドウが画面に出ているかで判定する。
        // 移動の直後は一覧の更新が遅れることも考えて、締め切りまでは待つ
        while !isOnScreen(windowID: before.windowID, pid: before.pid) {
            guard isCurrent(gen) else { return log.info("中止: 次の移動が始まった (\(ms())ms)") }
            guard Date() < deadline else { return log.info("戻さない: 元のウィンドウが画面に出ていない (\(ms())ms)") }
            usleep(5000)
        }
        guard isCurrent(gen) else { return log.info("中止: 次の移動が始まった (\(ms())ms)") }
        let front = AXUIElementSetAttributeValue(AXUIElementCreateApplication(before.pid),
                                                 kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var main = AXError.noValue
        var raise = AXError.noValue
        if let window = before.window {
            main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        log.info("戻した: frontmost=\(front.rawValue, privacy: .public) main=\(main.rawValue, privacy: .public) raise=\(raise.rawValue, privacy: .public) (\(ms())ms)")
        usleep(50000)
        let after = Focus.current()
        log.info("50ms 後: pid=\(after?.pid ?? -1, privacy: .public) window=\(after?.windowID.map(String.init) ?? "nil", privacy: .public) 戻った=\(before.isSame(after), privacy: .public)")
    }

    private static func isOnScreen(windowID: CGWindowID?, pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        if let windowID {
            return list.contains { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) == windowID }
        }
        // 通常のウィンドウ（レイヤー 0）だけを見る。メニューバーの項目などは数えない
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    private static func field(_ n: UInt32) -> CGEventField {
        unsafeBitCast(n, to: CGEventField.self)
    }

    private static func postSwipes(_ steps: Int) {
        if #available(macOS 27, *) {
            return MacOS27.postSwipes(steps)
        }
        let sign: Double = steps > 0 ? 1 : -1
        for _ in 0..<abs(steps) {
            // Began、Changed、Ended の3段階を送る
            for phase: Int64 in [1, 2, 4] {
                guard let e = CGEvent(source: nil) else { return }
                e.setIntegerValueField(field(55), value: 30)  // DockControl
                e.setIntegerValueField(field(110), value: 23)  // DockSwipe
                e.setIntegerValueField(field(132), value: phase)
                e.setDoubleValueField(field(124), value: sign * progress)
                e.setIntegerValueField(field(123), value: 1)  // 水平
                e.setDoubleValueField(field(129), value: sign * velocity)
                e.setDoubleValueField(field(130), value: sign * velocity)
                e.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// カーソルのあるディスプレイの UUID。CGSCopyManagedDisplaySpaces の Display Identifier と同じ形式。
    public static func cursorDisplayID() -> String? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0,
              let cf = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    private static func center(ofDisplay id: String) -> CGPoint? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        for display in ids.prefix(Int(count)) {
            guard let cf = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { continue }
            let uuid = CFUUIDCreateString(nil, cf) as String
            if uuid.caseInsensitiveCompare(id) == .orderedSame {
                let bounds = CGDisplayBounds(display)
                return CGPoint(x: bounds.midX, y: bounds.midY)
            }
        }
        return nil
    }

    private static func confirm(_ managedID: Int) throws {
        let deadline = Date().addingTimeInterval(confirmTimeout)
        while Date() < deadline {
            if SystemSpaces.current().contains(where: { $0.managedID == managedID && $0.isVisible }) {
                return
            }
            usleep(2000)
        }
        throw DeskmanError.switchNotConfirmed
    }
}

extension SpaceSwitcher {
    /// macOS 27 以降のスワイプ合成。
    ///
    /// Raycast 2.10.1 の `setCurrentSpaceWithoutAnimation(at:)` を逆アセンブルして読んだ形式をなぞる。
    /// macOS 27 では、フィールドを設定するだけでなく、シリアライズしたイベントの末尾に
    /// HID の DockSwipe イベント（タグ 4205）を足して作り直している。
    /// macOS 27 の環境がないため、実際に切り替わるかは未確認。
    enum MacOS27 {
        static let hidEventTag: UInt16 = 4205
        static let progress = 0.000016
        static let velocity = 9999.0

        static func postSwipes(_ steps: Int) {
            let direction = steps > 0 ? fingerSign() : -fingerSign()
            for _ in 0..<abs(steps) {
                for phase: Int64 in [1, 2, 4] {
                    guard let e = event(phase: phase, direction: direction),
                          let companion = CGEvent(source: nil) else { return }
                    companion.setIntegerValueField(field(55), value: 29)  // Gesture
                    e.post(tap: .cgSessionEventTap)
                    companion.post(tap: .cgSessionEventTap)
                }
            }
        }

        /// ナチュラルスクロールが有効（未設定も含む）なら −1。Raycast と同じ扱い。
        static func fingerSign() -> Double {
            let natural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                                    kCFPreferencesAnyApplication) as? Bool
            return natural ?? true ? -1 : 1
        }

        static func event(phase: Int64, direction: Double) -> CGEvent? {
            guard let e = CGEvent(source: nil) else { return nil }
            let p = direction * progress
            e.setIntegerValueField(field(55), value: 30)  // DockControl
            e.setIntegerValueField(field(110), value: 23)  // DockSwipe
            e.setIntegerValueField(field(132), value: phase)
            e.setIntegerValueField(field(134), value: phase)
            e.setIntegerValueField(field(135), value: Int64(Int32(bitPattern: Float(p).bitPattern)))
            e.setIntegerValueField(field(123), value: 1)  // 水平
            e.setIntegerValueField(field(115), value: 0)
            e.setDoubleValueField(field(124), value: p)
            e.setDoubleValueField(field(125), value: 0.1)
            e.setDoubleValueField(field(126), value: 0)
            if phase == 4 {
                e.setDoubleValueField(field(129), value: direction * velocity)
            }
            e.setDoubleValueField(field(130), value: 0)
            e.setDoubleValueField(field(138), value: 3)
            e.setDoubleValueField(field(169), value: Double(mach_absolute_time()))
            guard let serialized = e.data as Data? else { return nil }
            var data = serialized
            appendRecord(tag: hidEventTag,
                         payload: hidPayload(phase: phase, progress: p, timestamp: mach_absolute_time()),
                         to: &data)
            return CGEvent(withDataAllocator: nil, data: data as CFData)
        }

        /// シリアライズしたイベントの末尾に、長さとタグ（どちらも 2 バイトの big-endian）と中身を足す。
        static func appendRecord(tag: UInt16, payload: Data, to data: inout Data) {
            precondition(payload.count <= Int(UInt16.max))
            append(UInt16(payload.count).bigEndian, to: &data)
            append((tag & 0x3fff).bigEndian, to: &data)
            data.append(payload)
        }

        /// HID の DockSwipe イベント 1 個をシリアライズしたもの（68 バイト、little-endian）。
        /// 並びは IOKit の IOHIDEventData（size, type, options, depth）と一致する。
        static func hidPayload(phase: Int64, progress: Double, timestamp: UInt64) -> Data {
            var d = Data()
            // ヘッダ
            append(timestamp.littleEndian, to: &d)
            append(UInt64(0), to: &d)  // senderID
            append(UInt32(0), to: &d)  // options
            append(UInt32(0), to: &d)  // 属性の長さ
            append(UInt32(1).littleEndian, to: &d)  // イベントの数
            // DockSwipe イベント
            append(UInt32(40).littleEndian, to: &d)  // size
            append(UInt32(23).littleEndian, to: &d)  // type: DockSwipe
            append((UInt32(truncatingIfNeeded: phase) << 24).littleEndian, to: &d)  // options: 段階
            d.append(contentsOf: [0, 0, 0, 0])  // depth, reserved
            append(ioFixed(0.1).littleEndian, to: &d)
            append(Int32(0), to: &d)
            append(Int32(0), to: &d)
            append(Int32(0), to: &d)
            append(UInt16(1).littleEndian, to: &d)
            append(UInt16(3).littleEndian, to: &d)
            append(ioFixed(progress).littleEndian, to: &d)
            return d
        }

        /// 16.16 の固定小数点。0 でない値が 0 に丸められるときは ±1 にする（Raycast と同じ）。
        static func ioFixed(_ value: Double) -> Int32 {
            let scaled = (value * 65536).rounded(.towardZero)
            if scaled >= Double(Int32.max) { return .max }
            if scaled <= Double(Int32.min) { return .min }
            let fixed = Int32(scaled)
            if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
            return fixed
        }

        private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
    }
}
