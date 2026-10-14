import Foundation

enum Priority: Int, CaseIterable {
    case highest, high, medium, low, lowest

    var emoji: String { ["🔺", "⏫", "🔼", "🔽", "⏬"][rawValue] }
    var name: String { ["highest", "high", "medium", "low", "lowest"][rawValue] }

    /// Token after `!` in the quick-entry field: !high, !h, !med, !low, !! (high), !!! (highest).
    static func fromToken(_ s: String) -> Priority? {
        switch s.lowercased() {
        case "highest", "hh", "!!": return .highest
        case "high", "h", "!": return .high
        case "medium", "med", "m": return .medium
        case "low", "l": return .low
        case "lowest", "ll": return .lowest
        default: return nil
        }
    }
}

struct TaskItem: Equatable {
    var doc = 0               // index of the file this task lives in
    var line: Int             // line within that file
    var indent: Int
    var depth = 0
    var mark: Character
    var text: String          // raw text after the checkbox, metadata included
    var title: String         // text without dates, priority, recurrence and tags
    var due: Date?
    var scheduled: Date?
    var priority: Priority?
    var recurrence: String?
    var tags: [String]

    var done: Bool { mark == "x" || mark == "X" || mark == "-" }
    var cancelled: Bool { mark == "-" }
    var id: Int { TaskID.make(doc: doc, line: line) }
    var effectiveDate: Date? { due ?? scheduled }
}

struct QuickInput {
    var text = ""
    var due: Date?
    var priority: Priority?
    var recurrence: String?
}

private enum Rx {
    // Markers that start a metadata field (Tasks-style emoji format).
    static let markers = "📅⏳🛫➕✅❌🔺⏫🔼🔽⏬🔁"
    static let vs = #"\x{FE0F}?"#
    static let date = #"(\d{4}-\d{2}-\d{2})"#

    static let due = make("📅\(vs)\\s*\(date)")
    static let scheduled = make("⏳\(vs)\\s*\(date)")
    static let otherDates = make("[🛫➕✅❌]\(vs)\\s*\(date)")
    static let priority = make("[🔺⏫🔼🔽⏬]\(vs)")
    static let recurrence = make("🔁\(vs)\\s*([^\(markers)\\s][^\(markers)]*?)(?=\\s*(?:[\(markers)]|$))")
    static let tag = make(#"(?:^|\s)#([\p{L}\p{N}_/-]+)"#)
    static let space = make(#"\s+"#)

    static func make(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static func range(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    static func capture(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: range(s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func strip(_ re: NSRegularExpression, from s: String, with t: String = "") -> String {
        re.stringByReplacingMatches(in: s, range: range(s), withTemplate: t)
    }
}

/// Line-level helpers. The file is only ever edited line by line, so anything that
/// isn't a task (prose, frontmatter, code blocks) round-trips untouched.
enum MD {
    static let stampPattern = #" ?✅\x{FE0F}? ?\d{4}-\d{2}-\d{2}"#

    /// Lines that can hold tasks or headings: not YAML frontmatter, not inside code fences.
    static func scannableLines(_ lines: [String]) -> [Int] {
        var start = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { start = end + 1 }
        var out: [Int] = []
        var inFence = false
        for i in start..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence { out.append(i) }
        }
        return out
    }

    static func headings(in lines: [String]) -> [Heading] {
        scannableLines(lines).compactMap { i in
            parseHeading(lines[i]).map { Heading(line: i, level: $0.level, text: $0.text) }
        }
    }

    /// Where a new task belongs: the end of the named section (before its trailing blank lines),
    /// or the end of the file when `heading` is nil. Returns nil if that heading doesn't exist.
    static func insertionPoint(in lines: [String], underHeading heading: String?) -> Int? {
        let eof = lines.last == "" ? lines.count - 1 : lines.count
        guard let name = heading else { return max(eof, 0) }
        let heads = headings(in: lines)
        guard let h = heads.first(where: { $0.text.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        var end = heads.first { $0.line > h.line && $0.level <= h.level }?.line ?? eof
        while end > h.line + 1, isBlank(lines[end - 1]) { end -= 1 }
        return end
    }

    static func leadingWhitespace(_ s: String) -> String {
        String(s.prefix { $0 == " " || $0 == "\t" })
    }

    /// Tab counts as 4 columns.
    static func indentWidth(_ s: String) -> Int {
        var w = 0
        for c in s {
            if c == " " { w += 1 } else if c == "\t" { w += 4 } else { break }
        }
        return w
    }

    static func isBlank(_ s: String) -> Bool {
        s.allSatisfy { $0 == " " || $0 == "\t" }
    }

    static func parseTask(_ line: String, at index: Int = 0) -> TaskItem? {
        let ws = leadingWhitespace(line)
        let rest = line.dropFirst(ws.count)
        let head = Array(rest.prefix(5))
        guard head.count == 5, "-*+".contains(head[0]), head[1] == " ", head[2] == "[", head[4] == "]" else { return nil }
        let after = rest.dropFirst(5)
        guard after.isEmpty || after.first == " " else { return nil }
        let text = String(after.drop { $0 == " " })

        var title = text
        let due = Rx.capture(Rx.due, in: text).flatMap(Dates.parseISO)
        let scheduled = Rx.capture(Rx.scheduled, in: text).flatMap(Dates.parseISO)
        let recurrence = Rx.capture(Rx.recurrence, in: text)
        let priority = text.unicodeScalars.lazy.compactMap { s in
            Priority.allCases.first { $0.emoji.unicodeScalars.first == s }
        }.first

        var tags: [String] = []
        Rx.tag.enumerateMatches(in: text, range: Rx.range(text)) { m, _, _ in
            if let m, let r = Range(m.range(at: 1), in: text) { tags.append(String(text[r])) }
        }

        for re in [Rx.due, Rx.scheduled, Rx.otherDates, Rx.recurrence, Rx.priority] {
            title = Rx.strip(re, from: title)
        }
        title = Rx.strip(Rx.tag, from: title, with: " ")
        title = Rx.strip(Rx.space, from: title, with: " ").trimmingCharacters(in: .whitespaces)

        return TaskItem(line: index, indent: indentWidth(ws), mark: head[3], text: text, title: title,
                        due: due, scheduled: scheduled, priority: priority, recurrence: recurrence, tags: tags)
    }

    static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Field editing

    /// Replaces the field matching `pattern` in place (or removes it when `add` is nil).
    /// A field that isn't there yet is appended before any trailing done stamp.
    static func setField(_ line: String, removing pattern: String, adding add: String?) -> String {
        var s = line
        if let r = s.range(of: " ?" + pattern, options: .regularExpression) {
            let lead = s[r].hasPrefix(" ") ? " " : ""
            s.replaceSubrange(r, with: add.map { lead + $0 } ?? "")
            return s
        }
        guard let add else { return s }
        if let r = s.range(of: stampPattern + ".*$", options: .regularExpression) {
            s.insert(contentsOf: " " + add, at: r.lowerBound)
        } else {
            while s.last == " " { s.removeLast() }
            s += " " + add
        }
        return s
    }

    static func setDue(_ line: String, _ date: Date?) -> String {
        setField(line, removing: #"📅\x{FE0F}?\s*\d{4}-\d{2}-\d{2}"#, adding: date.map { "📅 " + Dates.format($0) })
    }

    static func setScheduled(_ line: String, _ date: Date?) -> String {
        setField(line, removing: #"⏳\x{FE0F}?\s*\d{4}-\d{2}-\d{2}"#, adding: date.map { "⏳ " + Dates.format($0) })
    }

    static func setPriority(_ line: String, _ p: Priority?) -> String {
        setField(line, removing: #"[🔺⏫🔼🔽⏬]\x{FE0F}?"#, adding: p?.emoji)
    }

    static func setRecurrence(_ line: String, _ text: String?) -> String {
        let m = Rx.markers
        return setField(line, removing: "🔁\\x{FE0F}?\\s*[^\(m)\\s][^\(m)]*?(?=\\s*(?:[\(m)]|$))",
                        adding: text.map { "🔁 " + $0 })
    }

    /// Changes the checkbox mark. Completing optionally appends a `✅ yyyy-MM-dd` stamp.
    static func setStatus(_ line: String, mark: Character, stamp: Bool, today: Date) -> String {
        let ws = leadingWhitespace(line).count
        var chars = Array(line)
        guard chars.count > ws + 3 else { return line }
        chars[ws + 3] = mark
        var s = String(chars).replacingOccurrences(of: stampPattern, with: "", options: .regularExpression)
        if (mark == "x" || mark == "X") && stamp {
            while s.last == " " { s.removeLast() }
            s += " ✅ " + Dates.format(today)
        }
        return s
    }

    static func outdent(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let spaces = line.prefix(4).prefix { $0 == " " }.count
        return String(line.dropFirst(spaces))
    }

    // MARK: Quick entry

    /// Pulls `@date`, `!priority` and `~recurrence` tokens out of what the user typed.
    static func parseQuick(_ input: String, now: Date) -> QuickInput {
        var q = QuickInput()
        var words: [String] = []
        for tok in input.split(separator: " ").map(String.init) {
            let body = String(tok.dropFirst())
            if tok.hasPrefix("@"), !body.isEmpty, let d = Dates.parse(body, now: now) { q.due = d; continue }
            if tok.hasPrefix("!"), !body.isEmpty, let p = Priority.fromToken(body) { q.priority = p; continue }
            if tok.hasPrefix("~"), !body.isEmpty, let r = Recurrence.canonical(token: body) { q.recurrence = r; continue }
            words.append(tok)
        }
        q.text = words.joined(separator: " ")
        return q
    }

    static func apply(_ q: QuickInput, to line: String) -> String {
        var s = line
        if let d = q.due { s = setDue(s, d) }
        if let p = q.priority { s = setPriority(s, p) }
        if let r = q.recurrence { s = setRecurrence(s, r) }
        return s
    }
}
