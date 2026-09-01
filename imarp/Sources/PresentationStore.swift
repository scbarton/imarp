import Foundation
import PencilKit
import UIKit

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

    /// Slide width÷height for the loaded deck, and the size of the canvas the
    /// presenter actually draws on. Together these let the external display
    /// map ink from the iPad's slide rect onto its own — see
    /// `SlideCanvasView.setDrawing(_:authoredOnCanvasOfSize:aspectRatio:)`.
    private(set) var slideAspectRatio: CGFloat = 16.0 / 9.0
    private(set) var authoringCanvasSize: CGSize = .zero

    /// Updated by the main scene once its step completes. Used only to
    /// attribute freshly-drawn ink to the right slide — the external
    /// display tracks its own current index locally, since it steps its
    /// webview independently in response to `.stepRequested`.
    private(set) var currentIndex = 0

    private var drawings: [Int: PKDrawing] = [:]

    /// The currently open `.marpbundle`'s root, used to persist ink under
    /// `ink/<slideIndex>.drawing` — kept separate from `source.md`/
    /// `source.html` so that re-exporting from BBEdit (which only touches
    /// those two files) never wipes annotations. `nil` for the bundled
    /// sample deck, which lives inside the read-only app bundle and so keeps
    /// ink in-memory only, same as before persistence existed.
    private(set) var bundleURL: URL?

    /// Debounced per-slide save timers, so a fast run of PencilKit's
    /// continuous drawing-changed updates during a single stroke doesn't
    /// write to disk many times a second — only once, shortly after the
    /// stroke settles.
    private var pendingInkSaves: [Int: DispatchWorkItem] = [:]

    /// So a scene created/reconnected after the toggle (e.g. the external
    /// display connecting mid-presentation) starts in the right state.
    private(set) var annotationsHidden = false

    private init() {
        // Bundled sample deck, shown until the user opens an .marpbundle.
        guard let url = Bundle.main.url(forResource: "deck", withExtension: "html", subdirectory: "Deck") else {
            fatalError("Bundled sample deck (Deck/deck.html) is missing from the app bundle")
        }
        deckHTMLURL = url
        deckDirectory = url.deletingLastPathComponent()
        let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        slideCount = MarpBundleLoader.slideCount(in: html)
        slideAspectRatio = MarpBundleLoader.slideAspectRatio(in: html)

        // Backgrounding (or an interruption that precedes termination) is
        // the one moment ink could otherwise be lost mid-debounce.
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushPendingInkSaves),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    func loadDeck(htmlURL: URL, directory: URL, slideCount: Int, slideAspectRatio: CGFloat, bundleURL: URL?) {
        flushPendingInkSaves()
        deckHTMLURL = htmlURL
        deckDirectory = directory
        self.slideCount = slideCount
        self.slideAspectRatio = slideAspectRatio
        self.bundleURL = bundleURL
        currentIndex = 0
        drawings = [:]
        loadInkFromDisk()
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
        scheduleInkSave(for: slideIndex)
    }

    private func inkFileURL(for slideIndex: Int) -> URL? {
        bundleURL?.appendingPathComponent("ink/\(slideIndex).drawing")
    }

    private func loadInkFromDisk() {
        guard let bundleURL else { return }
        let inkDirectory = bundleURL.appendingPathComponent("ink", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: inkDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "drawing" {
            guard let slideIndex = Int(file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let drawing = try? PKDrawing(data: data)
            else { continue }
            drawings[slideIndex] = drawing
        }
    }

    private func scheduleInkSave(for slideIndex: Int) {
        guard bundleURL != nil else { return }
        pendingInkSaves[slideIndex]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveInk(for: slideIndex)
            self?.pendingInkSaves[slideIndex] = nil
        }
        pendingInkSaves[slideIndex] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    @objc private func flushPendingInkSaves() {
        let pending = pendingInkSaves
        pendingInkSaves.removeAll()
        for (slideIndex, item) in pending {
            item.cancel()
            saveInk(for: slideIndex)
        }
    }

    private func saveInk(for slideIndex: Int) {
        guard let fileURL = inkFileURL(for: slideIndex) else { return }
        let drawing = drawings[slideIndex] ?? PKDrawing()
        let fm = FileManager.default
        // Clearing a slide's ink removes its file entirely rather than
        // writing an empty PKDrawing, so a cleared slide doesn't linger as
        // clutter in the bundle.
        guard !drawing.strokes.isEmpty else {
            try? fm.removeItem(at: fileURL)
            return
        }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? drawing.dataRepresentation().write(to: fileURL, options: .atomic)
    }

    /// Recorded by the main scene whenever its canvas lays out, so ink can be
    /// rescaled for the external display's differently-sized canvas.
    func setAuthoringCanvasSize(_ size: CGSize) {
        authoringCanvasSize = size
    }

    func setCurrentIndex(_ index: Int) {
        currentIndex = index
    }

    func setAnnotationsHidden(_ hidden: Bool) {
        annotationsHidden = hidden
        NotificationCenter.default.post(name: .annotationsHiddenDidChange, object: nil, userInfo: ["hidden": hidden])
    }
}
