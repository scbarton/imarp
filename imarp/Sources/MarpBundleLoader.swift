import Foundation
import CoreGraphics

/// An `.marpbundle` is a package directory (opens as a single item from
/// Files/iCloud), laid out flat so `source.html` and `assets/` are plain
/// siblings — no `<base href>` or asset-copying trick needed for images to
/// resolve, since everything a slide can reference lives in the same
/// directory as the HTML that references it:
///
///   MyDeck.marpbundle/
///     source.md          the actual Markdown — this is what an external
///                        editor (iA Writer, Obsidian, etc.) touches
///     source.html        cache — regenerated on-device whenever source.md
///                        is newer, via MarpRenderer. Never hand-edited.
///     theme.css          optional; registered with marp-core by name, same
///                        convention as marp-cli's --theme-set. Also found
///                        named after the deck's theme (chems.css for
///                        `theme: chems`), and in assets/ (see themeCandidates)
///     assets/            images/fonts source.md (and so source.html) refer
///                        to locally
///     ink/               Apple Pencil annotations, one file per slide index
///       0.drawing        (PKDrawing.dataRepresentation()) — see
///       ...              PresentationStore. Kept separate from the two
///                        files above so re-exporting the deck (which only
///                        touches source.md/source.html) never wipes
///                        annotations.
///
/// imarp is still read-only/presentation-only — it has no editing UI of its
/// own — but it does the actual Markdown → HTML rendering on-device (see
/// MarpRenderer), so a deck can be edited from any Markdown-capable app
/// without ever touching a Mac. A bundle with only `source.html` (no
/// `source.md`) is also accepted, for decks that genuinely are just static
/// HTML with no editable source.
///
/// A deck can also be a plain Markdown file (`.md`, `.markdown` or `.marp`),
/// with everything a bundle holds sitting beside it in the same folder:
///
///   Lecture 8.md         the Markdown
///   Lecture 8.html       rendered slides (same rule as source.html)
///   Lecture 8.ink/       Apple Pencil annotations
///   theme.css            optional, as in a bundle (or chems.css, or in assets/)
///   assets/              as in a bundle
///
/// Reaching the files beside it needs access to the whole folder, which the
/// presenter grants once per folder (see MainViewController).
enum MarpBundleLoader {
    /// File extensions opened as a Markdown deck.
    static let markdownExtensions: Set<String> = ["md", "markdown", "marp"]

    struct Contents {
        let deckHTMLURL: URL
        let deckDirectory: URL
        let slideCount: Int
        let slideAspectRatio: CGFloat
        /// Where PresentationStore saves this deck's ink.
        let inkDirectory: URL
        /// For the log: the bundle's or Markdown file's name.
        let name: String
        /// The files the slides are rendered from (the Markdown and every
        /// place its theme may be), watched for live reload; empty for a
        /// deck that's HTML only.
        let sourceFiles: [URL]
    }

    /// The files that make up a deck, wherever it lives.
    private struct Layout {
        let markdownURL: URL
        let htmlURL: URL
        let deckDirectory: URL
        let inkDirectory: URL
        let name: String
    }

    enum LoadError: Error {
        case missingContent
        case renderFailed(Error)
    }

    /// Loads a deck: a `.marpbundle`, or a Markdown file (see
    /// `markdownExtensions`) with its files beside it.
    static func load(from url: URL, completion: @escaping (Result<Contents, Error>) -> Void) {
        let isMarkdown = markdownExtensions.contains(url.pathExtension.lowercased())
        let layout: Layout
        if isMarkdown {
            let folder = url.deletingLastPathComponent()
            let name = url.deletingPathExtension().lastPathComponent
            layout = Layout(
                markdownURL: url,
                htmlURL: folder.appendingPathComponent("\(name).html"),
                deckDirectory: folder,
                inkDirectory: folder.appendingPathComponent("\(name).ink", isDirectory: true),
                name: url.lastPathComponent
            )
        } else {
            layout = Layout(
                markdownURL: url.appendingPathComponent("source.md"),
                htmlURL: url.appendingPathComponent("source.html"),
                deckDirectory: url,
                inkDirectory: url.appendingPathComponent("ink", isDirectory: true),
                name: url.lastPathComponent
            )
        }
        guard isMarkdown else {
            load(layout, completion: completion)
            return
        }
        // A bundle is downloaded from iCloud as one item when it's picked; a
        // Markdown deck's neighbors are separate files, and on the iPad iCloud
        // leaves them in the cloud until something asks for each one. WebKit
        // can't, so an image not yet downloaded just doesn't appear. So the
        // theme is fetched before rendering, and every file the slides refer
        // to (and the files those widget pages load) before showing them.
        DispatchQueue.global(qos: .userInitiated).async {
            ensureDownloaded([layout.markdownURL])
            ensureDownloaded(themeCandidates(layout))
            DispatchQueue.main.async {
                load(layout) { result in
                    guard case .success(let contents) = result else {
                        completion(result)
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        downloadReferencedFiles(of: contents.deckHTMLURL, in: layout.deckDirectory)
                        DispatchQueue.main.async { completion(result) }
                    }
                }
            }
        }
    }

    /// Makes sure these iCloud files are on this device, waiting for any
    /// download. A coordinated read is the documented way to have iCloud
    /// fetch an item; it returns once the file is local. Files that don't
    /// exist (locally or in iCloud) are skipped. Call off the main thread.
    @discardableResult
    private static func ensureDownloaded(_ urls: [URL]) -> (fetched: Int, missing: [String]) {
        var fetched = 0
        var missing: [String] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            let isUbiquitous = values?.isUbiquitousItem ?? false
            if FileManager.default.fileExists(atPath: url.path), !isUbiquitous || values?.ubiquitousItemDownloadingStatus == .current {
                continue
            }
            guard isUbiquitous else {
                // Not here and not in iCloud: a reference to nothing.
                missing.append(url.lastPathComponent)
                continue
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { _ in }
            if FileManager.default.fileExists(atPath: url.path) { fetched += 1 } else { missing.append(url.lastPathComponent) }
        }
        return (fetched, missing)
    }

    /// Downloads every local file `htmlURL` refers to (src, href, CSS url()),
    /// and the files referred to by any HTML pages among them (widget
    /// iframes), staying inside `directory`.
    private static func downloadReferencedFiles(of htmlURL: URL, in directory: URL) {
        var seen = Set<String>()
        var pages = [htmlURL]
        var fetched = 0
        var missing: [String] = []
        while let page = pages.popLast() {
            guard let html = try? String(contentsOf: page, encoding: .utf8) else { continue }
            let references = localReferences(in: html, relativeTo: page.deletingLastPathComponent())
                .filter { $0.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) }
                .filter { seen.insert($0.standardizedFileURL.path).inserted }
            let result = ensureDownloaded(references)
            fetched += result.fetched
            missing += result.missing
            pages += references.filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
        }
        DebugLog.write("store", "deck files: \(seen.count) referenced, \(fetched) downloaded from iCloud\(missing.isEmpty ? "" : ", missing: " + missing.joined(separator: ", "))")
    }

    /// Relative file references in an HTML page: src= and href= attributes
    /// and CSS url(), leaving out web addresses, data: URLs and in-page links.
    private static func localReferences(in html: String, relativeTo base: URL) -> [URL] {
        let text = html.replacingOccurrences(of: "&quot;", with: "\"")
        let patterns = [#"(?:src|href)\s*=\s*"([^"]+)""#, #"(?:src|href)\s*=\s*'([^']+)'"#, #"url\(\s*["']?([^"')]+)["']?\s*\)"#]
        var urls: [URL] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var reference = String(text[range]).trimmingCharacters(in: .whitespaces)
                let lower = reference.lowercased()
                if reference.isEmpty || reference.hasPrefix("#") || reference.hasPrefix("//") || lower.hasPrefix("data:")
                    || lower.range(of: "^[a-z][a-z0-9+.-]*:", options: .regularExpression) != nil {
                    continue
                }
                if let cut = reference.firstIndex(where: { $0 == "?" || $0 == "#" }) { reference = String(reference[..<cut]) }
                guard let decoded = reference.removingPercentEncoding else { continue }
                urls.append(URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL)
            }
        }
        return urls
    }

    private static func load(_ layout: Layout, completion: @escaping (Result<Contents, Error>) -> Void) {
        let fm = FileManager.default
        let hasMarkdown = fm.fileExists(atPath: layout.markdownURL.path)
        let hasHTML = fm.fileExists(atPath: layout.htmlURL.path)

        let cachedHTML = hasHTML ? try? String(contentsOf: layout.htmlURL, encoding: .utf8) : nil
        if hasMarkdown, cachedHTML == nil
            || sourceIsNewer(layout.markdownURL, than: layout.htmlURL)
            || !builtWithCurrentShell(cachedHTML ?? "")
            || themeStamp(in: cachedHTML ?? "") != themeStamp(for: theme(layout), in: layout) {
            renderFromSource(layout, completion: completion)
            return
        }

        guard let html = cachedHTML else {
            completion(.failure(LoadError.missingContent))
            return
        }
        completion(.success(contents(layout, html: html)))
    }

    private static func contents(_ layout: Layout, html: String) -> Contents {
        Contents(
            deckHTMLURL: layout.htmlURL,
            deckDirectory: layout.deckDirectory,
            slideCount: slideCount(in: html),
            slideAspectRatio: slideAspectRatio(in: html),
            inkDirectory: layout.inkDirectory,
            name: layout.name,
            sourceFiles: FileManager.default.fileExists(atPath: layout.markdownURL.path) ? [layout.markdownURL] + themeCandidates(layout) : []
        )
    }

    private static func renderFromSource(_ layout: Layout, completion: @escaping (Result<Contents, Error>) -> Void) {
        guard let markdown = try? String(contentsOf: layout.markdownURL, encoding: .utf8) else {
            completion(.failure(LoadError.missingContent))
            return
        }
        let themeURL = theme(layout)
        let themeCSS = themeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        DebugLog.write("store", "rendering \(layout.name) with theme \(themeURL.map { relativePath(of: $0, in: layout) } ?? "none (Marp's built-in themes only)")")

        MarpRenderer.shared.render(markdown: markdown, themeCSS: themeCSS) { result in
            switch result {
            case .failure(let error):
                completion(.failure(LoadError.renderFailed(error)))

            case .success(let rendered):
                do {
                    var assembled = try assemble(html: rendered.html, css: rendered.css)
                    // Which theme file (and which version of it) this was
                    // rendered with, so a new or changed theme re-renders.
                    assembled += "\n<!-- \(themeStamp(for: themeURL, in: layout)) -->\n"
                    try assembled.write(to: layout.htmlURL, atomically: true, encoding: .utf8)
                    completion(.success(contents(layout, html: assembled)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Splices fresh render output into the vendored presentation shell
    /// (marp-cli's bespoke.js/CSS chrome, extracted once — see
    /// marp-engine-build/README.md for how it was built).
    static func assemble(html: String, css: String) throws -> String {
        guard let shellURL = Bundle.main.url(forResource: "shell", withExtension: "html", subdirectory: "MarpEngine"),
              var shell = try? String(contentsOf: shellURL, encoding: .utf8)
        else {
            throw LoadError.missingContent
        }
        shell = shell.replacingOccurrences(of: "<!--IMARP_STYLE-->", with: css)
        shell = shell.replacingOccurrences(of: "<!--IMARP_SLIDES-->", with: html)
        return shell
    }

    /// The `marp-cli@x.y.z` stamp in a page's bespoke.js license comment,
    /// identifying which presentation shell it was assembled from.
    private static func shellVersion(in html: String) -> Substring? {
        guard let range = html.range(of: "marp-cli@") else { return nil }
        return html[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
    }

    private static let currentShellVersion: Substring? = {
        guard let url = Bundle.main.url(forResource: "shell", withExtension: "html", subdirectory: "MarpEngine"),
              let shell = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return shellVersion(in: shell)
    }()

    /// Whether a cached `source.html` came from the shell this build ships.
    /// When the shell is upgraded (e.g. marp-cli 4.5.1 added the slide
    /// overview), decks rendered with the old one are re-rendered so they
    /// pick up the new presentation features without the source changing.
    private static func builtWithCurrentShell(_ html: String) -> Bool {
        guard let current = currentShellVersion else { return true }
        return shellVersion(in: html) == current
    }

    /// Marp stamps every slide's `<section>` with the same
    /// `data-marpit-pagination-total="N"` attribute, so this is reliable
    /// regardless of how the deck was produced.
    static func slideCount(in html: String) -> Int {
        guard let range = html.range(of: "data-marpit-pagination-total=\"") else { return 1 }
        let digits = html[range.upperBound...].prefix(while: \.isNumber)
        return Int(digits) ?? 1
    }

    /// Width÷height of the deck's slides, read from the `viewBox` Marp emits
    /// on each slide's `<svg>` (e.g. `viewBox="0 0 1280 720"`). Needed because
    /// each screen letterboxes the slide to fit its own bounds, so ink drawn
    /// on the iPad has to be mapped slide-to-slide — not canvas-to-canvas — to
    /// land in the right place on a differently-shaped external display.
    /// Only the slide `<svg data-marpit-svg …>` tag itself is read: the first
    /// `viewBox` in the file can belong to something else entirely (an
    /// inline SVG image or icon), and taking its shape for the slide's sends
    /// ink to the wrong place on the external display. Falls back to Marp's
    /// own 16:9 default.
    static func slideAspectRatio(in html: String) -> CGFloat {
        let fallback: CGFloat = 16.0 / 9.0
        guard let slideTag = html.range(of: "data-marpit-svg") else { return fallback }
        let tagEnd = html[slideTag.upperBound...].firstIndex(of: ">") ?? html.endIndex
        guard let range = html.range(of: "viewBox=\"", range: slideTag.upperBound..<tagEnd)
                ?? html[..<slideTag.lowerBound].range(of: "viewBox=\"", options: .backwards).flatMap({ found in
                    // Attribute written before data-marpit-svg in the same tag.
                    html[found.upperBound..<slideTag.lowerBound].contains("<") ? nil : found
                })
        else { return fallback }
        let numbers = html[range.upperBound...].prefix(while: { $0.isNumber || $0 == " " || $0 == "." || $0 == "-" })
        // viewBox is "minX minY width height".
        let parts = numbers.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return fallback }
        return CGFloat(parts[2] / parts[3])
    }

    /// The deck's theme name: `theme:` in the front matter, or Marp's
    /// `<!-- theme: name -->` directive.
    private static func themeName(in markdown: String) -> String? {
        var lines = markdown.components(separatedBy: .newlines)[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" { break }
                if let name = value(of: "theme", in: trimmed) { return name }
            }
        }
        guard let start = markdown.range(of: #"<!--\s*theme\s*:"#, options: .regularExpression),
              let end = markdown[start.upperBound...].range(of: "-->")
        else { return nil }
        return value(of: "theme", in: "theme:" + markdown[start.upperBound..<end.lowerBound])
    }

    /// `name` from a `key: name` line, without quotes.
    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key), let colon = line.firstIndex(of: ":"),
              line[..<colon].trimmingCharacters(in: .whitespaces) == key
        else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        return value.isEmpty ? nil : value
    }

    /// Where the deck's theme may be, in the order they're tried: named
    /// after the theme (chems.css for `theme: chems`) or theme.css, beside
    /// the deck and then in its assets folder. The first that exists is
    /// used; its `@theme` name still has to match the deck's.
    private static func themeCandidates(_ layout: Layout) -> [URL] {
        let markdown = (try? String(contentsOf: layout.markdownURL, encoding: .utf8)) ?? ""
        var names = ["theme.css"]
        if let name = themeName(in: markdown), !name.contains("/"), name != "theme" {
            names.insert("\(name).css", at: 0)
        }
        let assets = layout.deckDirectory.appendingPathComponent("assets", isDirectory: true)
        return [layout.deckDirectory, assets].flatMap { directory in
            names.map { directory.appendingPathComponent($0) }
        }
    }

    /// The theme file the deck renders with, if any.
    private static func theme(_ layout: Layout) -> URL? {
        themeCandidates(layout).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func relativePath(of url: URL, in layout: Layout) -> String {
        let base = layout.deckDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// `imarp-theme: <file> <modified>`, or `imarp-theme: none`.
    private static func themeStamp(for theme: URL?, in layout: Layout) -> String {
        guard let theme else { return "imarp-theme: none" }
        let date = (try? FileManager.default.attributesOfItem(atPath: theme.path))?[.modificationDate] as? Date
        return "imarp-theme: \(relativePath(of: theme, in: layout)) \(Int(date?.timeIntervalSince1970 ?? 0))"
    }

    /// The theme stamp a rendered page was saved with (none before this
    /// was added, so those re-render once).
    private static func themeStamp(in html: String) -> String? {
        guard let start = html.range(of: "<!-- imarp-theme: ", options: .backwards),
              let end = html[start.upperBound...].range(of: " -->")
        else { return nil }
        return "imarp-theme: " + html[start.upperBound..<end.lowerBound]
    }

    private static func sourceIsNewer(_ source: URL, than rendered: URL) -> Bool {
        let fm = FileManager.default
        guard let sourceDate = try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
              let renderedDate = try? fm.attributesOfItem(atPath: rendered.path)[.modificationDate] as? Date
        else {
            return true
        }
        return sourceDate > renderedDate
    }
}

/// Live reload: while a deck is open, checks its source files (the Markdown
/// and its theme) every couple of seconds and calls `onChange` when one has
/// changed, whether it was saved on this device or the change came in
/// through iCloud. A newer version iCloud knows about but hasn't downloaded
/// yet is asked for first, and reported once it's here. Polling rather than
/// file presenters: it's simple, and it sees iCloud updates the same way as
/// local saves.
final class DeckWatcher {
    private let files: [URL]
    private var lastSeen: [URL: Date] = [:]
    private var timer: Timer?
    private let onChange: () -> Void

    init(files: [URL], onChange: @escaping () -> Void) {
        self.files = files
        self.onChange = onChange
        for file in files { lastSeen[file] = Self.modificationDate(of: file) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        var changed = false
        for var file in files {
            file.removeAllCachedResourceValues()
            let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus, status != .current {
                // iCloud has a newer version (or none here yet): fetch it,
                // and pick it up on a later check once it's down.
                try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                continue
            }
            let date = Self.modificationDate(of: file)
            if date != lastSeen[file] {
                lastSeen[file] = date
                changed = true
                DebugLog.write("store", "live reload: \(file.lastPathComponent) changed")
            }
        }
        if changed { onChange() }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
