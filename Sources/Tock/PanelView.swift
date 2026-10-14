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
            if store.fileURL == nil {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .animation(.easeOut(duration: 0.12), value: store.showHelp)
    }
}

struct EditBar: View {
    @Bindable var store: TaskStore
    let kind: EditKind
    @FocusState private var focused: Bool

    var body: some View {
        let (icon, prompt): (String, String) = switch kind {
        case .edit: ("pencil", "Edit task")
        case .due: ("calendar", "Due date: today, tomorrow, mon, +3d, 24.12. Empty clears")
        case .filter: ("magnifyingglass", "Filter by text or #tag")
        default: ("plus.circle.fill", "New task   @tomorrow  !high  ~weekly  #tag")
        }
        let text = kind == .filter ? $store.filter : $store.draft
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { store.commitEdit(keepOpen: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) }
                .onExitCommand { store.cancelEdit() }
                .onChange(of: store.filter) { _, _ in if kind == .filter { store.fixSelection() } }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.06))
        .onAppear { DispatchQueue.main.async { focused = true } }
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
            Text(store.fileURL?.deletingPathExtension().lastPathComponent ?? "")
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
                                TaskRow(item: t, selected: t.line == store.selected, today: today,
                                        file: obsidian ? store.fileURL : nil,
                                        onTap: { store.selected = t.line; store.onEditEnded?() },
                                        onDoubleTap: { store.selected = t.line; store.beginEdit(.edit) },
                                        onCheck: { store.selected = t.line; store.toggle(); store.onEditEnded?() })
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
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
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 3)
            .padding(.horizontal, 10)
    }
}

struct TaskRow: View {
    let item: TaskItem
    let selected: Bool
    let today: Date
    let file: URL?  // set only when Obsidian integration is on
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

    var body: some View {
        HStack(spacing: 12) {
            if let status = store.status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if store.fileURL == nil {
                Hint(key: "↩", label: "choose file")
                Hint(key: "c", label: "create new")
            } else if let kind = store.editing {
                Hint(key: "↩", label: kind == .filter ? "apply" : "save")
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
            if store.fileURL != nil, store.editing == nil, store.status == nil {
                Text("\(store.count(.all)) open").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct HelpOverlay: View {
    private let columns: [(String, [(String, String)])] = [
        ("Move", [("j k  ↑ ↓", "up / down"), ("g G", "top / bottom"), ("1 2 3", "All / Today / Upcoming"),
                  ("/", "filter (text or #tag)"), ("esc", "clear filter, then close")]),
        ("Tasks", [("x  space", "toggle done"), ("n", "new below"), ("N", "new at end"), ("e  ↩", "edit"),
                   ("dd", "delete"), ("t", "set due date"), ("p", "cycle priority"),
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
            Text("Tock edits a plain markdown file of checkbox tasks.\nPick the file you want to use, or create a new one.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
