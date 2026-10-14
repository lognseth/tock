import AppKit
import SwiftUI

/// `Tock --snapshot out.png [today|upcoming|help|edit|welcome|dark|window|windowdark]` renders the panel with sample data, for visual checks.
@MainActor
enum Snapshot {
    static func run(path: String, variant: String) -> Int32 {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "tock.snapshot")!
        defaults.removePersistentDomain(forName: "tock.snapshot")
        let prefs = Preferences(defaults: defaults)
        let store = TaskStore(prefs: prefs)
        let cal = Dates.calendar
        let today = Dates.startOfDay(Date())
        func day(_ n: Int) -> String { Dates.format(cal.date(byAdding: .day, value: n, to: today)!) }

        let sample = """
        # Work
        - [ ] Review pull request for the billing service #work 📅 \(day(0)) ⏫
        - [ ] Write release notes for 2.4 📅 \(day(-2)) 🔼
        \t- [ ] Collect changelog from the team
        \t- [x] Draft the summary
        - [ ] Quarterly planning prep 📅 \(day(3)) #planning
        - [ ] Water the plants 📅 \(day(1)) 🔁 every week

        # Home
        - [ ] Book dentist appointment #health ⏳ \(day(5))
        - [ ] Buy a birthday present for [[Anna]] 🔽
        - [x] Renew passport
        - [ ] Call the landlord about the heating

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tock-snapshot.md")
        try? sample.write(to: url, atomically: true, encoding: .utf8)
        store.fileURL = variant == "welcome" ? nil : url
        store.load()
        if variant == "today" { store.setView(.today) }
        if variant == "upcoming" { store.setView(.upcoming) }
        if variant == "help" { store.showHelp = true }
        if variant == "edit" { store.beginEdit(.newEnd) }
        if variant == "filter" { store.filter = "home"; store.fixSelection() }
        if variant != "welcome" && variant != "today" && variant != "upcoming" && variant != "filter" {
            store.selected = store.taskLines.dropFirst().first
        }

        if variant == "window" { store.showSection("Home") }
        let isWindow = variant == "window" || variant == "windowdark"
        if variant == "windowdark" { store.setView(.all) }
        let size = isWindow ? NSSize(width: 960, height: 640) : NSSize(width: 640, height: 480)
        let hosting = NSHostingView(rootView: isWindow
            ? AnyView(WindowView(store: store, prefs: prefs))
            : AnyView(PanelView(store: store, prefs: prefs)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: (variant == "dark" || variant == "windowdark") ? .darkAqua : .aqua)
        window.backgroundColor = (variant == "dark" || variant == "windowdark") ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
        return 0
    }
}
