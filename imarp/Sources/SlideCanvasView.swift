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
    private var didFinishInitialLoad = false
    private var loadedURL: URL?
    private var loadedDirectory: URL?

    /// Called with the position the page is *actually* showing whenever it
    /// settles on one: after a step, once a `show(_:)` has really landed, or
    /// if the page moves for any other reason. Anything tied to the visible
    /// slide (which ink to display, what the other screen should show) keys
    /// off this rather than off what was requested, since a request can be
    /// overridden (e.g. by bespoke's own startup after a reload) or still be
    /// mid-transition.
    var onPositionChanged: ((SlidePosition) -> Void)?

    /// Prefix for debug logging, so the two screens' logs can be told apart.
    var debugLabel = "slides"

    /// Last position reported or requested, so a page reload (e.g. after iOS
    /// kills the web content process while the app is backgrounded) can land
    /// back on it instead of slide 1.
    private var lastKnownPosition = SlidePosition.start

    /// Set by `show(_:)` until the page is confirmed to be there. While set,
    /// positions the page reports on its own are not passed on: a freshly
    /// (re)loaded page announces slide 1 before the jump takes effect, and
    /// that must never be mistaken for where the presentation is.
    private var targetPosition: SlidePosition?
    private var verifyGeneration = 0

    /// After a `show(_:)` lands, the page is held there for a few seconds:
    /// bespoke's own startup (its URL-hash handling) can move a freshly
    /// loaded page back to slide 1 *after* the jump took effect, so any move
    /// the page makes on its own in that window is undone. A step by the
    /// presenter ends the hold.
    private var holdPosition: SlidePosition?
    private var holdUntil = Date.distantPast

    /// Marp's bespoke runtime keeps its deck object private, but its sync
    /// plugin tags the deck with a `syncKey` property while setting up. This
    /// runs before any page script, catches that one `defineProperty` call to
    /// get hold of the deck, then puts the original back. With the deck in
    /// hand, stepping and jumping go through bespoke's own API (the same
    /// calls its presenter-view sync uses), and every slide/fragment change
    /// is reported back to the app.
    private static let deckHookScript = """
        (function () {
            var originalDefine = Object.defineProperty;
            Object.defineProperty = function (target, property, descriptor) {
                var result = originalDefine.apply(this, arguments);
                if (property === 'syncKey' && target && typeof target.slide === 'function' && typeof target.on === 'function') {
                    Object.defineProperty = originalDefine;
                    window.__imarpDeck = target;
                    target.on('fragment', function (event) {
                        window.__imarpPosition = { index: event.index, fragment: event.fragmentIndex };
                        window.webkit.messageHandlers.imarpPosition.postMessage([event.index, event.fragmentIndex]);
                    });
                }
                return result;
            };
            window.__imarpRead = function () {
                var deck = window.__imarpDeck;
                if (!deck) { return null; }
                var index = deck.slide();
                var position = window.__imarpPosition;
                return [index, (position && position.index === index) ? position.fragment : 0];
            };
            window.__imarpStep = function (forward) {
                var deck = window.__imarpDeck;
                if (!deck) { return false; }
                if (forward) { deck.next(); } else { deck.prev(); }
                return true;
            };
            window.__imarpGo = function (index, fragment) {
                var deck = window.__imarpDeck;
                if (!deck) { return null; }
                var current = window.__imarpRead();
                if (current[0] !== index || current[1] !== fragment) {
                    deck.slide(index, { fragment: fragment });
                }
                return window.__imarpRead();
            };
        })();
        """

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
            WKUserScript(source: Self.deckHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideChromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let messageProxy = WeakScriptMessageHandler()
        configuration.userContentController.add(messageProxy, name: "imarpPosition")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        messageProxy.target = self

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

    private func log(_ message: String) {
        #if DEBUG
        print("[imarp \(debugLabel)] \(message)")
        #endif
    }

    /// Loads a deck (the bundled sample, or one opened from an
    /// `.marpbundle`), replacing whatever was previously shown.
    func load(htmlURL: URL, directory: URL, at position: SlidePosition = .start) {
        log("load \(htmlURL.lastPathComponent) at \(position)")
        didFinishInitialLoad = false
        targetPosition = nil
        holdPosition = nil
        lastKnownPosition = position
        loadedURL = htmlURL
        loadedDirectory = directory
        // Opening at the slide's own URL hash makes bespoke start on that
        // slide itself, instead of starting on slide 1 and being moved.
        var components = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
        components?.fragment = "\(position.index + 1)"
        webView.loadFileURL(components?.url ?? htmlURL, allowingReadAccessTo: directory)
        if position != .start { show(position) }
    }

    /// Puts the deck at exactly `position` (slide and revealed fragments),
    /// then keeps checking until it's really there. A no-op if it already is,
    /// so calling it to re-assert the current position never disturbs the
    /// revealed bullets.
    func show(_ position: SlidePosition) {
        log("show \(position) loaded=\(didFinishInitialLoad)")
        lastKnownPosition = position
        targetPosition = position
        verifyGeneration += 1
        guard didFinishInitialLoad else { return }
        apply(position, generation: verifyGeneration, attemptsLeft: 12)
    }

    /// Asks bespoke to go to `position`, then checks shortly afterwards
    /// (once any slide transition has had time to swap slides) and asks
    /// again if it isn't there: bespoke may not be set up yet, or its own
    /// startup may have reset it to slide 1 after the first request.
    private func apply(_ position: SlidePosition, generation: Int, attemptsLeft: Int) {
        webView.evaluateJavaScript("window.__imarpGo(\(position.index), \(position.fragment))") { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.verify(position, generation: generation, attemptsLeft: attemptsLeft)
            }
        }
    }

    private func verify(_ position: SlidePosition, generation: Int, attemptsLeft: Int) {
        guard generation == verifyGeneration, targetPosition == position else { return }
        webView.evaluateJavaScript("window.__imarpRead()") { [weak self] result, _ in
            guard let self, generation == verifyGeneration, targetPosition == position else { return }
            if let actual = Self.position(from: result), actual == position {
                log("reached \(position)")
                holdPosition = position
                holdUntil = Date().addingTimeInterval(4)
                settle(on: position)
            } else if attemptsLeft > 0 {
                log("not yet at \(position) (showing \(String(describing: Self.position(from: result)))), retrying")
                apply(position, generation: generation, attemptsLeft: attemptsLeft - 1)
            } else {
                // Couldn't get there through bespoke (e.g. the deck changed
                // and has fewer slides now): fall back to a plain hash jump
                // and accept wherever the page reports it ends up.
                log("giving up on \(position), hash jump")
                targetPosition = nil
                webView.evaluateJavaScript("location.hash = '\(position.index + 1)';")
            }
        }
    }

    private func settle(on position: SlidePosition) {
        targetPosition = nil
        lastKnownPosition = position
        onPositionChanged?(position)
    }

    fileprivate func pageReported(_ position: SlidePosition) {
        if let targetPosition {
            if position == targetPosition {
                log("reported \(position), target reached")
                holdPosition = position
                holdUntil = Date().addingTimeInterval(4)
                settle(on: position)
            } else {
                log("reported \(position) while heading to \(targetPosition), ignored")
            }
            return
        }
        if let holdPosition, Date() < holdUntil, position != holdPosition {
            log("reported \(position) while held at \(holdPosition), moving back")
            show(holdPosition)
            return
        }
        log("reported \(position)")
        settle(on: position)
    }

    private static func position(from result: Any?) -> SlidePosition? {
        guard let values = result as? [Int], values.count == 2, values[0] >= 0 else { return nil }
        return SlidePosition(index: values[0], fragment: max(values[1], 0))
    }

    /// Steps forward/back exactly as the arrow keys would: fragment-aware,
    /// revealing one bullet at a time before moving to the next slide. The
    /// resulting position arrives through `onPositionChanged` once bespoke
    /// has actually moved (with a slide transition, that's a moment later).
    func step(forward: Bool) {
        guard didFinishInitialLoad else { return }
        log("step \(forward ? "forward" : "back")")
        // The presenter is driving now; stop chasing or holding any earlier
        // target.
        targetPosition = nil
        holdPosition = nil
        verifyGeneration += 1
        // Fallback for a page where the deck hook didn't take: simulate the
        // key press, then read the active slide from the DOM once any
        // transition has run. Each slide is an <svg data-marpit-svg>
        // (bespoke toggles .bespoke-marp-active on it) wrapping a
        // <section data-marpit-pagination="N">, N 1-indexed.
        let key = forward ? "ArrowRight" : "ArrowLeft"
        let script = """
            (function () {
                if (window.__imarpStep(\(forward))) { return true; }
                document.dispatchEvent(new KeyboardEvent('keydown', { key: '\(key)', bubbles: true }));
                return false;
            })();
            """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard (result as? Bool) == false else { return }
            self?.log("deck hook missing, keyboard fallback")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                let read = """
                    (function () {
                        var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
                        var section = active ? active.querySelector('section[data-marpit-pagination]') : null;
                        return section ? [parseInt(section.getAttribute('data-marpit-pagination'), 10) - 1, 0] : null;
                    })();
                    """
                self?.webView.evaluateJavaScript(read) { [weak self] result, _ in
                    if let position = Self.position(from: result) { self?.pageReported(position) }
                }
            }
        }
    }
}

/// WKUserContentController holds its message handlers strongly, which would
/// keep the view (and its webview) alive forever; this breaks that cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: SlideContentView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let values = message.body as? [Int], values.count == 2, values[0] >= 0 else { return }
        target?.pageReported(SlidePosition(index: values[0], fragment: max(values[1], 0)))
    }
}

extension SlideContentView: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let url = loadedURL, let directory = loadedDirectory else { return }
        let position = lastKnownPosition
        log("web content process terminated, reloading at \(position)")
        load(htmlURL: url, directory: directory, at: position)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("didFinish")
        didFinishInitialLoad = true
        if let targetPosition {
            show(targetPosition)
        }
    }
}

/// A small laser-pointer-style dot + glow, positioned in the host view's own
/// coordinate space by `SlideCanvasView.setPointer(normalizedPoint:aspectRatio:)`.
/// Never intercepts touches — it's purely a display layer, so hover/gesture
/// recognizers on the canvas beneath it keep working normally.
final class PointerDotView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isHidden = true
        layer.addSublayer(glowLayer)
        layer.addSublayer(dotLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let dotDiameter: CGFloat = 22
    private let glowDiameter: CGFloat = 60

    private lazy var dotLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemRed.cgColor
        layer.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
        layer.path = UIBezierPath(ovalIn: layer.bounds).cgPath
        return layer
    }()

    private lazy var glowLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.colors = [
            UIColor.systemRed.withAlphaComponent(0.55).cgColor,
            UIColor.systemRed.withAlphaComponent(0.0).cgColor,
        ]
        layer.locations = [0, 1]
        layer.bounds = CGRect(x: 0, y: 0, width: glowDiameter, height: glowDiameter)
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        return layer
    }()

    func show(at point: CGPoint) {
        isHidden = false
        // Disable implicit position animations so the dot doesn't visibly
        // lag behind a fast-moving hover — every update should land instantly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.position = point
        glowLayer.position = point
        CATransaction.commit()
    }

    func hide() {
        isHidden = true
    }
}

/// A slide (content + ink overlay) with an on/off switch for accepting
/// Pencil input — the iPad-side canvas is interactive, the external
/// display's canvas is display-only.
final class SlideCanvasView: UIView, PKCanvasViewDelegate {
    let contentView = SlideContentView()
    let canvasView = PKCanvasView()
    let pointerDotView = PointerDotView()

    var isDrawingEnabled: Bool = true {
        didSet { canvasView.isUserInteractionEnabled = isDrawingEnabled }
    }

    var onDrawingChanged: ((PKDrawing) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        pointerDotView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        // .anyInput would always allow finger drawing regardless of the
        // user's system-wide "Only Draw with Apple Pencil" setting; .default
        // respects that setting like other PencilKit apps do.
        canvasView.drawingPolicy = .default
        canvasView.delegate = self

        addSubview(contentView)
        addSubview(canvasView)
        // Above the ink layer, so the pointer stays visible even while
        // drawing is on screen.
        addSubview(pointerDotView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pointerDotView.topAnchor.constraint(equalTo: topAnchor),
            pointerDotView.bottomAnchor.constraint(equalTo: bottomAnchor),
            pointerDotView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pointerDotView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func loadDeck(htmlURL: URL, directory: URL, at position: SlidePosition = .start) {
        contentView.load(htmlURL: htmlURL, directory: directory, at: position)
    }

    func configure(position: SlidePosition, drawing: PKDrawing) {
        contentView.show(position)
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

    func show(_ position: SlidePosition) {
        contentView.show(position)
    }

    func step(forward: Bool) {
        contentView.step(forward: forward)
    }

    /// `normalizedPoint` is in the slide's own 0...1 x 0...1 space; `nil`
    /// hides the pointer. Mapped through this canvas's own `slideRect(in:aspectRatio:)`
    /// exactly like ink is rescaled, so the dot lands correctly regardless of
    /// how this canvas is letterboxed relative to where the point originated.
    func setPointer(normalizedPoint: CGPoint?, aspectRatio: CGFloat) {
        guard let normalizedPoint else {
            pointerDotView.hide()
            return
        }
        let rect = Self.slideRect(in: bounds.size, aspectRatio: aspectRatio)
        guard rect.width > 0, rect.height > 0 else {
            pointerDotView.hide()
            return
        }
        pointerDotView.show(at: CGPoint(
            x: rect.minX + normalizedPoint.x * rect.width,
            y: rect.minY + normalizedPoint.y * rect.height
        ))
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onDrawingChanged?(canvasView.drawing)
    }
}
