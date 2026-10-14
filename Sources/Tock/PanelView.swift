import SwiftUI

// MARK: - Small pieces

struct KeyCap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.09)))
    }
}

struct Hint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            KeyCap(key: key)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

private func priorityColor(_ p: Priority) -> Color {
    switch p {
    case .highest: return .red
    case .high: return .orange
    case .medium: return .yellow
    case .low: return .blue
    case .lowest: return .gray
    }
}

// MARK: - Panel

struct PanelView: View {
    @Bindable var store: TaskStore
    @ObservedObject var prefs: Preferences
    var body: some View {
        VStack(spacing: 0) {
            if !store.hasFiles {
                WelcomeView()
            } else {
                HeaderBar(store: store)
                Divider().opacity(0.4)
                ZStack {
                    TaskList(store: store, obsidian: prefs.obsidianEnabled)
                    if store.showHelp { HelpOverlay().transition(.opacity) }
                }
                if let kind = store.editing {
                    Divider().opacity(0.4)
                    EditBar(store: store, kind: kind)
                }
            }
            Divider().opacity(0.4)
            FooterBar(store: store)
        }
        .frame(width: 640, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .tockSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: store.showHelp)
    }
}

struct EditBar: View {
    @Bindable var store: TaskStore
    let kind: EditKind
    /// Floating glass bar (window) instead of a tinted full-width row (popup).
    var floating = false
    @FocusState private var focused: Bool

    var body: some View {
        let (icon, prompt): (String, String) = switch kind {
        case .edit: ("pencil", "Edit task")
        case .due: ("calendar", "Due date: today, tomorrow, mon, +3d, 24.12. Empty clears")
        case .snooze: ("moon.zzz", "Snooze until: tomorrow, mon, +3d, 24.12")
        case .move: ("arrow.turn.down.right", "Move to heading. Type to search, ↑↓ to choose")
        case .filter: ("magnifyingglass", "Filter by text or #tag")
        default: ("plus.circle.fill", "New task   @tomorrow  !high  ~weekly  #tag")
        }
        let text = kind == .filter ? $store.filter : $store.draft
        VStack(spacing: 0) {
            if kind == .move { MovePicker(store: store) }
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                TextField(prompt, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { store.commitEdit(keepOpen: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) }
                    .onExitCommand { store.cancelEdit() }
                    .onChange(of: store.filter) { _, _ in if kind == .filter { store.fixSelection() } }
                    .onChange(of: store.draft) { _, _ in if kind == .move { store.moveIndex = 0 } }
                    .onKeyPress(.upArrow) {
                        guard kind == .move else { return .ignored }
                        store.moveIndex = max(0, store.moveIndex - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard kind == .move else { return .ignored }
                        store.moveIndex = min(max(store.moveTargets().count - 1, 0), store.moveIndex + 1)
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, floating ? 11 : 12)
        }
        .background(floating ? Color.clear : Color.accentColor.opacity(0.06))
        .modifier(FloatingBar(enabled: floating, radius: 24))
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct MovePicker: View {
    let store: TaskStore

    var body: some View {
        let targets = store.moveTargets()
        VStack(alignment: .leading, spacing: 1) {
            if targets.isEmpty {
                Text("No matching heading").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
            }
            ForEach(Array(targets.prefix(7).enumerated()), id: \.element.id) { i, t in
                HStack(spacing: 8) {
                    Image(systemName: t.heading == nil ? "arrow.down.to.line" : "number")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                    Text(t.label).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(i == store.moveIndex ? Color.accentColor.opacity(0.18) : .clear))
            }
        }
        .padding(8)
        Divider().opacity(0.4)
    }
}

// MARK: - Header

struct HeaderBar: View {
    let store: TaskStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                tab(mode)
            }
            Spacer()
            if !store.filter.isEmpty && store.editing != .filter {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                    Text(store.filter).font(.system(size: 11)).lineLimit(1)
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            Text(store.fileTitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func tab(_ mode: ViewMode) -> some View {
        let selected = store.view == mode
        let n = store.count(mode)
        return HStack(spacing: 5) {
            Text(mode.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(selected ? Color.primary.opacity(0.1) : .clear))
    }
}

// MARK: - List

struct TaskList: View {
    let store: TaskStore
    let obsidian: Bool

    var body: some View {
        let rows = store.rows
        let today = store.today()
        ScrollViewReader { proxy in
            ScrollView {
                if rows.isEmpty {
                    emptyState.frame(maxWidth: .infinity).padding(.top, 90)
                } else {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            switch row {
                            case .heading(_, let level, let text):
                                SectionHeader(text: text, level: level)
                            case .task(let t):
                                TaskRow(item: t, selected: t.id == store.selected, today: today,
                                        file: obsidian ? store.url(of: t) : nil,
                                        fileLabel: store.multiFile && store.view != .all ? store.docs[t.doc].name : nil,
                                        onTap: { store.selected = t.id; store.onEditEnded?() },
                                        onDoubleTap: { store.selected = t.id; store.beginEdit(.edit) },
                                        onCheck: { store.selected = t.id; store.toggle(); store.onEditEnded?() })
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .onChange(of: store.selected) { _, new in
                if let new { proxy.scrollTo(new) }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if let error = store.fileError {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(.orange)
                Text(error).font(.callout).multilineTextAlignment(.center).padding(.horizontal, 40)
                Text("Choose another file in Settings (⌘,)").font(.caption).foregroundStyle(.secondary)
            } else if !store.filter.isEmpty {
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No matching tasks").foregroundStyle(.secondary)
            } else if store.view == .today {
                Image(systemName: "sun.max").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Nothing due today").foregroundStyle(.secondary)
            } else if store.view == .upcoming {
                Image(systemName: "calendar").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("Nothing scheduled").foregroundStyle(.secondary)
            } else {
                Image(systemName: "checklist").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No tasks yet").foregroundStyle(.secondary)
                HStack(spacing: 4) { Text("Press"); KeyCap(key: "n"); Text("to add one") }
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct SectionHeader: View {
    let text: String
    let level: Int

    var body: some View {
        if level == 0 {
            Label(text, systemImage: "doc.text")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.top, 14)
                .padding(.bottom, 2)
                .padding(.horizontal, 10)
        } else {
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 3)
                .padding(.horizontal, 10)
        }
    }
}

struct TaskRow: View {
    let item: TaskItem
    let selected: Bool
    let today: Date
    let file: URL?  // set only when Obsidian integration is on
    var fileLabel: String?
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onCheck: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(item.done ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .onTapGesture(perform: onCheck)
            Text(rendered)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 8)
            chips
        }
        .font(.system(size: 13.5))
        .padding(.vertical, 5)
        .padding(.trailing, 10)
        .padding(.leading, 10 + CGFloat(item.depth) * 22)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onTapGesture(perform: onTap)
    }

    private var icon: String {
        if item.cancelled { return "xmark.circle.fill" }
        return item.done ? "checkmark.circle.fill" : "circle"
    }

    private var rendered: AttributedString {
        let source = file != nil ? Obsidian.linkify(item.title, from: file) : item.title
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: opts)) ?? AttributedString(item.title)
    }

    @ViewBuilder
    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(item.tags.prefix(3), id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
            if let fileLabel {
                Text(fileLabel).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            if item.recurrence != nil {
                Image(systemName: "repeat").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let p = item.priority {
                Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(priorityColor(p))
            }
            if let d = item.effectiveDate {
                let diff = Dates.dayDiff(from: today, to: d)
                let overdue = diff < 0 && !item.done
                HStack(spacing: 3) {
                    if item.due == nil { Image(systemName: "hourglass").font(.system(size: 9)) }
                    Text(Dates.label(d, now: today))
                }
                .font(.system(size: 11))
                .foregroundStyle(item.done ? Color.secondary : overdue ? .red : diff == 0 ? .orange : .secondary)
            }
        }
    }
}

// MARK: - Footer, help, welcome

struct FooterBar: View {
    let store: TaskStore
    var floating = false

    var body: some View {
        HStack(spacing: 12) {
            if let status = store.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !store.hasFiles {
                Hint(key: "↩", label: "choose files")
                Hint(key: "c", label: "create new")
            } else if let kind = store.editing {
                Hint(key: "↩", label: kind == .filter ? "apply" : kind == .move ? "move here" : kind == .snooze ? "snooze" : "save")
                if store.closeAfterCommit { Hint(key: "⇧↩", label: "save & add another") }
                Hint(key: "esc", label: "cancel")
            } else {
                Hint(key: "j k", label: "move")
                Hint(key: "x", label: "done")
                Hint(key: "n", label: "new")
                Hint(key: "e", label: "edit")
                Hint(key: "t", label: "due")
                Hint(key: "/", label: "filter")
                Hint(key: "1 2 3", label: "views")
                Hint(key: "?", label: "help")
            }
            Spacer(minLength: 0)
            if store.hasFiles, store.editing == nil, store.status == nil {
                Text("\(store.count(.all)) open").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, floating ? 18 : 14)
        .padding(.vertical, floating ? 9 : 8)
        .modifier(FloatingBar(enabled: floating, radius: 22))
    }
}

/// Wraps a bar in its own glass capsule when it floats over the list.
struct FloatingBar: ViewModifier {
    let enabled: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .tockSurface(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

struct HelpOverlay: View {
    private let columns: [(String, [(String, String)])] = [
        ("Move", [("j k  ↑ ↓", "up / down"), ("g G", "top / bottom"), ("1 2 3", "All / Today / Upcoming"),
                  ("/", "filter (text or #tag)"), ("esc", "clear filter, then close")]),
        ("Tasks", [("x  space", "toggle done"), ("n", "new below"), ("N", "new at end"), ("e  ↩", "edit"),
                   ("dd", "delete"), ("t", "set due date"), ("s", "snooze (push date)"),
                   ("m", "move to heading"), ("p", "cycle priority"),
                   ("J K", "move down / up"), ("⇥  ⇧⇥", "indent / outdent"),
                   ("u  ⌃R", "undo / redo"), ("H", "show or hide done")]),
        ("Other", [("o", "open file"), ("l", "open linked note (Obsidian)"), ("⌘,", "settings")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(columns, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(.secondary)
                        ForEach(items, id: \.0) { key, label in
                            HStack(spacing: 8) {
                                KeyCap(key: key)
                                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 4) {
                Text("WHEN ADDING OR EDITING").font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                Text("@tomorrow  @mon  @+3d  @24.12     due date").font(.system(size: 12, design: .monospaced))
                Text("!high  !med  !low                 priority").font(.system(size: 12, design: .monospaced))
                Text("~daily  ~weekly  ~2w  ~weekday    repeat").font(.system(size: 12, design: .monospaced))
                Text("#tag                              tag").font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Tock").font(.title2.weight(.semibold))
            Text("Tock edits plain markdown files of checkbox tasks.\nPick the files you want to use, or create a new one.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
