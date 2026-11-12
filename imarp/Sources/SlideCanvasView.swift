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
                            if (window.__imarpShowHighlight) { window.__imarpShowHighlight(null); }
                            document.querySelectorAll('video, audio').forEach(function (media) { media.pause(); });
                            document.querySelectorAll('[data-imarp-filled]').forEach(function (media) { window.__imarpFill(media, false); });
                        }
                        window.__imarpPosition = { index: event.index, fragment: event.fragmentIndex };
                        // Third value: 1 if the presenter's own touch, click or
                        // key press (e.g. Marp's swipe) just caused this move.
                        var byPresenter = Date.now() - window.__imarpPresenterInputAt < 1000 ? 1 : 0;
                        window.webkit.messageHandlers.imarpPosition.postMessage([event.index, event.fragmentIndex, byPresenter]);
                    });
                }
                return result;
            };
            // When the presenter last touched, clicked or pressed a key on the
            // page itself (the external display's page never gets any), so a
            // move that follows is known to be theirs, not bespoke's own.
            window.__imarpPresenterInputAt = 0;
            ['touchend', 'mouseup', 'keydown'].forEach(function (type) {
                window.addEventListener(type, function (event) {
                    if (event.isTrusted) { window.__imarpPresenterInputAt = Date.now(); }
                }, true);
            });
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
            // Where the current slide's iframes are on the page, in the
            // unzoomed view's points (CSS pixels from the page's top left),
            // so a Pencil touch on one can work its controls instead of
            // drawing (see SlideCanvasView.pencilOnFrame). The app takes the
            // zoom out of the touch's position, as the page's own idea of its
            // pinch zoom (visualViewport) can lag behind or miss updates.
            // Sent whenever it changes: slide changes, resize.
            var frameRectsSent = '';
            function reportFrameRects() {
                var scrollX = window.scrollX || 0, scrollY = window.scrollY || 0;
                var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
                var rects = [];
                if (active && !window.__imarpOverviewOpen) {
                    active.querySelectorAll('iframe').forEach(function (frame) {
                        var r = frame.getBoundingClientRect();
                        if (r.width > 0 && r.height > 0) {
                            rects.push([r.left + scrollX, r.top + scrollY, r.width, r.height].map(Math.round));
                        }
                    });
                }
                var json = JSON.stringify(rects);
                if (json !== frameRectsSent) {
                    frameRectsSent = json;
                    post('imarpFrames', rects);
                }
            }
            setInterval(reportFrameRects, 400);
            if (window.visualViewport) {
                window.visualViewport.addEventListener('resize', reportFrameRects);
                window.visualViewport.addEventListener('scroll', reportFrameRects);
            }
            window.addEventListener('resize', reportFrameRects);
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
            // app), so the iPad's copy plays muted. While playing, the
            // position is also reported every couple of seconds, so the
            // other copy is pulled back into step if it drifts.
            window.__imarpMuted = false;
            var lastTimeReport = 0;
            function reportMedia(event) {
                var media = event.target;
                if (!media || typeof media.play !== 'function') { return; }
                if (event.type === 'timeupdate') {
                    if (media.paused || Date.now() - lastTimeReport < 2000) { return; }
                }
                lastTimeReport = Date.now();
                if (event.type === 'play') { media.muted = window.__imarpMuted; }
                var index = activeInteractive().indexOf(media);
                if (index < 0) { return; }
                var body = { index: index, playing: !media.paused, time: media.currentTime, rate: media.playbackRate };
                if (event.type === 'webkitbeginfullscreen') { body.fullscreen = true; }
                if (event.type === 'webkitendfullscreen') { body.fullscreen = false; }
                post('imarpMedia', body);
            }
            ['play', 'pause', 'seeked', 'ratechange', 'timeupdate', 'webkitbeginfullscreen', 'webkitendfullscreen'].forEach(function (type) {
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
                // Form controls are mirrored by value instead (see
                // formInputScript); a mirrored click would toggle them twice.
                if (tag === 'input' || tag === 'select' || tag === 'label') { return; }
                var index = activeInteractive().indexOf(target);
                if (index >= 0) { post('imarpControl', index); }
            }, true);
            // The Pencil belongs to the ink (drawing, or the laser pointer),
            // never to the page: keep its touches from Marp's swipe (a Pencil
            // stroke must not change slides) and from turning into taps on
            // links or controls. WebKit marks them touchType 'stylus'.
            function pageLog(text) { post('imarpLog', text); }
            ['touchstart', 'touchmove', 'touchend'].forEach(function (type) {
                window.addEventListener(type, function (event) {
                    var touches = event.changedTouches || [];
                    for (var i = 0; i < touches.length; i++) {
                        if (touches[i].touchType === 'stylus') {
                            if (type !== 'touchmove') { pageLog('Pencil ' + type + ' reached the page (blocked)'); }
                            event.stopPropagation();
                            if (event.cancelable) { event.preventDefault(); }
                            return;
                        }
                    }
                }, { capture: true, passive: false });
            });
            // While the page is pinch-zoomed, a one-finger drag should pan,
            // not swipe to another slide: keep touches from Marp's own swipe
            // handling (WebKit's panning doesn't depend on them). The same
            // for a Mac trackpad's two-finger scrolling (wheel events), which
            // Marp would otherwise also turn into a slide change. Whether it's
            // zoomed comes from the app (__imarpZoomed), which reads WebKit's
            // own zoom: the page's visualViewport.scale can miss its last
            // update after a quick pinch out and stay above 1, which would
            // leave swipes switched off until the next zoom.
            window.__imarpZoomed = false;
            ['touchstart', 'touchmove', 'touchend', 'wheel'].forEach(function (type) {
                window.addEventListener(type, function (event) {
                    if (window.__imarpZoomed) {
                        if (type === 'touchstart') {
                            pageLog('zoomed, so this touch is kept from the Marp swipe');
                        }
                        event.stopPropagation();
                    }
                }, { capture: true, passive: true });
            });
            // Highlighter (on a Mac, where __imarpHighlighter is set by the
            // app before the page loads): a click-and-drag over a slide's text
            // marks it, like a highlighter pen, on both screens; a plain click
            // or a change of slide clears it. WebKit's own text selection
            // can't be used: on Marp's scaled slides it picks up text well
            // away from the pointer. Here the text under the pointer comes
            // from caretRangeFromPoint (the same position clicks use, which
            // is right), and the mark is drawn in the text itself with the
            // CSS Custom Highlight API, so no position needs converting. The
            // range is passed to the other screen as paths from the slide's
            // <svg> to its two ends, which are the same on both screens.
            var highlightShown = false;
            var highlightRange = null;
            // WebKit doesn't repaint text a highlight no longer covers, so the
            // old mark would linger beside the new one: nudge its text into
            // repainting.
            function repaintRange(range) {
                var element = range && range.commonAncestorContainer;
                if (element && element.nodeType === 3) { element = element.parentNode; }
                if (!element || !element.style) { return; }
                var opacity = element.style.opacity;
                element.style.opacity = '0.999';
                requestAnimationFrame(function () { element.style.opacity = opacity; });
            }
            function slideSVGs() { return document.querySelectorAll('svg[data-marpit-svg]'); }
            function pathFrom(root, node) {
                var path = [];
                while (node && node !== root) {
                    var parent = node.parentNode;
                    if (!parent) { return null; }
                    path.unshift(Array.prototype.indexOf.call(parent.childNodes, node));
                    node = parent;
                }
                return node === root ? path : null;
            }
            function nodeAt(root, path) {
                var node = root;
                for (var i = 0; node && i < path.length; i++) { node = node.childNodes[path[i]]; }
                return node || null;
            }
            function ensureHighlightStyle() {
                if (document.getElementById('imarp-highlight-style') || !document.head) { return; }
                var style = document.createElement('style');
                style.id = 'imarp-highlight-style';
                style.textContent = '::highlight(imarp) { background-color: rgba(255, 221, 0, 0.6); }' +
                    // WebKit's own selection, cleared as soon as it appears
                    // on a slide (see the highlighter), shouldn't flash first.
                    (window.__imarpHighlighter ? ' svg[data-marpit-svg] ::selection { background-color: transparent; }' : '');
                document.head.appendChild(style);
            }
            // Shows a highlight ({ slide, start: [path, offset], end: [path,
            // offset] }), or clears it (null).
            window.__imarpShowHighlight = function (mark) {
                if (!window.CSS || !CSS.highlights || typeof Highlight === 'undefined') { return; }
                CSS.highlights.delete('imarp');
                repaintRange(highlightRange);
                highlightRange = null;
                if (!mark) {
                    highlightShown = false;
                    return;
                }
                var root = slideSVGs()[mark.slide];
                var startNode = root && nodeAt(root, mark.start[0]);
                var endNode = root && nodeAt(root, mark.end[0]);
                if (!startNode || !endNode) { return; }
                var range = document.createRange();
                try {
                    range.setStart(startNode, mark.start[1]);
                    range.setEnd(endNode, mark.end[1]);
                } catch (error) { return; }
                ensureHighlightStyle();
                CSS.highlights.set('imarp', new Highlight(range));
                highlightRange = range;
                highlightShown = true;
            };
            if (window.__imarpHighlighter) {
                var marking = null;
                var caretAt = function (x, y) {
                    var range = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
                    return range ? [range.startContainer, range.startOffset] : null;
                };
                var markBetween = function (svg, a, b) {
                    if (!svg.contains(a[0]) || !svg.contains(b[0])) { return null; }
                    var probe = document.createRange();
                    probe.setStart(a[0], a[1]);
                    probe.collapse(true);
                    var order = probe.comparePoint(b[0], b[1]);
                    if (order === 0) { return null; }
                    if (order < 0) { var swap = a; a = b; b = swap; }
                    var startPath = pathFrom(svg, a[0]), endPath = pathFrom(svg, b[0]);
                    if (!startPath || !endPath) { return null; }
                    return {
                        slide: Array.prototype.indexOf.call(slideSVGs(), svg),
                        start: [startPath, a[1]], end: [endPath, b[1]],
                    };
                };
                // Keep WebKit's own selection off the slides: a mouse press on
                // a slide's text is cancelled (which is what starts a
                // selection; presses on links and controls are left alone),
                // and a selection that appears anyway is cleared. Not with
                // user-select: none, as WebKit then won't draw the highlight
                // either.
                if (document.head) { ensureHighlightStyle(); }
                else { document.addEventListener('DOMContentLoaded', ensureHighlightStyle); }
                document.addEventListener('mousedown', function (event) {
                    if (event.button !== 0 || !onSlide(event.target)) { return; }
                    if (event.target.closest && event.target.closest(interactiveSelector)) { return; }
                    event.preventDefault();
                }, true);
                var onSlide = function (node) {
                    var element = node && node.nodeType === 3 ? node.parentNode : node;
                    return !!(element && element.closest && element.closest('svg[data-marpit-svg]'));
                };
                document.addEventListener('selectstart', function (event) {
                    if (onSlide(event.target)) { event.preventDefault(); }
                }, true);
                document.addEventListener('selectionchange', function () {
                    var selection = document.getSelection();
                    if (selection && selection.rangeCount && onSlide(selection.anchorNode)) { selection.removeAllRanges(); }
                });
                // A double-click highlights the word under it.
                var lastClick = { at: 0, x: 0, y: 0 };
                var wordAt = function (caret) {
                    if (!caret || caret[0].nodeType !== 3) { return null; }
                    var text = caret[0].data, start = caret[1], end = caret[1];
                    var isWord = function (c) { return /[\\p{L}\\p{N}_'’-]/u.test(c); };
                    while (start > 0 && isWord(text[start - 1])) { start--; }
                    while (end < text.length && isWord(text[end])) { end++; }
                    return end > start ? [[caret[0], start], [caret[0], end]] : null;
                };
                window.addEventListener('pointerdown', function (event) {
                    marking = null;
                    if (event.pointerType === 'pen' || event.button !== 0 || window.__imarpOverviewOpen) { return; }
                    var svg = event.target && event.target.closest && event.target.closest('svg[data-marpit-svg]');
                    if (!svg) { return; }
                    marking = { svg: svg, x: event.clientX, y: event.clientY, start: caretAt(event.clientX, event.clientY), moved: false };
                }, true);
                window.addEventListener('pointermove', function (event) {
                    if (!marking || !marking.start) { return; }
                    if (!marking.moved && Math.abs(event.clientX - marking.x) + Math.abs(event.clientY - marking.y) < 6) { return; }
                    if (!marking.moved) { pageLog('highlighter: marking (' + event.pointerType + ')'); }
                    marking.moved = true;
                    var end = caretAt(event.clientX, event.clientY);
                    var mark = end && markBetween(marking.svg, marking.start, end);
                    if (mark) {
                        window.__imarpShowHighlight(mark);
                        post('imarpHighlight', mark);
                    }
                }, true);
                var finishMarking = function (event) {
                    if (marking && !marking.moved && event.type === 'pointerup') {
                        var now = Date.now();
                        var second = now - lastClick.at < 450 && Math.abs(event.clientX - lastClick.x) + Math.abs(event.clientY - lastClick.y) < 8;
                        lastClick = { at: second ? 0 : now, x: event.clientX, y: event.clientY };
                        var word = second && wordAt(marking.start);
                        var mark = word && markBetween(marking.svg, word[0], word[1]);
                        if (mark) {
                            pageLog('highlighter: word');
                            window.__imarpShowHighlight(mark);
                            post('imarpHighlight', mark);
                        } else if (highlightShown) {
                            window.__imarpShowHighlight(null);
                            post('imarpHighlight', null);
                        }
                    }
                    marking = null;
                };
                window.addEventListener('pointerup', finishMarking, true);
                window.addEventListener('pointercancel', function (event) {
                    if (marking && marking.moved) { pageLog('highlighter: pointer cancelled'); }
                    finishMarking(event);
                }, true);
                // A drag that's marking text isn't a swipe to another slide.
                ['touchmove', 'touchend'].forEach(function (type) {
                    window.addEventListener(type, function (event) {
                        if (marking && marking.moved) { event.stopPropagation(); }
                    }, { capture: true, passive: true });
                });
            }
            // For the log: every finger touch the page gets (start and end
            // only), and the page's own zoom whenever it changes noticeably.
            ['touchstart', 'touchend', 'touchcancel'].forEach(function (type) {
                window.addEventListener(type, function (event) {
                    var touch = (event.changedTouches || [])[0];
                    if (!touch || touch.touchType === 'stylus') { return; }
                    var target = event.target && event.target.tagName ? event.target.tagName.toLowerCase() : '?';
                    pageLog(type + ' (' + event.touches.length + ' down) at ' + Math.round(touch.clientX) + ',' +
                        Math.round(touch.clientY) + ' on ' + target);
                }, { capture: true, passive: true });
            });
            if (window.visualViewport) {
                var loggedScale = 1;
                window.visualViewport.addEventListener('resize', function () {
                    var scale = window.visualViewport.scale;
                    if ((scale > 1.01) !== (loggedScale > 1.01) || Math.abs(scale - loggedScale) >= 0.25) {
                        loggedScale = scale;
                        pageLog('visualViewport scale ' + scale.toFixed(2));
                    }
                });
            }
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
                // Seeking stalls the picture for a moment, so small drift is left alone.
                if (typeof time === 'number' && Math.abs(media.currentTime - time) > 0.5) { media.currentTime = time; }
                if (playing) { media.play().catch(function () {}); } else { media.pause(); }
                return true;
            };
            // On the external display, slide videos are shown by painting
            // each frame into a canvas laid over the (transparent) video: a
            // video's own picture doesn't reach the receiver while the screen
            // is shared over AirPlay, but a canvas, being ordinary page
            // content, does. Switched on by the app (__imarpPaintVideos).
            window.__imarpPaintVideos = false;
            function paintVideos() {
                requestAnimationFrame(paintVideos);
                if (!window.__imarpPaintVideos) { return; }
                document.querySelectorAll('svg[data-marpit-svg].bespoke-marp-active video').forEach(function (video) {
                    var canvas = video.__imarpCanvas;
                    if (!canvas || canvas.parentNode !== video.parentNode) {
                        canvas = document.createElement('canvas');
                        canvas.style.position = 'absolute';
                        canvas.style.pointerEvents = 'none';
                        video.parentNode.insertBefore(canvas, video.nextSibling);
                        video.__imarpCanvas = canvas;
                    }
                    video.style.opacity = '0';
                    var width = video.offsetWidth, height = video.offsetHeight;
                    canvas.style.left = video.offsetLeft + 'px';
                    canvas.style.top = video.offsetTop + 'px';
                    canvas.style.width = width + 'px';
                    canvas.style.height = height + 'px';
                    canvas.style.zIndex = String((parseInt(getComputedStyle(video).zIndex, 10) || 0) + 1);
                    var scale = 2;
                    if (canvas.width !== Math.round(width * scale) || canvas.height !== Math.round(height * scale)) {
                        canvas.width = Math.round(width * scale);
                        canvas.height = Math.round(height * scale);
                    }
                    var context = canvas.getContext('2d');
                    if (video.hasAttribute('data-imarp-filled')) {
                        context.fillStyle = '#000';
                        context.fillRect(0, 0, canvas.width, canvas.height);
                    } else {
                        context.clearRect(0, 0, canvas.width, canvas.height);
                    }
                    if (video.readyState < 2 || !video.videoWidth) { return; }
                    // object-fit: contain, like the video itself.
                    var fit = Math.min(canvas.width / video.videoWidth, canvas.height / video.videoHeight);
                    var drawWidth = video.videoWidth * fit, drawHeight = video.videoHeight * fit;
                    context.drawImage(video, (canvas.width - drawWidth) / 2, (canvas.height - drawHeight) / 2, drawWidth, drawHeight);
                });
            }
            requestAnimationFrame(paintVideos);
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

    /// Runs in every frame, including iframes on slides (e.g. interactive
    /// widgets with sliders), which the deck hook can't see into. Each change
    /// the presenter makes to a form control (a slider, checkbox, menu, text
    /// field) is relayed up to the slideshow page, each frame adding its own
    /// position among its parent's iframes, and from there to the app, so the
    /// external display can set the same control on its copy of the page.
    /// Clicks on buttons inside iframes are relayed the same way. Mirrored
    /// changes are untrusted events, so they're never relayed back.
    private static let formInputScript = """
        (function () {
            var isTop = window === window.top;
            // A slide's iframes, in document order. In the slideshow page that
            // leaves out the overview's iframe, which only exists once opened.
            function frames() {
                var selector = isTop ? 'svg[data-marpit-svg] iframe' : 'iframe';
                return Array.prototype.slice.call(document.querySelectorAll(selector));
            }
            // An element's id, or its child-index path from the document (in
            // the slideshow page, from its slide, led by the slide's index, so
            // nothing the app or bespoke adds elsewhere can shift it).
            function slides() { return Array.prototype.slice.call(document.querySelectorAll('svg[data-marpit-svg]')); }
            function elementPath(element) {
                if (element.id) { return element.id; }
                var root = isTop ? element.closest('svg[data-marpit-svg]') : document.documentElement;
                if (!root) { return null; }
                var path = [];
                while (element && element !== root) {
                    path.unshift(Array.prototype.indexOf.call(element.parentNode.children, element));
                    element = element.parentNode;
                }
                if (isTop) { path.unshift(slides().indexOf(root)); }
                return path;
            }
            function findElement(path) {
                if (typeof path === 'string') { return document.getElementById(path); }
                var element = isTop ? slides()[path[0]] : document.documentElement;
                for (var i = isTop ? 1 : 0; i < path.length && element; i++) { element = element.children[path[i]]; }
                return element;
            }
            function relay(change) {
                if (isTop) {
                    var handler = window.webkit && window.webkit.messageHandlers.imarpInput;
                    if (handler) { handler.postMessage(change); }
                } else {
                    window.parent.postMessage({ imarpInputRelay: change }, '*');
                }
            }
            function report(event) {
                // A Pencil tap's click (see activateForPen) is the presenter's
                // own, though not marked trusted.
                if (!event.isTrusted && !penActivating) { return; }
                var element = event.target;
                var change;
                if (event.type === 'click') {
                    // The slideshow page mirrors its own clicks (see deckHookScript).
                    if (isTop || !element || !element.closest) { return; }
                    element = element.closest('button, summary, [onclick]');
                    if (!element) { return; }
                    change = { kind: 'click', frames: [], path: elementPath(element) };
                } else {
                    if (!element || !('value' in element) || !/^(INPUT|SELECT|TEXTAREA)$/.test(element.tagName)) { return; }
                    change = { kind: event.type, frames: [], path: elementPath(element),
                               value: String(element.value), checked: !!element.checked };
                }
                if (change.path !== null) { relay(change); }
            }
            ['input', 'change', 'click'].forEach(function (type) {
                document.addEventListener(type, report, true);
            });
            // Plotly's own sliders and menus (from a Plotly figure exported
            // to HTML) are drawn inside the plot, not HTML controls, so the
            // above never sees them. Plotly reports each change the
            // presenter makes (interaction, not an animation); relay the
            // slider's or menu's new position, and the external display
            // applies the same step. Plots can appear any time after load,
            // so they're looked for for a while.
            function hookPlotly() {
                document.querySelectorAll('.js-plotly-plot').forEach(function (plot) {
                    if (plot.__imarpHooked || typeof plot.on !== 'function') { return; }
                    plot.__imarpHooked = true;
                    plot.on('plotly_sliderchange', function (event) {
                        if (!event || !event.interaction || !event.slider) { return; }
                        var path = elementPath(plot);
                        if (path === null) { return; }
                        relay({ kind: 'plotly-slider', frames: [], path: path,
                                control: event.slider._index, active: event.slider.steps.indexOf(event.step) });
                    });
                    plot.on('plotly_buttonclicked', function (event) {
                        if (!event || !event.menu) { return; }
                        var path = elementPath(plot);
                        if (path === null) { return; }
                        relay({ kind: 'plotly-menu', frames: [], path: path,
                                control: event.menu._index, active: event.active });
                    });
                });
            }
            var plotlyLooks = 0;
            var plotlyTimer = setInterval(function () {
                hookPlotly();
                if (++plotlyLooks > 30) { clearInterval(plotlyTimer); }
            }, 1000);
            window.addEventListener('load', hookPlotly);
            // Applies a relayed Plotly slider or menu change: moves the
            // control to the same position and runs that step's command
            // (update, restyle, relayout or animate), as Plotly would.
            function applyPlotly(plot, change) {
                var Plotly = window.Plotly;
                var layout = plot._fullLayout;
                if (!Plotly || !layout) { return; }
                var isSlider = change.kind === 'plotly-slider';
                var control = (isSlider ? layout.sliders : layout.updatemenus || [])[change.control];
                var item = control && (isSlider ? control.steps : control.buttons)[change.active];
                if (!item) { return; }
                var update = {};
                update[(isSlider ? 'sliders[' : 'updatemenus[') + change.control + '].active'] = change.active;
                Plotly.relayout(plot, update).then(function () {
                    var command = Plotly[item.method];
                    if (item.method && item.method !== 'skip' && typeof command === 'function') {
                        command.apply(Plotly, [plot].concat(item.args || []));
                    }
                });
            }
            function apply(change) {
                if (change.frames.length > 0) {
                    var frame = frames()[change.frames[0]];
                    if (frame && frame.contentWindow) {
                        frame.contentWindow.postMessage({ imarpInputApply: {
                            kind: change.kind, frames: change.frames.slice(1), path: change.path,
                            value: change.value, checked: change.checked,
                            control: change.control, active: change.active } }, '*');
                    }
                    return;
                }
                var element = findElement(change.path);
                if (!element) { return; }
                if (change.kind === 'click') { element.click(); return; }
                if (change.kind === 'plotly-slider' || change.kind === 'plotly-menu') { applyPlotly(element, change); return; }
                if (element.type === 'checkbox' || element.type === 'radio') {
                    element.checked = change.checked;
                } else {
                    element.value = change.value;
                }
                element.dispatchEvent(new Event(change.kind, { bubbles: true }));
            }
            window.addEventListener('message', function (event) {
                var data = event.data;
                if (!data || typeof data !== 'object') { return; }
                if (data.imarpInputRelay) {
                    var index = frames().findIndex(function (frame) { return frame.contentWindow === event.source; });
                    if (index < 0) { return; }
                    var change = data.imarpInputRelay;
                    change.frames.unshift(index);
                    relay(change);
                } else if (data.imarpInputApply && !isTop) {
                    apply(data.imarpInputApply);
                }
            });
            if (isTop) { window.__imarpApplyInput = apply; }

            // Widgets keep every touch, zoomed in or not: a drag that starts
            // on a plot works the plot (Plotly claims it for its own dragging
            // and marks itself touch-action: none), and the slide is panned or
            // pinched from outside the widget. On a slide that's all widget,
            // Next, Previous or the overview resets the zoom. The slideshow
            // page passes the zoom state (__imarpZoomed, set by the app) down
            // to every frame, for the Mac's scrolling (below).
            var zoomed = false;
            // In pointer mode the Pencil only moves the dot, so widgets keep
            // its touches away from their controls (__imarpPencilBlocked, set
            // by the app; passed down like the zoom state). Otherwise the
            // Pencil works a widget's controls like a finger.
            var pencilBlocked = false;
            function blockPencil(event) {
                if (!pencilBlocked) { return; }
                var stylus = event.pointerType === 'pen' ||
                    Array.prototype.some.call(event.changedTouches || [], function (t) { return t.touchType === 'stylus'; });
                if (!stylus) { return; }
                event.stopPropagation();
                if (event.cancelable) { event.preventDefault(); }
            }
            if (!isTop) {
                ['touchstart', 'touchmove', 'touchend', 'pointerdown', 'pointermove', 'pointerup'].forEach(function (type) {
                    window.addEventListener(type, blockPencil, { capture: true, passive: false });
                });
            }
            // A Pencil tap on a widget's control: WebKit delivers the touch
            // (so dragging a slider works) but never turns a Pencil tap into
            // a click, so the widget page does it. A tap is under 10 points of
            // movement and 0.6 s. Any real click WebKit might still send for
            // the same tap is dropped, so nothing happens twice.
            var penDown = null;
            var penActivating = false;
            var penActivated = null;
            function activateForPen(target, x, y) {
                var control = target.closest ? target.closest('a[href], button, input, select, textarea, label, summary, [onclick], [role=button]') : null;
                var element = control || target;
                penActivating = true;
                try {
                    var tag = element.tagName;
                    var type = (element.type || '').toLowerCase();
                    if (tag === 'SELECT') {
                        element.focus();
                        if (typeof element.showPicker === 'function') { try { element.showPicker(); } catch (e) {} }
                    } else if (tag === 'TEXTAREA' || (tag === 'INPUT' && !/^(checkbox|radio|button|submit|reset|range|color|file|image)$/.test(type))) {
                        element.focus();
                    } else if (tag === 'INPUT' && type === 'range') {
                        // Dragged, not tapped; WebKit handles that itself.
                    } else if (control) {
                        element.click();
                    } else {
                        element.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y }));
                    }
                } finally {
                    penActivating = false;
                }
                penActivated = { element: element, time: Date.now() };
            }
            if (!isTop) {
                window.addEventListener('pointerdown', function (event) {
                    if (event.pointerType !== 'pen' || pencilBlocked) { return; }
                    penDown = { x: event.clientX, y: event.clientY, time: Date.now(), target: event.target };
                }, true);
                window.addEventListener('pointerup', function (event) {
                    if (event.pointerType !== 'pen' || !penDown || pencilBlocked) { penDown = null; return; }
                    var down = penDown;
                    penDown = null;
                    if (Math.hypot(event.clientX - down.x, event.clientY - down.y) > 10 || Date.now() - down.time > 600) { return; }
                    activateForPen(down.target, event.clientX, event.clientY);
                }, true);
                window.addEventListener('pointercancel', function () { penDown = null; }, true);
                window.addEventListener('click', function (event) {
                    if (!event.isTrusted || !penActivated || Date.now() - penActivated.time > 500) { return; }
                    if (penActivated.element === event.target || (penActivated.element.contains && penActivated.element.contains(event.target))) {
                        event.stopPropagation();
                        event.preventDefault();
                    }
                }, true);
            }
            function setPencilBlocked(value) {
                pencilBlocked = !!value;
                frames().forEach(function (frame) {
                    if (frame.contentWindow) { frame.contentWindow.postMessage({ imarpPencilBlocked: pencilBlocked }, '*'); }
                });
            }
            // On a Mac a zoomed slide pans with the trackpad's scrolling,
            // which widgets would otherwise take for their own (Plotly zooms
            // a plot with it), so while zoomed, scrolling is kept from them.
            // Clicks and drags work their controls as usual.
            function keepScrollFromWidget(event) {
                if (zoomed && window.__imarpOnMac) { event.stopPropagation(); }
            }
            if (!isTop) {
                window.addEventListener('wheel', keepScrollFromWidget, { capture: true, passive: true });
            }
            function setZoomed(value) {
                zoomed = !!value;
                frames().forEach(function (frame) {
                    if (frame.contentWindow) { frame.contentWindow.postMessage({ imarpZoomed: zoomed }, '*'); }
                });
            }
            window.addEventListener('message', function (event) {
                var data = event.data;
                if (!data || typeof data !== 'object') { return; }
                if (typeof data.imarpZoomed === 'boolean' && !isTop) {
                    setZoomed(data.imarpZoomed);
                } else if (typeof data.imarpPencilBlocked === 'boolean' && !isTop) {
                    setPencilBlocked(data.imarpPencilBlocked);
                } else if (data.imarpZoomQuery && event.source) {
                    // A frame that loaded asks for the current states.
                    event.source.postMessage({ imarpZoomed: zoomed }, '*');
                    event.source.postMessage({ imarpPencilBlocked: pencilBlocked }, '*');
                }
            });
            if (isTop) {
                window.__imarpSetZoomed = setZoomed;
                window.__imarpSetPencilBlocked = setPencilBlocked;
            } else {
                window.parent.postMessage({ imarpZoomQuery: true }, '*');
            }
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
        //
        // Marp's slide overview (see deckHookScript) is never removed once
        // opened: closing it only makes it transparent and pointer-events:
        // none. Its iframe, a grid of every slide, stays over the whole page,
        // and on iOS its scroller still takes vertical drags, so a zoomed-in
        // slide could then only be panned sideways (with more slides than fit
        // on one screen, the invisible grid scrolled instead). While closed,
        // the iframe is taken out of the layout; it keeps its page.
        let hideChromeCSS = """
            .bespoke-marp-osc { display: none !important; }
            .bespoke-marp-overview:not([data-open]) iframe,
            .bespoke-marp-overview[data-open=""] iframe { display: none !important; }
            """
        let hideChromeScript = """
            const style = document.createElement('style');
            style.textContent = \(String(reflecting: hideChromeCSS));
            document.head.appendChild(style);
            """
        // On a Mac, a click-and-drag highlights text (see the highlighter
        // in the deck hook); the page has to know before it loads.
        if ProcessInfo.processInfo.isiOSAppOnMac {
            configuration.userContentController.addUserScript(
                WKUserScript(source: "window.__imarpHighlighter = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
            configuration.userContentController.addUserScript(
                WKUserScript(source: "window.__imarpOnMac = true;", injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        // WebKit's own text selection is off (iPad and Mac): on the slides it
        // lands in the wrong place, and on a Mac its double-click word
        // selection flashes blue before the page can clear it.
        configuration.preferences.isTextInteractionEnabled = false
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.deckHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.overviewFrameScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.formInputScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideChromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let messageProxy = WeakScriptMessageHandler()
        configuration.userContentController.add(messageProxy, name: "imarpInput")
        configuration.userContentController.add(messageProxy, name: "imarpLog")
        configuration.userContentController.add(messageProxy, name: "imarpFrames")
        configuration.userContentController.add(messageProxy, name: "imarpPosition")
        configuration.userContentController.add(messageProxy, name: "imarpTransition")
        configuration.userContentController.add(messageProxy, name: "imarpOverview")
        configuration.userContentController.add(messageProxy, name: "imarpMedia")
        configuration.userContentController.add(messageProxy, name: "imarpControl")
        configuration.userContentController.add(messageProxy, name: "imarpHighlight")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        messageProxy.target = self
        // The presenter pinch-zooms the page itself; report it so the ink
        // canvas (and the external display) can follow.
        let reportZoom: (UIScrollView) -> Void = { [weak self] scrollView in
            self?.logPageZoomIfChanged(scrollView)
            self?.tellPageIfZoomed(scrollView.zoomScale > 1.01)
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
        // Panning a zoomed slide goes any way the fingers go, rather than
        // locking to an axis when it starts straight across or down.
        webView.scrollView.isDirectionalLockEnabled = false
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
        DebugLog.write(debugLabel, message)
    }

    private var lastLoggedPageZoom: CGFloat = 1
    private var pageToldZoomed = false

    /// Keeps the page's __imarpZoomed (which switches Marp's swipe off while
    /// zoomed in) in step with WebKit's actual zoom.
    private func tellPageIfZoomed(_ zoomed: Bool) {
        guard zoomed != pageToldZoomed else { return }
        pageToldZoomed = zoomed
        log("page told zoomed=\(zoomed)")
        webView.evaluateJavaScript("window.__imarpZoomed = \(zoomed); window.__imarpSetZoomed && window.__imarpSetZoomed(\(zoomed));")
    }

    /// Logs the page's zoom when it leaves or returns to normal size, or
    /// changes by a quarter or more, not on every frame of a pinch.
    private func logPageZoomIfChanged(_ scrollView: UIScrollView) {
        let scale = scrollView.zoomScale
        let wasZoomed = lastLoggedPageZoom > 1.001, isZoomed = scale > 1.001
        guard wasZoomed != isZoomed || abs(scale - lastLoggedPageZoom) >= 0.25 else { return }
        lastLoggedPageZoom = scale
        log(String(format: "page zoom %.2f (allowed %.2f...%.2f), offset (%.0f, %.0f)",
                   scale, scrollView.minimumZoomScale, scrollView.maximumZoomScale,
                   scrollView.contentOffset.x, scrollView.contentOffset.y))
    }

    /// Asks the page for its own view of things (slide, zoom, focus), for a
    /// log marker.
    func logPageState(_ note: String) {
        let scrollView = webView.scrollView
        let pan = scrollView.panGestureRecognizer
        func types(_ recognizer: UIGestureRecognizer) -> String {
            recognizer.allowedTouchTypes.compactMap { UITouch.TouchType(rawValue: $0.intValue).map { type -> String in
                switch type {
                case .direct: return "finger"
                case .pencil: return "pencil"
                case .indirect: return "indirect"
                case .indirectPointer: return "pointer"
                default: return "\(type.rawValue)"
                }
            } }.joined(separator: "+")
        }
        log("\(note): page pan enabled \(pan.isEnabled), state \(pan.state.logName), touches \(pan.minimumNumberOfTouches)...\(pan.maximumNumberOfTouches), types \(types(pan)); scroll enabled \(scrollView.isScrollEnabled), content \(scrollView.contentSize), bounds \(scrollView.bounds.size), offset \(scrollView.contentOffset)")
        let webGestures = (webView.scrollView.subviews + [webView.scrollView]).flatMap { $0.gestureRecognizers ?? [] }
        let busy = webGestures.filter { $0.state != .possible || !$0.isEnabled }
            .map { "\(type(of: $0)) \($0.isEnabled ? $0.state.logName : "disabled")" }
        log("\(note): web gestures not idle: \(busy.isEmpty ? "none" : busy.joined(separator: ", "))")
        // Inner scrollers WebKit made for elements in the page (they take
        // drags in whichever direction they can scroll).
        var inner: [String] = []
        func findScrollers(_ view: UIView) {
            if let scroller = view as? UIScrollView, scroller !== webView.scrollView {
                let frame = scroller.convert(scroller.bounds, to: webView)
                inner.append(String(format: "%@ at (%.0f, %.0f) %.0fx%.0f, content %.0fx%.0f, offset (%.0f, %.0f), scroll enabled %@",
                                    String(describing: type(of: scroller)), frame.minX, frame.minY, frame.width, frame.height,
                                    scroller.contentSize.width, scroller.contentSize.height,
                                    scroller.contentOffset.x, scroller.contentOffset.y, String(scroller.isScrollEnabled)))
            }
            view.subviews.forEach(findScrollers)
        }
        findScrollers(webView.scrollView)
        log("\(note): \(inner.count) inner scroller(s)\(inner.isEmpty ? "" : ": " + inner.joined(separator: " | "))")
        let overflowScript = """
            (function () {
                var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
                if (!active) { return 'no active slide'; }
                var out = [];
                [active].concat(Array.prototype.slice.call(active.querySelectorAll('*'))).forEach(function (el) {
                    var cs = getComputedStyle(el);
                    var over = el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1;
                    if ((cs.overflowX !== 'visible' || cs.overflowY !== 'visible') && over) {
                        out.push(el.tagName.toLowerCase() + (el.className && typeof el.className === 'string' ? '.' + el.className.split(' ')[0] : '') +
                            ' overflow ' + cs.overflowX + '/' + cs.overflowY + ' ' + el.clientWidth + 'x' + el.clientHeight + ' -> ' + el.scrollWidth + 'x' + el.scrollHeight);
                    }
                });
                return out.length ? out.join(' | ') : 'none';
            })();
            """
        webView.evaluateJavaScript(overflowScript) { [weak self] result, _ in
            self?.log("\(note): cropped elements with more content than fits: \(result as? String ?? "?")")
        }
        log(String(format: "%@: native page zoom %.2f (allowed %.2f...%.2f), loaded=%@, target=%@, hold=%@",
                   note, scrollView.zoomScale, scrollView.minimumZoomScale, scrollView.maximumZoomScale,
                   String(didFinishInitialLoad), String(describing: targetPosition), String(describing: holdPosition)))
        let script = """
            (function () {
                var deck = window.__imarpDeck;
                var vv = window.visualViewport;
                var active = document.activeElement;
                return 'page slide ' + (deck ? deck.slide() : '?') +
                    ', position ' + JSON.stringify(window.__imarpPosition || null) +
                    ', visualViewport scale ' + (vv ? vv.scale.toFixed(2) : '?') +
                    ', swipe guard zoomed=' + window.__imarpZoomed +
                    ', overview ' + window.__imarpOverviewOpen +
                    ', focus ' + (active ? active.tagName : 'none') +
                    ', viewport meta ' + ((document.querySelector('meta[name=viewport]') || {}).content || 'none');
            })();
            """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            self?.log("\(note): \(result as? String ?? "page didn't answer: \(String(describing: error))")")
        }
    }

    /// Loads a deck opened from an `.marpbundle` (or the gray start screen),
    /// replacing whatever was previously shown.
    func load(htmlURL: URL, directory: URL, at position: SlidePosition = .start) {
        log("load \(htmlURL.lastPathComponent) at \(position)")
        pageToldZoomed = false
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
        keepPencilOffPage()
    }

    /// The Pencil belongs to the ink, never to the page. PencilKit's drawing
    /// gesture only claims a stroke once it starts drawing, so a Pencil tap
    /// or drag could otherwise also work a link, a slider (even one inside
    /// an iframe) or a video's controls while leaving ink behind. Every
    /// gesture recognizer WebKit uses inside the webview (including the one
    /// that delivers touches to the page) is set to ignore the Pencil.
    /// WebKit adds recognizers as it goes, so this is re-applied after
    /// loads and layout.
    ///
    /// WebKit's own gestures (WK...) are the exception: they deliver touches
    /// and taps to the page, and the Pencil needs them to work a widget's
    /// controls inside an iframe (see SlideCanvasView.pencilOnFrame). Outside
    /// iframes the slideshow page's own script blocks Pencil touches, and the
    /// page's pan and pinch wait out SlideCanvasView's Pencil claim.
    private func keepPencilOffPage() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        var changed: [String] = []
        func apply(to view: UIView) {
            for recognizer in view.gestureRecognizers ?? []
            where recognizer.allowedTouchTypes.contains(pencil) && !String(describing: type(of: recognizer)).hasPrefix("WK") {
                recognizer.allowedTouchTypes = recognizer.allowedTouchTypes.filter { $0 != pencil }
                changed.append(String(describing: type(of: recognizer)))
            }
            view.subviews.forEach(apply)
        }
        apply(to: webView)
        if !changed.isEmpty {
            log("kept the Pencil off \(changed.count) page gesture(s): \(changed.joined(separator: ", "))")
        }
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
        let bounds = webView.bounds.size
        webView.evaluateJavaScript("window.__imarpGeometry()") { [weak self] result, _ in
            let values = (result as? [Double])?.map { String(format: "%.1f", $0) }.joined(separator: ", ") ?? "?"
            self?.log("geometry view=\(bounds) page[innerW, innerH, slideX, slideY, slideW, slideH]=[\(values)]")
        }
    }

    /// Puts the deck at exactly `position` (slide and revealed fragments),
    /// then keeps checking until it's really there. A no-op if it already is,
    /// so calling it to re-assert the current position never disturbs the
    /// revealed bullets.
    func show(_ position: SlidePosition) {
        // The gray start screen has no slides to go to.
        guard loadedURL != PresentationStore.startScreenURL else { return }
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

    /// `byPresenter`: the page moved because of the presenter's own touch,
    /// click or key press on it (e.g. Marp's swipe), which, like a toolbar
    /// step, stops chasing or holding any earlier position and is always
    /// accepted.
    fileprivate func pageReported(_ position: SlidePosition, byPresenter: Bool = false) {
        if byPresenter, targetPosition != nil || holdPosition != nil {
            log("reported \(position) by the presenter, hold ended")
            targetPosition = nil
            holdPosition = nil
            verifyGeneration += 1
        }
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
        log("reported \(position)\(byPresenter ? " (presenter's own touch or key)" : "")")
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

    /// The page's scroll view, which does its pinch-zoom and panning.
    var pageScrollView: UIScrollView { webView.scrollView }

    /// The page's own (pinch) zoom and scroll position changed.
    var onPageZoomChanged: ((CGFloat, CGPoint) -> Void)?
    private var zoomObservations: [NSKeyValueObservation] = []

    /// Whether this screen's slide videos play muted (the iPad's, while the
    /// external display carries the sound). Muted copies also stay out of
    /// AirPlay, so the iPad's never takes over the shared screen.
    var mutesMedia = false {
        didSet { applyMediaSettings() }
    }

    /// Whether this screen's slide videos are painted through a canvas
    /// (the external display's; see paintVideos in the deck hook).
    var paintsVideos = false {
        didSet { applyMediaSettings() }
    }

    private func applyMediaSettings() {
        guard didFinishInitialLoad else { return }
        webView.evaluateJavaScript("""
            window.__imarpMuted = \(mutesMedia);
            window.__imarpPaintVideos = \(paintsVideos);
            document.querySelectorAll('video, audio').forEach(function (m) {
                m.muted = \(mutesMedia);
                m.disableRemotePlayback = \(mutesMedia);
            });
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

    /// The presenter changed a form control (or clicked a button in a slide's
    /// iframe); the payload is opaque, for `applyFormInput(_:)` on the other
    /// screen.
    var onFormInput: (([String: Any]) -> Void)?

    func applyFormInput(_ change: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: change),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.__imarpApplyInput && window.__imarpApplyInput(\(json))")
    }

    /// Where the current slide's iframes are, in the unzoomed page's points
    /// (see reportFrameRects in the deck hook).
    private var frameRects: [CGRect] = []

    fileprivate func frameRectsReported(_ rects: [[Double]]) {
        frameRects = rects.filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
    }

    /// Whether `point` (in the unzoomed page's points) is over one of the
    /// current slide's iframes.
    func isOverFrame(_ point: CGPoint) -> Bool {
        frameRects.contains { $0.contains(point) }
    }

    /// Pointer mode: the Pencil only moves the dot, so widgets keep it away
    /// from their controls (see blockPencil in formInputScript).
    var blocksPencilInFrames = false {
        didSet { applyPencilBlocking() }
    }

    private func applyPencilBlocking() {
        guard didFinishInitialLoad else { return }
        webView.evaluateJavaScript("window.__imarpSetPencilBlocked && window.__imarpSetPencilBlocked(\(blocksPencilInFrames));")
    }

    fileprivate func pageLogged(_ text: String) {
        log("page: \(text)")
    }

    fileprivate func formInputReported(_ change: [String: Any]) {
        onFormInput?(change)
    }

    /// The presenter highlighted text on a slide (on a Mac), or cleared it
    /// (nil); the payload is opaque, for `showHighlight(_:)` on the other
    /// screen.
    var onHighlight: (([String: Any]?) -> Void)?

    fileprivate func highlightReported(_ mark: [String: Any]?) {
        onHighlight?(mark)
    }

    func showHighlight(_ mark: [String: Any]?) {
        var json = "null"
        if let mark, let data = try? JSONSerialization.data(withJSONObject: mark),
           let text = String(data: data, encoding: .utf8) {
            json = text
        }
        webView.evaluateJavaScript("window.__imarpShowHighlight && window.__imarpShowHighlight(\(json))")
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
        if message.name == "imarpFrames" {
            if let rects = message.body as? [[Double]] { target?.frameRectsReported(rects) }
            return
        }
        if message.name == "imarpLog" {
            if let text = message.body as? String { target?.pageLogged(text) }
            return
        }
        if message.name == "imarpInput" {
            if let change = message.body as? [String: Any] { target?.formInputReported(change) }
            return
        }
        if message.name == "imarpHighlight" {
            target?.highlightReported(message.body as? [String: Any])
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
        guard let values = message.body as? [Int], values.count >= 2, values[0] >= 0 else { return }
        let byPresenter = values.count > 2 && values[2] == 1
        target?.pageReported(SlidePosition(index: values[0], fragment: max(values[1], 0)), byPresenter: byPresenter)
    }
}

extension SlideContentView: WKNavigationDelegate {
    /// Tapped links: within the deck (`#3`) they move it as usual; anything
    /// else opens in its own app (Safari...) rather than replacing the deck.
    /// A web link tapped inside a widget (an iframe) opens there too: most
    /// sites refuse to be shown inside another page, which left the widget
    /// blank. Links between a widget's own local pages stay in the widget.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let frame = navigationAction.targetFrame, !frame.isMainFrame,
           let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            log("opening link \(url) from a widget outside the deck")
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
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
        keepPencilOffPage()
        applyPencilBlocking()
        // A (re)loaded page starts out thinking it isn't zoomed.
        pageToldZoomed = false
        tellPageIfZoomed(webView.scrollView.zoomScale > 1.01)
        applyMediaSettings()
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
        layer.fillColor = UIColor.systemGreen.cgColor
        layer.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
        layer.path = UIBezierPath(ovalIn: layer.bounds).cgPath
        return layer
    }()

    private lazy var glowLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.colors = [
            UIColor.systemGreen.withAlphaComponent(0.55).cgColor,
            UIColor.systemGreen.withAlphaComponent(0.0).cgColor,
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

    /// Set while the lasso or ruler is in use. PencilKit's lasso (selecting,
    /// dragging, its Cut/Copy/Delete menu) and ruler need touches on the
    /// canvas itself, which the ink layer otherwise refuses so fingers reach
    /// the slide (see the touch model in init). Meanwhile the ink layer
    /// takes every touch, fingers included, and PencilKit's drawing gesture
    /// goes back onto the canvas, its natural home.
    var inkTakesTouches = false {
        didSet { updateInkLayer() }
    }

    var isOverviewOpen: Bool { contentView.isOverviewOpen }
    var onOverviewChanged: ((Bool) -> Void)?

    private func updateInkLayer() {
        canvasView.isHidden = annotationsHidden || overviewShowing
        let inkActive = isDrawingEnabled && !annotationsHidden && !overviewShowing && !isDrawingSuspended
        canvasView.drawingGestureRecognizer.isEnabled = inkActive
        // PencilKit's own switch (iOS 18+): it manages the drawing gesture
        // itself and can turn it back on (seen on a Mac), so set both.
        if #available(iOS 18.0, *) { canvasView.isDrawingEnabled = inkActive }
        let takeTouches = inkActive && inkTakesTouches
        if canvasView.isUserInteractionEnabled != takeTouches {
            DebugLog.write("ink", takeTouches ? "ink layer takes all touches (lasso/ruler)" : "ink layer passes fingers to the slide")
        }
        canvasView.isUserInteractionEnabled = takeTouches
        // Adding a recognizer to a view moves it there from wherever it was.
        let home: UIView = takeTouches ? canvasView : self
        if canvasView.drawingGestureRecognizer.view !== home {
            home.addGestureRecognizer(canvasView.drawingGestureRecognizer)
        }
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
        // For the log: every touch over the slide, and when the gestures
        // that compete for them (PencilKit's drawing, the page's pinch and
        // pan) start and stop.
        let touchLogger = TouchLogger(target: nil, action: nil)
        touchLogger.describeLocation = { [weak self] touch in
            guard let self else { return "?" }
            let rect = Self.slideRect(in: bounds.size, aspectRatio: PresentationStore.shared.slideAspectRatio)
            let location = touch.location(in: canvasView)
            let zoom = canvasView.zoomScale
            guard rect.width > 0, rect.height > 0 else { return "(\(Int(location.x)), \(Int(location.y)))" }
            return String(format: "slide (%.2f, %.2f)", (location.x / zoom - rect.minX) / rect.width, (location.y / zoom - rect.minY) / rect.height)
        }
        addGestureRecognizer(touchLogger)
        canvasView.drawingGestureRecognizer.addTarget(self, action: #selector(logGestureState(_:)))
        contentView.pageScrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(logGestureState(_:)))
        contentView.pageScrollView.panGestureRecognizer.addTarget(self, action: #selector(logGestureState(_:)))
        // The Pencil never pans or zooms the page (fingers do). Telling the
        // page's scroll view to ignore it doesn't stick (UIScrollView resets
        // its pan's touch types), so instead every Pencil touch is claimed by
        // this Pencil-only gesture, which starts the instant the tip lands,
        // and the page's pan and pinch may only start once it has failed.
        // Fingers never reach it, so finger panning is unaffected.
        pencilClaim.minimumPressDuration = 0
        pencilClaim.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilClaim.cancelsTouchesInView = false
        pencilClaim.delaysTouchesBegan = false
        pencilClaim.delaysTouchesEnded = false
        pencilClaim.delegate = self
        addGestureRecognizer(pencilClaim)
        keepPageGesturesFromPencil()
        // A Pencil touch that lands on one of the slide's iframes (a widget,
        // a notebook page) works its controls, which are small and suit the
        // Pencil's precision, instead of drawing: this Pencil-only gesture
        // starts at once for such touches, and drawing has to wait for it to
        // fail. Elsewhere it never receives the touch, so drawing is as usual.
        pencilOnFrame.minimumPressDuration = 0
        pencilOnFrame.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencilOnFrame.cancelsTouchesInView = false
        pencilOnFrame.delaysTouchesBegan = false
        pencilOnFrame.delaysTouchesEnded = false
        pencilOnFrame.delegate = self
        pencilOnFrame.addTarget(self, action: #selector(logGestureState(_:)))
        addGestureRecognizer(pencilOnFrame)
        canvasView.drawingGestureRecognizer.require(toFail: pencilOnFrame)
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

    /// Ink comes and goes in slide space (see PresentationStore.slideSpaceSize):
    /// coordinates on a fixed-size slide, the same on every screen. On the
    /// canvas it's in this view's own points, with the slide wherever it's
    /// letterboxed to, so it's mapped across both ways. The canvas's size at
    /// the time of the last mapping, so a resize can re-place the ink.
    private var inkLayoutSize: CGSize = .zero
    private var pendingSlideDrawing: PKDrawing?
    private var isSettingDrawing = false

    private func slideSpaceToCanvas(for size: CGSize) -> CGAffineTransform? {
        let store = PresentationStore.shared
        return Self.inkTransform(from: store.slideSpaceSize, to: size, aspectRatio: store.slideAspectRatio)
    }

    /// Shows `drawing`, in slide space. Doesn't count as an edit: nothing is
    /// reported through onDrawingChanged (so it isn't saved again).
    func setDrawing(_ drawing: PKDrawing) {
        guard bounds.width > 0, bounds.height > 0, let transform = slideSpaceToCanvas(for: bounds.size) else {
            // Not laid out yet; placed once it is (see layoutSubviews).
            pendingSlideDrawing = drawing
            return
        }
        pendingSlideDrawing = nil
        inkLayoutSize = bounds.size
        placeOnCanvas(drawing.transformed(using: transform))
    }

    private func placeOnCanvas(_ drawing: PKDrawing) {
        isSettingDrawing = true
        canvasView.drawing = drawing
        isSettingDrawing = false
        // PKCanvasView doesn't always invalidate its rendered tile cache on a
        // programmatic (non-gesture) assignment, most visibly when swapping
        // to an empty PKDrawing() — the strokes are gone from the model but
        // stale pixels remain on screen until something forces a redraw.
        canvasView.setNeedsDisplay()
    }

    /// Follows a resize (a Mac window, rotation, the external display's
    /// final size), keeping the ink on the same part of the slide.
    private func replaceInkForCurrentSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if let pending = pendingSlideDrawing {
            setDrawing(pending)
            return
        }
        guard bounds.size != inkLayoutSize else { return }
        let aspect = PresentationStore.shared.slideAspectRatio
        if inkLayoutSize != .zero, let transform = Self.inkTransform(from: inkLayoutSize, to: bounds.size, aspectRatio: aspect) {
            placeOnCanvas(canvasView.drawing.transformed(using: transform))
        }
        inkLayoutSize = bounds.size
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

    /// Set while the ink layer is being moved to match the page, so its
    /// zoom and scroll changes aren't pushed straight back to the page (see
    /// zoomDidChange). Pushing back used to fight the presenter's own pans:
    /// wherever the ink layer can't scroll as far as the page (vertically,
    /// in practice), it pulled the page back each time.
    private var isFollowingPage = false

    private func followPageZoom(scale: CGFloat, offset: CGPoint) {
        isFollowingPage = true
        defer { isFollowingPage = false }
        if abs(canvasView.zoomScale - scale) > 0.0001 {
            canvasView.setZoomScale(scale, animated: false)
        }
        if abs(canvasView.contentOffset.x - offset.x) > 0.5 || abs(canvasView.contentOffset.y - offset.y) > 0.5 {
            canvasView.contentOffset = offset
        }
        if abs(canvasView.contentOffset.y - offset.y) > 0.5 || abs(canvasView.contentOffset.x - offset.x) > 0.5 {
            logZoomMismatch("ink layer couldn't follow the page")
        }
    }

    private var lastMismatchLog = Date.distantPast

    private func logZoomMismatch(_ note: String) {
        guard Date().timeIntervalSince(lastMismatchLog) > 1 else { return }
        lastMismatchLog = Date()
        let page = contentView.pageScrollView
        DebugLog.write("zoom", String(format: "%@: page zoom %.2f offset (%.0f, %.0f) content (%.0f, %.0f); ink zoom %.2f offset (%.0f, %.0f) content (%.0f, %.0f)",
                                      note, page.zoomScale, page.contentOffset.x, page.contentOffset.y, page.contentSize.width, page.contentSize.height,
                                      canvasView.zoomScale, canvasView.contentOffset.x, canvasView.contentOffset.y, canvasView.contentSize.width, canvasView.contentSize.height))
    }

    @objc private func logGestureState(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state != .changed else { return }
        let name: String
        if recognizer === canvasView.drawingGestureRecognizer {
            name = isDrawingSuspended ? "drawing gesture (suspended for pointer)" : "drawing gesture"
        } else if recognizer === contentView.pageScrollView.pinchGestureRecognizer {
            name = "page pinch"
        } else if recognizer === contentView.pageScrollView.panGestureRecognizer {
            name = "page pan"
        } else if recognizer === pencilOnFrame {
            name = "Pencil on a widget (no drawing)"
        } else {
            name = String(describing: type(of: recognizer))
        }
        DebugLog.write("gesture", "\(name) \(recognizer.state.logName)")
        if recognizer === contentView.pageScrollView.panGestureRecognizer, recognizer.state == .ended {
            lastMismatchLog = .distantPast
            logZoomMismatch("after pan")
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        DebugLog.write("zoom", String(format: "ink layer zoom ended at %.2f, page at %.2f", scale, contentView.pageScrollView.zoomScale))
    }

    private func zoomDidChange() {
        let zoom = canvasView.zoomScale
        let offset = canvasView.contentOffset
        // The page leads; the ink layer only drives it when it was moved
        // some other way (reset, the external display mirroring the iPad,
        // a pinch on the ink layer itself in lasso mode).
        if !isFollowingPage {
            contentView.setZoom(scale: zoom, offset: offset)
        }
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

    /// Claims every Pencil touch over the slide; see init.
    private let pencilClaim = UILongPressGestureRecognizer(target: nil, action: nil)
    /// Claims Pencil touches on the slide's iframes, holding drawing off; see init.
    private let pencilOnFrame = UILongPressGestureRecognizer(target: nil, action: nil)
    private var pageGesturesKeptFromPencil = Set<ObjectIdentifier>()

    /// The page's pinch gesture only exists once WebKit enables zooming, so
    /// this is repeated at layout until both pan and pinch are covered.
    private func keepPageGesturesFromPencil() {
        let scrollView = contentView.pageScrollView
        for recognizer in [scrollView.panGestureRecognizer, scrollView.pinchGestureRecognizer].compactMap({ $0 })
        where !pageGesturesKeptFromPencil.contains(ObjectIdentifier(recognizer)) {
            recognizer.require(toFail: pencilClaim)
            pageGesturesKeptFromPencil.insert(ObjectIdentifier(recognizer))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        keepPageGesturesFromPencil()
        // At normal size the canvas's content is exactly its bounds (no
        // scrolling, strokes in the view's own coordinates); zooming needs a
        // content size to scale from.
        if !isZoomed {
            if canvasView.contentSize != bounds.size { canvasView.contentSize = bounds.size }
            if canvasView.contentOffset != .zero { canvasView.contentOffset = .zero }
        }
        replaceInkForCurrentSize()
    }

    /// Reports the presenter's own edits, in slide space.
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSettingDrawing else { return }
        DebugLog.write("ink", "\(canvasView.drawing.strokes.count) strokes, canvas zoom \(String(format: "%.2f", canvasView.zoomScale))")
        guard let toCanvas = slideSpaceToCanvas(for: bounds.size) else { return }
        onDrawingChanged?(canvasView.drawing.transformed(using: toCanvas.inverted()))
    }
}

extension SlideCanvasView: UIGestureRecognizerDelegate {
    /// The Pencil claim (see init) only exists to hold off the page's pan
    /// and pinch; drawing and the laser pointer go on alongside it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pencilClaim || gestureRecognizer === pencilOnFrame
    }

    /// The iframe claim only takes Pencil touches that land on an iframe.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pencilOnFrame else { return true }
        let location = touch.location(in: canvasView)
        let zoom = canvasView.zoomScale
        return contentView.isOverFrame(CGPoint(x: location.x / zoom, y: location.y / zoom))
    }
}
