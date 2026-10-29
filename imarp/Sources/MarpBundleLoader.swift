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
///                        convention as marp-cli's --theme-set
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
///   theme.css            optional, as in a bundle
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
    }

    /// The files that make up a deck, wherever it lives.
    private struct Layout {
        let markdownURL: URL
        let htmlURL: URL
        let themeURL: URL
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
        let layout: Layout
        if markdownExtensions.contains(url.pathExtension.lowercased()) {
            let folder = url.deletingLastPathComponent()
            let name = url.deletingPathExtension().lastPathComponent
            layout = Layout(
                markdownURL: url,
                htmlURL: folder.appendingPathComponent("\(name).html"),
                themeURL: folder.appendingPathComponent("theme.css"),
                deckDirectory: folder,
                inkDirectory: folder.appendingPathComponent("\(name).ink", isDirectory: true),
                name: url.lastPathComponent
            )
        } else {
            layout = Layout(
                markdownURL: url.appendingPathComponent("source.md"),
                htmlURL: url.appendingPathComponent("source.html"),
                themeURL: url.appendingPathComponent("theme.css"),
                deckDirectory: url,
                inkDirectory: url.appendingPathComponent("ink", isDirectory: true),
                name: url.lastPathComponent
            )
        }
        load(layout, completion: completion)
    }

    private static func load(_ layout: Layout, completion: @escaping (Result<Contents, Error>) -> Void) {
        let fm = FileManager.default
        let hasMarkdown = fm.fileExists(atPath: layout.markdownURL.path)
        let hasHTML = fm.fileExists(atPath: layout.htmlURL.path)

        let cachedHTML = hasHTML ? try? String(contentsOf: layout.htmlURL, encoding: .utf8) : nil
        if hasMarkdown, cachedHTML == nil
            || sourceIsNewer(layout.markdownURL, than: layout.htmlURL)
            || !builtWithCurrentShell(cachedHTML ?? "") {
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
            name: layout.name
        )
    }

    private static func renderFromSource(_ layout: Layout, completion: @escaping (Result<Contents, Error>) -> Void) {
        guard let markdown = try? String(contentsOf: layout.markdownURL, encoding: .utf8) else {
            completion(.failure(LoadError.missingContent))
            return
        }
        let themeCSS = try? String(contentsOf: layout.themeURL, encoding: .utf8)

        MarpRenderer.shared.render(markdown: markdown, themeCSS: themeCSS) { result in
            switch result {
            case .failure(let error):
                completion(.failure(LoadError.renderFailed(error)))

            case .success(let rendered):
                do {
                    let assembled = try assemble(html: rendered.html, css: rendered.css)
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
