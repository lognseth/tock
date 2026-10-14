import AppKit

/// Optional Obsidian integration. Everything here is only used when the user turns it on in Settings.
enum Obsidian {
    /// Walks up from the file looking for a `.obsidian` folder.
    static func vaultRoot(of file: URL) -> URL? {
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.pathComponents.count > 1 {
            var isDir: ObjCBool = false
            let marker = dir.appendingPathComponent(".obsidian").path
            if FileManager.default.fileExists(atPath: marker, isDirectory: &isDir), isDir.boolValue { return dir }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static var isInstalled: Bool {
        guard let url = URL(string: "obsidian://open") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    private static func url(_ items: [URLQueryItem]) -> URL? {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = items
        return c.url
    }

    /// Link to the note itself.
    static func noteURL(for file: URL) -> URL? {
        if let root = vaultRoot(of: file) {
            let prefix = root.standardizedFileURL.path + "/"
            let path = file.standardizedFileURL.path
            if path.hasPrefix(prefix) {
                var rel = String(path.dropFirst(prefix.count))
                if rel.hasSuffix(".md") { rel.removeLast(3) }
                return url([URLQueryItem(name: "vault", value: root.lastPathComponent),
                            URLQueryItem(name: "file", value: rel)])
            }
        }
        return url([URLQueryItem(name: "path", value: file.path)])
    }

    /// Link to a `[[wikilink]]` target, resolved by Obsidian within the file's vault.
    static func linkURL(target: String, from file: URL) -> URL? {
        var items = [URLQueryItem(name: "file", value: target)]
        if let root = vaultRoot(of: file) { items.insert(URLQueryItem(name: "vault", value: root.lastPathComponent), at: 0) }
        return url(items)
    }

    private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#)

    /// (target, display) for each `[[target|display]]` in the text.
    static func wikilinks(in text: String) -> [(target: String, display: String)] {
        wikilink.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let t = Range(m.range(at: 1), in: text) else { return nil }
            let target = String(text[t])
            let display = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? target
            return (target, display)
        }
    }

    /// Rewrites wikilinks as markdown links so they render clickable.
    static func linkify(_ text: String, from file: URL?) -> String {
        guard let file else { return text }
        var out = text
        for m in wikilink.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: out), let t = Range(m.range(at: 1), in: out) else { continue }
            let target = String(out[t])
            let display = Range(m.range(at: 2), in: out).map { String(out[$0]) } ?? target
            guard let link = linkURL(target: target, from: file) else { continue }
            out.replaceSubrange(whole, with: "[\(display)](\(link.absoluteString))")
        }
        return out
    }
}
