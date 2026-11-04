import AppKit
import ApplicationServices
import DeskmanCore

/// Mission Control の画面の上端に、各デスクトップの真上に名前を出す（名前がなければ「Desktop 番号」）。
///
/// Mission Control の名前は Dock が描いていて書き換えられないので、Dock のアクセシビリティ要素から
/// デスクトップの位置を読み、上端に自分のパネルを置く。ノッチの形（上は角、下は角丸）で、上から降りてくる。Dock は開閉を通知しないので、一定の間隔で問い合わせる。
/// 要素の構造（id=mc、mc.display、mc.spaces.list）は公開された仕様ではなく、実測に基づく。
@MainActor
final class MissionControlOverlay {
    /// 問い合わせの間隔。VM の実測では、閉じている間の CPU は Deskman 約 0.1〜0.3%、Dock 約 0.3%。
    private static let interval: TimeInterval = 0.1
    /// 開いている間の間隔。バーの開閉にノッチの横の動きを追いつかせる
    private static let openInterval: TimeInterval = 0.03

    private var timer: Timer?
    private var dock: (pid: pid_t, element: AXUIElement)?
    private var panels: [LabelPanel] = []
    /// 名前は開いたときに読む。並びは並べ替えに追いつくよう毎回読む
    private var names: [String: String]?
    /// ディスプレイ（mc.display の枠）ごとの幅。折りたたまれたバーを見たときに測って覚える
    private var widths: [String: CGFloat] = [:]

    func start() {
        guard timer == nil else { return }
        schedule(Self.interval)
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
                schedule(Self.interval)
            }
            return
        }
        if names == nil { schedule(Self.openInterval) }
        let names = self.names ?? (try? NameStore())?.names ?? [:]
        self.names = names
        let allSpaces = SystemSpaces.current()
        var labels: [(MissionControlLabel, CGRect)] = []
        for display in Self.children(root) where Self.string(display, kAXIdentifierAttribute) == "mc.display" {
            guard let displayFrame = Self.frame(display),
                  let list = Self.find(display, id: "mc.spaces.list") else { continue }
            let buttons = Self.children(list).compactMap(Self.frame)
            let spaces = MissionControlLabels.spaces(onDisplay: Self.displayUUID(at: displayFrame),
                                                     in: allSpaces)
            let key = "\(displayFrame)"
            if let width = MissionControlLabels.width(buttons: buttons) { widths[key] = width }
            labels += MissionControlLabels.make(buttons: buttons, top: displayFrame.minY,
                                                width: widths[key] ?? MissionControlLabels.fallbackWidth,
                                                spaces: spaces, names: names).map { ($0, displayFrame) }
        }
        show(labels)
    }

    private func show(_ labels: [(MissionControlLabel, CGRect)]) {
        while panels.count < labels.count { panels.append(LabelPanel()) }
        for (i, panel) in panels.enumerated() {
            if i < labels.count {
                panel.show(labels[i].0, display: labels[i].1)
            } else {
                panel.hide()
            }
        }
    }

    private func hideAll() {
        panels.forEach { $0.hide() }
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

/// 画面の上端に出すノッチの形の名前。クリックは下の Mission Control に通す。
/// パネルはディスプレイの上端の帯に置き、中のノッチだけを動かす。パネルを画面の外へ動かすと上にある別のディスプレイに出てしまい、
/// パネル自体を横に動かすアニメーションでは速さの指定（一定の速さ）が効かなかったため。
@MainActor
private final class LabelPanel: NSPanel {
    private static let cornerRadius: CGFloat = 10
    private static let showDuration: TimeInterval = 0.14
    private static let hideDuration: TimeInterval = 0.15
    /// バーの開閉での横の動き。プレビューの展開に追いつくよう、一定の速さで素早く
    private static let moveDuration: TimeInterval = 0.1

    private let notch = NSVisualEffectView()
    private let field = NSTextField(labelWithString: "")
    private let tint = NSView()
    /// 隠すアニメーションの途中で再び出したとき、古い完了処理で消さないための番号
    private var generation = 0
    private var hiding = false

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

        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        // 元の名前が透けないよう、ぼかしの上に色を重ねる。表示中のデスクトップはアクセントカラー
        notch.material = .hudWindow
        notch.blendingMode = .behindWindow
        notch.state = .active
        notch.wantsLayer = true
        notch.layer?.cornerRadius = Self.cornerRadius
        // AppKit のレイヤーは左下原点なので、MinY が下の角
        notch.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        notch.layer?.masksToBounds = true
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        notch.addSubview(tint)
        let border = NotchBorder(radius: Self.cornerRadius)
        border.autoresizingMask = [.width, .height]
        notch.addSubview(border)

        field.alignment = .center
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        notch.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: notch.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: notch.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: notch.centerYAnchor),
        ])
        container.addSubview(notch)
        contentView = container
    }

    /// display はそのディスプレイの枠（アクセシビリティの座標）
    func show(_ label: MissionControlLabel, display: CGRect) {
        field.stringValue = label.name
        field.font = .systemFont(ofSize: 13, weight: label.current ? .semibold : .medium)
        tint.layer?.backgroundColor = label.current
            ? NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
            : NSColor.black.withAlphaComponent(0.45).cgColor
        // アクセシビリティは左上原点、AppKit は主ディスプレイの左下原点
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let rect = label.frame
        let strip = NSRect(x: display.minX, y: primaryHeight - rect.maxY, width: display.width, height: rect.height)
        let down = NSRect(x: rect.minX - display.minX, y: 0, width: rect.width, height: rect.height)
        if isVisible && !hiding && frame == strip {
            // バーの開閉では大きさは変えず、位置だけを一定の速さで動かす
            guard notch.frame != down else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.moveDuration
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                notch.animator().frame = down
            }
            return
        }
        if frame != strip { setFrame(strip, display: false) }
        guard !isVisible || hiding else {
            notch.frame = down
            return
        }
        // 上から降りてくる
        generation += 1
        hiding = false
        notch.frame = down.offsetBy(dx: 0, dy: down.height)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            notch.animator().frame = down
        }
    }

    /// 上へ引っ込めてから消す
    func hide() {
        guard isVisible, !hiding else { return }
        hiding = true
        generation += 1
        let current = generation
        let up = notch.frame.offsetBy(dx: 0, dy: notch.frame.height - notch.frame.minY)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            notch.animator().frame = up
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.hiding = false
                self.orderOut(nil)
            }
        })
    }
}

/// ノッチの縁。左右と下（角丸）だけに引き、画面の上端に接する辺には引かない。
private final class NotchBorder: NSView {
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: bounds.maxY))
        path.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        path.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                       startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: r.maxX, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.25).setStroke()
        path.stroke()
    }
}
