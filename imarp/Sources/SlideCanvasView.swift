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

    /// Called with true when a slide transition starts animating and false
    /// once it has finished.
    var onTransitionActiveChanged: ((Bool) -> Void)?

    /// Called when Marp's slide overview opens or closes.
    var onOverviewChanged: ((Bool) -> Void)?
    private(set) var isOverviewOpen = false

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
    private var lastViewportSize: CGSize = .zero

    /// Marp's bespoke runtime keeps its deck object private, but its sync
    /// plugin tags the deck with a `syncKey` property while setting up. This
    /// runs before any page script, catches that one `defineProperty` call to
    /// get hold of the deck, then puts the original back. With the deck in
    /// hand, stepping and jumping go through bespoke's own API (the same
    /// calls its presenter-view sync uses), and every slide/fragment change
    /// is reported back to the app.
    static let deckHookScript = """
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
            // Marp's slide transitions run through the View Transitions API.
            // Report when they start and finish, so ink for the outgoing
            // slide can be hidden while the slides animate and the new
            // slide's ink shown only once the animation is over.
            if (typeof document.startViewTransition === 'function') {
                var originalStartViewTransition = document.startViewTransition;
                var running = 0;
                document.startViewTransition = function () {
                    var transition = originalStartViewTransition.apply(document, arguments);
                    running += 1;
                    if (running === 1) { window.webkit.messageHandlers.imarpTransition.postMessage(true); }
                    transition.finished.finally(function () {
                        running -= 1;
                        if (running === 0) { window.webkit.messageHandlers.imarpTransition.postMessage(false); }
                    });
                    return transition;
                };
            }
            // marp-cli's slide overview (a grid of every slide, opened with
            // Esc/o or deck.toggleOverviewView) lives in an overlay <div
            // class="bespoke-marp-overview" data-open="1|">; report when it
            // opens and closes, however that happened (picking a slide
            // closes it from inside the overview's own iframe).
            window.__imarpOverviewOpen = false;
            document.addEventListener('DOMContentLoaded', function () {
                new MutationObserver(function () {
                    var overview = document.querySelector('.bespoke-marp-overview');
                    var open = !!(overview && overview.dataset.open);
                    if (open !== window.__imarpOverviewOpen) {
                        window.__imarpOverviewOpen = open;
                        window.webkit.messageHandlers.imarpOverview.postMessage(open);
                        // The overview's iframe is kept between openings, so
                        // tell it which slide is current each time.
                        var frame = open && overview.querySelector('iframe');
                        if (frame && frame.contentWindow && window.__imarpDeck) {
                            frame.contentWindow.postMessage({ imarpCurrentSlide: window.__imarpDeck.slide() }, '*');
                        }
                    }
                }).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['data-open'] });
            });
            // Picks from the overview (see overviewFrameScript). Marp links the
            // overview to the slideshow through localStorage, which doesn't
            // carry between frames of a page loaded from a file, so the pick
            // is relayed with postMessage and applied here instead.
            window.addEventListener('message', function (event) {
                var data = event.data;
                var deck = window.__imarpDeck;
                if (!data || typeof data !== 'object' || !deck) { return; }
                if (typeof data.imarpOverviewSelect === 'number') {
                    deck.slide(data.imarpOverviewSelect, { fragment: -1 });
                } else if (data.imarpOverviewReady && event.source) {
                    event.source.postMessage({ imarpCurrentSlide: deck.slide() }, '*');
                }
            });
            window.__imarpToggleOverview = function (open) {
                var deck = window.__imarpDeck;
                if (!deck || typeof deck.toggleOverviewView !== 'function') { return false; }
                deck.toggleOverviewView(open);
                return true;
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
            // Marp's page asks for width=device-width,height=device-height,
            // which in a WKWebView means the *screen's* size, not the view's:
            // on the iPad (view shorter than the screen) and on an external
            // display that lays the slide out in the wrong box, shifting it
            // from where the ink and pointer mapping expect it. The app sets
            // the view's real size instead, and again whenever it changes.
            window.__imarpSetViewport = function (width, height) {
                var meta = document.querySelector('meta[name=viewport]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.setAttribute('name', 'viewport');
                    document.head.appendChild(meta);
                }
                meta.setAttribute('content', 'width=' + width + ', height=' + height + ', initial-scale=1, maximum-scale=1, user-scalable=no');
            };
            window.__imarpGeometry = function () {
                var svg = document.querySelector('svg[data-marpit-svg]');
                if (!svg) { return [window.innerWidth, window.innerHeight]; }
                var box = svg.getBoundingClientRect();
                var viewBox = svg.viewBox.baseVal;
                var scale = Math.min(box.width / viewBox.width, box.height / viewBox.height);
                var width = viewBox.width * scale, height = viewBox.height * scale;
                return [window.innerWidth, window.innerHeight, box.left + (box.width - width) / 2, box.top + (box.height - height) / 2, width, height];
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

    /// Runs inside marp-cli's slide overview, which is an iframe of the same
    /// deck in `?view=overview` mode (and does nothing in any other frame).
    /// Relays the slide the presenter picks to the slideshow page with
    /// postMessage, and takes the current slide from it so the grid starts
    /// on the right one; see the message listener in `deckHookScript`.
    private static let overviewFrameScript = """
        (function () {
            if (window === window.top || !/[?&]view=overview/.test(location.search)) { return; }
            var originalDefine = Object.defineProperty;
            Object.defineProperty = function (target, property, descriptor) {
                var result = originalDefine.apply(this, arguments);
                if (property === 'syncKey' && target && typeof target.slide === 'function') {
                    Object.defineProperty = originalDefine;
                    window.__imarpOverviewDeck = target;
                }
                return result;
            };
            function slideIndex(element) {
                var svg = element && element.closest && element.closest('svg[data-marpit-svg]');
                if (!svg) { return -1; }
                return Array.prototype.indexOf.call(document.querySelectorAll('svg[data-marpit-svg]'), svg);
            }
            function pick(index) {
                if (index >= 0) { window.parent.postMessage({ imarpOverviewSelect: index }, '*'); }
            }
            document.addEventListener('click', function (event) { pick(slideIndex(event.target)); }, true);
            document.addEventListener('keydown', function (event) {
                if (event.key === 'Enter' || event.key === ' ') { pick(slideIndex(document.activeElement)); }
            }, true);
            window.addEventListener('message', function (event) {
                var data = event.data;
                var deck = window.__imarpOverviewDeck;
                if (data && typeof data.imarpCurrentSlide === 'number' && deck) {
                    deck.slide(data.imarpCurrentSlide, { fragment: -1 });
                }
            });
            window.addEventListener('load', function () {
                window.parent.postMessage({ imarpOverviewReady: true }, '*');
            });
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
            WKUserScript(source: Self.overviewFrameScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideChromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let messageProxy = WeakScriptMessageHandler()
        configuration.userContentController.add(messageProxy, name: "imarpPosition")
        configuration.userContentController.add(messageProxy, name: "imarpTransition")
        configuration.userContentController.add(messageProxy, name: "imarpOverview")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        messageProxy.target = self

        backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        // Otherwise the page is inset by the window's safe area (overscan on
        // some external displays), shifting the slide away from where
        // `SlideCanvasView.slideRect(in:aspectRatio:)` says it is and so
        // putting ink and the pointer off target.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
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
        if isOverviewOpen {
            isOverviewOpen = false
            onOverviewChanged?(false)
        }
        lastViewportSize = .zero
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

    override func layoutSubviews() {
        super.layoutSubviews()
        updateViewport()
    }

    private func updateViewport() {
        let size = webView.bounds.size
        guard didFinishInitialLoad, size.width > 0, size.height > 0, size != lastViewportSize else { return }
        lastViewportSize = size
        webView.evaluateJavaScript("window.__imarpSetViewport(\(Int(size.width.rounded())), \(Int(size.height.rounded())))") { [weak self] _, _ in
            self?.logGeometry()
        }
    }

    private func logGeometry() {
        #if DEBUG
        let bounds = webView.bounds.size
        webView.evaluateJavaScript("window.__imarpGeometry()") { [weak self] result, _ in
            let values = (result as? [Double])?.map { String(format: "%.1f", $0) }.joined(separator: ", ") ?? "?"
            self?.log("geometry view=\(bounds) page[innerW, innerH, slideX, slideY, slideW, slideH]=[\(values)]")
        }
        #endif
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

    /// Opens or closes Marp's slide overview. Only decks rendered with a
    /// marp-cli 4.5+ shell have one; on anything older this does nothing.
    func setOverviewOpen(_ open: Bool) {
        guard didFinishInitialLoad else { return }
        webView.evaluateJavaScript("window.__imarpToggleOverview(\(open))") { [weak self] result, _ in
            if (result as? Bool) != true { self?.log("deck has no slide overview") }
        }
    }

    fileprivate func overviewReported(open: Bool) {
        log("overview \(open ? "opened" : "closed")")
        isOverviewOpen = open
        // Picking a slide in the overview moves the deck on its own, which
        // must not be undone as an unrequested move.
        if open {
            holdPosition = nil
            targetPosition = nil
        }
        onOverviewChanged?(open)
    }

    fileprivate func transitionReported(active: Bool) {
        log("transition \(active ? "started" : "finished")")
        onTransitionActiveChanged?(active)
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
        if message.name == "imarpOverview" {
            guard let open = message.body as? Bool else { return }
            target?.overviewReported(open: open)
            return
        }
        if message.name == "imarpTransition" {
            guard let active = message.body as? Bool else { return }
            target?.transitionReported(active: active)
            return
        }
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
        updateViewport()
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
        didSet { updateInkLayer() }
    }

    /// The presenter's hide-ink toggle.
    var annotationsHidden = false {
        didSet { updateInkLayer() }
    }

    /// While Marp's slide overview is up, the ink layer gets out of the way:
    /// it belongs to one slide, not to the grid, and taps have to reach the
    /// overview underneath rather than draw.
    private var overviewShowing = false {
        didSet { updateInkLayer() }
    }

    var isOverviewOpen: Bool { contentView.isOverviewOpen }
    var onOverviewChanged: ((Bool) -> Void)?

    private func updateInkLayer() {
        canvasView.isHidden = annotationsHidden || overviewShowing
        canvasView.isUserInteractionEnabled = isDrawingEnabled && !overviewShowing
    }

    func setOverviewOpen(_ open: Bool) {
        contentView.setOverviewOpen(open)
    }

    var onDrawingChanged: ((PKDrawing) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        pointerDotView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.backgroundColor = .clear
        // PKCanvasView is a scroll view, and strokes are stored in its
        // content coordinates. Left to itself it can pick up an automatic
        // content inset (and a matching scroll offset), which silently
        // shifts every stored stroke relative to the slide underneath, so
        // the same ink then lands a few points off on the other screen.
        // Pin content coordinates to the view's own.
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.isScrollEnabled = false
        // .anyInput would always allow finger drawing regardless of the
        // user's system-wide "Only Draw with Apple Pencil" setting; .default
        // respects that setting like other PencilKit apps do.
        canvasView.drawingPolicy = .default
        canvasView.delegate = self
        contentView.onTransitionActiveChanged = { [weak self] active in
            self?.setInkSuppressedForTransition(active)
        }
        contentView.onOverviewChanged = { [weak self] open in
            guard let self else { return }
            overviewShowing = open
            onOverviewChanged?(open)
        }

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
        guard let transform = Self.inkTransform(from: sourceSize, to: bounds.size, aspectRatio: aspectRatio) else {
            setDrawing(drawing)
            return
        }
        setDrawing(drawing.transformed(using: transform))
    }

    /// Maps ink drawn on a canvas of `sourceSize` onto one of
    /// `destinationSize`, slide rect to slide rect, so a stroke stays over the
    /// same part of the slide. nil if either size is empty.
    static func inkTransform(from sourceSize: CGSize, to destinationSize: CGSize, aspectRatio: CGFloat) -> CGAffineTransform? {
        let source = slideRect(in: sourceSize, aspectRatio: aspectRatio)
        let destination = slideRect(in: destinationSize, aspectRatio: aspectRatio)
        guard source.width > 0, destination.width > 0 else { return nil }
        let scale = destination.width / source.width
        var transform = CGAffineTransform(translationX: destination.minX, y: destination.minY)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -source.minX, y: -source.minY)
        return transform
    }

    private var inkRevealFailsafe: DispatchWorkItem?

    /// Ink belongs to one slide, so while a transition animates between two
    /// slides it's hidden (the old slide's ink shouldn't ride along on the
    /// outgoing slide, nor the new slide's appear before it has arrived),
    /// then faded back in. Done with alpha rather than by swapping in an
    /// empty drawing: on the iPad that would count as an edit and save over
    /// the slide's ink. Independent of the hide-annotations toggle, which
    /// uses isHidden.
    private func setInkSuppressedForTransition(_ suppressed: Bool) {
        inkRevealFailsafe?.cancel()
        inkRevealFailsafe = nil
        if suppressed {
            canvasView.layer.removeAllAnimations()
            canvasView.alpha = 0
            // Never leave the ink hidden if the end of the transition is
            // somehow never reported.
            let failsafe = DispatchWorkItem { [weak self] in self?.setInkSuppressedForTransition(false) }
            inkRevealFailsafe = failsafe
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: failsafe)
        } else if canvasView.alpha < 1 {
            UIView.animate(withDuration: 0.2) { self.canvasView.alpha = 1 }
        }
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

    override func layoutSubviews() {
        super.layoutSubviews()
        if canvasView.contentOffset != .zero { canvasView.contentOffset = .zero }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        #if DEBUG
        print("[imarp ink] canvas frame=\(canvasView.frame) offset=\(canvasView.contentOffset) inset=\(canvasView.adjustedContentInset) drawing bounds=\(canvasView.drawing.bounds)")
        #endif
        onDrawingChanged?(canvasView.drawing)
    }
}
