import UIKit
import PencilKit

/// External-display-side UI: canvas only, no toolbar, no touch handling.
/// Never steps on its own: after each step the main scene records the exact
/// slide and fragment in `PresentationStore.currentPosition`, and this scene
/// jumps straight there (with the deck's own slide transition). Also mirrors
/// deck changes and ink-visibility toggles from the main scene, since the
/// external display always shows exactly what the presenter sees.
final class ExternalDisplayViewController: UIViewController {
    private let slideCanvas = SlideCanvasView()

    /// The slide this screen is actually showing, for picking and matching
    /// incoming ink updates to it. nil until the page has confirmed one
    /// (e.g. just after the deck loads), so no ink is shown on a guess.
    private var currentIndex: Int?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        slideCanvas.isDrawingEnabled = false
        // Ink follows the slide this screen is actually showing, as reported
        // by its own page, so it can never belong to a different slide.
        slideCanvas.contentView.debugLabel = "external"
        slideCanvas.contentView.onPositionChanged = { [weak self] position in
            guard let self else { return }
            currentIndex = position.index
            showRescaledDrawing(for: position.index)
            // This screen only ever follows the iPad, so if its page moved
            // anywhere else on its own, put it back.
            let wanted = PresentationStore.shared.currentPosition
            if position != wanted { slideCanvas.show(wanted) }
        }
        slideCanvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(slideCanvas)
        NSLayoutConstraint.activate([
            slideCanvas.topAnchor.constraint(equalTo: view.topAnchor),
            slideCanvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            slideCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            slideCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(forName: .slideIndexDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.followStore()
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
        if let currentIndex { showRescaledDrawing(for: currentIndex) }
    }

    private func reloadDeckFromStore() {
        let store = PresentationStore.shared
        // Not hardcoded to 0: the scene can be recreated (e.g. after the app
        // is backgrounded and returns) while the main screen is mid-deck.
        // A genuinely new deck resets the store's index to 0 itself.
        currentIndex = nil
        slideCanvas.loadDeck(htmlURL: store.deckHTMLURL, directory: store.deckDirectory, at: store.currentPosition)
        slideCanvas.show(store.currentPosition)
        // Blank until the page confirms which slide it's on.
        slideCanvas.setDrawing(PKDrawing())
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

    private func followStore() {
        slideCanvas.show(PresentationStore.shared.currentPosition)
    }

    @objc private func handleDrawingChanged(_ note: Notification) {
        guard let slideIndex = note.userInfo?["slideIndex"] as? Int, slideIndex == currentIndex else { return }
        showRescaledDrawing(for: slideIndex)
    }
}
