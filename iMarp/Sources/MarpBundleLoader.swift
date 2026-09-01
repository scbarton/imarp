import Foundation

/// An `.imarpbundle` is a package directory (registered as a UTType, opens
/// as a single item in Files/iCloud) laid out as:
///
///   MyDeck.imarpbundle/
///     info.json         { "slideCount": N }
///     rendered/
///       deck.html        Marp CLI's rendered output
///       assets/           images/fonts the deck references locally
///
/// Rendering happens offline (e.g. via `marp-cli` on a Mac) — iMarp only
/// ever reads the pre-rendered HTML, matching the app's read-only-render-
/// plus-annotate scope. A `source/` folder with the original deck.md could
/// be added later for portability without iMarp needing to do anything
/// with it.
enum MarpBundleLoader {
    struct Contents {
        let deckHTMLURL: URL
        let deckDirectory: URL
        let slideCount: Int
    }

    enum LoadError: Error {
        case missingRenderedDeck
        case missingOrInvalidInfo
    }

    private struct Info: Decodable {
        let slideCount: Int
    }

    static func load(from bundleURL: URL) throws -> Contents {
        let deckDirectory = bundleURL.appendingPathComponent("rendered", isDirectory: true)
        let deckHTMLURL = deckDirectory.appendingPathComponent("deck.html")
        guard FileManager.default.fileExists(atPath: deckHTMLURL.path) else {
            throw LoadError.missingRenderedDeck
        }

        let infoURL = bundleURL.appendingPathComponent("info.json")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? JSONDecoder().decode(Info.self, from: data)
        else {
            throw LoadError.missingOrInvalidInfo
        }

        return Contents(deckHTMLURL: deckHTMLURL, deckDirectory: deckDirectory, slideCount: info.slideCount)
    }
}
