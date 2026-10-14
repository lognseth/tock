import SwiftUI

/// The full window: a sidebar (views, lists, tags) next to the same task list the popup uses.
struct WindowView: View {
    @Bindable var store: TaskStore
    @ObservedObject var prefs: Preferences

    var body: some View {
        HStack(spacing: 0) {
            if store.hasFiles {
                Sidebar(store: store)
                    .frame(width: 220)
                Divider()
            }
            VStack(spacing: 0) {
                if !store.hasFiles {
                    WelcomeView()
                } else {
                    WindowHeader(store: store)
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
        }
        .frame(minWidth: 700, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.12), value: store.showHelp)
    }
}

struct WindowHeader: View {
    let store: TaskStore

    var body: some View {
        HStack(spacing: 10) {
            Text(store.viewTitle).font(.title3.weight(.semibold)).lineLimit(1)
            Spacer()
            if !store.filter.isEmpty && store.editing != .filter {
                Button {
                    store.clearFilter()
                    store.onEditEnded?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10))
                        Text(store.filter).font(.system(size: 11)).lineLimit(1)
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

struct Sidebar: View {
    @Bindable var store: TaskStore

    private static let icons: [ViewMode: String] = [.all: "tray.full", .today: "sun.max", .upcoming: "calendar"]

    var body: some View {
        let sections = store.sections
        let minLevel = sections.filter { !$0.isFile }.map(\.level).min() ?? 1
        let tags = store.tags
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                title("Views")
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    SidebarRow(icon: Self.icons[mode] ?? "circle", title: mode.title, count: store.count(mode),
                               selected: store.view == mode && store.scope == .all && store.filter.isEmpty) {
                        choose { store.showView(mode) }
                    }
                }
                if !sections.isEmpty {
                    title(store.multiFile ? "Files" : "Lists")
                    ForEach(sections) { s in
                        if s.isFile {
                            SidebarRow(icon: "doc.text", title: s.name, count: s.count,
                                       selected: store.view == .all && store.scope == .file(s.doc)) {
                                choose { store.showFile(s.doc) }
                            }
                        } else {
                            SidebarRow(icon: "list.bullet", title: s.name, count: s.count,
                                       selected: store.view == .all && store.scope == .section(doc: s.doc, name: s.name),
                                       indent: s.level - minLevel + (store.multiFile ? 1 : 0)) {
                                choose { store.showSection(doc: s.doc, name: s.name) }
                            }
                        }
                    }
                }
                if !tags.isEmpty {
                    title("Tags")
                    ForEach(tags) { t in
                        SidebarRow(icon: "number", title: t.name, count: t.count,
                                   selected: store.filter == "#" + t.name) {
                            choose { store.showTag(t.name) }
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Clicking must not leave keyboard focus on the sidebar; the list keys expect the window itself.
    private func choose(_ action: () -> Void) {
        action()
        store.onEditEnded?()
    }

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            .padding(.bottom, 3)
            .padding(.horizontal, 8)
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let count: Int
    let selected: Bool
    var indent = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5)
            .padding(.trailing, 8)
            .padding(.leading, 8 + CGFloat(max(indent, 0)) * 14)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}
