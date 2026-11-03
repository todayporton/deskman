import AppKit
import ApplicationServices
import DeskmanCore

/// Mission Control のデスクトップ名の上に、設定した名前を重ねる。
///
/// Mission Control の名前は Dock が描いていて書き換えられないので、Dock のアクセシビリティ要素から
/// 位置を読み、その上に自分のパネルを置く。Dock は開閉を通知しないので、一定の間隔で問い合わせる。
/// 要素の構造（id=mc、mc.display、mc.spaces.list）は公開された仕様ではなく、実測に基づく。
@MainActor
final class MissionControlOverlay {
    /// 問い合わせの間隔。VM の実測では、閉じている間の CPU は Deskman 約 0.1〜0.3%、Dock 約 0.3%。
    private static let interval: TimeInterval = 0.1

    private var timer: Timer?
    private var dock: (pid: pid_t, element: AXUIElement)?
    private var panels: [LabelPanel] = []
    /// 名前は開いたときに読む。並びは並べ替えに追いつくよう毎回読む
    private var names: [String: String]?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hideAll()
        names = nil
    }

    /// Dock の要素は使い回す。Dock が再起動して問い合わせに失敗したら、次の回で探し直す。
    private func dockElement() -> AXUIElement? {
        if let dock { return dock.element }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Dock が応答しないときに、メニューバーまで止めない
        AXUIElementSetMessagingTimeout(element, 0.25)
        dock = (app.processIdentifier, element)
        return element
    }

    private func tick() {
        guard let dockElement = dockElement() else { return }
        // Dock の直下には常に Dock 自体のリストがあるので、空なら問い合わせに失敗している
        let top = Self.children(dockElement)
        if top.isEmpty { dock = nil }
        guard let root = top.first(where: { Self.string($0, kAXIdentifierAttribute) == "mc" }) else {
            if names != nil {
                hideAll()
                names = nil
            }
            return
        }
        let names = self.names ?? (try? NameStore())?.names ?? [:]
        self.names = names
        let allSpaces = SystemSpaces.current()
        var labels: [MissionControlLabel] = []
        for display in Self.children(root) where Self.string(display, kAXIdentifierAttribute) == "mc.display" {
            guard let displayFrame = Self.frame(display),
                  let list = Self.find(display, id: "mc.spaces.list"),
                  let bar = Self.frame(list) else { continue }
            let buttons = Self.children(list).compactMap(Self.frame)
            let spaces = MissionControlLabels.spaces(onDisplay: Self.displayUUID(at: displayFrame),
                                                     in: allSpaces)
            labels += MissionControlLabels.make(buttons: buttons, bar: bar, spaces: spaces, names: names)
        }
        show(labels)
    }

    private func show(_ labels: [MissionControlLabel]) {
        while panels.count < labels.count { panels.append(LabelPanel()) }
        for (i, panel) in panels.enumerated() {
            if i < labels.count {
                panel.show(labels[i])
            } else {
                panel.orderOut(nil)
            }
        }
    }

    private func hideAll() {
        panels.forEach { $0.orderOut(nil) }
    }

    // MARK: - アクセシビリティ

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? {
        attribute(e, name) as? String
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
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

    private static func find(_ e: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
        if string(e, kAXIdentifierAttribute) == id { return e }
        guard depth < 4 else { return nil }
        for c in children(e) {
            if let found = find(c, id: id, depth: depth + 1) { return found }
        }
        return nil
    }

    /// mc.display の枠と同じ範囲のディスプレイの UUID。アクセシビリティと CGDisplayBounds は同じ座標系。
    private static func displayUUID(at frame: CGRect) -> String? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        let display = ids.prefix(Int(count)).first { CGDisplayBounds($0).integral == frame.integral }
        return display.flatMap(SpaceSwitcher.displayUUID)
    }
}

/// 元の名前を覆うパネル。クリックは下の Mission Control に通す。
@MainActor
private final class LabelPanel: NSPanel {
    private let field = NSTextField(labelWithString: "")
    private let tint = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // overlay のレベルなら、Mission Control の表示中も縮小されずに最前面に出る（VM で確認）
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        // 元の名前が透けないよう、ぼかしの上に色を重ねる。表示中のデスクトップはアクセントカラー
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)

        field.alignment = .center
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        contentView = effect
    }

    func show(_ label: MissionControlLabel) {
        field.stringValue = label.name
        field.font = .systemFont(ofSize: label.collapsed ? 13 : 12, weight: label.current ? .semibold : .medium)
        tint.layer?.backgroundColor = label.current
            ? NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            : NSColor.black.withAlphaComponent(0.45).cgColor
        var rect = label.frame
        if label.collapsed {
            // 名前が元より長いときは少しだけ広げる。隣との隙間（VM で 12pt）は残す
            let needed = field.intrinsicContentSize.width + 12
            let width = min(max(rect.width, needed), rect.width + 8)
            rect = rect.insetBy(dx: (rect.width - width) / 2, dy: 0)
        }
        // アクセシビリティは左上原点、AppKit は主ディスプレイの左下原点
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        if self.frame != frame { setFrame(frame, display: false) }
        if !isVisible { orderFrontRegardless() }
    }
}
