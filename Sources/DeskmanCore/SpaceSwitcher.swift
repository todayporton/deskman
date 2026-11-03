import ApplicationServices
import ColorSync
import CoreGraphics
import Foundation

/// Dock スワイプを合成してデスクトップを移動する。
///
/// 進捗をほぼ 0 にしてアニメーションする距離をなくす手法は InstantSpaceSwitcher (MIT) を参考にした。
/// VM (macOS 26.6.2) の実測では、3つ先への移動も途中を経由せず約 50ms で完了した。
/// macOS 27 ではイベントの形式が変わると InstantSpaceSwitcher に記載があり、そこは未対応。
public enum SpaceSwitcher {
    private static let progress = 0.000016
    private static let velocity = 2000.0
    private static let confirmTimeout: TimeInterval = 1

    public static func go(to target: Space, restoreCursor: Bool = false) throws {
        let spaces = SystemSpaces.current()
        // 順番待ちの間に並びが変わった場合に備えて、最新の一覧で計算する
        guard let fresh = spaces.first(where: { $0.managedID == target.managedID }) else {
            throw DeskmanError.notInList(target.uuid)
        }
        guard case let .swipe(displayID, steps, changeDisplay) = SwitchPlan.make(fresh, in: spaces) else {
            return
        }
        guard AXIsProcessTrusted() else { throw DeskmanError.notTrusted }
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
    }

    private static func field(_ n: UInt32) -> CGEventField {
        unsafeBitCast(n, to: CGEventField.self)
    }

    private static func postSwipes(_ steps: Int) {
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
