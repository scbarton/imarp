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
enum MarpBundleLoader {
    struct Contents {
        let deckHTMLURL: URL
        let deckDirectory: URL
        let slideCount: Int
        let slideAspectRatio: CGFloat
        /// The `.marpbundle` root — where PresentationStore persists ink
        /// (`ink/<slideIndex>.drawing`).
        let bundleURL: URL
    }

    enum LoadError: Error {
        case missingContent
        case renderFailed(Error)
    }

    static func load(from bundleURL: URL, completion: @escaping (Result<Contents, Error>) -> Void) {
        let fm = FileManager.default
        let sourceMDURL = bundleURL.appendingPathComponent("source.md")
        let sourceHTMLURL = bundleURL.appendingPathComponent("source.html")

        let hasMarkdown = fm.fileExists(atPath: sourceMDURL.path)
        let hasHTML = fm.fileExists(atPath: sourceHTMLURL.path)

        if hasMarkdown, !hasHTML || sourceIsNewer(sourceMDURL, than: sourceHTMLURL) {
            renderFromSource(bundleURL: bundleURL, sourceMDURL: sourceMDURL, completion: completion)
            return
        }

        guard hasHTML, let html = try? String(contentsOf: sourceHTMLURL, encoding: .utf8) else {
            completion(.failure(LoadError.missingContent))
            return
        }
        completion(.success(Contents(
            deckHTMLURL: sourceHTMLURL,
            deckDirectory: bundleURL,
            slideCount: slideCount(in: html),
            slideAspectRatio: slideAspectRatio(in: html),
            bundleURL: bundleURL
        )))
    }

    private static func renderFromSource(bundleURL: URL, sourceMDURL: URL, completion: @escaping (Result<Contents, Error>) -> Void) {
        guard let markdown = try? String(contentsOf: sourceMDURL, encoding: .utf8) else {
            completion(.failure(LoadError.missingContent))
            return
        }
        let themeCSS = try? String(contentsOf: bundleURL.appendingPathComponent("theme.css"), encoding: .utf8)

        MarpRenderer.shared.render(markdown: markdown, themeCSS: themeCSS) { result in
            switch result {
            case .failure(let error):
                completion(.failure(LoadError.renderFailed(error)))

            case .success(let rendered):
                do {
                    let assembled = try assemble(html: rendered.html, css: rendered.css)
                    let sourceHTMLURL = bundleURL.appendingPathComponent("source.html")
                    try assembled.write(to: sourceHTMLURL, atomically: true, encoding: .utf8)

                    completion(.success(Contents(
                        deckHTMLURL: sourceHTMLURL,
                        deckDirectory: bundleURL,
                        slideCount: slideCount(in: assembled),
                        slideAspectRatio: slideAspectRatio(in: assembled),
                        bundleURL: bundleURL
                    )))
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
    /// Falls back to Marp's own 16:9 default.
    static func slideAspectRatio(in html: String) -> CGFloat {
        let fallback: CGFloat = 16.0 / 9.0
        guard let range = html.range(of: "viewBox=\"0 0 ") else { return fallback }
        let numbers = html[range.upperBound...].prefix(while: { $0.isNumber || $0 == " " || $0 == "." })
        let parts = numbers.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 2, parts[0] > 0, parts[1] > 0 else { return fallback }
        return CGFloat(parts[0] / parts[1])
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
