import Foundation

/// Run with `Tock --selftest`. (Plain Command Line Tools ship neither XCTest nor Swift Testing.)
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ cond: Bool, _ msg: @autoclosure () -> String, line: Int = #line) {
        checks += 1
        if !cond { failures += 1; print("FAIL line \(line): \(msg())") }
    }

    private static func eq<T: Equatable>(_ a: T, _ b: T, line: Int = #line) {
        check(a == b, "\n  got:      \(a)\n  expected: \(b)", line: line)
    }

    /// Wednesday 2026-10-14.
    private static let today = Dates.parseISO("2026-10-14")!
    private static func d(_ s: String) -> Date { Dates.parseISO(s)! }

    private static func makePrefs() -> Preferences {
        let suite = "tock.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Preferences(defaults: defaults)
    }

    private static func makeStore(_ content: String, prefs: Preferences? = nil) -> (TaskStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tock-\(UUID().uuidString).md")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        let store = TaskStore(prefs: prefs ?? makePrefs())
        store.now = { today }
        store.setFiles([url])
        return (store, url)
    }

    private static func disk(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }

    static func run() -> Int32 {
        parsing()
        dates()
        recurrence()
        quickEntry()
        editing()
        structure()
        views()
        indexing()
        sidebar()
        multiFile()
        moveAndSnooze()
        reminders()
        external()
        obsidian()
        print(failures == 0 ? "selftest: all \(checks) checks passed" : "selftest: \(failures) of \(checks) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: -

    private static func parsing() {
        eq(MD.parseTask("- [ ] a")?.title, "a")
        eq(MD.parseTask("\t* [x] b")?.done, true)
        eq(MD.parseTask("\t* [x] b")?.indent, 4)
        eq(MD.parseTask("- [-] gone")?.cancelled, true)
        eq(MD.parseTask("- [/] doing")?.done, false)
        check(MD.parseTask("- [ ]nospace") == nil, "nospace")
        check(MD.parseTask("- plain bullet") == nil, "plain bullet")
        check(MD.parseTask("- [] empty box") == nil, "empty box")

        let t = MD.parseTask("- [ ] Pay rent #money/home 📅 2026-10-20 ⏫ 🔁 every month ⏳ 2026-10-18")!
        eq(t.title, "Pay rent")
        eq(t.due, d("2026-10-20"))
        eq(t.scheduled, d("2026-10-18"))
        eq(t.priority, .high)
        eq(t.recurrence, "every month")
        eq(t.tags, ["money/home"])

        let u = MD.parseTask("- [x] done ✅ 2026-10-01 📅\u{FE0F} 2026-10-02")!
        eq(u.title, "done")
        eq(u.due, d("2026-10-02"))
        eq(MD.parseTask("- [ ] fix #1 issue")?.tags ?? [], ["1"])
        eq(MD.parseTask("- [ ] see [[Note|alias]] and **bold**")?.title, "see [[Note|alias]] and **bold**")
    }

    private static func dates() {
        eq(Dates.parse("today", now: today), today)
        eq(Dates.parse("tom", now: today), d("2026-10-15"))
        eq(Dates.parse("fri", now: today), d("2026-10-16"))
        eq(Dates.parse("wed", now: today), d("2026-10-21"))       // same weekday means next week
        eq(Dates.parse("monday", now: today), d("2026-10-19"))
        eq(Dates.parse("+3d", now: today), d("2026-10-17"))
        eq(Dates.parse("+2w", now: today), d("2026-10-28"))
        eq(Dates.parse("+1m", now: today), d("2026-11-14"))
        eq(Dates.parse("nextweek", now: today), d("2026-10-19"))
        eq(Dates.parse("2027-01-05", now: today), d("2027-01-05"))
        eq(Dates.parse("24.12", now: today), d("2026-12-24"))
        eq(Dates.parse("01.10", now: today), d("2027-10-01"))     // already passed, so next year
        eq(Dates.parse("24.12.27", now: today), d("2027-12-24"))
        check(Dates.parse("31.02", now: today) == nil, "invalid day")
        check(Dates.parse("banana", now: today) == nil, "garbage")
        check(Dates.parse("m", now: today) == nil, "too-short weekday")
        eq(Dates.label(d("2026-10-14"), now: today), "Today")
        eq(Dates.label(d("2026-10-15"), now: today), "Tomorrow")
        eq(Dates.label(d("2026-10-13"), now: today), "Yesterday")
    }

    private static func recurrence() {
        eq(Recurrence.canonical(token: "weekly"), "every week")
        eq(Recurrence.canonical(token: "2w"), "every 2 weeks")
        eq(Recurrence.canonical(token: "d"), "every day")
        check(Recurrence.canonical(token: "soon") == nil, "bad token")
        let week = Recurrence("every week")!
        eq(week.next(from: d("2026-10-14"), today: today), d("2026-10-21"))
        let wd = Recurrence("every weekday")!
        eq(wd.next(from: d("2026-10-16"), today: today), d("2026-10-19"))  // Fri -> Mon
        let whenDone = Recurrence("every 2 days when done")!
        eq(whenDone.next(from: d("2026-01-01"), today: today), d("2026-10-16"))
        check(Recurrence("sometimes") == nil, "not a rule")

        // Completing a recurring task spawns the next one right below.
        let (s, url) = makeStore("- [ ] water plants 📅 2026-10-14 🔁 every week\n- [ ] other\n")
        s.toggle()
        eq(disk(url), "- [x] water plants 📅 2026-10-14 🔁 every week\n- [ ] water plants 📅 2026-10-21 🔁 every week\n- [ ] other\n")
        eq(s.selected, 1)
        s.undo()
        eq(disk(url), "- [ ] water plants 📅 2026-10-14 🔁 every week\n- [ ] other\n")
    }

    private static func quickEntry() {
        let q = MD.parseQuick("buy milk @tomorrow !high ~weekly #home @nonsense", now: today)
        eq(q.text, "buy milk #home @nonsense")
        eq(q.due, d("2026-10-15"))
        eq(q.priority, .high)
        eq(q.recurrence, "every week")
        eq(MD.apply(q, to: "- [ ] x"), "- [ ] x 📅 2026-10-15 ⏫ 🔁 every week")
        // Replacing a field keeps a done stamp last.
        eq(MD.setDue("- [x] a 📅 2026-01-01 ✅ 2026-02-02", d("2026-03-03")), "- [x] a 📅 2026-03-03 ✅ 2026-02-02")
        eq(MD.setRecurrence("- [ ] a 🔁 every day 📅 2026-01-01", "every week"), "- [ ] a 🔁 every week 📅 2026-01-01")
        eq(MD.setDue("- [ ] a 📅 2026-01-01 ⏫", nil), "- [ ] a ⏫")
        eq(MD.setPriority("- [ ] a ⏫", nil), "- [ ] a")
    }

    private static func editing() {
        do { // toggle: no stamp by default, stamp when enabled
            let src = "---\ntitle: x\n---\n# Inbox\nprose here\n- [ ] one\n- [ ] two\n"
            let (s, url) = makeStore(src)
            eq(s.selected, 5)
            s.toggle()
            eq(disk(url), src.replacingOccurrences(of: "- [ ] one", with: "- [x] one"))
            s.toggle()
            eq(disk(url), src)

            let prefs = makePrefs(); prefs.stampDone = true
            let (s2, url2) = makeStore(src, prefs: prefs)
            s2.toggle()
            check(disk(url2).contains("- [x] one ✅ 2026-10-14\n"), "stamp")
            s2.toggle()
            eq(disk(url2), src)
        }
        do { // new below keeps indent; append keeps trailing newline; tokens applied
            let (s, url) = makeStore("- [ ] a\n\t- [ ] b\n- [ ] c\n")
            s.beginEdit(.newBelow); s.draft = "a2 @tom"; s.commitEdit()
            eq(disk(url), "- [ ] a\n\t- [ ] b\n- [ ] a2 📅 2026-10-15\n- [ ] c\n")
            s.beginEdit(.newEnd); s.draft = "z !low"; s.commitEdit()
            eq(disk(url), "- [ ] a\n\t- [ ] b\n- [ ] a2 📅 2026-10-15\n- [ ] c\n- [ ] z 🔽\n")
        }
        do { // edit keeps done mark and bullet; undo/redo
            let src = "* [x] a\n"
            let (s, url) = makeStore(src)
            s.beginEdit(.edit)
            eq(s.draft, "a")
            s.draft = "b"; s.commitEdit()
            eq(disk(url), "* [x] b\n")
            s.undo(); eq(disk(url), src)
            s.redo(); eq(disk(url), "* [x] b\n")
        }
        do { // empty-title and bad-date commits keep the editor open
            let (s, url) = makeStore("- [ ] a\n")
            s.beginEdit(.newEnd); s.draft = "@tomorrow"; s.commitEdit()
            check(s.editing == .newEnd, "still editing when only tokens typed")
            s.cancelEdit()
            s.beginEdit(.due); s.draft = "garbage"; s.commitEdit()
            check(s.editing == .due, "still editing on bad date")
            s.draft = "fri"; s.commitEdit()
            eq(disk(url), "- [ ] a 📅 2026-10-16\n")
            s.beginEdit(.due); s.draft = ""; s.commitEdit()
            eq(disk(url), "- [ ] a\n")
        }
        do { // priority cycle
            let (s, url) = makeStore("- [ ] a\n")
            s.cyclePriority(); eq(disk(url), "- [ ] a ⏫\n")
            s.cyclePriority(); eq(disk(url), "- [ ] a 🔼\n")
            s.cyclePriority(); eq(disk(url), "- [ ] a 🔽\n")
            s.cyclePriority(); eq(disk(url), "- [ ] a\n")
        }
        do { // new tasks under a heading
            let prefs = makePrefs(); prefs.newTaskHeading = "Inbox"
            let (s, url) = makeStore("# Work\n- [ ] w\n\n## Inbox\n- [ ] i1\n\n# Later\n- [ ] l\n", prefs: prefs)
            s.beginEdit(.newEnd); s.draft = "i2"; s.commitEdit()
            eq(disk(url), "# Work\n- [ ] w\n\n## Inbox\n- [ ] i1\n- [ ] i2\n\n# Later\n- [ ] l\n")

            let prefs2 = makePrefs(); prefs2.newTaskHeading = "Inbox"
            let (s2, url2) = makeStore("- [ ] a\n", prefs: prefs2)
            s2.beginEdit(.newEnd); s2.draft = "b"; s2.commitEdit()
            eq(disk(url2), "- [ ] a\n\n## Inbox\n- [ ] b\n")
        }
    }

    private static func structure() {
        do { // delete removes children
            let (s, url) = makeStore("- [ ] a\n\t- [ ] b\n- [ ] c\n")
            s.selected = 0; s.delete()
            eq(disk(url), "- [ ] c\n"); eq(s.selected, 0)
        }
        do { // reorder moves whole block
            let (s, url) = makeStore("- [ ] a\n\t- [ ] b\n- [ ] c\n")
            s.selected = 0; s.reorder(1)
            eq(disk(url), "- [ ] c\n- [ ] a\n\t- [ ] b\n"); eq(s.selected, 1)
            s.reorder(-1)
            eq(disk(url), "- [ ] a\n\t- [ ] b\n- [ ] c\n"); eq(s.selected, 0)
        }
        do { // indent / outdent
            let (s, url) = makeStore("- [ ] a\n- [ ] b\n")
            s.selected = 1; s.indent(1)
            eq(disk(url), "- [ ] a\n\t- [ ] b\n")
            s.indent(-1)
            eq(disk(url), "- [ ] a\n- [ ] b\n")
        }
    }

    private static func views() {
        let src = """
        # A
        - [ ] later 📅 2026-10-20
        - [ ] overdue 📅 2026-10-10 #x
        - [ ] today ⏳ 2026-10-14
        - [x] finished 📅 2026-10-14
        - [ ] undated
        - [ ] tomorrow 📅 2026-10-15

        """
        let (s, url) = makeStore(src)
        eq(s.count(.all), 5); eq(s.count(.today), 2); eq(s.count(.upcoming), 2)

        s.setView(.today)
        eq(s.rows.compactMap { if case .task(let t) = $0 { return t.title } else { return nil } }, ["overdue", "today"])
        eq(s.rows.compactMap { if case .heading(_, _, let t) = $0 { return t } else { return nil } }, ["Overdue", "Today"])
        s.setView(.upcoming)
        eq(s.rows.compactMap { if case .task(let t) = $0 { return t.title } else { return nil } }, ["tomorrow", "later"])

        // Structure edits are blocked outside the plain All view, so file order can't be corrupted.
        let before = disk(url)
        s.reorder(1); s.indent(1)
        eq(disk(url), before)

        s.setView(.all)
        s.filter = "#x"; s.fixSelection()
        eq(s.taskIDs.count, 1)
        s.filter = "TODAY"; s.fixSelection()
        eq(s.taskIDs.count, 1)
        s.filter = ""
        s.showDone = false
        eq(s.taskIDs.count, 5)
    }

    private static func indexing() {
        // Frontmatter and fenced code are never treated as tasks; depth follows nesting not width.
        let src = "---\n- [ ] in frontmatter\n---\n- [ ] real\n```\n- [ ] in code\n```\n- [ ] a\n  - [ ] b\n    - [ ] c\n"
        let (s, _) = makeStore(src)
        eq(s.docs[0].taskMap.values.map(\.title).sorted(), ["a", "b", "c", "real"])
        eq(s.docs[0].taskMap[8]?.depth, 1)
        eq(s.docs[0].taskMap[9]?.depth, 2)

        let (empty, _) = makeStore("")
        eq(empty.taskIDs.count, 0)
        empty.beginEdit(.newEnd); empty.draft = "first"; empty.commitEdit()
        eq(empty.docs[0].lines, ["- [ ] first", ""])
    }

    private static func sidebar() {
        let src = "# Work\n- [ ] a #x\n- [ ] b #x #y\n## Sub\n- [ ] c\n# Home\n- [ ] d #y\n- [x] e #z\n"
        let (s, _) = makeStore(src)
        eq(s.sections.map(\.name), ["Work", "Sub", "Home"])
        eq(s.sections.map(\.count), [3, 1, 1])
        eq(s.tags.map(\.name), ["x", "y"])             // done tasks don't count; ties sort by name
        eq(s.tags.map(\.count), [2, 2])

        s.showSection("Work")
        eq(s.taskIDs.count, 3)                        // includes the nested ## Sub
        eq(s.viewTitle, "Work")
        s.showSection("Sub")
        eq(s.taskIDs.count, 1)
        s.showTag("y")
        eq(s.taskIDs.count, 2)
        check(s.scope == .all && s.filter == "#y", "tag resets section")
        s.showView(.today)
        check(s.filter.isEmpty && s.view == .today, "showView resets filter")
        s.showView(.all)
        eq(s.taskIDs.count, 5)
        s.showSection("Home"); s.setView(.all)
        check(s.scope == .all, "keyboard 1 clears the section")

        // Reordering still works inside a section, using real file lines.
        let (s2, url2) = makeStore("# A\n- [ ] 1\n- [ ] 2\n# B\n- [ ] 3\n")
        s2.showSection("A"); s2.selected = 1; s2.reorder(1)
        eq(disk(url2), "# A\n- [ ] 2\n- [ ] 1\n# B\n- [ ] 3\n")
    }

    private static func makeMulti(_ contents: [String], inbox: Int = 0) -> (TaskStore, [URL]) {
        let urls = contents.map { content -> URL in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tock-\(UUID().uuidString).md")
            try! content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let store = TaskStore(prefs: makePrefs())
        store.now = { today }
        store.setFiles(urls, inbox: urls[inbox])
        return (store, urls)
    }

    private static func multiFile() {
        let (s, urls) = makeMulti(["# Work\n- [ ] w1 📅 2026-10-14\n- [ ] w2\n", "# Home\n- [ ] h1 📅 2026-10-10\n- [x] h2\n"], inbox: 1)
        eq(s.docs.count, 2)
        eq(s.fileTitle, "2 files")
        eq(s.count(.all), 3); eq(s.count(.today), 2)
        eq(s.taskIDs.count, 4)                                 // done tasks are shown by default
        eq(s.taskIDs.map { TaskID.doc($0) }, [0, 0, 1, 1])

        // Today merges files, overdue first.
        s.setView(.today)
        eq(s.taskIDs.map { s.task($0)!.title }, ["h1", "w1"])
        s.setView(.all)

        // File and section scopes, and new tasks follow the scope.
        s.showFile(1)
        eq(s.taskIDs.count, 2)
        s.beginEdit(.newEnd); s.draft = "scoped"; s.commitEdit()
        eq(disk(urls[1]), "# Home\n- [ ] h1 📅 2026-10-10\n- [x] h2\n- [ ] scoped\n")
        s.showView(.all)
        s.beginEdit(.newEnd); s.draft = "to inbox"; s.commitEdit()
        check(disk(urls[1]).hasSuffix("- [ ] to inbox\n"), "unscoped quick add goes to the inbox file")
        eq(disk(urls[0]), "# Work\n- [ ] w1 📅 2026-10-14\n- [ ] w2\n")

        // Selection and edits address the right file.
        s.selected = TaskID.make(doc: 1, line: 1)
        s.toggle()
        check(disk(urls[1]).contains("- [x] h1"), "toggle edits the second file")
        eq(disk(urls[0]), "# Work\n- [ ] w1 📅 2026-10-14\n- [ ] w2\n")

        // Undo goes back through changes in either file.
        s.undo(); s.undo(); s.undo()
        eq(disk(urls[1]), "# Home\n- [ ] h1 📅 2026-10-10\n- [x] h2\n")

        // Removing a file keeps the others.
        s.setFiles([urls[0]])
        eq(s.docs.count, 1)
        eq(s.fileTitle, s.docs[0].name)
    }

    private static func moveAndSnooze() {
        // Move within a file.
        let (s, url) = makeStore("# A\n- [ ] 1\n\t- [ ] 1a\n- [ ] 2\n\n# B\n- [ ] 3\n")
        s.selected = 1
        s.beginEdit(.move)
        eq(s.moveTargets().map(\.label), ["A", "B", "End of file"])
        s.draft = "b"; s.commitEdit()
        eq(disk(url), "# A\n- [ ] 2\n\n# B\n- [ ] 3\n- [ ] 1\n\t- [ ] 1a\n")
        eq(s.selected, 5)
        s.undo()
        eq(disk(url), "# A\n- [ ] 1\n\t- [ ] 1a\n- [ ] 2\n\n# B\n- [ ] 3\n")

        // A nested task moves to the top level of its new section.
        s.selected = 2
        s.beginEdit(.move); s.draft = "a"; s.commitEdit()
        eq(disk(url), "# A\n- [ ] 1\n- [ ] 2\n- [ ] 1a\n\n# B\n- [ ] 3\n")

        // Move across files as one undoable step.
        let (m, urls) = makeMulti(["# One\n- [ ] x\n", "# Two\n- [ ] y\n"])
        m.selected = TaskID.make(doc: 0, line: 1)
        m.beginEdit(.move); m.draft = "two"; m.commitEdit()
        eq(disk(urls[0]), "# One\n")
        eq(disk(urls[1]), "# Two\n- [ ] y\n- [ ] x\n")
        eq(m.selected, TaskID.make(doc: 1, line: 2))
        m.undo()
        eq(disk(urls[0]), "# One\n- [ ] x\n")
        eq(disk(urls[1]), "# Two\n- [ ] y\n")

        // Snooze moves the due date, or the scheduled date if that's all there is.
        let (z, zurl) = makeStore("- [ ] a 📅 2026-10-14\n- [ ] b ⏳ 2026-10-14\n- [ ] c\n")
        z.setView(.today)
        eq(z.taskIDs, [0, 1])
        z.selected = 0
        z.beginEdit(.snooze); z.draft = "+3d"; z.commitEdit()
        eq(disk(zurl), "- [ ] a 📅 2026-10-17\n- [ ] b ⏳ 2026-10-14\n- [ ] c\n")
        eq(z.selected, 1)                                       // moved on to the next visible task
        z.beginEdit(.snooze); z.draft = "fri"; z.commitEdit()
        eq(disk(zurl), "- [ ] a 📅 2026-10-17\n- [ ] b ⏳ 2026-10-16\n- [ ] c\n")
        eq(z.taskIDs.count, 0)
        z.setView(.all); z.selected = 2
        z.beginEdit(.snooze); z.draft = "garbage"; z.commitEdit()
        check(z.editing == .snooze, "bad date keeps the prompt open")
        z.cancelEdit()
    }

    private static func reminders() {
        let a = MD.parseTask("- [ ] first 📅 2026-10-10")!
        let b = MD.parseTask("- [ ] second 📅 2026-10-14")!
        let c = MD.parseTask("- [ ] third")!
        check(Reminders.summary(overdue: [], today: []) == nil, "nothing due, no notification")
        eq(Reminders.summary(overdue: [a], today: [b])?.title, "1 overdue, 1 due today")
        eq(Reminders.summary(overdue: [], today: [b])?.title, "1 due today")
        eq(Reminders.summary(overdue: [a], today: [b, c, c, c])?.body, "• first\n• second\n• third\n…and 2 more")

        let nine = 9 * 60
        let day = Dates.parseISO("2026-10-14")!
        func at(_ h: Int, _ m: Int = 0) -> Date { day.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        check(!Reminders.shouldSend(now: at(8, 59), lastSent: nil, minutes: nine), "before the time")
        check(Reminders.shouldSend(now: at(9), lastSent: nil, minutes: nine), "at the time")
        check(Reminders.shouldSend(now: at(14), lastSent: nil, minutes: nine), "late launch still sends")
        check(!Reminders.shouldSend(now: at(14), lastSent: at(9), minutes: nine), "already sent today")
        check(Reminders.shouldSend(now: at(9), lastSent: at(9).addingTimeInterval(-86400), minutes: nine), "sent yesterday")

        // Overdue and due-today lists come from every file.
        let (s, _) = makeMulti(["- [ ] a 📅 2026-10-01\n- [ ] b 📅 2026-10-14\n", "- [ ] c ⏳ 2026-10-14\n- [x] d 📅 2026-10-01\n- [ ] e 📅 2026-10-20\n"])
        let due = s.dueSummary()
        eq(due.overdue.map(\.title), ["a"])
        eq(due.today.map(\.title), ["b", "c"])
    }

    private static func external() {
        // A change made by another app between our load and our write is picked up, not clobbered.
        let (s, url) = makeStore("- [ ] a\n")
        Thread.sleep(forTimeInterval: 0.05)
        try! "- [ ] top\n- [ ] a\n".write(to: url, atomically: true, encoding: .utf8)
        s.beginEdit(.newEnd); s.draft = "mine"; s.commitEdit()
        eq(disk(url), "- [ ] top\n- [ ] a\n- [ ] mine\n")

        // An edit in progress follows its line if the file shifts.
        let (s2, url2) = makeStore("- [ ] a\n- [ ] b\n")
        s2.selected = 1
        s2.beginEdit(.edit)
        Thread.sleep(forTimeInterval: 0.05)
        try! "- [ ] new\n- [ ] a\n- [ ] b\n".write(to: url2, atomically: true, encoding: .utf8)
        s2.draft = "b2"; s2.commitEdit()
        eq(disk(url2), "- [ ] new\n- [ ] a\n- [ ] b2\n")

        // Missing file reports an error instead of crashing.
        let (s3, url3) = makeStore("- [ ] a\n")
        try? FileManager.default.removeItem(at: url3)
        s3.load()
        check(s3.fileError != nil, "file error surfaced")
    }

    private static func obsidian() {
        let links = Obsidian.wikilinks(in: "see [[Project X|the project]] and [[Other#Heading]]")
        eq(links.map(\.target), ["Project X", "Other#Heading"])
        eq(links.map(\.display), ["the project", "Other#Heading"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Notes")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("Tasks.md")
        eq(Obsidian.vaultRoot(of: file)?.lastPathComponent, root.lastPathComponent)
        let url = Obsidian.noteURL(for: file)!.absoluteString
        check(url.contains("file=Notes/Tasks") || url.contains("file=Notes%2FTasks"), url)
        check(url.contains("vault=vault-"), url)
        check(Obsidian.linkify("a [[B|c]] d", from: file).contains("[c](obsidian://open?"), "linkify")
        // Outside a vault: no vault root, falls back to path.
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString).md")
        check(Obsidian.vaultRoot(of: plain) == nil, "no vault above temp dir")
        check(Obsidian.noteURL(for: plain)!.absoluteString.contains("path="), "path fallback")
        try? FileManager.default.removeItem(at: root)
    }
}
