import AppKit
import ApplicationServices
import DeskmanCore
import ServiceManagement

/// メニューバーに出すもの。値は UserDefaults に保存する。
enum MenuBarStyle: String, CaseIterable {
    case name, number, icon

    var title: String {
        switch self {
        case .name: "Name"
        case .number: "Number"
        case .icon: "Icon"
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private static let styleKey = "menuBarStyle"
    /// 0.3.0 以前の「Show Icon Only」。style が未設定のときだけ読む
    private static let iconOnlyKey = "showIconOnly"
    /// 最後にタイトルを決めたときのカーソルのディスプレイ。変わったときだけ更新する。
    private var lastCursorDisplay: CGDirectDisplayID?
    private var mouseMonitor: Any?
    private static let missionControlKey = "showNamesInMissionControl"
    private let missionControl = MissionControlOverlay()

    private var style: MenuBarStyle {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: Self.styleKey), let style = MenuBarStyle(rawValue: raw) {
                return style
            }
            return defaults.bool(forKey: Self.iconOnlyKey) ? .icon : .name
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.styleKey)
            UserDefaults.standard.removeObject(forKey: Self.iconOnlyKey)
        }
    }

    private var namesInMissionControl: Bool {
        get { UserDefaults.standard.bool(forKey: Self.missionControlKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.missionControlKey) }
    }

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.missionControlKey: true])
        menu.delegate = self
        item.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshTitle),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshTitle),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        applyDisplayMode()
        if namesInMissionControl { missionControl.start() }
    }

    private func applyDisplayMode() {
        if style == .icon {
            stopWatchingCursor()
            item.length = NSStatusItem.variableLength
            item.button?.image = MenuBarIcon.make()
            item.button?.title = ""
            return
        }
        item.button?.image = nil
        // 番号は桁数で幅が変わらないよう、2桁分の幅に固定する。名前は長さに合わせる
        item.length = style == .number ? Self.numberWidth() : NSStatusItem.variableLength
        startWatchingCursor()
        refreshTitle()
    }

    /// 番号に使う等幅数字のフォント
    private static func numberFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// 「00」が収まる長さ。macOS はこの長さの外にも余白を足す（VM の macOS 26 で約 18pt）ので、
    /// 名前のとき（文字幅 + 約 24pt）と見た目の余白がそろうよう、足す分は小さくする
    private static func numberWidth() -> CGFloat {
        let text = ("00" as NSString).size(withAttributes: [.font: numberFont()]).width
        return ceil(text) + 6
    }

    /// 名前か番号を出すときだけ、カーソルがディスプレイをまたいだのを見張る。
    /// 他のアプリに届くマウスの移動だけを受ける。自分のメニューを開いている間は見張らない
    /// （メニューの中の移動まで処理すると、項目のハイライトが遅れる）。
    private func startWatchingCursor() {
        guard mouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                             .rightMouseDragged, .otherMouseDragged]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
    }

    private func stopWatchingCursor() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        stopWatchingCursor()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard style != .icon else { return }
        startWatchingCursor()
        refreshTitle()
    }

    private func cursorMoved() {
        guard let display = SpaceSwitcher.cursorDisplay(), display != lastCursorDisplay else { return }
        refreshTitle()
    }

    private func names() -> [String: String] {
        (try? NameStore())?.names ?? [:]
    }

    private func title(for space: Space, names: [String: String]) -> String {
        names[space.uuid] ?? (space.isFullscreen ? "Full Screen" : "Desktop \(space.index)")
    }

    /// カーソルのあるディスプレイで表示中のデスクトップの名前か番号を出す。
    @objc private func refreshTitle() {
        let style = self.style
        guard style != .icon else { return }
        let display = SpaceSwitcher.cursorDisplay()
        lastCursorDisplay = display
        let spaces = SystemSpaces.current()
        guard let s = SpaceResolver.visible(onDisplay: display.flatMap(SpaceSwitcher.displayUUID),
                                            spaces: spaces) else { return }
        if style == .number {
            // 番号は Mission Control の「デスクトップN」と同じ、全ディスプレイを通した番号
            item.button?.attributedTitle = NSAttributedString(
                string: String(s.index), attributes: [.font: Self.numberFont()])
        } else {
            item.button?.title = title(for: s, names: names())
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let currentNames = names()
        var lastDisplay: String?
        var displayNumber = 0
        for s in SystemSpaces.current() {
            if s.displayID != lastDisplay {
                if lastDisplay != nil { menu.addItem(.separator()) }
                displayNumber += 1
                let header = NSMenuItem(title: "Display \(displayNumber)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                lastDisplay = s.displayID
            }
            let row = NSMenuItem(title: title(for: s, names: currentNames),
                                 action: #selector(go(_:)), keyEquivalent: "")
            row.target = self
            row.tag = s.managedID
            row.state = s.isActive ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let rename = NSMenuItem(title: "Rename Current Desktop…",
                                action: #selector(renameCurrent), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)
        let styleMenu = NSMenu()
        let current = style
        for option in MenuBarStyle.allCases {
            let row = NSMenuItem(title: option.title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = option.rawValue
            row.state = option == current ? .on : .off
            styleMenu.addItem(row)
        }
        let styleItem = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        let mcItem = NSMenuItem(title: "Show Names in Mission Control",
                                action: #selector(toggleNamesInMissionControl), keyEquivalent: "")
        mcItem.target = self
        mcItem.state = namesInMissionControl ? .on : .off
        menu.addItem(mcItem)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Deskman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleNamesInMissionControl() {
        namesInMissionControl.toggle()
        if namesInMissionControl {
            missionControl.start()
        } else {
            missionControl.stop()
        }
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MenuBarStyle(rawValue: raw) else { return }
        self.style = style
        applyDisplayMode()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            show(error)
        }
    }

    @objc private func go(_ sender: NSMenuItem) {
        guard let s = SystemSpaces.current().first(where: { $0.managedID == sender.tag }) else { return }
        do {
            try SpaceSwitcher.go(to: s)
        } catch {
            show(error)
        }
    }

    @objc private func renameCurrent() {
        guard let s = SystemSpaces.current().first(where: \.isActive) else { return }
        if s.isFullscreen {
            show(DeskmanError.fullscreenNotNameable)
            return
        }
        if s.uuid.isEmpty {
            show(DeskmanError.noUUID)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Desktop Name"
        alert.informativeText = "Leave empty to remove the name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = names()[s.uuid] ?? ""
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            var store = try NameStore()
            try store.set(name: field.stringValue, for: s.uuid)
            refreshTitle()
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = (error as? DeskmanError)?.message ?? "\(error)"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor
func runMenuBar() -> Never {
    // すでに常駐しているなら、ソケットを奪わずに終了する
    if GoSocket.isServerRunning() { exit(0) }
    do {
        try GoSocket.serve { request in
            GoSocket.handle(request) { error in
                // システム設定 > サウンド で選ばれている通知音を鳴らす
                if error.playsAlertSound { DispatchQueue.main.async { NSSound.beep() } }
            }
        }
    } catch {
        FileHandle.standardError.write(Data("Could not open the socket: \(error)\n".utf8))
        exit(1)
    }
    let promptKey = "AXTrustedCheckOptionPrompt" as CFString
    _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController()
    withExtendedLifetime(controller) { app.run() }
    exit(0)
}
