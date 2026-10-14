import AppKit
import SwiftUI

/// `Tock --snapshot out.png [today|upcoming|help|edit|move|snooze|welcome|dark|window|windowdark|multi]` renders the panel with sample data, for visual checks.
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
        var urls = variant == "welcome" ? [] : [url]
        if variant == "multi" {
            let second = FileManager.default.temporaryDirectory.appendingPathComponent("Reading.md")
            try? "# Books\n- [ ] Finish the Swift concurrency chapter 📅 \(day(0)) #learning\n- [ ] Order the new paperback\n\n# Articles\n- [ ] Read the Sparkle docs ⏫\n".write(to: second, atomically: true, encoding: .utf8)
            urls.append(second)
        }
        store.setFiles(urls)
        if variant == "today" { store.setView(.today) }
        if variant == "upcoming" { store.setView(.upcoming) }
        if variant == "help" { store.showHelp = true }
        if variant == "edit" { store.beginEdit(.newEnd) }
        if variant == "move" { store.beginEdit(.move) }
        if variant == "snooze" { store.beginEdit(.snooze) }
        if variant == "filter" { store.filter = "home"; store.fixSelection() }
        if variant != "welcome" && variant != "today" && variant != "upcoming" && variant != "filter" {
            store.selected = store.taskIDs.dropFirst().first
        }

        if variant == "window" { store.showSection("Home") }
        let isWindow = ["window", "windowdark", "multi"].contains(variant)
        if variant == "windowdark" { store.setView(.all) }
        let size = isWindow ? NSSize(width: 960, height: 640) : NSSize(width: 640, height: 480)
        let hosting = NSHostingView(rootView: isWindow
            ? AnyView(WindowView(store: store, prefs: prefs))
            : AnyView(PanelView(store: store, prefs: prefs)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let dark = variant == "dark" || variant == "windowdark"

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)
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
