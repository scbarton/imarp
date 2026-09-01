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
    private var presentButton: UIBarButtonItem?

    /// The bundle URL currently holding a `startAccessingSecurityScopedResource`
    /// claim (see `UIDocumentPickerDelegate` below), so it can be released
    /// when a different deck is opened.
    private var accessedBundleURL: URL?

    /// Typed as `AnyObject` because a stored property can't have an
    /// iOS 27-only type while the deployment target is 17.0; the computed
    /// property below restores the real type behind an availability check.
    private var displayRegistrationStorage: AnyObject?

    @available(iOS 27.0, *)
    private var displayRegistration: UISceneAccessoryRegistration? {
        get { displayRegistrationStorage as? UISceneAccessoryRegistration }
        set { displayRegistrationStorage = newValue }
    }

    /// Presentation clickers (connected via the adapter's USB port, or
    /// Bluetooth) enumerate as HID keyboards and send one of these key sets —
    /// UIKit routes them here via the responder chain regardless of which
    /// view currently holds focus, so no pairing/setup step is needed beyond
    /// plugging the clicker in.
    override var keyCommands: [UIKeyCommand]? {
        // Plain arrow keys are claimed by iPadOS's focus-navigation system
        // (moving focus between the toolbar's buttons) before they'd
        // otherwise reach these key commands — wantsPriorityOverSystemBehavior
        // opts back in. Space isn't used for focus movement, so it worked
        // without this.
        [
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(nextTapped)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextTapped)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(nextTapped)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(previousTapped)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousTapped)),
        ].map {
            $0.wantsPriorityOverSystemBehavior = true
            return $0
        }
    }

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

        let presentItem = UIBarButtonItem(
            title: "Present", style: .plain, target: self, action: #selector(presentTapped)
        )
        presentButton = presentItem

        toolbar.items = [
            UIBarButtonItem(title: "Open…", style: .plain, target: self, action: #selector(openTapped)),
            presentItem,
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

        // Finger-only (excludes .pencil) so a fast pencil stroke while
        // annotating is never misread as a page-advance swipe.
        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(nextTapped))
        swipeLeft.direction = .left
        swipeLeft.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(previousTapped))
        swipeRight.direction = .right
        swipeRight.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        slideCanvas.canvasView.addGestureRecognizer(swipeLeft)
        slideCanvas.canvasView.addGestureRecognizer(swipeRight)

        NotificationCenter.default.addObserver(forName: .stepRequested, object: nil, queue: .main) { [weak self] note in
            self?.handleStepRequested(note)
        }
        NotificationCenter.default.addObserver(forName: .deckDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadDeckFromStore()
        }

        registerExternalDisplayAccessory()
        reloadDeckFromStore()
    }

    /// iOS 27 changed how an app gets the external display. Previously the
    /// system connected a `.windowExternalDisplayNonInteractive` scene on its
    /// own and the app opted out by ignoring it; as of iOS 27 that scene is
    /// only offered to an app that has registered a *scene accessory*, and
    /// requesting the role directly fails outright with "the requested role
    /// … is not supported".
    ///
    /// The registration is tied to this view controller: while it's on screen,
    /// enabled, and a display is attached, the system connects the scene and
    /// drives `ExternalDisplaySceneDelegate`.
    private func registerExternalDisplayAccessory() {
        // On iOS 17–26 the system connects the external scene by itself, using
        // the manifest entry in Info.plist; nothing to register.
        guard #available(iOS 27.0, *) else { return }
        let configuration = UISceneConfiguration()
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
        displayRegistration = registerSceneAccessory(accessory)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The external display rescales ink relative to this size, so it has
        // to reflect the canvas ink is actually drawn on (and follow rotation).
        PresentationStore.shared.setAuthoringCanvasSize(slideCanvas.bounds.size)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.addObserver(slideCanvas.canvasView)
        toolPicker.setVisible(true, forFirstResponder: slideCanvas.canvasView)
        slideCanvas.canvasView.becomeFirstResponder()
        updatePresentButtonTitle()
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

    /// Toggles the dedicated external-display presentation. iPadOS mirrors by
    /// default and only surrenders the display to an app that explicitly asks
    /// for it — see `ExternalDisplay`.
    /// The system presents the accessory automatically whenever a display is
    /// attached, so this is a manual override for suppressing it (e.g. to drop
    /// back to mirroring mid-talk) rather than the thing that starts it.
    @objc private func presentTapped() {
        guard #available(iOS 27.0, *), let registration = displayRegistration else { return }
        registration.isEnabled.toggle()
        // The scene connects/disconnects asynchronously, so let the system
        // settle before reading state back for the button title.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.updatePresentButtonTitle()
        }
    }

    private func updatePresentButtonTitle() {
        guard #available(iOS 27.0, *), let registration = displayRegistration else { return }
        presentButton?.title = registration.isEnabled ? "Mirror" : "Present"
    }

    @objc private func hideAnnotationsTapped() {
        let store = PresentationStore.shared
        let hidden = !store.annotationsHidden
        store.setAnnotationsHidden(hidden)
        hideAnnotationsButton?.title = hidden ? "Show Ink" : "Hide Ink"
        slideCanvas.canvasView.isHidden = hidden
    }

    @objc private func openTapped() {
        guard let bundleType = UTType(filenameExtension: "marpbundle") else { return }
        // asCopy: false — opening in place (rather than a throwaway copy in
        // the app's Inbox) is what makes the rendered-HTML cache and ink
        // persistence actually stick: both write back into the bundle
        // MarpBundleLoader/PresentationStore were handed, so if that were a
        // copy, every write would be discarded the next time this deck opens.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [bundleType], asCopy: false)
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

        // Opening in place (see openTapped) means this URL is
        // security-scoped: reads/writes need startAccessingSecurityScopedResource
        // for the duration this deck stays open. Only one deck is open at a
        // time, so the previous one's access is released here too.
        guard bundleURL.startAccessingSecurityScopedResource() else {
            let alert = UIAlertController(
                title: "Couldn't Open Deck",
                message: "iOS denied access to \(bundleURL.lastPathComponent).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        accessedBundleURL?.stopAccessingSecurityScopedResource()
        accessedBundleURL = bundleURL

        // Opening a source-only bundle renders on-device (a few JS
        // round-trips through MarpRenderer), so this isn't instant —
        // show something rather than a frozen toolbar.
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.center = view.center
        spinner.startAnimating()
        view.addSubview(spinner)

        MarpBundleLoader.load(from: bundleURL) { [weak self] result in
            guard let self else { return }
            spinner.removeFromSuperview()
            switch result {
            case .success(let contents):
                PresentationStore.shared.loadDeck(
                    htmlURL: contents.deckHTMLURL,
                    directory: contents.deckDirectory,
                    slideCount: contents.slideCount,
                    slideAspectRatio: contents.slideAspectRatio,
                    bundleURL: contents.bundleURL
                )
            case .failure(let error):
                accessedBundleURL?.stopAccessingSecurityScopedResource()
                accessedBundleURL = nil
                let alert = UIAlertController(
                    title: "Couldn't Open Deck",
                    message: "\(bundleURL.lastPathComponent) doesn't look like a valid .marpbundle: \(error)",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}
