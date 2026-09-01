import Foundation
import CoreGraphics

/// An `.imarpbundle` is a package directory (opens as a single item from
/// Files/iCloud), laid out as:
///
///   MyDeck.imarpbundle/
///     source/
///       deck.md          the actual Markdown — this is what an external
///                        editor (iA Writer, Obsidian, etc.) touches
///       theme.css        optional; registered with marp-core by name,
///                        same convention as marp-cli's --theme-set
///       assets/          images/fonts deck.md references locally
///     rendered/          cache — regenerated on-device whenever source/
///       deck.html        is newer, via MarpRenderer. Never hand-edited.
///       assets/
///
/// imarp is still read-only/presentation-only — it has no editing UI of its
/// own — but it does the actual Markdown → HTML rendering on-device (see
/// MarpRenderer), so a deck can be edited from any Markdown-capable app
/// without ever touching a Mac. A bundle with only `rendered/` (no
/// `source/`) is also accepted, for decks that genuinely are just static
/// HTML with no editable source.
enum MarpBundleLoader {
    struct Contents {
        let deckHTMLURL: URL
        let deckDirectory: URL
        let slideCount: Int
        let slideAspectRatio: CGFloat
    }

    enum LoadError: Error {
        case missingContent
        case renderFailed(Error)
    }

    static func load(from bundleURL: URL, completion: @escaping (Result<Contents, Error>) -> Void) {
        let fm = FileManager.default
        let sourceDeckURL = bundleURL.appendingPathComponent("source/deck.md")
        let renderedDeckURL = bundleURL.appendingPathComponent("rendered/deck.html")
        let renderedDir = bundleURL.appendingPathComponent("rendered", isDirectory: true)

        let hasSource = fm.fileExists(atPath: sourceDeckURL.path)
        let hasRendered = fm.fileExists(atPath: renderedDeckURL.path)

        if hasSource, !hasRendered || sourceIsNewer(sourceDeckURL, than: renderedDeckURL) {
            renderFromSource(bundleURL: bundleURL, sourceDeckURL: sourceDeckURL, completion: completion)
            return
        }

        guard hasRendered, let html = try? String(contentsOf: renderedDeckURL, encoding: .utf8) else {
            completion(.failure(LoadError.missingContent))
            return
        }
        completion(.success(Contents(
            deckHTMLURL: renderedDeckURL,
            deckDirectory: renderedDir,
            slideCount: slideCount(in: html),
            slideAspectRatio: slideAspectRatio(in: html)
        )))
    }

    private static func renderFromSource(bundleURL: URL, sourceDeckURL: URL, completion: @escaping (Result<Contents, Error>) -> Void) {
        guard let markdown = try? String(contentsOf: sourceDeckURL, encoding: .utf8) else {
            completion(.failure(LoadError.missingContent))
            return
        }
        let themeCSS = try? String(contentsOf: bundleURL.appendingPathComponent("source/theme.css"), encoding: .utf8)

        MarpRenderer.shared.render(markdown: markdown, themeCSS: themeCSS) { result in
            switch result {
            case .failure(let error):
                completion(.failure(LoadError.renderFailed(error)))

            case .success(let rendered):
                do {
                    let assembled = try assemble(html: rendered.html, css: rendered.css)
                    let renderedDir = bundleURL.appendingPathComponent("rendered", isDirectory: true)
                    let renderedDeckURL = renderedDir.appendingPathComponent("deck.html")

                    try FileManager.default.createDirectory(at: renderedDir, withIntermediateDirectories: true)
                    try assembled.write(to: renderedDeckURL, atomically: true, encoding: .utf8)

                    // Mirror source assets alongside the cache so the cached
                    // HTML's relative image/font paths resolve exactly like
                    // a marp-cli-rendered bundle's would.
                    let sourceAssets = bundleURL.appendingPathComponent("source/assets", isDirectory: true)
                    if FileManager.default.fileExists(atPath: sourceAssets.path) {
                        let renderedAssets = renderedDir.appendingPathComponent("assets", isDirectory: true)
                        try? FileManager.default.removeItem(at: renderedAssets)
                        try FileManager.default.copyItem(at: sourceAssets, to: renderedAssets)
                    }

                    completion(.success(Contents(
                        deckHTMLURL: renderedDeckURL,
                        deckDirectory: renderedDir,
                        slideCount: slideCount(in: assembled),
                        slideAspectRatio: slideAspectRatio(in: assembled)
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
