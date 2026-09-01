import UIKit
import PencilKit
import UniformTypeIdentifiers

/// iPad-side UI: toolbar (navigation, deck loading, export, annotation
/// controls) plus the interactive drawing canvas. This is the ONLY scene
/// that receives Pencil input; the external-display scene mirrors the
/// resulting ink read-only.
final class MainViewController: UIViewController {
    private let slideCanvas = SlideCanvasView()
    private let toolbar = UIToolbar()
    private let toolPicker = PKToolPicker()
    private var hideAnnotationsButton: UIBarButtonItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        slideCanvas.isDrawingEnabled = true
        slideCanvas.onDrawingChanged = { [weak self] drawing in
            guard self != nil else { return }
            let store = PresentationStore.shared
            store.setDrawing(drawing, for: store.currentIndex)
        }

        let hideButton = UIBarButtonItem(
            title: "Hide Ink", style: .plain, target: self, action: #selector(hideAnnotationsTapped)
        )
        hideAnnotationsButton = hideButton

        toolbar.items = [
            UIBarButtonItem(title: "Open…", style: .plain, target: self, action: #selector(openTapped)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "◀ Prev", style: .plain, target: self, action: #selector(previousTapped)),
            UIBarButtonItem(title: "Next ▶", style: .plain, target: self, action: #selector(nextTapped)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            hideButton,
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearTapped)),
            UIBarButtonItem(title: "Export PDF", style: .plain, target: self, action: #selector(exportTapped)),
        ]

        slideCanvas.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        view.addSubview(slideCanvas)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            slideCanvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            slideCanvas.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            slideCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            slideCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(forName: .stepRequested, object: nil, queue: .main) { [weak self] note in
            self?.handleStepRequested(note)
        }
        NotificationCenter.default.addObserver(forName: .deckDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadDeckFromStore()
        }

        reloadDeckFromStore()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.addObserver(slideCanvas.canvasView)
        toolPicker.setVisible(true, forFirstResponder: slideCanvas.canvasView)
        slideCanvas.canvasView.becomeFirstResponder()
    }

    private func reloadDeckFromStore() {
        let store = PresentationStore.shared
        slideCanvas.loadDeck(htmlURL: store.deckHTMLURL, directory: store.deckDirectory)
        slideCanvas.configure(slideIndex: store.currentIndex, drawing: store.drawing(for: store.currentIndex))
    }

    @objc private func previousTapped() {
        NotificationCenter.default.post(name: .stepRequested, object: nil, userInfo: ["forward": false])
    }

    @objc private func nextTapped() {
        NotificationCenter.default.post(name: .stepRequested, object: nil, userInfo: ["forward": true])
    }

    @objc private func clearTapped() {
        applyDrawing(PKDrawing(), forSlideIndex: PresentationStore.shared.currentIndex, actionName: "Clear")
    }

    /// Registers this drawing change on the canvas's undo manager — the
    /// same one PencilKit's tool picker already uses for stroke-level
    /// undo/redo — so Clear (and anything else routed through here) folds
    /// into the same Undo/Redo history instead of being a silent, permanent
    /// action of its own.
    private func applyDrawing(_ drawing: PKDrawing, forSlideIndex index: Int, actionName: String? = nil) {
        let store = PresentationStore.shared
        let previousDrawing = store.drawing(for: index)

        let undoManager = slideCanvas.canvasView.undoManager
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyDrawing(previousDrawing, forSlideIndex: index)
        }
        if let actionName {
            undoManager?.setActionName(actionName)
        }

        store.setDrawing(drawing, for: index)
        if store.currentIndex == index {
            slideCanvas.setDrawing(drawing)
        }
    }

    @objc private func hideAnnotationsTapped() {
        let store = PresentationStore.shared
        let hidden = !store.annotationsHidden
        store.setAnnotationsHidden(hidden)
        hideAnnotationsButton?.title = hidden ? "Show Ink" : "Hide Ink"
        slideCanvas.canvasView.isHidden = hidden
    }

    @objc private func openTapped() {
        guard let bundleType = UTType(filenameExtension: "imarpbundle") else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [bundleType], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func exportTapped() {
        let pageSize = slideCanvas.bounds.size
        PDFExporter.export(pageSize: pageSize) { [weak self] url in
            guard let self, let url else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.barButtonItem = toolbar.items?.last
            }
            present(activity, animated: true)
        }
    }

    private func handleStepRequested(_ note: Notification) {
        guard let forward = note.userInfo?["forward"] as? Bool else { return }
        slideCanvas.step(forward: forward) { [weak self] newIndex in
            guard let self else { return }
            let store = PresentationStore.shared
            store.setCurrentIndex(newIndex)
            slideCanvas.setDrawing(store.drawing(for: newIndex))
        }
    }
}

extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let bundleURL = urls.first else { return }
        do {
            let contents = try MarpBundleLoader.load(from: bundleURL)
            PresentationStore.shared.loadDeck(
                htmlURL: contents.deckHTMLURL,
                directory: contents.deckDirectory,
                slideCount: contents.slideCount
            )
        } catch {
            let alert = UIAlertController(
                title: "Couldn't Open Deck",
                message: "\(bundleURL.lastPathComponent) doesn't look like a valid .imarpbundle: \(error)",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}
