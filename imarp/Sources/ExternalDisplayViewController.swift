import UIKit

/// External-display-side UI: canvas only, no toolbar, no touch handling.
/// Steps its own WKWebView in lockstep with the main scene by reacting to
/// the same `.stepRequested` events (see PresentationStore) rather than
/// being told a slide index — this keeps Marp's incremental bullet builds
/// (fragments) correctly in sync between the two screens. Also mirrors
/// deck changes and ink-visibility toggles from the main scene, since the
/// external display always shows exactly what the presenter sees.
final class ExternalDisplayViewController: UIViewController {
    private let slideCanvas = SlideCanvasView()

    /// Tracked locally rather than read from PresentationStore.currentIndex,
    /// since this scene steps its webview independently of the main scene.
    private var currentIndex = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        slideCanvas.isDrawingEnabled = false
        slideCanvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(slideCanvas)
        NSLayoutConstraint.activate([
            slideCanvas.topAnchor.constraint(equalTo: view.topAnchor),
            slideCanvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            slideCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            slideCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(forName: .stepRequested, object: nil, queue: .main) { [weak self] note in
            self?.handleStepRequested(note)
        }
        NotificationCenter.default.addObserver(forName: .deckDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadDeckFromStore()
        }
        NotificationCenter.default.addObserver(forName: .annotationsHiddenDidChange, object: nil, queue: .main) { [weak self] note in
            guard let hidden = note.userInfo?["hidden"] as? Bool else { return }
            self?.slideCanvas.canvasView.isHidden = hidden
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDrawingChanged(_:)),
            name: .drawingDidChange, object: nil
        )
        NotificationCenter.default.addObserver(forName: .pointerDidMove, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let point = (note.userInfo?["point"] as? NSValue)?.cgPointValue
            slideCanvas.setPointer(normalizedPoint: point, aspectRatio: PresentationStore.shared.slideAspectRatio)
        }
        NotificationCenter.default.addObserver(forName: .pointerEnabledDidChange, object: nil, queue: .main) { [weak self] note in
            guard let enabled = note.userInfo?["enabled"] as? Bool, !enabled else { return }
            self?.slideCanvas.setPointer(normalizedPoint: nil, aspectRatio: 0)
        }

        slideCanvas.canvasView.isHidden = PresentationStore.shared.annotationsHidden
        reloadDeckFromStore()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The rescale depends on this canvas's bounds, which aren't final when
        // the scene first connects — redo it once they are.
        showRescaledDrawing(for: currentIndex)
    }

    private func reloadDeckFromStore() {
        let store = PresentationStore.shared
        currentIndex = 0
        slideCanvas.loadDeck(htmlURL: store.deckHTMLURL, directory: store.deckDirectory)
        slideCanvas.contentView.showSlide(index: currentIndex)
        showRescaledDrawing(for: currentIndex)
    }

    /// Ink arrives in the iPad canvas's coordinate space, which is a different
    /// size (and often a different shape) from this display's, so it has to be
    /// mapped across rather than shown as-is.
    private func showRescaledDrawing(for slideIndex: Int) {
        let store = PresentationStore.shared
        slideCanvas.setDrawing(
            store.drawing(for: slideIndex),
            authoredOnCanvasOfSize: store.authoringCanvasSize,
            aspectRatio: store.slideAspectRatio
        )
    }

    private func handleStepRequested(_ note: Notification) {
        guard let forward = note.userInfo?["forward"] as? Bool else { return }
        slideCanvas.step(forward: forward) { [weak self] newIndex in
            guard let self else { return }
            currentIndex = newIndex
            showRescaledDrawing(for: newIndex)
        }
    }

    @objc private func handleDrawingChanged(_ note: Notification) {
        guard let slideIndex = note.userInfo?["slideIndex"] as? Int, slideIndex == currentIndex else { return }
        showRescaledDrawing(for: slideIndex)
    }
}
