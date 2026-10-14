import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// ⌘Z / ⌘⇧Z / ⌘W are ours unless a text field is being edited (then the field editor owns them).
private func claimsKeyEquivalent(_ event: NSEvent, isEditing: Bool) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return !isEditing && flags.contains(.command) && ["z", "w"].contains(event.charactersIgnoringModifiers ?? "")
}

final class FloatingPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Void)?
    var isEditingText: () -> Bool = { false }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) { keyHandler?(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if claimsKeyEquivalent(event, isEditing: isEditingText()) { keyHandler?(event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class TockWindow: NSWindow {
    var keyHandler: ((NSEvent) -> Void)?
    var isEditingText: () -> Bool = { false }

    override func keyDown(with event: NSEvent) { keyHandler?(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if claimsKeyEquivalent(event, isEditing: isEditingText()) { keyHandler?(event); return true }
        return super.performKeyEquivalent(with: event)
    }
}

enum Surface { case popup, window }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let prefs = Preferences.shared
    private lazy var store = TaskStore(prefs: prefs)
    private var panel: FloatingPanel!
    private var mainWindow: TockWindow?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var registeredCombos: [KeyCombo] = []
    private var pollTimer: Timer?

    private let panelSize = NSSize(width: 640, height: 480)

    private var mainWindowVisible: Bool { mainWindow?.isVisible == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        applyActivationPolicy()
        setupMainMenu()

        store.fileURL = prefs.filePath.map { URL(fileURLWithPath: $0) }
        store.load()
        store.onCloseRequest = { [weak self] in self?.closePanel() }
        store.onEditEnded = { [weak self] in self?.activeWindow?.makeFirstResponder(nil) }

        setupPanel()
        setupStatusItem()
        prefs.onChange = { [weak self] in self?.applyPrefs() }
        registerHotKeys()
        updateBadge()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.store.editing == nil { self.store.reloadIfChanged() }
                self.updateBadge()
            }
        }

        if prefs.showInDock { showWindow(quickAdd: false) }
        else if store.fileURL == nil { showPopup(quickAdd: false) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if prefs.showInDock || prefs.openInWindow { showWindow(quickAdd: false) } else { showPopup(quickAdd: false) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Whichever of our windows currently receives keystrokes.
    private var activeWindow: NSWindow? {
        if mainWindow?.isKeyWindow == true { return mainWindow }
        if panel.isKeyWindow { return panel }
        return mainWindowVisible ? mainWindow : panel
    }

    // MARK: - Prefs

    private func applyActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = prefs.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    private func applyPrefs() {
        let url = prefs.filePath.map { URL(fileURLWithPath: $0) }
        if url != store.fileURL {
            store.fileURL = url
            store.selected = nil
            store.section = nil
            store.load()
            updateWindowTitle()
        }
        applyActivationPolicy()
        registerHotKeys()
        rebuildMenu()
        updateBadge()
    }

    private func registerHotKeys() {
        let wanted = [prefs.openHotKey, prefs.quickAddHotKey]
        guard wanted != registeredCombos else { return }
        registeredCombos = wanted
        hotKeys = []  // unregisters the old ones

        var failures: [String] = []
        if let k = HotKey(id: 1, combo: wanted[0], handler: { [weak self] in
            MainActor.assumeIsolated { self?.toggleMain() }
        }) { hotKeys.append(k) } else { failures.append(wanted[0].display) }
        if let k = HotKey(id: 2, combo: wanted[1], handler: { [weak self] in
            MainActor.assumeIsolated { self?.quickAdd() }
        }) { hotKeys.append(k) } else { failures.append(wanted[1].display) }

        prefs.hotKeyError = failures.isEmpty ? nil
            : "\(failures.joined(separator: ", ")) is already used by another app. Pick a different shortcut."
    }

    // MARK: - Popup

    private func setupPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event, surface: .popup) }
        panel.isEditingText = { [weak self] in self?.store.editing != nil }
        panel.contentView = NSHostingView(rootView: PanelView(store: store, prefs: prefs))
    }

    private func showPopup(quickAdd: Bool) {
        store.resetTransient()
        store.load()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panelSize.width / 2,
                                         y: f.maxY - f.height * 0.22 - panelSize.height))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        if quickAdd && store.fileURL != nil {
            store.closeAfterCommit = true
            store.beginEdit(.newEnd)
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        store.resetTransient()
        panel.orderOut(nil)
        if !mainWindowVisible { NSApp.hide(nil) }  // hands focus back to the previous app
        updateBadge()
    }

    // MARK: - Window

    private func makeMainWindow() -> TockWindow {
        let w = TockWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Tock"
        w.minSize = NSSize(width: 700, height: 440)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.keyHandler = { [weak self] event in self?.handleKey(event, surface: .window) }
        w.isEditingText = { [weak self] in self?.store.editing != nil }
        w.contentView = NSHostingView(rootView: WindowView(store: store, prefs: prefs))
        if !w.setFrameAutosaveName("TockMainWindow") { w.center() }
        mainWindow = w
        return w
    }

    private func updateWindowTitle() {
        mainWindow?.subtitle = store.fileURL?.lastPathComponent ?? ""
    }

    private func showWindow(quickAdd: Bool) {
        if panel.isVisible { store.resetTransient(); panel.orderOut(nil) }
        let w = mainWindow ?? makeMainWindow()
        store.resetTransient()
        store.load()
        updateWindowTitle()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)
        if quickAdd && store.fileURL != nil { store.beginEdit(.newEnd) }
    }

    private func hideWindow() {
        store.resetTransient()
        mainWindow?.orderOut(nil)
        if !prefs.showInDock { NSApp.hide(nil) }
    }

    // MARK: - Entry points (hotkeys, menu)

    private var wantsWindow: Bool { prefs.openInWindow || mainWindowVisible }

    private func toggleMain() {
        if wantsWindow {
            if mainWindow?.isKeyWindow == true { hideWindow() } else { showWindow(quickAdd: false) }
        } else if panel.isVisible {
            closePanel()
        } else {
            showPopup(quickAdd: false)
        }
    }

    private func quickAdd() {
        if wantsWindow { showWindow(quickAdd: true) } else { showPopup(quickAdd: true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, notification.object as? NSPanel === panel else { return }
        store.resetTransient()
        panel.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        store.reloadIfChanged()
        mainWindow?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        store.resetTransient()
    }

    // MARK: - Keys (the text field owns the keyboard while editing)

    private func dismissPopup(_ surface: Surface) {
        if surface == .popup { closePanel() }
    }

    private func handleKey(_ event: NSEvent, surface: Surface) {
        let chars = event.characters ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)

        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers ?? "" {
            case "z": if flags.contains(.shift) { store.redo() } else { store.undo() }
            case "w": if surface == .popup { closePanel() } else { mainWindow?.performClose(nil) }
            default: break
            }
            return
        }

        if store.showHelp { store.showHelp = false; return }

        if store.fileURL == nil {
            if code == kVK_Return { chooseFile() }
            else if code == kVK_Escape { dismissPopup(surface) }
            else if chars == "c" { createFile() }
            return
        }

        if flags.contains(.control) {
            if code == kVK_ANSI_R { store.redo() }
            return
        }

        let shift = flags.contains(.shift)
        switch code {
        case kVK_DownArrow: store.pendingD = false; store.move(1); return
        case kVK_UpArrow: store.pendingD = false; store.move(-1); return
        case kVK_Return, kVK_ANSI_KeypadEnter: store.beginEdit(.edit); return
        case kVK_Tab: store.indent(shift ? -1 : 1); return
        case kVK_Space: store.toggle(); return
        case kVK_Escape:
            if store.pendingD { store.pendingD = false }
            else if !store.filter.isEmpty { store.clearFilter() }
            else if store.section != nil { store.clearSection() }
            else { dismissPopup(surface) }
            return
        default: break
        }

        if chars != "d" { store.pendingD = false }
        switch chars {
        case "j": store.move(1)
        case "k": store.move(-1)
        case "J": store.reorder(1)
        case "K": store.reorder(-1)
        case "g": store.jumpTop()
        case "G": store.jumpBottom()
        case "x": store.toggle()
        case "n": store.beginEdit(.newBelow)
        case "N": store.beginEdit(.newEnd)
        case "e": store.beginEdit(.edit)
        case "t": store.beginEdit(.due)
        case "p": store.cyclePriority()
        case "/": store.beginEdit(.filter)
        case "u": store.undo()
        case "H": store.showDone.toggle()
        case "1": store.setView(.all)
        case "2": store.setView(.today)
        case "3": store.setView(.upcoming)
        case "?": store.showHelp = true
        case "o": openFile(surface)
        case "l": openLinkedNote(surface)
        case "d":
            if store.pendingD { store.pendingD = false; store.delete() } else { store.pendingD = true }
        default: break
        }
    }

    // MARK: - Opening

    private func openFile(_ surface: Surface = .popup) {
        guard let url = store.fileURL else { return }
        dismissPopup(surface)
        if prefs.obsidianEnabled, let link = Obsidian.noteURL(for: url) {
            NSWorkspace.shared.open(link)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLinkedNote(_ surface: Surface) {
        guard prefs.obsidianEnabled else { store.flash("Turn on Obsidian integration in Settings to follow links"); return }
        guard let url = store.fileURL, let s = store.selected, let task = store.taskMap[s] else { return }
        guard let link = Obsidian.wikilinks(in: task.text).first,
              let target = Obsidian.linkURL(target: link.target, from: url) else {
            store.flash("No [[link]] in this task")
            return
        }
        dismissPopup(surface)
        NSWorkspace.shared.open(target)
    }

    // MARK: - Menus

    private func setupMainMenu() {
        // Accessory apps have no visible menu bar, but key equivalents (⌘V in the text field, ⌘,) still need a main menu.
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Tock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Show Tock", action: #selector(menuOpenWindow), keyEquivalent: "0").target = self
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Tock")
        statusItem.button?.imagePosition = .imageLeading
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open To-Dos    \(prefs.openHotKey.display)", action: #selector(menuOpen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quick Add    \(prefs.quickAddHotKey.display)", action: #selector(menuQuickAdd), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Window", action: #selector(menuOpenWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open File", action: #selector(menuOpenFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func updateBadge() {
        let n = prefs.showBadge ? store.count(.today) : 0
        statusItem.button?.title = n > 0 ? " \(n)" : ""
    }

    @objc private func menuOpen() { if wantsWindow { showWindow(quickAdd: false) } else { showPopup(quickAdd: false) } }
    @objc private func menuQuickAdd() { quickAdd() }
    @objc private func menuOpenWindow() { showWindow(quickAdd: false) }
    @objc private func menuOpenFile() { openFile() }

    @objc private func menuSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                prefs: prefs,
                chooseFile: { [weak self] in self?.chooseFile() },
                createFile: { [weak self] in self?.createFile() }))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Tock Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - File selection

    private let markdown = UTType(filenameExtension: "md") ?? .plainText

    private func chooseFile() {
        panel.orderOut(nil)
        NSApp.activate()
        let open = NSOpenPanel()
        open.message = "Choose the markdown file that holds your to-dos"
        open.allowedContentTypes = [markdown, .plainText]
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        prefs.filePath = url.path
    }

    private func createFile() {
        panel.orderOut(nil)
        NSApp.activate()
        let save = NSSavePanel()
        save.message = "Create a markdown file for your to-dos"
        save.nameFieldStringValue = "Tasks.md"
        save.allowedContentTypes = [markdown]
        guard save.runModal() == .OK, let url = save.url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try "# Tasks\n\n- [ ] Try Tock\n".write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        prefs.filePath = url.path
    }
}
