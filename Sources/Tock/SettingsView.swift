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
    let addFiles: () -> Void
    let createFile: () -> Void
    let testReminder: () -> Void

    var body: some View {
        Form {
            Section("To-do files") {
                if prefs.filePaths.isEmpty {
                    Text("No files yet").foregroundStyle(.secondary)
                }
                ForEach(prefs.filePaths, id: \.self) { path in
                    HStack {
                        Button {
                            prefs.inboxPath = path
                        } label: {
                            Image(systemName: isInbox(path) ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                                .foregroundStyle(isInbox(path) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isInbox(path) ? "New tasks go here" : "Make this the file for new tasks")
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button {
                            prefs.filePaths.removeAll { $0 == path }
                            if prefs.inboxPath == path { prefs.inboxPath = nil }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop using this file (it isn't deleted)")
                    }
                }
                HStack {
                    Button("Add files…", action: addFiles)
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

            Section("Reminders") {
                Toggle("Daily summary of tasks due", isOn: $prefs.remindersEnabled)
                if prefs.remindersEnabled {
                    DatePicker("Send at", selection: reminderTime, displayedComponents: .hourAndMinute)
                    Button("Send a test notification", action: testReminder)
                }
                Text("One notification a day listing what's overdue or due today. Tock has to be running.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = prefs.reminderError { Text(error).font(.caption).foregroundStyle(.red) }
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
        .frame(width: 520, height: 780)
    }

    private func isInbox(_ path: String) -> Bool {
        (prefs.inboxPath ?? prefs.filePaths.first) == path
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: { Dates.startOfDay(Date()).addingTimeInterval(TimeInterval(prefs.reminderMinutes * 60)) },
            set: { date in
                let c = Dates.calendar.dateComponents([.hour, .minute], from: date)
                prefs.reminderMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 0)
            })
    }

    @ViewBuilder
    private var obsidianStatus: some View {
        if !Obsidian.isInstalled {
            Label("Obsidian doesn't seem to be installed.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if let path = prefs.inboxPath ?? prefs.filePaths.first, let vault = Obsidian.vaultRoot(of: URL(fileURLWithPath: path)) {
            Label("Vault: \(vault.lastPathComponent)", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("No vault found around your files. Links open by path.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
