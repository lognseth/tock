import SwiftUI

/// The full window: a floating sidebar (views, lists, tags) next to the same task list the popup uses.
/// The sidebar and the bottom bars are glass; the list itself stays flat for readability.
struct WindowView: View {
    @Bindable var store: TaskStore
    @ObservedObject var prefs: Preferences

    private let sidebarShape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        ZStack {
            WindowBackdrop()
            HStack(alignment: .top, spacing: 0) {
                if store.hasFiles {
                    // Starts below the traffic-light row so the buttons don't straddle the card's corner.
                    Sidebar(store: store)
                        .frame(width: 236)
                        .clipShape(sidebarShape)
                        .tockSurface(sidebarShape)
                        .padding(EdgeInsets(top: 44, leading: 10, bottom: 10, trailing: 0))
                }
                VStack(spacing: 0) {
                    if !store.hasFiles {
                        WelcomeView()
                    } else {
                        WindowHeader(store: store)
                        ZStack {
                            TaskList(store: store, obsidian: prefs.obsidianEnabled)
                            if store.showHelp { HelpOverlay().transition(.opacity) }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    GlassEffectContainer(spacing: 8) {
                        VStack(spacing: 8) {
                            if let kind = store.editing { EditBar(store: store, kind: kind, floating: true) }
                            FooterBar(store: store, floating: true)
                        }
                    }
                    .padding(.bottom, 10)
                    .padding(.top, 4)
                }
                // Same 10pt margin as the sidebar card, so nothing touches the window edge.
                .padding(.horizontal, 10)
            }
        }
        .ignoresSafeArea(.container, edges: .top)  // content runs under the transparent title bar
        .frame(minWidth: 700, minHeight: 440)
        .animation(.easeOut(duration: 0.12), value: store.showHelp)
    }
}

/// A soft accent glow gives the glass something to refract.
struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(0.16), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.purple.opacity(0.08), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 480)
        }
        .ignoresSafeArea()
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
        .padding(.horizontal, 18)   // lines the title up with the row icons below
        .padding(.top, 14)          // centred on the traffic lights
        .padding(.bottom, 8)
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
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
        }
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
