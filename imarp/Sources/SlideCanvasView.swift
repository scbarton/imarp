import UIKit
import WebKit
import PencilKit

/// Renders Marp's bespoke-navigable HTML output. Slide changes within a
/// loaded deck are driven by setting `location.hash` or simulating a key
/// press on the existing page rather than reloading, so navigation is
/// instant and matches how Marp's own presentation mode works. Loading a
/// *different* deck (see `load(htmlURL:directory:)`) does a full page load.
final class SlideContentView: UIView {
    private let webView: WKWebView
    private var pendingSlideIndex: Int?
    private var didFinishInitialLoad = false

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        // Marp's bespoke output ships its own on-screen page controls and a
        // fullscreen toggle. Navigation here is driven entirely by our own
        // toolbar (and, on the external display, by nothing at all), so
        // hide that chrome rather than let it show through on either screen.
        let hideChromeCSS = """
            .bespoke-marp-osc { display: none !important; }
            """
        let hideChromeScript = """
            const style = document.createElement('style');
            style.textContent = \(String(reflecting: hideChromeCSS));
            document.head.appendChild(style);
            """
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideChromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)

        backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Loads a deck (the bundled sample, or one opened from an
    /// `.imarpbundle`), replacing whatever was previously shown.
    func load(htmlURL: URL, directory: URL) {
        didFinishInitialLoad = false
        pendingSlideIndex = nil
        webView.loadFileURL(htmlURL, allowingReadAccessTo: directory)
    }

    /// Marp/bespoke slides are 1-indexed via `location.hash`. Jumping
    /// directly by hash always resets that slide's fragments (incremental
    /// bullet reveals) back to hidden, so this is only for landing on a
    /// slide fresh — not for stepping through a live presentation. Use
    /// `step(forward:completion:)` for that.
    func showSlide(index: Int) {
        guard didFinishInitialLoad else {
            pendingSlideIndex = index
            return
        }
        webView.evaluateJavaScript("location.hash = '\(index + 1)';")
    }

    /// Steps forward/back exactly as if the user pressed the arrow key —
    /// this reuses Marp's own bespoke keyboard-navigation logic, which is
    /// fragment-aware (reveals one bullet at a time before moving to the
    /// next slide). There's no exposed JS API for this, so the same key
    /// event a real keypress would produce is simulated instead, then the
    /// resulting active slide's index is read back from the DOM.
    func step(forward: Bool, completion: @escaping (Int) -> Void) {
        guard didFinishInitialLoad else {
            completion(0)
            return
        }
        let key = forward ? "ArrowRight" : "ArrowLeft"
        // Each slide is an <svg data-marpit-svg> (bespoke toggles the
        // .bespoke-marp-active class on it at runtime) wrapping a
        // <section data-marpit-pagination="N"> — N is the 1-indexed slide
        // number, present regardless of how deep marp-core nests things.
        let script = """
            (function () {
                document.dispatchEvent(new KeyboardEvent('keydown', { key: '\(key)', bubbles: true }));
                var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
                var section = active ? active.querySelector('section[data-marpit-pagination]') : null;
                return section ? parseInt(section.getAttribute('data-marpit-pagination'), 10) - 1 : -1;
            })();
            """
        webView.evaluateJavaScript(script) { result, _ in
            completion((result as? Int) ?? 0)
        }
    }

}

extension SlideContentView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        if let index = pendingSlideIndex {
            pendingSlideIndex = nil
            showSlide(index: index)
        }
    }
}

/// A slide (content + ink overlay) with an on/off switch for accepting
/// Pencil input — the iPad-side canvas is interactive, the external
/// display's canvas is display-only.
final class SlideCanvasView: UIView, PKCanvasViewDelegate {
    let contentView = SlideContentView()
    let canvasView = PKCanvasView()

    var isDrawingEnabled: Bool = true {
        didSet { canvasView.isUserInteractionEnabled = isDrawingEnabled }
    }

    var onDrawingChanged: ((PKDrawing) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        // .anyInput would always allow finger drawing regardless of the
        // user's system-wide "Only Draw with Apple Pencil" setting; .default
        // respects that setting like other PencilKit apps do.
        canvasView.drawingPolicy = .default
        canvasView.delegate = self

        addSubview(contentView)
        addSubview(canvasView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadDeck(htmlURL: URL, directory: URL) {
        contentView.load(htmlURL: htmlURL, directory: directory)
    }

    func configure(slideIndex: Int, drawing: PKDrawing) {
        contentView.showSlide(index: slideIndex)
        setDrawing(drawing)
    }

    /// Where the slide itself sits inside `size` once letterboxed to preserve
    /// `aspectRatio` — the webview scales the slide to fit and centers it, so
    /// on a 4:3-ish iPad canvas a 16:9 slide leaves bars above and below,
    /// while on a 16:9 TV it fills the screen.
    static func slideRect(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspectRatio > 0 else { return .zero }
        let fitted: CGSize
        if size.width / size.height > aspectRatio {
            fitted = CGSize(width: size.height * aspectRatio, height: size.height)
        } else {
            fitted = CGSize(width: size.width, height: size.width / aspectRatio)
        }
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Displays ink drawn on a different-sized canvas. Ink is stored in the
    /// authoring canvas's points, so putting it on the larger external canvas
    /// unchanged leaves it clustered in one corner at the wrong scale; this
    /// maps the source slide rect onto this canvas's slide rect so a stroke
    /// stays over the same part of the slide on both screens.
    func setDrawing(_ drawing: PKDrawing, authoredOnCanvasOfSize sourceSize: CGSize, aspectRatio: CGFloat) {
        let source = Self.slideRect(in: sourceSize, aspectRatio: aspectRatio)
        let destination = Self.slideRect(in: bounds.size, aspectRatio: aspectRatio)
        guard source.width > 0, destination.width > 0 else {
            setDrawing(drawing)
            return
        }
        let scale = destination.width / source.width
        var transform = CGAffineTransform(translationX: destination.minX, y: destination.minY)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -source.minX, y: -source.minY)
        setDrawing(drawing.transformed(using: transform))
    }

    func setDrawing(_ drawing: PKDrawing) {
        canvasView.drawing = drawing
        // PKCanvasView doesn't always invalidate its rendered tile cache on a
        // programmatic (non-gesture) assignment, most visibly when swapping
        // to an empty PKDrawing() — the strokes are gone from the model but
        // stale pixels remain on screen until something forces a redraw.
        canvasView.setNeedsDisplay()
    }

    func step(forward: Bool, completion: @escaping (Int) -> Void) {
        contentView.step(forward: forward, completion: completion)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onDrawingChanged?(canvasView.drawing)
    }
}
