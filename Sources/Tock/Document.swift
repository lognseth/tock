import Foundation
import Observation

/// Tasks are identified across files by `doc * stride + line`.
enum TaskID {
    static let stride = 1_000_000
    static func make(doc: Int, line: Int) -> Int { doc * stride + line }
    static func doc(_ id: Int) -> Int { id / stride }
    static func line(_ id: Int) -> Int { id % stride }
}

struct Heading {
    let line: Int
    let level: Int
    let text: String
}

enum Entry {
    case task(TaskItem)
    case heading(Heading)
}

/// One markdown file: its lines and the task/heading index built from them.
@MainActor
@Observable
final class Document {
    let url: URL
    private(set) var index: Int
    private(set) var lines: [String] = []
    private(set) var taskMap: [Int: TaskItem] = [:]   // keyed by line within this file
    private(set) var headings: [Heading] = []
    private(set) var outline: [Entry] = []
    private(set) var error: String?
    @ObservationIgnored private var mtime: Date?

    init(url: URL, index: Int) {
        self.url = url
        self.index = index
    }

    var name: String { url.deletingPathExtension().lastPathComponent }

    func assign(index: Int) {
        guard index != self.index else { return }
        self.index = index
        reindex()
    }

    // MARK: IO

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    var changedOnDisk: Bool { Self.modificationDate(url) != mtime }

    func load() {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            lines = text.components(separatedBy: "\n")
            mtime = Self.modificationDate(url)
            error = nil
        } catch {
            lines = []
            mtime = nil
            self.error = "Can't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
        reindex()
    }

    /// Replaces the content and writes it to disk. Returns an error message on failure.
    func setLines(_ new: [String]) -> String? {
        lines = new
        reindex()
        do {
            try new.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            mtime = Self.modificationDate(url)
            return nil
        } catch {
            return "Can't write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Structure

    /// End (exclusive) of a task plus its more-indented children.
    func blockEnd(_ i: Int) -> Int { Self.blockEnd(i, in: lines) }

    static func blockEnd(_ i: Int, in lines: [String]) -> Int {
        let w = MD.indentWidth(lines[i])
        var j = i + 1
        while j < lines.count, !MD.isBlank(lines[j]), MD.indentWidth(lines[j]) > w { j += 1 }
        return j
    }

    private func reindex() {
        var tasks: [Int: TaskItem] = [:]
        var heads: [Heading] = []
        var entries: [Entry] = []
        var indentStack: [Int] = []

        for i in MD.scannableLines(lines) {
            let line = lines[i]
            if var t = MD.parseTask(line, at: i) {
                while let last = indentStack.last, last >= t.indent { indentStack.removeLast() }
                t.doc = index
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
}
