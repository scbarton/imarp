import UIKit
import WebKit
import PencilKit

/// Composites each slide's rendered HTML with its ink overlay into a single
/// PDF page. Uses an offscreen WKWebView (positioned outside the visible
/// bounds of the key window, not hidden — a hidden/zero-alpha WKWebView
/// often stops rendering and produces blank snapshots) so export doesn't
/// visibly flip through slides on screen.
///
/// Each page is exactly one slide (1280 points wide, at the deck's own
/// aspect ratio), with no letterbox bars. The webview gets the same deck
/// hook and viewport fix as the on-screen slides (see SlideContentView):
/// without the viewport fix, Marp's `height=device-height` lays the slide
/// out against the screen's height rather than the page's, shifting it away
/// from the ink. Slides are opened through bespoke's own API with slide
/// transitions skipped (otherwise a snapshot can catch one mid-animation)
/// and every incremental bullet revealed, so each page shows the slide in
/// its fully built state.
///
/// Every composited page image is collected into an array first, and the
/// actual PDF is only assembled at the very end in one synchronous pass via
/// `UIGraphicsPDFRenderer`. The legacy `UIGraphicsBeginPDFContextToData` /
/// `UIGraphicsBeginPDFPage` API was tried first and produced PDFs that
/// "PDF Expert" reported as corrupted — that API drives a single global
/// current-graphics-context stack, and spreading page-drawing calls across
/// many async callbacks (JS evaluation, snapshot completion) risks another
/// main-thread operation — WebKit's own internal rendering included —
/// disturbing that stack in between. Doing all the drawing synchronously,
/// after every async step has already finished, avoids that entirely.
enum PDFExporter {
    static let pageWidth: CGFloat = 1280

    /// Waits for bespoke to finish setting up (the deck hook has captured the
    /// deck), then sizes the page's viewport to the webview.
    private static let prepareScript = """
        for (var i = 0; i < 60 && !window.__imarpDeck; i++) {
            await new Promise(function (resolve) { setTimeout(resolve, 50); });
        }
        window.__imarpSetViewport(width, height);
        await new Promise(function (resolve) { setTimeout(resolve, 150); });
        return !!window.__imarpDeck;
        """

    /// Puts slide `index` on screen with all its fragments revealed, then
    /// waits for fonts and a repaint. Falls back to a hash jump plus
    /// simulated key presses for a page without the deck hook.
    private static let showSlideScript = """
        var deck = window.__imarpDeck;
        if (deck) {
            deck.skipTransition = true;
            deck.slide(index, { fragment: -1 });
        } else {
            location.hash = String(index + 1);
            await new Promise(function (resolve) { setTimeout(resolve, 200); });
            var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
            var section = active ? active.querySelector('section[data-marpit-fragments]') : null;
            var count = section ? parseInt(section.getAttribute('data-marpit-fragments'), 10) : 0;
            for (var i = 0; i < count; i++) {
                document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
            }
        }
        if (document.fonts) { await document.fonts.ready; }
        await new Promise(function (resolve) { setTimeout(resolve, 120); });
        return true;
        """

    static func export(completion: @escaping (URL?) -> Void) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first })
            .first
        else {
            completion(nil)
            return
        }

        let store = PresentationStore.shared
        let aspectRatio = store.slideAspectRatio > 0 ? store.slideAspectRatio : 16.0 / 9.0
        let pageSize = CGSize(width: pageWidth, height: (pageWidth / aspectRatio).rounded())
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let inkTransform = SlideCanvasView.inkTransform(
            from: store.authoringCanvasSize, to: pageSize, aspectRatio: aspectRatio
        )

        let hostFrame = CGRect(x: window.bounds.width + 100, y: 0, width: pageSize.width, height: pageSize.height)
        // Marp's bespoke output ships its own on-screen page controls and a
        // fullscreen toggle (see SlideContentView) — hide them here too, or
        // they bake into the exported PDF pages.
        let configuration = WKWebViewConfiguration()
        let hideChromeScript = """
            const style = document.createElement('style');
            style.textContent = '.bespoke-marp-osc { display: none !important; }';
            document.head.appendChild(style);
            """
        configuration.userContentController.addUserScript(
            WKUserScript(source: SlideContentView.deckHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: hideChromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        // The deck hook reports positions, transitions and the overview
        // through these; nothing here needs them, but posting to a handler
        // that isn't registered would throw inside the page.
        let sink = IgnoredScriptMessages()
        for name in ["imarpPosition", "imarpTransition", "imarpOverview", "imarpMedia", "imarpControl"] {
            configuration.userContentController.add(sink, name: name)
        }
        let webView = WKWebView(frame: hostFrame, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        window.addSubview(webView)

        webView.loadFileURL(store.deckHTMLURL, allowingReadAccessTo: store.deckDirectory)

        var pageImages: [UIImage] = []

        func finish(_ url: URL?) {
            webView.removeFromSuperview()
            for name in ["imarpPosition", "imarpTransition", "imarpOverview", "imarpMedia", "imarpControl"] {
                configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
            completion(url)
        }

        func writeFinalPDF() {
            guard !pageImages.isEmpty else {
                finish(nil)
                return
            }
            let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
            let data = renderer.pdfData { context in
                for image in pageImages {
                    context.beginPage()
                    image.draw(in: pageRect)
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("iMarp-export-\(Int(Date().timeIntervalSince1970)).pdf")
            do {
                try data.write(to: url, options: .atomic)
                finish(url)
            } catch {
                finish(nil)
            }
        }

        func renderSlide(_ index: Int) {
            guard index < store.slideCount else {
                writeFinalPDF()
                return
            }
            webView.callAsyncJavaScript(showSlideScript, arguments: ["index": index], in: nil, in: .page) { _ in
                webView.takeSnapshot(with: nil) { image, _ in
                    var drawing = store.drawing(for: index)
                    if let inkTransform {
                        drawing = drawing.transformed(using: inkTransform)
                    }
                    let inkImage = drawing.image(from: pageRect, scale: UIScreen.main.scale)
                    let composited = UIGraphicsImageRenderer(size: pageSize).image { _ in
                        image?.draw(in: pageRect)
                        inkImage.draw(in: pageRect)
                    }
                    pageImages.append(composited)
                    renderSlide(index + 1)
                }
            }
        }

        var loadObservation: NSKeyValueObservation?
        loadObservation = webView.observe(\.isLoading) { wv, _ in
            guard !wv.isLoading else { return }
            loadObservation?.invalidate()
            let size = ["width": Int(pageSize.width), "height": Int(pageSize.height)]
            wv.callAsyncJavaScript(prepareScript, arguments: size, in: nil, in: .page) { _ in
                renderSlide(0)
            }
        }
    }
}

private final class IgnoredScriptMessages: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
