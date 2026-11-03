import AppKit
import ApplicationServices
import DeskmanCore
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshTitle),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    private func names() -> [String: String] {
        (try? NameStore())?.names ?? [:]
    }

    private func title(for space: Space, names: [String: String]) -> String {
        names[space.uuid] ?? (space.isFullscreen ? "Full Screen" : "Desktop \(space.index)")
    }

    @objc private func refreshTitle() {
        guard let s = SystemSpaces.current().first(where: \.isActive) else { return }
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
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Deskman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
