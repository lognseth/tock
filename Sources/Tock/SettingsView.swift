import SwiftUI

/// (`@State` is a macro in the newest SDK and needs a plugin the Command Line Tools don't ship.)
@MainActor
final class RecorderState: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func start(_ apply: @escaping (KeyCombo) -> Void) {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.stop(); return nil }  // esc cancels
            if let combo = KeyCombo(event: event) {
                apply(combo)
                self?.stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @StateObject private var state = RecorderState()

    var body: some View {
        Button(state.recording ? "Type shortcut…" : combo.display) {
            if state.recording { state.stop() } else { state.start { combo = $0 } }
        }
        .buttonStyle(.bordered)
        .tint(state.recording ? .accentColor : nil)
        .onDisappear { state.stop() }
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let chooseFile: () -> Void
    let createFile: () -> Void

    var body: some View {
        Form {
            Section("To-do file") {
                LabeledContent("File") {
                    Text(prefs.filePath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                HStack {
                    Button("Choose…", action: chooseFile)
                    Button("New file…", action: createFile)
                }
                TextField("New tasks go under heading", text: $prefs.newTaskHeading,
                          prompt: Text("End of file"))
            }

            Section("Shortcuts") {
                LabeledContent("Open list") { ShortcutRecorder(combo: $prefs.openHotKey) }
                LabeledContent("Quick add") { ShortcutRecorder(combo: $prefs.quickAddHotKey) }
                if let error = prefs.hotKeyError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Window") {
                Picker("Open shortcut shows", selection: $prefs.openInWindow) {
                    Text("Quick popup").tag(false)
                    Text("Full window").tag(true)
                }
                Toggle("Show Tock in the Dock and ⌘Tab", isOn: $prefs.showInDock)
                Text("Quick add always uses the popup unless the window is already open.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Show tasks due count in menu bar", isOn: $prefs.showBadge)
                Toggle("Show completed tasks by default", isOn: $prefs.showDoneByDefault)
                Toggle("Add completion date (✅ yyyy-MM-dd) when checking off", isOn: $prefs.stampDone)
                Toggle("Launch at login", isOn: Binding(
                    get: { prefs.launchAtLogin },
                    set: { on in
                        do { try prefs.setLaunchAtLogin(on); prefs.loginError = nil }
                        catch { prefs.loginError = error.localizedDescription }
                    }))
                if let loginError = prefs.loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section("Obsidian") {
                Toggle("Obsidian integration", isOn: $prefs.obsidianEnabled)
                Text("Open the note in Obsidian, show [[wikilinks]] as links, and jump to a linked note with l.")
                    .font(.caption).foregroundStyle(.secondary)
                if prefs.obsidianEnabled { obsidianStatus }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
    }

    @ViewBuilder
    private var obsidianStatus: some View {
        if !Obsidian.isInstalled {
            Label("Obsidian doesn't seem to be installed.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if let path = prefs.filePath, let vault = Obsidian.vaultRoot(of: URL(fileURLWithPath: path)) {
            Label("Vault: \(vault.lastPathComponent)", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("No vault found around this file. Links open by path.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
