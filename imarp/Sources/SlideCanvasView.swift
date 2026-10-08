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
                        // Leaving a slide stops its videos/audio, so sound
                        // never carries on from a slide that's gone.
                        if (window.__imarpPosition && window.__imarpPosition.index !== event.index) {
                            document.querySelectorAll('video, audio').forEach(function (media) { media.pause(); });
                            document.querySelectorAll('[data-imarp-filled]').forEach(function (media) { window.__imarpFill(media, false); });
                        }
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
                meta.setAttribute('content', 'width=' + width + ', height=' + height + ', initial-scale=1, minimum-scale=1, maximum-scale=5, user-scalable=yes');
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
            // The presenter's fingers use the slide's own HTML directly (the
            // ink layer passes them through). What they do is reported to the
            // app so the external display can do the same; elements are
            // identified by their position among the active slide's
            // interactive elements, which is the same on both screens.
            var interactiveSelector = 'a[href], video, audio, button, summary, input, select, label, [onclick]';
            function activeInteractive() {
                var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
                return active ? Array.prototype.slice.call(active.querySelectorAll(interactiveSelector)) : [];
            }
            function post(name, body) {
                var handler = window.webkit && window.webkit.messageHandlers[name];
                if (handler) { handler.postMessage(body); }
            }
            // Videos and audio: native controls, mirrored. Media events don't
            // bubble, so listen in the capture phase. Sound comes from the
            // external display when there is one (__imarpMuted, set by the
            // app), so the iPad's copy plays muted.
            window.__imarpMuted = false;
            function reportMedia(event) {
                var media = event.target;
                if (!media || typeof media.play !== 'function') { return; }
                if (event.type === 'play') { media.muted = window.__imarpMuted; }
                var index = activeInteractive().indexOf(media);
                if (index < 0) { return; }
                var body = { index: index, playing: !media.paused, time: media.currentTime, rate: media.playbackRate };
                if (event.type === 'webkitbeginfullscreen') { body.fullscreen = true; }
                if (event.type === 'webkitendfullscreen') { body.fullscreen = false; }
                post('imarpMedia', body);
            }
            ['play', 'pause', 'seeked', 'ratechange', 'webkitbeginfullscreen', 'webkitendfullscreen'].forEach(function (type) {
                document.addEventListener(type, reportMedia, true);
            });
            // Other controls (buttons, <details>...): report real taps (not
            // the app's own mirrored clicks). Links aren't mirrored: in-deck
            // links move the deck, which the external display follows anyway.
            document.addEventListener('click', function (event) {
                if (!event.isTrusted || !event.target || !event.target.closest) { return; }
                var target = event.target.closest(interactiveSelector);
                if (!target) { return; }
                var tag = target.tagName.toLowerCase();
                if (tag === 'a' || tag === 'video' || tag === 'audio') { return; }
                var index = activeInteractive().indexOf(target);
                if (index >= 0) { post('imarpControl', index); }
            }, true);
            // The Pencil belongs to the ink (drawing, or the laser pointer),
            // never to the page: keep its touches from Marp's swipe (a Pencil
            // stroke must not change slides) and from turning into taps on
            // links or controls. WebKit marks them touchType 'stylus'.
            ['touchstart', 'touchmove', 'touchend'].forEach(function (type) {
                window.addEventListener(type, function (event) {
                    var touches = event.changedTouches || [];
                    for (var i = 0; i < touches.length; i++) {
                        if (touches[i].touchType === 'stylus') {
                            event.stopPropagation();
                            if (event.cancelable) { event.preventDefault(); }
                            return;
                        }
                    }
                }, { capture: true, passive: false });
            });
            // While the page is pinch-zoomed, a one-finger drag should pan,
            // not swipe to another slide: keep touches from Marp's own swipe
            // handling (WebKit's panning doesn't depend on them).
            ['touchstart', 'touchmove', 'touchend'].forEach(function (type) {
                window.addEventListener(type, function (event) {
                    if (window.visualViewport && window.visualViewport.scale > 1.01) { event.stopPropagation(); }
                }, { capture: true, passive: true });
            });
            window.__imarpActivate = function (index) {
                var element = activeInteractive()[index];
                if (element) { element.click(); }
                return !!element;
            };
            // Applies what the other screen's media did.
            window.__imarpMedia = function (index, playing, time, rate, muted) {
                var media = activeInteractive()[index];
                if (!media || typeof media.play !== 'function') { return null; }
                media.muted = muted;
                if (typeof rate === 'number' && rate > 0) { media.playbackRate = rate; }
                if (typeof time === 'number' && Math.abs(media.currentTime - time) > 0.3) { media.currentTime = time; }
                if (playing) { media.play().catch(function () {}); } else { media.pause(); }
                return true;
            };
            // A slide video filling the whole slide (on the external display,
            // the whole screen): what the external display shows while the
            // presenter has the video in iOS's full-screen player on the iPad.
            window.__imarpFill = function (media, on) {
                if (on && !media.hasAttribute('data-imarp-filled')) {
                    media.setAttribute('data-imarp-filled', media.getAttribute('style') || '');
                    media.style.cssText = 'position:absolute; left:0; top:0; width:100%; height:100%; ' +
                        'object-fit:contain; background:#000; z-index:1000; margin:0;';
                } else if (!on && media.hasAttribute('data-imarp-filled')) {
                    media.setAttribute('style', media.getAttribute('data-imarp-filled'));
                    media.removeAttribute('data-imarp-filled');
                }
            };
            // on: true/false to set, or null to toggle. Returns the result.
            window.__imarpMediaFill = function (index, on) {
                var media = activeInteractive()[index];
                if (!media || typeof media.play !== 'function') { return null; }
                if (on === null) { on = !media.hasAttribute('data-imarp-filled'); }
                window.__imarpFill(media, on);
                return on;
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
        // Slide videos play in place, and the external display can start one
        // without a touch of its own (it mirrors taps made on the iPad).
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
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
        configuration.userContentController.add(messageProxy, name: "imarpMedia")
        configuration.userContentController.add(messageProxy, name: "imarpControl")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        messageProxy.target = self
        // The presenter pinch-zooms the page itself; report it so the ink
        // canvas (and the external display) can follow.
        let reportZoom: (UIScrollView) -> Void = { [weak self] scrollView in
            self?.onPageZoomChanged?(scrollView.zoomScale, scrollView.contentOffset)
        }
        zoomObservations = [
            webView.scrollView.observe(\.contentOffset) { scrollView, _ in reportZoom(scrollView) },
            webView.scrollView.observe(\.zoomScale) { scrollView, _ in reportZoom(scrollView) },
        ]

        backgroundColor = .black
        // Scrolling only ever happens while pinch-zoomed in (at normal size
        // the page is exactly the view's size), and then it's the pan.
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        webView.scrollView.bouncesZoom = false
        // Long-pressing a link shouldn't pop up a preview mid-talk.
        webView.allowsLinkPreview = false
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
    /// The presenter played, paused, seeked, changed speed or toggled full
    /// screen on one of the current slide's videos (native controls), as
    /// reported by the page: index among the slide's interactive elements,
    /// playing, time, rate, and the new full-screen state if that changed.
    var onMediaEvent: ((Int, Bool, Double, Double, Bool?) -> Void)?

    /// The presenter tapped one of the current slide's other HTML controls.
    var onControlActivated: ((Int) -> Void)?

    /// The page's own (pinch) zoom and scroll position changed.
    var onPageZoomChanged: ((CGFloat, CGPoint) -> Void)?
    private var zoomObservations: [NSKeyValueObservation] = []

    /// Whether this screen's slide videos play muted (the iPad's, while the
    /// external display carries the sound).
    var mutesMedia = false {
        didSet { applyMediaMuting() }
    }

    private func applyMediaMuting() {
        guard didFinishInitialLoad else { return }
        webView.evaluateJavaScript("""
            window.__imarpMuted = \(mutesMedia);
            document.querySelectorAll('video, audio').forEach(function (m) { m.muted = \(mutesMedia); });
            """)
    }

    func activateControl(index: Int) {
        webView.evaluateJavaScript("window.__imarpActivate(\(index))")
    }

    /// Matches one of the current slide's videos to the other screen's.
    func setMedia(index: Int, playing: Bool, time: Double?, rate: Double?, muted: Bool) {
        let timeJS = time.map { String($0) } ?? "null"
        let rateJS = rate.map { String($0) } ?? "null"
        webView.evaluateJavaScript("window.__imarpMedia(\(index), \(playing), \(timeJS), \(rateJS), \(muted))")
    }

    fileprivate func mediaReported(_ info: [String: Any]) {
        guard let index = info["index"] as? Int, let playing = info["playing"] as? Bool else { return }
        let time = (info["time"] as? Double) ?? 0
        let rate = (info["rate"] as? Double) ?? 1
        log("media \(index) playing=\(playing) time=\(time) rate=\(rate) fullscreen=\(String(describing: info["fullscreen"]))")
        onMediaEvent?(index, playing, time, rate, info["fullscreen"] as? Bool)
    }

    fileprivate func controlReported(_ index: Int) {
        log("control \(index) tapped")
        onControlActivated?(index)
    }

    /// Makes a slide video fill the slide (`on` nil toggles); reports the
    /// resulting state.
    func setMediaFilled(index: Int, on: Bool?, completion: ((Bool) -> Void)? = nil) {
        let onJS = on.map { $0 ? "true" : "false" } ?? "null"
        webView.evaluateJavaScript("window.__imarpMediaFill(\(index), \(onJS))") { result, _ in
            if let filled = result as? Bool { completion?(filled) }
        }
    }

    /// Zooms the page natively (WebKit re-renders it sharp at the new scale)
    /// to match the ink canvas above it.
    func setZoom(scale: CGFloat, offset: CGPoint) {
        let scrollView = webView.scrollView
        if abs(scrollView.zoomScale - scale) > 0.0001 {
            scrollView.setZoomScale(scale, animated: false)
        }
        if scrollView.contentOffset != offset {
            scrollView.contentOffset = offset
        }
    }

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
        if message.name == "imarpMedia" {
            if let info = message.body as? [String: Any] { target?.mediaReported(info) }
            return
        }
        if message.name == "imarpControl" {
            if let index = message.body as? Int { target?.controlReported(index) }
            return
        }
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
    /// Tapped links: within the deck (`#3`) they move it as usual; anything
    /// else opens in its own app (Safari...) rather than replacing the deck.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              navigationAction.targetFrame?.isMainFrame ?? true,
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var current = webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        target?.fragment = nil
        current?.fragment = nil
        target?.query = nil
        current?.query = nil
        if let target, let current, target == current {
            decisionHandler(.allow)
            return
        }
        log("opening link \(url) outside the deck")
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

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
        applyMediaMuting()
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
    /// it belongs to one slide, not to the grid.
    private var overviewShowing = false {
        didSet { updateInkLayer() }
    }

    /// Set while the Pencil drives the laser pointer instead of drawing.
    var isDrawingSuspended = false {
        didSet { updateInkLayer() }
    }

    var isOverviewOpen: Bool { contentView.isOverviewOpen }
    var onOverviewChanged: ((Bool) -> Void)?

    private func updateInkLayer() {
        canvasView.isHidden = annotationsHidden || overviewShowing
        canvasView.drawingGestureRecognizer.isEnabled =
            isDrawingEnabled && !annotationsHidden && !overviewShowing && !isDrawingSuspended
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
        // Zoom: the presenter pinches the page itself (WebKit zooms it
        // natively and sharp), and the canvas is zoomed to match in
        // followPageZoom. Strokes stay sharp and keep being stored in
        // unzoomed content coordinates, so saved ink, the external display's
        // rescaling and PDF export are all unaffected.
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = Self.maximumZoom
        canvasView.bounces = false
        canvasView.bouncesZoom = false
        canvasView.isScrollEnabled = false
        // Touch model: fingers belong to the slide's own HTML (links, video
        // controls, Marp's swipes, pinch-zoom), the Pencil to the ink. iOS
        // doesn't say finger or Pencil when it picks which view gets a touch,
        // so the ink layer takes no touches itself; PencilKit's drawing
        // gesture is moved up to this view instead, where (as a gesture on
        // an ancestor) it still sees every touch over the slide, takes the
        // ones that draw, and cancels them for the page. Which ones draw
        // follows the tool picker's "Draw with Finger" setting (.default):
        // with it off, only the Pencil draws and fingers pass to the page
        // untouched. (PencilKit's lasso and ruler need touches on the canvas
        // itself, so they don't work here; pens and the eraser do.)
        canvasView.drawingPolicy = .default
        canvasView.isUserInteractionEnabled = false
        addGestureRecognizer(canvasView.drawingGestureRecognizer)
        canvasView.delegate = self
        contentView.onTransitionActiveChanged = { [weak self] active in
            self?.setInkSuppressedForTransition(active)
        }
        contentView.onOverviewChanged = { [weak self] open in
            guard let self else { return }
            overviewShowing = open
            onOverviewChanged?(open)
        }
        // Pinch-zoom happens natively in the page; the ink follows it.
        contentView.onPageZoomChanged = { [weak self] scale, offset in
            self?.followPageZoom(scale: scale, offset: offset)
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
        // Slide content coordinates, then onto the screen through the zoom.
        let content = CGPoint(
            x: rect.minX + normalizedPoint.x * rect.width,
            y: rect.minY + normalizedPoint.y * rect.height
        )
        let zoom = canvasView.zoomScale
        let offset = canvasView.contentOffset
        pointerDotView.show(at: CGPoint(x: content.x * zoom - offset.x, y: content.y * zoom - offset.y))
    }

    // MARK: Zoom

    static let maximumZoom: CGFloat = 5

    var isZoomed: Bool { canvasView.zoomScale > 1.001 }

    /// Called with the part of the slide currently visible, normalized to the
    /// slide (0...1 in each direction), or nil when not zoomed in.
    var onVisibleRegionChanged: ((CGRect?) -> Void)?

    /// Where `recognizer` is, in the unzoomed page/canvas coordinates that
    /// ink strokes and the page's own layout use.
    func pagePoint(for recognizer: UIGestureRecognizer) -> CGPoint {
        let location = recognizer.location(in: canvasView)
        let zoom = canvasView.zoomScale
        return CGPoint(x: location.x / zoom, y: location.y / zoom)
    }

    /// `pagePoint(for:)` normalized to the slide (0...1 when over it).
    func normalizedSlidePoint(for recognizer: UIGestureRecognizer) -> CGPoint? {
        let rect = Self.slideRect(in: bounds.size, aspectRatio: PresentationStore.shared.slideAspectRatio)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = pagePoint(for: recognizer)
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    func resetZoom(animated: Bool) {
        guard isZoomed else { return }
        canvasView.setZoomScale(1, animated: animated)
    }

    /// Zooms so that `region` (normalized to the slide, as reported by the
    /// other screen's onVisibleRegionChanged) fills this canvas as nearly as
    /// its shape allows, centered on it. nil returns to the whole slide.
    func showSlideRegion(_ region: CGRect?) {
        guard let region else {
            resetZoom(animated: false)
            return
        }
        let slide = Self.slideRect(in: bounds.size, aspectRatio: PresentationStore.shared.slideAspectRatio)
        guard slide.width > 0, region.width > 0, region.height > 0 else { return }
        let target = CGRect(
            x: slide.minX + region.minX * slide.width,
            y: slide.minY + region.minY * slide.height,
            width: region.width * slide.width,
            height: region.height * slide.height
        )
        let zoom = min(max(min(bounds.width / target.width, bounds.height / target.height), 1), Self.maximumZoom)
        let visible = CGSize(width: bounds.width / zoom, height: bounds.height / zoom)
        let origin = CGPoint(
            x: min(max(target.midX - visible.width / 2, 0), bounds.width - visible.width),
            y: min(max(target.midY - visible.height / 2, 0), bounds.height - visible.height)
        )
        canvasView.setZoomScale(zoom, animated: false)
        canvasView.contentOffset = CGPoint(x: origin.x * zoom, y: origin.y * zoom)
    }

    private func followPageZoom(scale: CGFloat, offset: CGPoint) {
        if abs(canvasView.zoomScale - scale) > 0.0001 {
            canvasView.setZoomScale(scale, animated: false)
        }
        if abs(canvasView.contentOffset.x - offset.x) > 0.5 || abs(canvasView.contentOffset.y - offset.y) > 0.5 {
            canvasView.contentOffset = offset
        }
    }

    private func zoomDidChange() {
        let zoom = canvasView.zoomScale
        let offset = canvasView.contentOffset
        contentView.setZoom(scale: zoom, offset: offset)
        guard isZoomed else {
            onVisibleRegionChanged?(nil)
            return
        }
        let slide = Self.slideRect(in: bounds.size, aspectRatio: PresentationStore.shared.slideAspectRatio)
        guard slide.width > 0, slide.height > 0 else { return }
        let visible = CGRect(x: offset.x / zoom, y: offset.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
        onVisibleRegionChanged?(CGRect(
            x: (visible.minX - slide.minX) / slide.width,
            y: (visible.minY - slide.minY) / slide.height,
            width: visible.width / slide.width,
            height: visible.height / slide.height
        ))
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        zoomDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        zoomDidChange()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At normal size the canvas's content is exactly its bounds (no
        // scrolling, strokes in the view's own coordinates); zooming needs a
        // content size to scale from.
        if !isZoomed {
            if canvasView.contentSize != bounds.size { canvasView.contentSize = bounds.size }
            if canvasView.contentOffset != .zero { canvasView.contentOffset = .zero }
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        #if DEBUG
        print("[imarp ink] canvas frame=\(canvasView.frame) offset=\(canvasView.contentOffset) inset=\(canvasView.adjustedContentInset) drawing bounds=\(canvasView.drawing.bounds)")
        #endif
        onDrawingChanged?(canvasView.drawing)
    }
}
