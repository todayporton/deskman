// 検証用。フォーカスのあるウィンドウをタイトルバーで掴んだままデスクトップを切り替え、
// ウィンドウを運べるかを試す。ホストでは実行しない（spike/move-window.sh で VM 用の .app にする）。
// 使い方: move <行き先の番号> [stay] [key | swipe=hid+gesture+slow] [nodrag] [掴んでから切り替えるまでの ms] [離すまでの ms]
// 前面のアプリが自分以外になるまで待ってから動く。macvm activate で運びたいウィンドウを前に出す。
import AppKit
import ApplicationServices
import DeskmanCore

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ c: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let targetIndex = args.first.flatMap(Int.init) else {
    print("usage: move <index> [stay] [grabMs] [releaseMs]")
    exit(64)
}
let stay = args.contains("stay")
let numbers = args.dropFirst().compactMap { Int($0) }
let grabDelay = numbers.first ?? 50
let releaseDelay = numbers.dropFirst().first ?? 50

func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func spaces(of window: CGWindowID) -> [Int] {
    CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [window] as CFArray) as? [Int] ?? []
}
@_silgen_name("CGSGetSymbolicHotKeyValue")
func CGSGetSymbolicHotKeyValue(_ hotKey: Int32, _ key: UnsafeMutablePointer<UInt16>?, _ code: UnsafeMutablePointer<UInt16>?, _ mods: UnsafeMutablePointer<UInt32>?) -> Int32
@_silgen_name("CGSIsSymbolicHotKeyEnabled") func CGSIsSymbolicHotKeyEnabled(_ hotKey: Int32) -> Bool
@_silgen_name("CGSSetSymbolicHotKeyEnabled") func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ on: Bool) -> Int32
func hotKeyInfo(_ id: Int32) -> (code: UInt16, mods: UInt32, enabled: Bool, err: Int32) {
    var k: UInt16 = 0, c: UInt16 = 0, m: UInt32 = 0
    let err = CGSGetSymbolicHotKeyValue(id, &k, &c, &m)
    return (c, m, CGSIsSymbolicHotKeyEnabled(id), err)
}
for id: Int32 in [79, 80, 81, 82] {
    let i = hotKeyInfo(id)
    print("hotkey \(id): code=\(i.code) mods=0x\(String(i.mods, radix: 16)) enabled=\(i.enabled) err=\(i.err)")
}
// hkoff: 79/81 を無効にしただけで終わる（ユーザーの環境の再現）。hkon: 有効に戻すだけ
if CommandLine.arguments.contains("hkoff") || CommandLine.arguments.contains("hkon") {
    let on = CommandLine.arguments.contains("hkon")
    for id: Int32 in [79, 81] { print("set \(id) \(on) -> \(CGSSetSymbolicHotKeyEnabled(id, on))") }
    for id: Int32 in [79, 81] { print("now \(id) enabled=\(CGSIsSymbolicHotKeyEnabled(id))") }
    exit(0)
}

func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
/// SpaceSwitcher と同じ DockSwipe を、送り先や付け足すイベントを変えて送る（掴んだまま切り替わるかの検証）
/// mode: hid = HID の段に送る、gesture = Gesture イベントも送る、slow = Changed を間隔を空けて何度も送る
func swipe(_ steps: Int, modes: Set<String>) {
    let sign: Double = steps > 0 ? 1 : -1
    let tap: CGEventTapLocation = modes.contains("hid") ? .cghidEventTap : .cgSessionEventTap
    for _ in 0..<abs(steps) {
        var phases: [(Int64, Double)] = [(1, 0.000016), (2, 0.000016), (4, 0.000016)]
        if modes.contains("slow") {
            phases = [(1, 0.01)] + (1...10).map { (2, Double($0) * 0.1) } + [(4, 1.0)]
        }
        for (phase, progress) in phases {
            guard let e = CGEvent(source: nil) else { return }
            e.setIntegerValueField(field(55), value: 30)
            e.setIntegerValueField(field(110), value: 23)
            e.setIntegerValueField(field(132), value: phase)
            e.setDoubleValueField(field(124), value: sign * progress)
            e.setIntegerValueField(field(123), value: 1)
            let v = modes.contains("slow") ? (phase == 4 ? 2.0 : 0.5) : 9999.0
            e.setDoubleValueField(field(129), value: sign * v)
            e.setDoubleValueField(field(130), value: sign * v)
            e.post(tap: tap)
            if modes.contains("gesture"), let g = CGEvent(source: nil) {
                g.setIntegerValueField(field(55), value: 29)
                g.post(tap: tap)
            }
            if modes.contains("slow") { usleep(16_000) }
        }
    }
}

func mouse(_ type: CGEventType, _ point: CGPoint) {
    let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                    mouseCursorPosition: point, mouseButton: .left)
    if type != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cghidEventTap)
}

guard AXIsProcessTrusted() else { print("not trusted"); exit(4) }
// 前面のアプリが自分以外になるまで待つ（最大 60 秒）
let me = ProcessInfo.processInfo.processIdentifier
for _ in 0..<600 {
    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me { break }
    usleep(100_000)
}
usleep(2_000_000)

// 前面のアプリのウィンドウ
guard let front = NSWorkspace.shared.frontmostApplication else { print("no front app"); exit(1) }
let appElement = AXUIElementCreateApplication(front.processIdentifier)
let windows = attr(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
print("front=\(front.bundleIdentifier ?? "?") pid=\(front.processIdentifier) windows=\(windows.count)")
guard let window = attr(appElement, kAXFocusedWindowAttribute) ?? attr(appElement, kAXMainWindowAttribute)
        ?? windows.first else { print("no window"); exit(1) }
let w = window as! AXUIElement
var wid: CGWindowID = 0
_ = _AXUIElementGetWindow(w, &wid)
guard let wf = frame(w) else { print("no frame"); exit(1) }
// 掴む位置: 拡大ボタンのすぐ右。ボタンがなければ左上から少し内側
let grab: CGPoint
if let zoom = attr(w, kAXZoomButtonAttribute), let zf = frame(zoom as! AXUIElement) {
    grab = CGPoint(x: zf.maxX + 12, y: zf.midY)
} else {
    grab = CGPoint(x: wf.minX + 90, y: wf.minY + 14)
}
let all = SystemSpaces.current()
// 行き先 0 は、デスクトップ 1 と 2 を行き来する（繰り返し試す用）
let activeIndex = all.first(where: \.isActive)?.index ?? 1
let wanted = targetIndex == 0 ? (activeIndex == 1 ? 2 : 1) : targetIndex
guard let origin = all.first(where: \.isActive), let target = all.first(where: { $0.index == wanted }) else {
    print("no target"); exit(1)
}
print("window=\(wid) frame=\(wf) grab=\(grab) spaces=\(spaces(of: wid)) from=\(origin.index)(\(origin.managedID)) to=\(target.index)(\(target.managedID))")

let start = Date()
let cursor = CGEvent(source: nil)?.location ?? .zero
CGWarpMouseCursorPosition(grab)
if args.contains("moved") {
    // ワープした直後の押下が無視されることがあるので、移動のイベントを送ってから押す
    mouse(.mouseMoved, grab)
    usleep(20_000)
}
mouse(.leftMouseDown, grab)
usleep(useconds_t(grabDelay * 1000))
// 少し動かして、ドラッグとして扱わせる
if !args.contains("nodrag") {
    mouse(.leftMouseDragged, CGPoint(x: grab.x + 1, y: grab.y))
    mouse(.leftMouseDragged, grab)
}
print("grabbed \(ms(start))ms")
if args.contains("hk") {
    // Raycast と同じ: 79/81 のキーを WindowServer から読み、無効なら一時的に有効にして送り、元に戻す
    let steps = target.index - origin.index
    let id: Int32 = steps > 0 ? 81 : 79
    let info = hotKeyInfo(id)
    if !info.enabled { print("enable \(id) -> \(CGSSetSymbolicHotKeyEnabled(id, true))") }
    let row = all.filter { $0.displayID == origin.displayID }
    var here = row.firstIndex { $0.managedID == origin.managedID }!
    for _ in 0..<abs(steps) {
        var flags = CGEventFlags(rawValue: UInt64(info.mods))
        if (123...126).contains(info.code) { flags.insert(.maskNumericPad) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: info.code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cgSessionEventTap)
        }
        here += steps > 0 ? 1 : -1
        let next = row[here].managedID
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !SystemSpaces.current().contains(where: { $0.managedID == next && $0.isVisible }) {
            usleep(2000)
        }
        print("  step \(ms(start))ms visible=\(SystemSpaces.current().first(where: \.isVisible)?.index ?? -1)")
    }
    if !info.enabled { print("restore \(id) -> \(CGSSetSymbolicHotKeyEnabled(id, false))") }
} else if args.contains("key") {
    // Control+→ / Control+← を、行き先までの数だけ送る
    let steps = target.index - origin.index
    let code: CGKeyCode = steps > 0 ? 124 : 123
    let row = all.filter { $0.displayID == origin.displayID }
    var here = row.firstIndex { $0.managedID == origin.managedID }!
    for _ in 0..<abs(steps) {
        // 1つずつ送り、着いてから次を送る（続けて送ると掴んだ状態が外れた）
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e?.post(tap: .cgSessionEventTap)
        }
        here += steps > 0 ? 1 : -1
        let next = row[here].managedID
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !SystemSpaces.current().contains(where: { $0.managedID == next && $0.isVisible }) {
            usleep(2000)
        }
        print("  step \(ms(start))ms")
        usleep(useconds_t(releaseDelay * 1000))
    }
    print("switched(key) \(ms(start))ms visible=\(SystemSpaces.current().first(where: \.isVisible)?.index ?? -1)")
} else if let m = args.first(where: { $0.hasPrefix("swipe=") }) {
    let modes = Set(m.dropFirst(6).split(separator: "+").map(String.init))
    swipe(target.index - origin.index, modes: modes)
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline, !SystemSpaces.current().contains(where: { $0.managedID == target.managedID && $0.isVisible }) {
        usleep(2000)
    }
    print("switched(\(m)) \(ms(start))ms visible=\(SystemSpaces.current().first(where: \.isVisible)?.index ?? -1)")
} else {
    do {
        try SpaceSwitcher.go(to: target)
        print("switched \(ms(start))ms")
    } catch {
        print("switch failed: \(error)")
    }
}
usleep(useconds_t(releaseDelay * 1000))
mouse(.leftMouseUp, grab)
CGWarpMouseCursorPosition(cursor)
print("released \(ms(start))ms spaces=\(spaces(of: wid))")
if stay {
    // 離した直後はスワイプが効かないことがあったので、間を空ける
    let wait = Int(ProcessInfo.processInfo.environment["RETURN_MS"] ?? "") ?? args.compactMap { $0.hasPrefix("r") ? Int($0.dropFirst()) : nil }.first ?? 0
    usleep(useconds_t(wait * 1000))
    print("return after \(wait)ms")
    do {
        try SpaceSwitcher.go(to: origin)
        print("returned \(ms(start))ms")
    } catch {
        print("return failed: \(error)")
    }
}
usleep(300_000)
let after = frame(w).map { "\($0)" } ?? "?"
print("after 300ms: spaces=\(spaces(of: wid)) frame=\(after) active=\(SystemSpaces.current().first(where: \.isActive)?.index ?? -1)")
