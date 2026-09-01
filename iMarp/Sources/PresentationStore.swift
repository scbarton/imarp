import Foundation
import PencilKit

extension Notification.Name {
    /// Posted (userInfo["forward"]: Bool) when Prev/Next is pressed. Both
    /// the main and external-display scenes observe this and independently
    /// step their own WKWebView via simulated arrow-key events, rather than
    /// being told a target slide index — Marp's bespoke fragment stepping
    /// (incremental bullet builds) only works correctly through its own
    /// keyboard-navigation logic, since jumping via `location.hash` always
    /// resets a slide's fragments back to hidden. Because both webviews
    /// load the identical deck and receive the identical sequence of steps,
    /// they stay in lockstep without needing to coordinate slide/fragment
    /// state explicitly.
    static let stepRequested = Notification.Name("stepRequested")
    static let drawingDidChange = Notification.Name("drawingDidChange")
    /// Posted when a new deck has been loaded (see `PresentationStore.loadDeck`).
    /// Both scenes reload their own webview from the new deck's URL and
    /// reset to slide 0.
    static let deckDidChange = Notification.Name("deckDidChange")
    /// Posted (userInfo["hidden"]: Bool) when the presenter toggles ink
    /// visibility. Both scenes observe this — the external display always
    /// shows exactly what the presenter sees, so hiding ink to check the
    /// bare slide underneath hides it everywhere, not just on the iPad.
    static let annotationsHiddenDidChange = Notification.Name("annotationsHiddenDidChange")
}

/// Single source of truth shared by the main (toolbar) scene and the
/// external-display (canvas-only) scene. Both scenes run in the same
/// process, so a singleton + NotificationCenter is enough to keep them
/// in sync without any IPC.
///
/// Slide identity is index-based for now: a loaded deck is static and
/// read-only (no in-app reordering/editing), so "slide 3" always means the
/// same slide for as long as that deck is loaded. If live editing/
/// reordering is added later, this should move to a stable per-slide ID
/// instead of index, so ink doesn't get scrambled when slides move.
final class PresentationStore {
    static let shared = PresentationStore()

    private(set) var deckHTMLURL: URL
    private(set) var deckDirectory: URL
    private(set) var slideCount: Int

    /// Updated by the main scene once its step completes. Used only to
    /// attribute freshly-drawn ink to the right slide — the external
    /// display tracks its own current index locally, since it steps its
    /// webview independently in response to `.stepRequested`.
    private(set) var currentIndex = 0

    private var drawings: [Int: PKDrawing] = [:]

    /// So a scene created/reconnected after the toggle (e.g. the external
    /// display connecting mid-presentation) starts in the right state.
    private(set) var annotationsHidden = false

    private init() {
        // Bundled sample deck, shown until the user opens an .imarpbundle.
        guard let url = Bundle.main.url(forResource: "deck", withExtension: "html", subdirectory: "Deck") else {
            fatalError("Bundled sample deck (Deck/deck.html) is missing from the app bundle")
        }
        deckHTMLURL = url
        deckDirectory = url.deletingLastPathComponent()
        slideCount = 6
    }

    func loadDeck(htmlURL: URL, directory: URL, slideCount: Int) {
        deckHTMLURL = htmlURL
        deckDirectory = directory
        self.slideCount = slideCount
        currentIndex = 0
        drawings = [:]
        NotificationCenter.default.post(name: .deckDidChange, object: nil)
    }

    func drawing(for slideIndex: Int) -> PKDrawing {
        drawings[slideIndex] ?? PKDrawing()
    }

    func setDrawing(_ drawing: PKDrawing, for slideIndex: Int) {
        drawings[slideIndex] = drawing
        NotificationCenter.default.post(
            name: .drawingDidChange,
            object: nil,
            userInfo: ["slideIndex": slideIndex]
        )
    }

    func setCurrentIndex(_ index: Int) {
        currentIndex = index
    }

    func setAnnotationsHidden(_ hidden: Bool) {
        annotationsHidden = hidden
        NotificationCenter.default.post(name: .annotationsHiddenDidChange, object: nil, userInfo: ["hidden": hidden])
    }
}
