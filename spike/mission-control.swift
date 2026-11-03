// 検証用。Mission Control のデスクトップ名の上に、設定した名前を重ねられるかを試す。ホストでは実行しない。
// 使い方（Deskman.app と同じ bundle ID・署名の .app に入れて VM で起動する。spike/mission-control.sh）:
//   dump     Mission Control を開くたびに Dock のアクセシビリティ要素を出力する
//   overlay  Mission Control のデスクトップ名の上に名前を重ねる
// 出力は stdout（macvm logs で読む）。
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let mode = CommandLine.arguments.dropFirst().first ?? "dump"
let start = Date()
func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}
func describe(_ e: AXUIElement) -> String {
    let parts: [(String, String?)] = [
        ("role", str(e, kAXRoleAttribute)), ("subrole", str(e, kAXSubroleAttribute)),
        ("title", str(e, kAXTitleAttribute)), ("desc", str(e, kAXDescriptionAttribute)),
        ("id", str(e, kAXIdentifierAttribute)), ("value", (attr(e, kAXValueAttribute)).map { "\($0)" }),
    ]
    let f = frame(e).map { " frame=\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
    return parts.compactMap { k, v in v.map { "\(k)=\($0)" } }.joined(separator: " ") + f
}
func dump(_ e: AXUIElement, depth: Int = 0, max: Int = 12) {
    print(String(repeating: "  ", count: depth) + describe(e))
    guard depth < max else { return }
    for c in children(e) { dump(c, depth: depth + 1, max: max) }
}

guard AXIsProcessTrusted() else {
    print("not trusted")
    exit(4)
}
guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
    print("no dock")
    exit(1)
}
let dock = AXUIElementCreateApplication(dockApp.processIdentifier)
print("dock pid=\(dockApp.processIdentifier)")

/// Mission Control の表示中だけ Dock の直下に現れる要素を探す（Dock 自体のリストは除く）
func missionControlRoot() -> AXUIElement? {
    children(dock).first { str($0, kAXRoleAttribute) != kAXListRole as String }
}

func find(_ e: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
    if str(e, kAXIdentifierAttribute) == id { return e }
    guard depth < 6 else { return nil }
    for c in children(e) { if let f = find(c, id: id, depth: depth + 1) { return f } }
    return nil
}

/// デスクトップのボタン（mc.spaces.list の子）と、名前のラベルがある位置。
/// ボタンの枠はサムネイルで、名前はその下に描かれる。バーが折りたたまれているときはボタンが名前そのもの。
func labels(in root: AXUIElement) -> [(AXUIElement, String, CGRect)] {
    guard let list = find(root, id: "mc.spaces.list"), let bar = frame(list) else { return [] }
    return children(list).compactMap { e in
        guard let f = frame(e) else { return nil }
        let name = str(e, kAXTitleAttribute) ?? ""
        // 折りたたまれたバーでは、ボタンの y が実際の表示とずれる（VM で 40pt 上）。バーの縦の中央に置く
        let label = f.height < 40
            ? CGRect(x: f.minX, y: bar.minY + (bar.height - f.height) / 2, width: f.width, height: f.height)
            : CGRect(x: f.minX, y: f.maxY + 2, width: f.width, height: 20)
        return (e, name, label)
    }
}

if mode == "observe" {
    // Mission Control の開閉で Dock が通知を出すかを調べる
    var observer: AXObserver?
    AXObserverCreate(dockApp.processIdentifier, { _, element, name, _ in
        let id = str(element, kAXIdentifierAttribute) ?? "-"
        let role = str(element, kAXRoleAttribute) ?? "-"
        print("\(ms())ms \(name) role=\(role) id=\(id) mc=\(missionControlRoot() != nil)")
    }, &observer)
    for n in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXFocusedUIElementChangedNotification,
              kAXLayoutChangedNotification, kAXSelectedChildrenChangedNotification, kAXValueChangedNotification,
              kAXWindowCreatedNotification, kAXTitleChangedNotification, kAXApplicationActivatedNotification] {
        let r = AXObserverAddNotification(observer!, dock, n as CFString, nil)
        print("add \(n): \(r.rawValue)")
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer!), .defaultMode)
    app.run()
    exit(0)
}

var wasOpen = false
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if mode == "dump" {
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        let root = missionControlRoot()
        if root != nil, !wasOpen {
            print("=== opened (\(ms())ms)")
            dump(dock)
        }
        if root == nil, wasOpen { print("=== closed (\(ms())ms)") }
        wasOpen = root != nil
    }
    app.run()
    exit(0)
}

// overlay: 名前は ~/.config/deskman/names.json ではなく、検証用に「名前 N」を出す
var panels: [NSPanel] = []
func panel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = true
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    let field = NSTextField(labelWithString: "")
    field.alignment = .center
    field.font = .systemFont(ofSize: 13, weight: .semibold)
    field.textColor = .white
    field.drawsBackground = true
    field.backgroundColor = NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.4, alpha: 1)
    field.wantsLayer = true
    field.layer?.cornerRadius = 4
    p.contentView = field
    return p
}
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
var lastLog = ""
let interval = Double(CommandLine.arguments.dropFirst(2).first ?? "") ?? 0.03
print("interval=\(interval)")
Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
    let found = missionControlRoot().map(labels) ?? []
    while panels.count < found.count { panels.append(panel()) }
    for (i, p) in panels.enumerated() {
        guard i < found.count else { p.orderOut(nil); continue }
        let (_, name, f) = found[i]
        // AX は左上原点、AppKit は左下原点
        let r = NSRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        (p.contentView as! NSTextField).stringValue = "名前 \(i + 1)"
        p.setFrame(r, display: true)
        p.orderFrontRegardless()
        _ = name
    }
    let log = found.map { "\($0.1)@\(Int($0.2.minX)),\(Int($0.2.minY)) \(Int($0.2.width))x\(Int($0.2.height))" }.joined(separator: " | ")
    if log != lastLog {
        print("\(ms())ms \(log.isEmpty ? "(closed)" : log)")
        lastLog = log
    }
}
app.run()
