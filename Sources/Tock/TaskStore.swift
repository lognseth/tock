import Foundation
import Observation

enum EditKind {
    case newBelow, newEnd, edit, due, snooze, move, filter
}

enum ViewMode: Int, CaseIterable {
    case all, today, upcoming

    var title: String { ["All", "Today", "Upcoming"][rawValue] }
}

/// What the All view is limited to (picked in the window sidebar).
enum Scope: Equatable {
    case all
    case file(Int)
    case section(doc: Int, name: String)
}

struct SectionInfo: Identifiable {
    let id: Int        // global id of the heading (or file header)
    let doc: Int
    let name: String
    let level: Int     // 0 for a file entry
    let count: Int
    var isFile: Bool { level == 0 }
}

struct TagInfo: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

struct MoveTarget: Identifiable {
    let doc: Int
    let heading: String?  // nil = end of file
    let label: String
    var id: String { "\(doc)/\(heading ?? "")" }
}

enum Row: Identifiable {
    case heading(id: Int, level: Int, text: String)
    case task(TaskItem)

    var id: Int {
        switch self {
        case .heading(let id, _, _): return id
        case .task(let t): return t.id
        }
    }
}

private struct HistoryEntry {
    let doc: Document
    let lines: [String]
}

@MainActor
@Observable
final class TaskStore {
    private(set) var docs: [Document] = []
    private(set) var inboxIndex = 0

    var selected: Int?          // global task id
    var editing: EditKind?
    var draft = ""
    var filter = ""
    var view: ViewMode = .all
    var scope: Scope = .all
    var showDone: Bool
    var showHelp = false
    var status: String?
    var moveIndex = 0

    @ObservationIgnored let prefs: Preferences
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored var pendingD = false
    @ObservationIgnored var closeAfterCommit = false
    @ObservationIgnored var onCloseRequest: (() -> Void)?
    @ObservationIgnored var onEditEnded: (() -> Void)?
    @ObservationIgnored private var undoStack: [[HistoryEntry]] = []
    @ObservationIgnored private var redoStack: [[HistoryEntry]] = []
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

    // MARK: - Files

    var hasFiles: Bool { !docs.isEmpty }
    var multiFile: Bool { docs.count > 1 }
    var fileError: String? { docs.compactMap(\.error).first }

    var fileTitle: String {
        switch docs.count {
        case 0: return ""
        case 1: return docs[0].name
        default: return "\(docs.count) files"
        }
    }

    /// File that receives new tasks when nothing narrower applies.
    var inboxDoc: Document? {
        docs.indices.contains(inboxIndex) ? docs[inboxIndex] : docs.first
    }

    /// Reuses documents that are already open so their state survives preference changes.
    func setFiles(_ urls: [URL], inbox: URL? = nil) {
        var unique: [URL] = []
        for u in urls where !unique.contains(u) { unique.append(u) }

        var next: [Document] = []
        for (i, u) in unique.enumerated() {
            if let existing = docs.first(where: { $0.url == u }) {
                existing.assign(index: i)
                next.append(existing)
            } else {
                let d = Document(url: u, index: i)
                d.load()
                next.append(d)
            }
        }
        let changed = next.map(\.url) != docs.map(\.url)
        docs = next
        inboxIndex = inbox.flatMap { u in docs.firstIndex { $0.url == u } } ?? 0
        if changed {
            undoStack.removeAll()
            redoStack.removeAll()
            selected = nil
            scope = .all
        }
        fixSelection()
    }

    func load() {
        for d in docs { refresh(d, force: true) }
    }

    func reloadIfChanged() {
        for d in docs { refresh(d, force: false) }
    }

    /// Reloads a file and keeps the same task selected if the file shifted underneath us.
    private func refresh(_ d: Document, force: Bool) {
        guard force || d.changedOnDisk else { return }
        var origin: String?
        var oldLine = 0
        if let s = selected, TaskID.doc(s) == d.index, d.lines.indices.contains(TaskID.line(s)) {
            oldLine = TaskID.line(s)
            origin = d.lines[oldLine]
        }
        d.load()
        if let origin, !(d.lines.indices.contains(oldLine) && d.lines[oldLine] == origin) {
            selected = d.lines.indices.filter { d.lines[$0] == origin }
                .min { abs($0 - oldLine) < abs($1 - oldLine) }
                .map { TaskID.make(doc: d.index, line: $0) }
        }
        fixSelection()
    }

    private func save(_ d: Document, _ lines: [String]) {
        if let error = d.setLines(lines) { flash(error) }
    }

    // MARK: - History

    private func commit(_ changes: [(doc: Document, lines: [String])]) {
        let real = changes.filter { $0.doc.lines != $0.lines }
        guard !real.isEmpty else { return }
        undoStack.append(real.map { HistoryEntry(doc: $0.doc, lines: $0.doc.lines) })
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        for c in real { save(c.doc, c.lines) }
    }

    private func mutate(_ doc: Document, _ body: (inout [String]) -> Void) {
        var new = doc.lines
        body(&new)
        commit([(doc, new)])
    }

    /// Moves one step through history, unless a file changed on disk since (then the history is stale).
    private func step(from source: inout [[HistoryEntry]], to target: inout [[HistoryEntry]]) {
        guard let entry = source.last else { return }
        if entry.contains(where: { $0.doc.changedOnDisk }) {
            load()
            undoStack.removeAll()
            redoStack.removeAll()
            flash("File changed on disk, undo history cleared")
            return
        }
        source.removeLast()
        target.append(entry.map { HistoryEntry(doc: $0.doc, lines: $0.doc.lines) })
        for s in entry { save(s.doc, s.lines) }
        fixSelection()
    }

    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }

    // MARK: - Lookup

    func task(_ id: Int) -> TaskItem? {
        let d = TaskID.doc(id)
        return docs.indices.contains(d) ? docs[d].taskMap[TaskID.line(id)] : nil
    }

    func url(of task: TaskItem) -> URL? {
        docs.indices.contains(task.doc) ? docs[task.doc].url : nil
    }

    /// The file the user most likely means: the selected task's, else the inbox.
    var activeFileURL: URL? {
        if let s = selected, let t = task(s) { return url(of: t) }
        return inboxDoc?.url
    }

    private func currentTask() -> (task: TaskItem, doc: Document)? {
        reloadIfChanged()
        guard let s = selected, let t = task(s) else { return nil }
        return (t, docs[t.doc])
    }

    // MARK: - Rows

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

    private func fileHeadingID(_ doc: Int) -> Int { -2_000_000 - doc }

    var rows: [Row] {
        view == .all ? allRows() : dateRows()
    }

    private func sectionRange(_ d: Document, _ name: String) -> Range<Int>? {
        guard let h = d.headings.first(where: { $0.text == name }) else { return nil }
        let end = d.headings.first { $0.line > h.line && $0.level <= h.level }?.line ?? d.lines.count
        return h.line..<end
    }

    private func allRows() -> [Row] {
        var out: [Row] = []
        for d in docs {
            var range: Range<Int>?
            switch scope {
            case .all: break
            case .file(let i): if i != d.index { continue }
            case .section(let i, let name):
                if i != d.index { continue }
                range = sectionRange(d, name)
            }
            if multiFile, scope == .all {
                out.append(.heading(id: fileHeadingID(d.index), level: 0, text: d.name))
            }
            for entry in d.outline {
                switch entry {
                case .task(let t):
                    if (t.done && !showDone) || !matchesFilter(t) { continue }
                    if let range, !range.contains(t.line) { continue }
                    out.append(.task(t))
                case .heading(let h):
                    if let range, !range.contains(h.line) { continue }
                    out.append(.heading(id: TaskID.make(doc: d.index, line: h.line), level: h.level, text: h.text))
                }
            }
        }
        return prune(out)
    }

    /// Drops headings that have no task under them before the next heading of the same or higher rank.
    private func prune(_ rows: [Row]) -> [Row] {
        rows.enumerated().compactMap { i, row in
            guard case .heading(_, let level, _) = row else { return row }
            for next in rows[(i + 1)...] {
                switch next {
                case .task: return row
                case .heading(_, let l, _): if l <= level { return nil }
                }
            }
            return nil
        }
    }

    private func dateRows() -> [Row] {
        let today = self.today()
        let items = docs.flatMap { $0.taskMap.values }.filter { t in
            guard !t.done, let d = t.effectiveDate, matchesFilter(t) else { return false }
            return view == .today ? d <= today : d > today
        }.sorted { a, b in
            let (da, db) = (a.effectiveDate!, b.effectiveDate!)
            if da != db { return da < db }
            return a.id < b.id
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

    var taskIDs: [Int] {
        rows.compactMap { if case .task(let t) = $0 { return t.id } else { return nil } }
    }

    private var allTasks: [TaskItem] { docs.flatMap { $0.taskMap.values } }

    func count(_ mode: ViewMode) -> Int {
        let today = self.today()
        return allTasks.filter { t in
            guard !t.done else { return false }
            switch mode {
            case .all: return true
            case .today: return t.effectiveDate.map { $0 <= today } ?? false
            case .upcoming: return t.effectiveDate.map { $0 > today } ?? false
            }
        }.count
    }

    /// Open tasks that are overdue or due today, for the daily summary.
    func dueSummary() -> (overdue: [TaskItem], today: [TaskItem]) {
        let today = self.today()
        let open = allTasks.filter { !$0.done }.sorted { $0.id < $1.id }
        return (open.filter { $0.effectiveDate.map { $0 < today } ?? false },
                open.filter { $0.effectiveDate == today })
    }

    var canStructure: Bool { view == .all && filter.isEmpty }

    var viewTitle: String {
        guard view == .all else { return view.title }
        switch scope {
        case .all: return "All"
        case .file(let i): return docs.indices.contains(i) ? docs[i].name : "All"
        case .section(_, let name): return name
        }
    }

    // MARK: - Sidebar data

    private func openCount(_ d: Document, in range: Range<Int>? = nil) -> Int {
        d.taskMap.values.filter { !$0.done && (range?.contains($0.line) ?? true) }.count
    }

    /// Files (when there are several) each followed by their headings, with open-task counts.
    var sections: [SectionInfo] {
        var out: [SectionInfo] = []
        for d in docs {
            if multiFile {
                out.append(SectionInfo(id: fileHeadingID(d.index), doc: d.index, name: d.name, level: 0, count: openCount(d)))
            }
            for h in d.headings {
                let end = d.headings.first { $0.line > h.line && $0.level <= h.level }?.line ?? d.lines.count
                out.append(SectionInfo(id: TaskID.make(doc: d.index, line: h.line), doc: d.index, name: h.text,
                                       level: h.level, count: openCount(d, in: h.line..<end)))
            }
        }
        return out
    }

    var tags: [TagInfo] {
        var counts: [String: Int] = [:]
        for t in allTasks where !t.done {
            for tag in Set(t.tags) { counts[tag, default: 0] += 1 }
        }
        return counts.map { TagInfo(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    func fixSelection() {
        let tasks = taskIDs
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
        moveIndex = 0
    }

    // MARK: - Navigation

    func move(_ delta: Int) {
        let tasks = taskIDs
        guard !tasks.isEmpty else { selected = nil; return }
        if let s = selected, let p = tasks.firstIndex(of: s) {
            selected = tasks[max(0, min(tasks.count - 1, p + delta))]
        } else {
            selected = delta >= 0 ? tasks.first : tasks.last
        }
    }

    func jumpTop() { selected = taskIDs.first }
    func jumpBottom() { selected = taskIDs.last }

    func setView(_ mode: ViewMode) {
        view = mode
        if mode == .all { scope = .all }
        fixSelection()
    }

    /// Sidebar choices reset everything else so the list shows exactly what was picked.
    func showView(_ mode: ViewMode) {
        filter = ""
        scope = .all
        view = mode
        fixSelection()
    }

    func showFile(_ doc: Int) {
        filter = ""
        view = .all
        scope = .file(doc)
        fixSelection()
    }

    func showSection(doc: Int, name: String) {
        filter = ""
        view = .all
        scope = .section(doc: doc, name: name)
        fixSelection()
    }

    /// Convenience for the first file containing that heading.
    func showSection(_ name: String) {
        guard let d = docs.first(where: { $0.headings.contains { $0.text == name } }) else { return }
        showSection(doc: d.index, name: name)
    }

    func showTag(_ tag: String) {
        scope = .all
        view = .all
        filter = "#" + tag
        fixSelection()
    }

    func clearFilter() {
        filter = ""
        fixSelection()
    }

    func clearScope() {
        scope = .all
        fixSelection()
    }

    // MARK: - Actions

    func toggle() {
        guard let (t, doc) = currentTask() else { return }
        let tasks = taskIDs
        let after = tasks.first { $0 > t.id }
        let before = tasks.last { $0 < t.id }
        let today = self.today()
        let nowDone = !t.done
        let stamp = prefs.stampDone
        let rule = nowDone ? Recurrence(t.recurrence ?? "") : nil
        let end = doc.blockEnd(t.line)
        let base = t.due ?? t.scheduled ?? today
        let nextDate = rule?.next(from: base, today: today)
        var insertedAt: Int?

        mutate(doc) {
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
            selected = TaskID.make(doc: doc.index, line: insertedAt)
            flash("Next: \(Dates.label(nextDate, now: today))")
        } else if nowDone && (view != .all || !showDone) {
            selected = after ?? before
        }
    }

    func delete() {
        guard let (t, doc) = currentTask() else { return }
        let end = doc.blockEnd(t.line)
        let tasks = taskIDs
        let removedIDs = (t.line..<end).map { TaskID.make(doc: doc.index, line: $0) }
        let after = tasks.first { $0 > t.id && !removedIDs.contains($0) }
        let before = tasks.last { $0 < t.id }
        mutate(doc) { $0.removeSubrange(t.line..<end) }
        // Later lines in the same file moved up by the size of the removed block.
        selected = after.map { TaskID.doc($0) == doc.index ? $0 - (end - t.line) : $0 } ?? before
    }

    func reorder(_ delta: Int) {
        guard canStructure, let (t, doc) = currentTask() else { return }
        let s = t.line
        let end = doc.blockEnd(s)
        let w = MD.indentWidth(doc.lines[s])
        if delta > 0 {
            guard end < doc.lines.count, doc.taskMap[end] != nil, MD.indentWidth(doc.lines[end]) == w else { return }
            let nextEnd = doc.blockEnd(end)
            mutate(doc) {
                let block = Array($0[s..<end])
                let next = Array($0[end..<nextEnd])
                $0.replaceSubrange(s..<nextEnd, with: next + block)
            }
            selected = TaskID.make(doc: doc.index, line: s + (nextEnd - end))
        } else {
            var j = s - 1
            while j >= 0, !MD.isBlank(doc.lines[j]), MD.indentWidth(doc.lines[j]) > w { j -= 1 }
            guard j >= 0, doc.taskMap[j] != nil, MD.indentWidth(doc.lines[j]) == w else { return }
            mutate(doc) {
                let prev = Array($0[j..<s])
                let block = Array($0[s..<end])
                $0.replaceSubrange(j..<end, with: block + prev)
            }
            selected = TaskID.make(doc: doc.index, line: j)
        }
    }

    func indent(_ delta: Int) {
        guard canStructure, let (t, doc) = currentTask() else { return }
        let end = doc.blockEnd(t.line)
        mutate(doc) {
            for i in t.line..<end {
                $0[i] = delta > 0 ? "\t" + $0[i] : MD.outdent($0[i])
            }
        }
    }

    func cyclePriority() {
        guard let (t, doc) = currentTask() else { return }
        let next: Priority?
        switch t.priority {
        case nil: next = .high
        case .high?: next = .medium
        case .medium?: next = .low
        default: next = nil
        }
        mutate(doc) { $0[t.line] = MD.setPriority($0[t.line], next) }
        flash(next.map { "Priority: \($0.name)" } ?? "Priority cleared")
    }

    // MARK: - Move to heading

    func moveTargets() -> [MoveTarget] {
        let q = draft.lowercased().trimmingCharacters(in: .whitespaces)
        var out: [MoveTarget] = []
        for d in docs {
            let prefix = multiFile ? "\(d.name) › " : ""
            for h in d.headings { out.append(MoveTarget(doc: d.index, heading: h.text, label: prefix + h.text)) }
            out.append(MoveTarget(doc: d.index, heading: nil, label: prefix + "End of file"))
        }
        return q.isEmpty ? out : out.filter { $0.label.lowercased().contains(q) }
    }

    private func perform(move t: TaskItem, to target: MoveTarget) {
        guard docs.indices.contains(target.doc) else { return }
        let src = docs[t.doc], dst = docs[target.doc]
        let end = src.blockEnd(t.line)

        // The block lands at the target's top level, whatever it was nested under before.
        var block = Array(src.lines[t.line..<end])
        let base = MD.leadingWhitespace(block[0])
        if !base.isEmpty { block = block.map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : $0 } }

        var srcLines = src.lines
        srcLines.removeSubrange(t.line..<end)
        var dstLines = src === dst ? srcLines : dst.lines
        guard let pos = MD.insertionPoint(in: dstLines, underHeading: target.heading) else { return }
        dstLines.insert(contentsOf: block, at: pos)

        if src === dst {
            commit([(src, dstLines)])
        } else {
            commit([(src, srcLines), (dst, dstLines)])
        }
        selected = TaskID.make(doc: dst.index, line: pos)
        flash("Moved to \(target.label)")
    }

    // MARK: - Editing

    func beginEdit(_ kind: EditKind) {
        reloadIfChanged()
        switch kind {
        case .edit:
            guard let (t, doc) = currentTask() else { return }
            draft = t.text
            editOrigin = doc.lines[t.line]
            editing = .edit
        case .due:
            guard let (t, doc) = currentTask() else { return }
            draft = t.due.map(Dates.format) ?? ""
            editOrigin = doc.lines[t.line]
            editing = .due
        case .snooze, .move:
            guard let (t, doc) = currentTask() else { return }
            draft = ""
            moveIndex = 0
            editOrigin = doc.lines[t.line]
            editing = kind
        case .newBelow:
            if let (t, doc) = currentTask(), canStructure {
                editOrigin = doc.lines[t.line]
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
        if closeAfterCommit, let kind, [.newBelow, .newEnd, .edit].contains(kind) {
            closeAfterCommit = false
            onCloseRequest?()
        }
    }

    /// Re-finds the line being edited if the file moved underneath us.
    private func resolveOrigin() -> Int? {
        guard let origin = editOrigin, let s = selected else { return nil }
        let d = TaskID.doc(s)
        guard docs.indices.contains(d) else { return nil }
        let lines = docs[d].lines
        if lines.indices.contains(TaskID.line(s)), lines[TaskID.line(s)] == origin { return s }
        return lines.firstIndex(of: origin).map { TaskID.make(doc: d, line: $0) }
    }

    private func finishEdit() {
        editing = nil
        draft = ""
        editOrigin = nil
        onEditEnded?()
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

        switch kind {
        case .due, .snooze:
            guard let id = resolveOrigin(), let t = task(id) else { cancelEdit(); flash("File changed, edit cancelled"); return }
            let doc = docs[t.doc]
            var date: Date?
            if !text.isEmpty {
                guard let d = Dates.parse(text, now: now()) else {
                    flash("Couldn't read “\(text)” as a date")
                    return
                }
                date = d
            } else if kind == .snooze {
                cancelEdit()
                return
            }
            let tasks = taskIDs
            let after = tasks.first { $0 > id }, before = tasks.last { $0 < id }
            finishEdit()
            mutate(doc) {
                // Snoozing a task that only has a scheduled date moves that date instead.
                if kind == .snooze, t.due == nil, t.scheduled != nil {
                    $0[t.line] = MD.setScheduled($0[t.line], date)
                } else {
                    $0[t.line] = MD.setDue($0[t.line], date)
                }
            }
            selected = id
            if !taskIDs.contains(id) { selected = after ?? before }
            if kind == .snooze, let date { flash("Snoozed until \(Dates.label(date, now: today()))") }
            return

        case .move:
            let targets = moveTargets()
            guard let id = resolveOrigin(), let t = task(id), !targets.isEmpty else { cancelEdit(); return }
            let target = targets[min(moveIndex, targets.count - 1)]
            let tasks = taskIDs
            let after = tasks.first { $0 > id }, before = tasks.last { $0 < id }
            finishEdit()
            perform(move: t, to: target)
            if !taskIDs.contains(selected ?? -1) { selected = after ?? before }
            return

        default:
            break
        }

        let quick = MD.parseQuick(text, now: now())
        guard !quick.text.isEmpty else {
            if text.isEmpty { cancelEdit() } else { flash("A task needs a title") }
            return
        }

        switch kind {
        case .edit:
            guard let id = resolveOrigin(), let t = task(id) else { cancelEdit(); flash("File changed, edit cancelled"); return }
            let doc = docs[t.doc]
            let ws = MD.leadingWhitespace(doc.lines[t.line])
            let bullet = doc.lines[t.line].dropFirst(ws.count).first ?? "-"
            let line = "\(ws)\(bullet) [\(t.mark)] \(quick.text)"
            mutate(doc) { $0[t.line] = MD.apply(quick, to: line) }
            selected = id
        case .newBelow:
            if let id = resolveOrigin(), let t = task(id) {
                let doc = docs[t.doc]
                let ws = MD.leadingWhitespace(doc.lines[t.line])
                let pos = doc.blockEnd(t.line)
                mutate(doc) { $0.insert(MD.apply(quick, to: "\(ws)- [ ] \(quick.text)"), at: pos) }
                selected = TaskID.make(doc: doc.index, line: pos)
            } else {
                appendTask(quick)
            }
        case .newEnd:
            appendTask(quick)
        default:
            break
        }

        editOrigin = nil
        if closeAfterCommit && keepOpen && kind == .newEnd {
            // Stay in the editor so the text field keeps keyboard focus.
            flash("Added")
            draft = ""
            return
        }
        finishEdit()
        if closeAfterCommit {
            closeAfterCommit = false
            onCloseRequest?()
        }
    }

    /// New tasks go to the file and section you're looking at, else the inbox file under the configured heading.
    private func appendTask(_ quick: QuickInput) {
        var doc = inboxDoc
        var heading: String? = prefs.newTaskHeading.trimmingCharacters(in: .whitespaces)
        switch scope {
        case .all: break
        case .file(let i): if docs.indices.contains(i) { doc = docs[i] }
        case .section(let i, let name): if docs.indices.contains(i) { doc = docs[i]; heading = name }
        }
        guard let doc else { return }
        if heading?.isEmpty == true { heading = nil }

        let line = MD.apply(quick, to: "- [ ] \(quick.text)")
        var lines = doc.lines
        let pos: Int
        if let found = MD.insertionPoint(in: lines, underHeading: heading) {
            pos = found
            lines.insert(line, at: pos)
        } else {
            // Heading doesn't exist yet: create it at the end of the file.
            let eof = lines.last == "" ? lines.count - 1 : lines.count
            var block = ["## \(heading ?? "")", line]
            if eof > 0, !MD.isBlank(lines[eof - 1]) { block.insert("", at: 0) }
            lines.insert(contentsOf: block, at: eof)
            pos = eof + block.count - 1
        }
        commit([(doc, lines)])
        selected = TaskID.make(doc: doc.index, line: pos)
    }
}
