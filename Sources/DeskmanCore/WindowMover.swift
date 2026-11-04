import ApplicationServices
import CoreGraphics
import Foundation
import os

/// フォーカスのあるウィンドウの移動の道筋。行き先までに通るデスクトップを、1 ステップずつ並べる。
public struct MovePlan: Equatable, Sendable {
    public let origin: Space
    /// 最後が行き先。空なら移動しない（すでに行き先にいる）。
    public let path: [Space]

    /// ウィンドウは表示中（フォーカスのある）デスクトップにあるものとして、同じディスプレイの中だけを運ぶ。
    public static func make(to target: Space, spaces: [Space]) throws -> MovePlan {
        guard let origin = spaces.first(where: \.isActive) else {
            throw DeskmanError.nameNotFound("current")
        }
        if origin.isFullscreen { throw DeskmanError.cannotMoveWindow(.fullscreen) }
        guard target.displayID == origin.displayID else {
            throw DeskmanError.cannotMoveWindow(.otherDisplay)
        }
        if target.isFullscreen { throw DeskmanError.cannotMoveWindow(.toFullscreen) }
        let row = spaces.filter { $0.displayID == origin.displayID }
        guard let from = row.firstIndex(where: { $0.managedID == origin.managedID }),
              let to = row.firstIndex(where: { $0.managedID == target.managedID }) else {
            throw DeskmanError.notInList(target.uuid)
        }
        let path: [Space] = from < to ? Array(row[(from + 1)...to]) : Array(row[to..<from].reversed())
        // 途中のフルスクリーンも 1 ステップとして通る（Control+矢印は Mission Control の並びどおりに進む）
        return MovePlan(origin: origin, path: path)
    }
}

/// フォーカスのあるウィンドウを、タイトルバーで掴んだままデスクトップを切り替えて運ぶ。
///
/// 掴んでいる間は Dock スワイプの合成が効かないので、キーボードショートカット
/// 「右／左の操作スペースに移動」（既定は Control+→ / Control+←）で 1 ステップずつ切り替える。続けて送ると掴んだ状態が外れるので、
/// 着いたのを確かめてから次を送る。実測は設計資料の「ウィンドウを別のデスクトップへ運ぶ検証」を参照。
public enum WindowMover {
    /// 実機で失敗したときに状況を追えるよう、運ぶたびに記録する（log show --predicate 'subsystem == "online.todayporton.deskman"'）
    private static let log = Logger(subsystem: "online.todayporton.deskman", category: "move")
    /// 1 ステップを待つ上限。アニメーションは約 330ms（掴み損ねたときは約 620ms）。
    private static let stepTimeout: TimeInterval = 1.5
    /// 掴んでから切り替えるまで、着いてから離すまで、離してから戻るまでの間（VM で調整）
    private static let grabDelay: useconds_t = 50_000
    private static let releaseDelay: useconds_t = 50_000
    private static let returnDelay: useconds_t = 50_000

    public static func move(to target: Space, stay: Bool) throws {
        guard AXIsProcessTrusted() else { throw DeskmanError.notTrusted }
        let plan = try MovePlan.make(to: target, spaces: SystemSpaces.current())
        guard !plan.path.isEmpty else { return }
        let right = plan.path[0].index > plan.origin.index
        // 「左／右の操作スペースに移動」に割り当てられたキーを使う。オフなら運ぶ間だけオンにする
        guard let (shortcut, enabled) = SpaceShortcuts.current(right: right) else {
            throw DeskmanError.cannotMoveWindow(.noShortcut)
        }
        let window = try focusedWindow()
        if boolAttribute(window, "AXFullScreen") == true { throw DeskmanError.cannotMoveWindow(.fullscreen) }
        guard let close = buttonFrame(window, kAXCloseButtonAttribute) else {
            throw DeskmanError.cannotMoveWindow(.noTitleBar)
        }
        // Raycast と同じく、閉じるボタンと最小化ボタンの間の上寄りを掴む。
        // 拡大ボタンの右はツールバーやタブが置かれていて掴めないアプリがあった（実機）
        let gapRight = buttonFrame(window, kAXMinimizeButtonAttribute)?.minX ?? close.maxX + 6
        let grab = CGPoint(x: (close.maxX + gapRight) / 2, y: close.minY + close.height / 4)
        let windowID = SpaceSwitcher.windowID(of: window)

        let cursor = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(grab)
        mouse(.leftMouseDown, grab)
        // 押すだけで運べる。以前は 1pt 動かして戻すドラッグを足していたが、戻す方が効かず、
        // 掴んでいる間ウィンドウが右へずれた（離すと戻る）。省いても VM で 4 回とも運べた
        usleep(grabDelay)

        log.notice("move from=\(plan.origin.index) display=\(plan.origin.displayID, privacy: .public) path=\(plan.path.map(\.index), privacy: .public) key=\(shortcut.keyCode) mods=0x\(String(shortcut.modifiers, radix: 16), privacy: .public) enabled=\(enabled) grab=\(grab.debugDescription, privacy: .public)")
        let arrived = SpaceShortcuts.whileEnabled {
            log.notice("hotkey enabled left=\(SpaceShortcuts.current(right: false)?.enabled ?? false) right=\(SpaceShortcuts.current(right: true)?.enabled ?? false) cursor=\((CGEvent(source: nil)?.location).debugDescription, privacy: .public)")
            for step in plan.path {
                press(shortcut)
                let ok = waitUntilVisible(step.managedID)
                let visible = SystemSpaces.current().filter(\.isVisible).map(\.index)
                log.notice("step to=\(step.index) ok=\(ok) visible=\(visible, privacy: .public)")
                if !ok { return false }
            }
            return true
        }
        usleep(releaseDelay)
        mouse(.leftMouseUp, grab)
        if let cursor { CGWarpMouseCursorPosition(cursor) }
        // ウィンドウが行き先へ移ったかを確かめる。掴み損ねると、自分だけが移ってウィンドウは残る
        let carried = windowID.map { id in
            plan.path.last.map { SystemSpaces.spaceIDs(ofWindow: id).contains($0.managedID) } ?? true
        } ?? true
        log.notice("released arrived=\(arrived) carried=\(carried) windowSpaces=\(windowID.map { SystemSpaces.spaceIDs(ofWindow: $0) } ?? [], privacy: .public)")
        if !arrived || !carried {
            // 途中のデスクトップに置き去りにしない
            usleep(returnDelay)
            try? SpaceSwitcher.go(to: plan.origin)
            throw arrived ? DeskmanError.windowNotCarried : DeskmanError.moveNotConfirmed
        }
        if stay {
            // 離した直後はスワイプが効かないことがあった
            usleep(returnDelay)
            try SpaceSwitcher.go(to: plan.origin)
        }
    }

    private static func focusedWindow() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let app = attribute(system, kAXFocusedApplicationAttribute),
              CFGetTypeID(app) == AXUIElementGetTypeID() else {
            throw DeskmanError.cannotMoveWindow(.noWindow)
        }
        let appElement = app as! AXUIElement
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = attribute(appElement, name), CFGetTypeID(w) == AXUIElementGetTypeID() {
                return w as! AXUIElement
            }
        }
        throw DeskmanError.cannotMoveWindow(.noWindow)
    }

    private static func waitUntilVisible(_ managedID: Int) -> Bool {
        let deadline = Date().addingTimeInterval(stepTimeout)
        while Date() < deadline {
            if SystemSpaces.current().contains(where: { $0.managedID == managedID && $0.isVisible }) {
                return true
            }
            usleep(2000)
        }
        return false
    }

    /// HID のイベントソースで作り、クリック回数を付けて HID の段に送る。
    /// ソースなしで cgSessionEventTap に送ると、ほとんど掴めなかった（VM で実測）。
    private static func mouse(_ type: CGEventType, _ point: CGPoint) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                        mouseCursorPosition: point, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.post(tap: .cghidEventTap)
    }

    private static func press(_ shortcut: SpaceShortcut) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down)
            e?.flags = shortcut.flags
            e?.post(tap: .cgSessionEventTap)
        }
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func buttonFrame(_ window: AXUIElement, _ name: String) -> CGRect? {
        guard let button = attribute(window, name), CFGetTypeID(button) == AXUIElementGetTypeID() else { return nil }
        return frame(button as! AXUIElement)
    }

    private static func boolAttribute(_ e: AXUIElement, _ name: String) -> Bool? {
        (attribute(e, name) as? NSNumber)?.boolValue
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attribute(e, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(e, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
