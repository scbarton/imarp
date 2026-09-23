import WebKit

/// Runs `@marp-team/marp-core` (bundled as plain browser JS — no Node/DOM
/// dependencies, see marp-engine-build/ in the repo) inside a hidden
/// WKWebView to render Markdown to Marp's slide HTML/CSS entirely on-device,
/// with no Mac round-trip. Loaded once and reused for the app's lifetime.
///
/// The renderer only produces the slide content + theme CSS — the
/// interactive presentation shell (bespoke.js navigation, fragment
/// stepping, OSC controls) comes from `MarpEngine/shell.html`, which has
/// that machinery extracted from a real `marp-cli` build with two markers
/// (`<!--IMARP_SLIDES-->`, `<!--IMARP_STYLE-->`) where fresh render output
/// gets spliced in. See `MarpBundleLoader.assemblePresentation`.
///
/// Results come back via `postMessage`/`WKScriptMessageHandler` rather than
/// `evaluateJavaScript`'s own return value: WKWebView's `evaluateJavaScript`
/// completion-handler bridge has a well-known failure mode
/// (`WKErrorDomain` code 5, "JavaScript execution returned a result of an
/// unsupported type") when the returned value is a large/complex object —
/// exactly what a full deck's rendered HTML+CSS is. `postMessage` doesn't
/// share that limitation, so the render script posts its result instead of
/// returning it.
final class MarpRenderer: NSObject {
    static let shared = MarpRenderer()

    struct RenderResult {
        let html: String
        let css: String
    }

    enum RenderError: Error {
        case engineError(String)
        case invalidResponse
    }

    private static let resultMessageHandlerName = "marpResult"

    private let webView: WKWebView
    private var didFinishLoad = false
    private var pendingWork: [() -> Void] = []
    private var pendingRequests: [String: (Result<RenderResult, Error>) -> Void] = [:]

    private override init() {
        webView = WKWebView(frame: .zero)
        super.init()
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: Self.resultMessageHandlerName)

        guard let harnessURL = Bundle.main.url(forResource: "harness", withExtension: "html", subdirectory: "MarpEngine") else {
            fatalError("MarpEngine/harness.html is missing from the app bundle")
        }
        webView.loadFileURL(harnessURL, allowingReadAccessTo: harnessURL.deletingLastPathComponent())
    }

    /// `themeCSS` should be `@theme <name>`-tagged CSS matching the
    /// Markdown's frontmatter `theme:` value, exactly as marp-cli's
    /// `--theme-set` flag works — marp-core resolves it by that name.
    func render(markdown: String, themeCSS: String?, completion: @escaping (Result<RenderResult, Error>) -> Void) {
        let work: () -> Void = { [weak self] in
            self?.performRender(markdown: markdown, themeCSS: themeCSS, completion: completion)
        }
        if didFinishLoad {
            work()
        } else {
            pendingWork.append(work)
        }
    }

    private func performRender(markdown: String, themeCSS: String?, completion: @escaping (Result<RenderResult, Error>) -> Void) {
        let requestID = UUID().uuidString
        pendingRequests[requestID] = completion

        let idJS = Self.jsStringLiteral(requestID)
        let markdownJS = Self.jsStringLiteral(markdown)
        let themeJS = themeCSS.map(Self.jsStringLiteral) ?? "null"
        let script = """
            (function () {
                try {
                    const result = window.MarpEngine.render(\(markdownJS), \(themeJS));
                    window.webkit.messageHandlers.\(Self.resultMessageHandlerName).postMessage({ id: \(idJS), html: result.html, css: result.css });
                } catch (e) {
                    window.webkit.messageHandlers.\(Self.resultMessageHandlerName).postMessage({ id: \(idJS), error: String((e && e.message) || e) });
                }
            })();
            """
        // The script itself no longer returns the (potentially huge) result —
        // it posts it via the message handler above instead, so this
        // evaluateJavaScript call only ever bridges back `undefined`/small
        // values and won't hit the large-payload bridging bug.
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            guard let self, let pending = self.pendingRequests.removeValue(forKey: requestID) else { return }
            pending(.failure(error))
        }
    }

    /// A JSON-encoded string is also a valid JS string literal — safe
    /// escaping for free, no hand-rolled quoting.
    private static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}

extension MarpRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoad = true
        let work = pendingWork
        pendingWork = []
        work.forEach { $0() }
    }
}

extension MarpRenderer: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let id = dict["id"] as? String else { return }
        guard let completion = pendingRequests.removeValue(forKey: id) else { return }

        if let errorMessage = dict["error"] as? String {
            completion(.failure(RenderError.engineError(errorMessage)))
            return
        }
        guard let html = dict["html"] as? String, let css = dict["css"] as? String else {
            completion(.failure(RenderError.invalidResponse))
            return
        }
        completion(.success(RenderResult(html: html, css: css)))
    }
}
