import Foundation
import PencilKit
import UIKit

/// Where a bespoke deck is: which slide, and how many of its fragments
/// (incremental bullets) are revealed.
struct SlidePosition: Equatable {
    var index: Int
    var fragment: Int

    static let start = SlidePosition(index: 0, fragment: 0)
}

extension Notification.Name {
    /// Posted (userInfo["forward"]: Bool) when Prev/Next is pressed. Only
    /// the main scene steps its webview in response; it then records the
    /// exact resulting slide and fragment in the store and posts
    /// `.slideIndexDidChange`.
    static let stepRequested = Notification.Name("stepRequested")
    /// Posted by the main scene after it has stepped (or re-asserted its
    /// position) and recorded `PresentationStore.currentPosition`. The
    /// external display follows it by jumping straight to that slide and
    /// fragment, so the two screens can't drift apart by stepping twice or
    /// missing a step.
    static let slideIndexDidChange = Notification.Name("slideIndexDidChange")
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
    /// Posted whenever the laser pointer's position or visibility changes.
    /// userInfo["point"]: NSValue(CGPoint)?, normalized to the SLIDE's own
    /// 0...1 x 0...1 space (not the canvas) — absent/nil means "hidden".
    /// Both scenes observe this and re-derive their own canvas-space
    /// position by mapping the normalized point through their own
    /// `SlideCanvasView.slideRect(in:aspectRatio:)`, exactly like ink is
    /// rescaled, so the dot lands over the same part of the slide on both
    /// screens regardless of how differently each canvas is letterboxed.
    static let pointerDidMove = Notification.Name("pointerDidMove")
    /// Posted (userInfo["index"], ["playing"], ["time"], ["rate"]) when the
    /// presenter played, paused, seeked or changed the speed of one of the
    /// current slide's videos on the iPad; the external display does the
    /// same to its copy. `index` counts the active
    /// slide's interactive elements, the same on both screens.
    static let mediaCommand = Notification.Name("mediaCommand")
    /// Posted (userInfo["index"], ["filled"]) when one of the current slide's
    /// videos entered or left iOS's full-screen player on the iPad; the
    /// external display fills its screen with the video meanwhile.
    static let mediaFillChanged = Notification.Name("mediaFillChanged")
    /// Posted (userInfo["index"]) after the presenter tapped one of the
    /// current slide's other HTML controls (a button, a <details> summary...)
    /// on the iPad, so the external display can do the same.
    static let htmlControlActivated = Notification.Name("htmlControlActivated")
    /// Posted (userInfo["change"]) after the presenter changed a form control
    /// on a slide (e.g. a widget's slider, inside an iframe) or clicked a
    /// button inside a slide's iframe, so the external display can do the same.
    static let formInputChanged = Notification.Name("formInputChanged")
    /// Posted (userInfo["mark"], absent to clear) when the presenter
    /// highlights text on a slide (on a Mac), so the external display shows
    /// the same highlight.
    static let highlightChanged = Notification.Name("highlightChanged")
    /// Posted (userInfo["region"]: NSValue CGRect, normalized to the slide;
    /// absent when back to the whole slide) as the iPad zooms and pans.
    static let slideZoomDidChange = Notification.Name("slideZoomDidChange")
    /// Posted when the external display scene starts or stops showing slides.
    static let externalDisplayActiveDidChange = Notification.Name("externalDisplayActiveDidChange")
    /// Posted (userInfo["enabled"]: Bool) when the toolbar pointer toggle is
    /// flipped. Both scenes observe this so a display connecting
    /// mid-presentation starts in the right state, and so the main scene's
    /// hover recognizer can be gated at the source.
    static let pointerEnabledDidChange = Notification.Name("pointerEnabledDidChange")
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

    /// Slide width÷height for the loaded deck.
    private(set) var slideAspectRatio: CGFloat = 16.0 / 9.0

    /// Ink is kept (in memory and on disk) in slide space: coordinates on a
    /// slide this size, 1280 wide like an exported PDF page, whatever size the
    /// slide is shown at. Each screen maps it onto its own slide rect (see
    /// SlideCanvasView.setDrawing), so it lands on the same spot on the iPad,
    /// the external display, a Mac window or a PDF page.
    var slideSpaceSize: CGSize {
        let aspect = slideAspectRatio > 0 ? slideAspectRatio : 16.0 / 9.0
        return CGSize(width: 1280, height: (1280 / aspect).rounded())
    }

    /// Ink saved before slide space (`ink/<n>.drawing`, not
    /// `ink/<n>.slide.drawing`) is in the points of the iPad canvas it was
    /// drawn on: always this iPad, full screen in landscape, where the canvas
    /// is 1194 x 738. It's mapped into slide space when read; the old file
    /// is left alone.
    private static let legacyCanvasSize = CGSize(width: 1194, height: 738)

    /// Updated by the main scene once its step completes. The single source
    /// of truth for what's on screen: the external display mirrors it, and
    /// ink is always attributed to `currentIndex`.
    private(set) var currentPosition = SlidePosition.start
    var currentIndex: Int { currentPosition.index }

    private var drawings: [Int: PKDrawing] = [:]

    /// Where the open deck's ink is saved, one file per slide index: `ink/`
    /// inside a `.marpbundle`, or `<name>.ink/` beside a Markdown deck (see
    /// MarpBundleLoader). Kept apart from the Markdown and the rendered HTML,
    /// so editing or re-rendering the deck never touches annotations. `nil`
    /// on the gray start screen, which has no ink.
    private(set) var inkDirectory: URL?

    /// Debounced per-slide save timers, so a fast run of PencilKit's
    /// continuous drawing-changed updates during a single stroke doesn't
    /// write to disk many times a second — only once, shortly after the
    /// stroke settles.
    private var pendingInkSaves: [Int: DispatchWorkItem] = [:]

    /// So a scene created/reconnected after the toggle (e.g. the external
    /// display connecting mid-presentation) starts in the right state.
    private(set) var annotationsHidden = false

    /// Gates whether the main scene's Pencil-hover recognizer does anything
    /// at all (see `MainViewController.handleHover(_:)`) — set via the
    /// toolbar's "Pointer" toggle button.
    private(set) var pointerEnabled = false

    /// Whether the external display scene is showing slides. While it is,
    /// slide video sound comes from it, and the iPad's copy plays muted.
    var externalDisplayActive = false {
        didSet {
            guard externalDisplayActive != oldValue else { return }
            NotificationCenter.default.post(name: .externalDisplayActiveDidChange, object: nil)
        }
    }

    /// The latest value of every form control the presenter has changed in
    /// this deck, so an external display that connects (or reloads) later
    /// shows the same widget state. Keyed by the control's frames and path.
    private(set) var formInputs: [String: [String: Any]] = [:]

    func recordFormInput(_ change: [String: Any]) {
        guard (change["kind"] as? String) != "click",
              let frames = change["frames"], let path = change["path"]
        else { return }
        formInputs["\(frames)|\(path)"] = change
    }

    /// The part of the slide the iPad is zoomed into (normalized), so an
    /// external display that connects mid-zoom starts at the same view.
    private(set) var zoomRegion: CGRect?

    func setZoomRegion(_ region: CGRect?) {
        zoomRegion = region
        var userInfo: [String: Any] = [:]
        if let region { userInfo["region"] = NSValue(cgRect: region) }
        NotificationCenter.default.post(name: .slideZoomDidChange, object: nil, userInfo: userInfo)
    }

    /// Whether a deck is open (as opposed to the gray start screen).
    var hasDeck: Bool { inkDirectory != nil }

    /// The start screen's gray, also used behind it on the iPad (see
    /// MainViewController.reloadDeckFromStore).
    static let startScreenGray = UIColor(white: 0x55 / 255.0, alpha: 1)

    /// A plain gray page, shown on both screens until a deck is opened.
    static let startScreenURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imarp-start.html")
        let html = """
            <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">\
            <style>html, body { margin: 0; height: 100%; background: #555; }</style></head><body></body></html>
            """
        try? html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    private init() {
        deckHTMLURL = Self.startScreenURL
        deckDirectory = Self.startScreenURL.deletingLastPathComponent()
        slideCount = 0

        // Backgrounding (or an interruption that precedes termination) is
        // the one moment ink could otherwise be lost mid-debounce.
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushPendingInkSaves),
            name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    /// `keepPosition`: a live reload of the same deck (see DeckWatcher),
    /// which stays on the current slide (or the last one, if the deck got
    /// shorter) instead of starting over.
    func loadDeck(htmlURL: URL, directory: URL, slideCount: Int, slideAspectRatio: CGFloat, inkDirectory: URL?, name: String, keepPosition: Bool = false) {
        flushPendingInkSaves()
        deckHTMLURL = htmlURL
        deckDirectory = directory
        self.slideCount = slideCount
        self.slideAspectRatio = slideAspectRatio
        DebugLog.write("store", "\(keepPosition ? "reloaded" : "loaded") \(name): \(slideCount) slides, aspect \(slideAspectRatio)")
        self.inkDirectory = inkDirectory
        if keepPosition {
            currentPosition = SlidePosition(index: min(currentPosition.index, max(slideCount - 1, 0)), fragment: currentPosition.fragment)
        } else {
            currentPosition = .start
        }
        drawings = [:]
        formInputs = [:]
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
        inkDirectory?.appendingPathComponent("\(slideIndex).slide.drawing")
    }

    private func legacyInkFileURL(for slideIndex: Int) -> URL? {
        inkDirectory?.appendingPathComponent("\(slideIndex).drawing")
    }

    /// Reads `<n>.slide.drawing` (slide space) where there is one, and
    /// otherwise maps an old `<n>.drawing` (iPad canvas points) into slide
    /// space.
    private func loadInkFromDisk() {
        guard let inkDirectory else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: inkDirectory, includingPropertiesForKeys: nil) else { return }
        var current: [Int: PKDrawing] = [:]
        var legacy: [Int: PKDrawing] = [:]
        for file in files where file.pathExtension == "drawing" {
            let stem = file.deletingPathExtension().lastPathComponent
            let isCurrent = stem.hasSuffix(".slide")
            guard let slideIndex = Int(isCurrent ? String(stem.dropLast(6)) : stem),
                  let data = try? Data(contentsOf: file),
                  let drawing = try? PKDrawing(data: data)
            else { continue }
            if isCurrent { current[slideIndex] = drawing } else { legacy[slideIndex] = drawing }
        }
        let fromLegacy = SlideCanvasView.inkTransform(from: Self.legacyCanvasSize, to: slideSpaceSize, aspectRatio: slideAspectRatio)
        for (slideIndex, drawing) in legacy where current[slideIndex] == nil {
            guard let fromLegacy else { continue }
            drawings[slideIndex] = drawing.transformed(using: fromLegacy)
        }
        for (slideIndex, drawing) in current where !drawing.strokes.isEmpty {
            drawings[slideIndex] = drawing
        }
        DebugLog.write("store", "ink: \(current.count) slide-space file(s), \(legacy.filter { current[$0.key] == nil }.count) old file(s) converted")
    }

    private func scheduleInkSave(for slideIndex: Int) {
        guard inkDirectory != nil else { return }
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
        // clutter in the bundle; unless an old-format file is still there,
        // which an empty slide-space file has to override.
        let hasLegacy = legacyInkFileURL(for: slideIndex).map { fm.fileExists(atPath: $0.path) } ?? false
        guard !drawing.strokes.isEmpty || hasLegacy else {
            try? fm.removeItem(at: fileURL)
            return
        }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? drawing.dataRepresentation().write(to: fileURL, options: .atomic)
    }

    func setCurrentPosition(_ position: SlidePosition) {
        currentPosition = position
    }

    func setAnnotationsHidden(_ hidden: Bool) {
        annotationsHidden = hidden
        NotificationCenter.default.post(name: .annotationsHiddenDidChange, object: nil, userInfo: ["hidden": hidden])
    }

    func setPointerEnabled(_ enabled: Bool) {
        pointerEnabled = enabled
        if !enabled {
            NotificationCenter.default.post(name: .pointerDidMove, object: nil, userInfo: [:])
        }
        NotificationCenter.default.post(name: .pointerEnabledDidChange, object: nil, userInfo: ["enabled": enabled])
    }

    /// `point` is normalized to the slide's own 0...1 x 0...1 space; `nil`
    /// hides the pointer.
    func setPointerPosition(_ point: CGPoint?) {
        var userInfo: [String: Any] = [:]
        if let point {
            userInfo["point"] = NSValue(cgPoint: point)
        }
        NotificationCenter.default.post(name: .pointerDidMove, object: nil, userInfo: userInfo)
    }
}
