import UIKit
import WebKit
import PencilKit

/// Composites each slide's rendered HTML with its ink overlay into a single
/// PDF page. Uses an offscreen WKWebView (positioned outside the visible
/// bounds of the key window, not hidden — a hidden/zero-alpha WKWebView
/// often stops rendering and produces blank snapshots) so export doesn't
/// visibly flip through slides on screen.
///
/// Exports each slide in its fully-built state (all incremental bullets
/// revealed), not one page per build step. Jumping straight to a slide via
/// `location.hash` always resets its fragments to hidden, so after jumping,
/// this reveals exactly that slide's own fragment count via simulated
/// forward keypresses — bounded and safe, since it never steps more times
/// than the slide has fragments (which would spill into the next slide).
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
    static func export(pageSize: CGSize, completion: @escaping (URL?) -> Void) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first })
            .first
        else {
            completion(nil)
            return
        }

        let store = PresentationStore.shared
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
            WKUserScript(source: hideChromeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: hostFrame, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        window.addSubview(webView)

        webView.loadFileURL(store.deckHTMLURL, allowingReadAccessTo: store.deckDirectory)

        let pageRect = CGRect(origin: .zero, size: pageSize)
        var pageImages: [UIImage] = []

        func finish(_ url: URL?) {
            webView.removeFromSuperview()
            completion(url)
        }

        func revealFragments(remaining: Int, then: @escaping () -> Void) {
            guard remaining > 0 else {
                then()
                return
            }
            webView.evaluateJavaScript(
                "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));"
            ) { _, _ in
                revealFragments(remaining: remaining - 1, then: then)
            }
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
            webView.evaluateJavaScript("location.hash = '\(index + 1)';") { _, _ in
                // Hash navigation is a DOM update, not a full load; give the
                // page a beat to repaint before reading its fragment count.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let fragmentCountScript = """
                        (function () {
                            var active = document.querySelector('svg[data-marpit-svg].bespoke-marp-active');
                            var section = active ? active.querySelector('section[data-marpit-fragments]') : null;
                            return section ? parseInt(section.getAttribute('data-marpit-fragments'), 10) : 0;
                        })();
                        """
                    webView.evaluateJavaScript(fragmentCountScript) { result, _ in
                        let fragmentCount = (result as? Int) ?? 0
                        revealFragments(remaining: fragmentCount) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                webView.takeSnapshot(with: nil) { image, _ in
                                    let drawing = store.drawing(for: index)
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
                    }
                }
            }
        }

        var loadObservation: NSKeyValueObservation?
        loadObservation = webView.observe(\.isLoading) { wv, _ in
            guard !wv.isLoading else { return }
            loadObservation?.invalidate()
            renderSlide(0)
        }
    }
}
