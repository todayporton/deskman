import AppKit
import ApplicationServices
import DeskmanCore
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private static let iconOnlyKey = "showIconOnly"
    /// 最後にタイトルを決めたときのカーソルのディスプレイ。変わったときだけ更新する。
    private var lastCursorDisplay: CGDirectDisplayID?
    private var mouseMonitor: Any?
    private static let missionControlKey = "showNamesInMissionControl"
    private let missionControl = MissionControlOverlay()

    private var iconOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.iconOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.iconOnlyKey) }
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
        if iconOnly {
            stopWatchingCursor()
            item.button?.image = MenuBarIcon.make()
            item.button?.title = ""
            return
        }
        item.button?.image = nil
        startWatchingCursor()
        refreshTitle()
    }

    /// 名前を出すときだけ、カーソルがディスプレイをまたいだのを見張る。
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
        guard !iconOnly else { return }
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

    /// カーソルのあるディスプレイで表示中のデスクトップの名前を出す。
    @objc private func refreshTitle() {
        guard !iconOnly else { return }
        let display = SpaceSwitcher.cursorDisplay()
        lastCursorDisplay = display
        let spaces = SystemSpaces.current()
        guard let s = SpaceResolver.visible(onDisplay: display.flatMap(SpaceSwitcher.displayUUID),
                                            spaces: spaces) else { return }
        item.button?.title = title(for: s, names: names())
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
        let iconItem = NSMenuItem(title: "Show Icon Only", action: #selector(toggleIconOnly), keyEquivalent: "")
        iconItem.target = self
        iconItem.state = iconOnly ? .on : .off
        menu.addItem(iconItem)
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

    @objc private func toggleIconOnly() {
        iconOnly.toggle()
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
