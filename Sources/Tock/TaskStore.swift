import Foundation
import Observation

enum EditKind {
    case newBelow, newEnd, edit, due, filter
}

enum ViewMode: Int, CaseIterable {
    case all, today, upcoming

    var title: String { ["All", "Today", "Upcoming"][rawValue] }
}

struct Heading {
    let line: Int
    let level: Int
    let text: String
}

struct SectionInfo: Identifiable {
    let id: Int  // heading line
    let name: String
    let level: Int
    let count: Int
}

struct TagInfo: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

private enum Entry {
    case task(TaskItem)
    case heading(Heading)
}

@MainActor
@Observable
final class TaskStore {
    var lines: [String] = []
    private(set) var taskMap: [Int: TaskItem] = [:]
    private(set) var headings: [Heading] = []
    @ObservationIgnored private var outline: [Entry] = []

    var selected: Int?
    var editing: EditKind?
    var draft = ""
    var filter = ""
    var view: ViewMode = .all
    var section: String?  // heading text; limits the All view to that part of the file
    var showDone: Bool
    var showHelp = false
    var status: String?
    var fileError: String?
    var fileURL: URL?

    @ObservationIgnored let prefs: Preferences
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var pendingD = false
    @ObservationIgnored var closeAfterCommit = false
    @ObservationIgnored var onCloseRequest: (() -> Void)?
    @ObservationIgnored var onEditEnded: (() -> Void)?
    @ObservationIgnored private var mtime: Date?
    @ObservationIgnored private var undoStack: [[String]] = []
    @ObservationIgnored private var redoStack: [[String]] = []
    @ObservationIgnored private var editOrigin: String?
    @ObservationIgnored private var flashToken = UUID()

    init(prefs: Preferences) {
        self.prefs = prefs
        showDone = prefs.showDoneByDefault
    }

    func today() -> Date { Dates.startOfDay(now()) }

    func flash(_ message: String) {
        status = message
        let token = UUID()
        flashToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if flashToken == token { status = nil }
        }
    }

    // MARK: - Index

    private func reindex() {
        var tasks: [Int: TaskItem] = [:]
        var heads: [Heading] = []
        var entries: [Entry] = []
        var inFence = false
        var indentStack: [Int] = []

        var start = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { start = end + 1 }

        for i in start..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if var t = MD.parseTask(line, at: i) {
                while let last = indentStack.last, last >= t.indent { indentStack.removeLast() }
                t.depth = indentStack.count
                indentStack.append(t.indent)
                tasks[i] = t
                entries.append(.task(t))
            } else if let h = MD.parseHeading(line) {
                indentStack.removeAll()
                let heading = Heading(line: i, level: h.level, text: h.text)
                heads.append(heading)
                entries.append(.heading(heading))
            }
        }
        taskMap = tasks
        headings = heads
        outline = entries
    }

    // MARK: - Derived rows

    private func matchesFilter(_ t: TaskItem) -> Bool {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let title = t.title.lowercased()
        return words.allSatisfy { w in
            if w.hasPrefix("#"), w.count > 1 {
                return t.tags.contains { $0.lowercased().hasPrefix(w.dropFirst()) }
            }
            return title.contains(w) || t.tags.contains { $0.lowercased().contains(w) }
        }
    }

    var rows: [Row] {
        view == .all ? allRows() : dateRows()
    }

    private func sectionRange(_ name: String) -> Range<Int>? {
        guard let h = headings.first(where: { $0.text == name }) else { return nil }
        let end = headings.first { $0.line > h.line && $0.level <= h.level }?.line ?? lines.count
        return h.line..<end
    }

    private func allRows() -> [Row] {
        let range = section.flatMap(sectionRange)
        var out: [Row] = []
        for entry in outline {
            switch entry {
            case .task(let t):
                if (t.done && !showDone) || !matchesFilter(t) { continue }
                if let range, !range.contains(t.line) { continue }
                out.append(.task(t))
            case .heading(let h):
                if let range, !range.contains(h.line) { continue }
                out.append(.heading(id: h.line, level: h.level, text: h.text))
            }
        }
        // Drop headings with nothing under them.
        return out.enumerated().compactMap { i, row in
            guard case .heading = row else { return row }
            if i + 1 >= out.count { return nil }
            if case .heading = out[i + 1] { return nil }
            return row
        }
    }

    private func dateRows() -> [Row] {
        let today = self.today()
        let items = taskMap.values.filter { t in
            guard !t.done, let d = t.effectiveDate, matchesFilter(t) else { return false }
            return view == .today ? d <= today : d > today
        }.sorted { a, b in
            let (da, db) = (a.effectiveDate!, b.effectiveDate!)
            return da == db ? a.line < b.line : da < db
        }

        var out: [Row] = []
        var lastKey = ""
        var headingID = -1
        for var t in items {
            t.depth = 0
            let d = t.effectiveDate!
            let key = view == .today ? (d < today ? "Overdue" : "Today") : Dates.heading(d, now: today)
            if key != lastKey {
                out.append(.heading(id: headingID, level: 2, text: key))
                headingID -= 1
                lastKey = key
            }
            out.append(.task(t))
        }
        return out
    }

    var taskLines: [Int] {
        rows.compactMap { if case .task(let t) = $0 { return t.line } else { return nil } }
    }

    func count(_ mode: ViewMode) -> Int {
        let today = self.today()
        return taskMap.values.filter { t in
            guard !t.done else { return false }
            switch mode {
            case .all: return true
            case .today: return t.effectiveDate.map { $0 <= today } ?? false
            case .upcoming: return t.effectiveDate.map { $0 > today } ?? false
            }
        }.count
    }

    var canStructure: Bool { view == .all && filter.isEmpty }

    var viewTitle: String { view == .all ? (section ?? "All") : view.title }

    /// Headings with their open-task counts, for the window sidebar.
    var sections: [SectionInfo] {
        headings.map { h in
            let end = headings.first { $0.line > h.line && $0.level <= h.level }?.line ?? lines.count
            let n = taskMap.values.filter { !$0.done && $0.line > h.line && $0.line < end }.count
            return SectionInfo(id: h.line, name: h.text, level: h.level, count: n)
        }
    }

    var tags: [TagInfo] {
        var counts: [String: Int] = [:]
        for t in taskMap.values where !t.done {
            for tag in Set(t.tags) { counts[tag, default: 0] += 1 }
        }
        return counts.map { TagInfo(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    // MARK: - File IO

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func load() {
        guard let url = fileURL else { return }
        let origin = selected.flatMap { lines.indices.contains($0) ? lines[$0] : nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            lines = text.components(separatedBy: "\n")
            mtime = Self.modificationDate(url)
            fileError = nil
            reindex()
            // Keep the same task selected if the file shifted underneath us.
            if let origin, let s = selected, !(lines.indices.contains(s) && lines[s] == origin) {
                selected = lines.indices.filter { lines[$0] == origin }.min { abs($0 - s) < abs($1 - s) }
            }
            fixSelection()
        } catch {
            lines = []
            reindex()
            fileError = "Can't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reloadIfChanged() {
        guard let url = fileURL else { return }
        if Self.modificationDate(url) != mtime { load() }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            mtime = Self.modificationDate(url)
        } catch {
            flash("Can't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func mutate(_ body: (inout [String]) -> Void) {
        let before = lines
        body(&lines)
        guard lines != before else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        save()
        reindex()
    }

    func fixSelection() {
        let tasks = taskLines
        if let s = selected, tasks.contains(s) { return }
        selected = tasks.first
    }

    func resetTransient() {
        editing = nil
        draft = ""
        closeAfterCommit = false
        pendingD = false
        showHelp = false
        editOrigin = nil
    }

    // MARK: - Navigation

    func move(_ delta: Int) {
        let tasks = taskLines
        guard !tasks.isEmpty else { selected = nil; return }
        if let s = selected, let p = tasks.firstIndex(of: s) {
            selected = tasks[max(0, min(tasks.count - 1, p + delta))]
        } else {
            selected = delta >= 0 ? tasks.first : tasks.last
        }
    }

    func jumpTop() { selected = taskLines.first }
    func jumpBottom() { selected = taskLines.last }

    func setView(_ mode: ViewMode) {
        view = mode
        if mode == .all { section = nil }
        fixSelection()
    }

    /// Sidebar choices: reset everything else so the list shows exactly what was picked.
    func showView(_ mode: ViewMode) {
        filter = ""
        section = nil
        view = mode
        fixSelection()
    }

    func showSection(_ name: String) {
        filter = ""
        view = .all
        section = name
        fixSelection()
    }

    func showTag(_ tag: String) {
        section = nil
        view = .all
        filter = "#" + tag
        fixSelection()
    }

    func clearSection() {
        section = nil
        fixSelection()
    }

    func clearFilter() {
        filter = ""
        fixSelection()
    }

    // MARK: - Block helpers

    /// End (exclusive) of a task plus its more-indented children.
    private func blockEnd(_ i: Int, in lines: [String]) -> Int {
        let w = MD.indentWidth(lines[i])
        var j = i + 1
        while j < lines.count, !MD.isBlank(lines[j]), MD.indentWidth(lines[j]) > w { j += 1 }
        return j
    }

    private func currentTask() -> TaskItem? {
        reloadIfChanged()
        guard let s = selected else { return nil }
        return taskMap[s]
    }

    // MARK: - Actions

    func toggle() {
        guard let t = currentTask() else { return }
        let tasks = taskLines
        let after = tasks.first { $0 > t.line }
        let before = tasks.last { $0 < t.line }
        let today = self.today()
        let nowDone = !t.done
        let stamp = prefs.stampDone
        let rule = nowDone ? Recurrence(t.recurrence ?? "") : nil
        let end = blockEnd(t.line, in: lines)
        let base = t.due ?? t.scheduled ?? today
        let nextDate = rule?.next(from: base, today: today)
        var insertedAt: Int?

        mutate {
            let original = $0[t.line]
            $0[t.line] = MD.setStatus(original, mark: nowDone ? "x" : " ", stamp: stamp, today: today)
            guard let next = nextDate else { return }

            // Recurring: spawn the next occurrence right after this task's block.
            let shift = Dates.dayDiff(from: base, to: next)
            var copy = MD.setStatus(original, mark: " ", stamp: false, today: today)
            copy = MD.setDue(copy, next)
            if let s = t.scheduled, t.due != nil { copy = MD.setScheduled(copy, Dates.addDays(s, shift)) }
            $0.insert(copy, at: end)
            insertedAt = end
        }

        if let insertedAt, let nextDate {
            selected = insertedAt
            flash("Next: \(Dates.label(nextDate, now: today))")
        } else if nowDone && (view != .all || !showDone) {
            selected = after ?? before
        }
    }

    func delete() {
        guard let t = currentTask() else { return }
        let end = blockEnd(t.line, in: lines)
        let tasks = taskLines
        let after = tasks.first { $0 >= end }
        let before = tasks.last { $0 < t.line }
        mutate { $0.removeSubrange(t.line..<end) }
        selected = after.map { $0 - (end - t.line) } ?? before
    }

    func reorder(_ delta: Int) {
        guard canStructure, let t = currentTask() else { return }
        let s = t.line
        let end = blockEnd(s, in: lines)
        let w = MD.indentWidth(lines[s])
        if delta > 0 {
            guard end < lines.count, taskMap[end] != nil, MD.indentWidth(lines[end]) == w else { return }
            let nextEnd = blockEnd(end, in: lines)
            mutate {
                let block = Array($0[s..<end])
                let next = Array($0[end..<nextEnd])
                $0.replaceSubrange(s..<nextEnd, with: next + block)
            }
            selected = s + (nextEnd - end)
        } else {
            var j = s - 1
            while j >= 0, !MD.isBlank(lines[j]), MD.indentWidth(lines[j]) > w { j -= 1 }
            guard j >= 0, taskMap[j] != nil, MD.indentWidth(lines[j]) == w else { return }
            mutate {
                let prev = Array($0[j..<s])
                let block = Array($0[s..<end])
                $0.replaceSubrange(j..<end, with: block + prev)
            }
            selected = j
        }
    }

    func indent(_ delta: Int) {
        guard canStructure, let t = currentTask() else { return }
        let end = blockEnd(t.line, in: lines)
        mutate {
            for i in t.line..<end {
                $0[i] = delta > 0 ? "\t" + $0[i] : MD.outdent($0[i])
            }
        }
    }

    func cyclePriority() {
        guard let t = currentTask() else { return }
        let next: Priority?
        switch t.priority {
        case nil: next = .high
        case .high?: next = .medium
        case .medium?: next = .low
        default: next = nil
        }
        mutate { $0[t.line] = MD.setPriority($0[t.line], next) }
        flash(next.map { "Priority: \($0.name)" } ?? "Priority cleared")
    }

    func undo() {
        guard let url = fileURL else { return }
        if Self.modificationDate(url) != mtime {
            load()
            undoStack.removeAll()
            redoStack.removeAll()
            flash("File changed on disk, undo history cleared")
            return
        }
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(lines)
        lines = previous
        save()
        reindex()
        fixSelection()
    }

    func redo() {
        guard let url = fileURL else { return }
        if Self.modificationDate(url) != mtime {
            load()
            undoStack.removeAll()
            redoStack.removeAll()
            flash("File changed on disk, undo history cleared")
            return
        }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(lines)
        lines = next
        save()
        reindex()
        fixSelection()
    }

    // MARK: - Editing

    func beginEdit(_ kind: EditKind) {
        reloadIfChanged()
        switch kind {
        case .edit:
            guard let t = currentTask() else { return }
            draft = t.text
            editOrigin = lines[t.line]
            editing = .edit
        case .due:
            guard let t = currentTask() else { return }
            draft = t.due.map(Dates.format) ?? ""
            editOrigin = lines[t.line]
            editing = .due
        case .newBelow:
            if let t = currentTask(), canStructure {
                editOrigin = lines[t.line]
                editing = .newBelow
            } else {
                editing = .newEnd
            }
            draft = ""
        case .newEnd:
            draft = ""
            editing = .newEnd
        case .filter:
            editing = .filter
        }
    }

    func cancelEdit() {
        let kind = editing
        editing = nil
        draft = ""
        editOrigin = nil
        if kind == .filter { clearFilter() }
        onEditEnded?()
        if closeAfterCommit, kind != .filter, kind != .due {
            closeAfterCommit = false
            onCloseRequest?()
        }
    }

    /// Re-finds the line being edited if the file moved underneath us.
    private func resolveOrigin() -> Int? {
        guard let origin = editOrigin else { return nil }
        if let s = selected, lines.indices.contains(s), lines[s] == origin { return s }
        return lines.firstIndex(of: origin)
    }

    func commitEdit(keepOpen: Bool = false) {
        guard let kind = editing else { return }

        if kind == .filter {
            editing = nil
            fixSelection()
            onEditEnded?()
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        reloadIfChanged()

        if kind == .due {
            guard let s = resolveOrigin() else { cancelEdit(); flash("File changed, edit cancelled"); return }
            var date: Date?
            if !text.isEmpty {
                guard let d = Dates.parse(text, now: now()) else {
                    flash("Couldn't read “\(text)” as a date")
                    return
                }
                date = d
            }
            editing = nil
            draft = ""
            editOrigin = nil
            mutate { $0[s] = MD.setDue($0[s], date) }
            selected = s
            onEditEnded?()
            return
        }

        let quick = MD.parseQuick(text, now: now())
        guard !quick.text.isEmpty else {
            if text.isEmpty { cancelEdit() } else { flash("A task needs a title") }
            return
        }

        switch kind {
        case .edit:
            guard let s = resolveOrigin(), let t = taskMap[s] else { cancelEdit(); flash("File changed, edit cancelled"); return }
            let ws = MD.leadingWhitespace(lines[s])
            let bullet = lines[s].dropFirst(ws.count).first ?? "-"
            let line = "\(ws)\(bullet) [\(t.mark)] \(quick.text)"
            mutate { $0[s] = MD.apply(quick, to: line) }
            selected = s
        case .newBelow:
            if let s = resolveOrigin() {
                let ws = MD.leadingWhitespace(lines[s])
                let pos = blockEnd(s, in: lines)
                mutate { $0.insert(MD.apply(quick, to: "\(ws)- [ ] \(quick.text)"), at: pos) }
                selected = pos
            } else {
                appendTask(quick)
            }
        case .newEnd:
            appendTask(quick)
        case .due, .filter:
            break
        }

        editOrigin = nil
        if closeAfterCommit && keepOpen && kind == .newEnd {
            // Stay in the editor so the text field keeps keyboard focus.
            flash("Added")
            draft = ""
            return
        }
        editing = nil
        draft = ""
        onEditEnded?()
        if closeAfterCommit {
            closeAfterCommit = false
            onCloseRequest?()
        }
    }

    /// Adds to the end of the file, or under the configured heading.
    private func appendTask(_ quick: QuickInput) {
        let line = MD.apply(quick, to: "- [ ] \(quick.text)")
        let heading = prefs.newTaskHeading.trimmingCharacters(in: .whitespaces)
        let eof = lines.last == "" ? lines.count - 1 : lines.count

        guard !heading.isEmpty else {
            mutate { $0.insert(line, at: eof) }
            selected = eof
            return
        }

        if let h = headings.first(where: { $0.text.caseInsensitiveCompare(heading) == .orderedSame }) {
            var end = headings.first { $0.line > h.line && $0.level <= h.level }?.line ?? eof
            while end > h.line + 1, MD.isBlank(lines[end - 1]) { end -= 1 }
            mutate { $0.insert(line, at: end) }
            selected = end
        } else {
            // Heading doesn't exist yet: create it at the end of the file.
            var block = ["## \(heading)", line]
            if eof > 0, !MD.isBlank(lines[eof - 1]) { block.insert("", at: 0) }
            mutate { $0.insert(contentsOf: block, at: eof) }
            selected = eof + block.count - 1
        }
    }
}
