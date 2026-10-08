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
    private var pointerToggleButton: UIBarButtonItem?

    /// The bundle URL currently holding a `startAccessingSecurityScopedResource`
    /// claim (see `UIDocumentPickerDelegate` below), so it can be released
    /// when a different deck is opened.
    private var accessedBundleURL: URL?

    private lazy var pencilPointer = UILongPressGestureRecognizer(
        target: self, action: #selector(handlePointerGesture(_:))
    )

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
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(slidesTapped))
        // While the slide overview is open, leave the arrow keys to it (they
        // move the selection around its grid) instead of stepping the deck
        // hidden behind it.
        guard !slideCanvas.isOverviewOpen else { return [escape] }
        // Plain arrow keys are claimed by iPadOS's focus-navigation system
        // (moving focus between the toolbar's buttons) before they'd
        // otherwise reach these key commands — wantsPriorityOverSystemBehavior
        // opts back in. Space isn't used for focus movement, so it worked
        // without this.
        return [
            escape,
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
        // Black, like the slide's letterbox bars, so the strip below the
        // canvas (kept clear for the home indicator) doesn't show as a band.
        view.backgroundColor = .black

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

        let pointerItem = UIBarButtonItem(
            title: "Pointer", style: .plain, target: self, action: #selector(pointerToggleTapped)
        )
        pointerToggleButton = pointerItem

        toolbar.items = [
            UIBarButtonItem(title: "Open…", style: .plain, target: self, action: #selector(openTapped)),
            presentItem,
            pointerItem,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "◀ Prev", style: .plain, target: self, action: #selector(previousTapped)),
            UIBarButtonItem(title: "Slides", style: .plain, target: self, action: #selector(slidesTapped)),
            UIBarButtonItem(title: "Next ▶", style: .plain, target: self, action: #selector(nextTapped)),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            hideButton,
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearTapped)),
            UIBarButtonItem(title: "Export PDF", style: .plain, target: self, action: #selector(exportTapped)),
        ]

        slideCanvas.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        // Black button titles (white in dark mode) rather than the default
        // blue tint.
        toolbar.tintColor = .label
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

        // Fingers use the slide itself: its links and video controls,
        // Marp's own swipe to change slides, and pinch to zoom (the ink
        // layer passes them through; see SlideCanvasView). Here the
        // external display is kept in step with what they do.
        slideCanvas.onVisibleRegionChanged = { region in
            PresentationStore.shared.setZoomRegion(region)
        }
        slideCanvas.contentView.onMediaEvent = { index, playing, time, rate, fullscreen in
            NotificationCenter.default.post(name: .mediaCommand, object: nil, userInfo: [
                "index": index, "playing": playing, "time": time, "rate": rate,
            ])
            // iOS's full-screen player covers only the iPad; the external
            // display shows the video filling its screen meanwhile.
            if let fullscreen {
                NotificationCenter.default.post(name: .mediaFillChanged, object: nil, userInfo: [
                    "index": index, "filled": fullscreen,
                ])
            }
        }
        slideCanvas.contentView.onControlActivated = { index in
            NotificationCenter.default.post(name: .htmlControlActivated, object: nil, userInfo: ["index": index])
        }
        // Sound comes from the external display when there is one.
        slideCanvas.contentView.mutesMedia = PresentationStore.shared.externalDisplayActive
        NotificationCenter.default.addObserver(forName: .externalDisplayActiveDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.slideCanvas.contentView.mutesMedia = PresentationStore.shared.externalDisplayActive
        }

        // The laser pointer follows the Pencil. In pointer mode, touching
        // down with the Pencil moves the dot instead of drawing (PencilKit's
        // drawing gesture is switched off; see updatePointerMode), and
        // lifting it hides the dot. Pencil-only, so fingers still use the
        // slide. Recognizes immediately (no minimum press) so the dot appears
        // the moment the tip lands. On the canvas's container, like
        // PencilKit's own drawing gesture, since the canvas takes no touches.
        pencilPointer.minimumPressDuration = 0
        pencilPointer.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        // Alongside the page's own touch handling underneath, which would
        // otherwise claim the touch first.
        pencilPointer.delegate = self
        slideCanvas.addGestureRecognizer(pencilPointer)

        // On iPads that support Apple Pencil hover (M2 iPad Pro and later),
        // holding the tip just above the screen moves the dot too. Hover
        // never fires during a touch-down stroke, so it can't conflict with
        // drawing.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePointerGesture(_:)))
        slideCanvas.addGestureRecognizer(hover)
        updatePointerMode()

        NotificationCenter.default.addObserver(forName: .stepRequested, object: nil, queue: .main) { [weak self] note in
            self?.handleStepRequested(note)
        }
        NotificationCenter.default.addObserver(forName: .deckDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadDeckFromStore()
        }
        NotificationCenter.default.addObserver(forName: .pointerEnabledDidChange, object: nil, queue: .main) { [weak self] note in
            guard let enabled = note.userInfo?["enabled"] as? Bool else { return }
            self?.pointerToggleButton?.title = enabled ? "Pointer On" : "Pointer"
            self?.updatePointerMode()
        }
        NotificationCenter.default.addObserver(forName: .pointerDidMove, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let point = (note.userInfo?["point"] as? NSValue)?.cgPointValue
            slideCanvas.setPointer(normalizedPoint: point, aspectRatio: PresentationStore.shared.slideAspectRatio)
        }

        // The store (and so the external display, and which slide new ink
        // belongs to) follows what this webview is actually showing, as
        // reported by the page itself, not what was last requested.
        slideCanvas.contentView.debugLabel = "ipad"
        slideCanvas.contentView.onPositionChanged = { [weak self] position in
            guard let self else { return }
            let store = PresentationStore.shared
            // A zoom belongs to the slide it was made on.
            if position.index != store.currentIndex { slideCanvas.resetZoom(animated: true) }
            store.setCurrentPosition(position)
            slideCanvas.setDrawing(store.drawing(for: position.index))
            NotificationCenter.default.post(name: .slideIndexDidChange, object: nil)
        }

        // Coming back from another app, re-assert the slide the store says is
        // current: the webview may have been reloaded meanwhile. Once it's
        // confirmed there, onPositionChanged brings the ink and the external
        // display along.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            slideCanvas.show(PresentationStore.shared.currentPosition)
            restoreToolPicker()
        }

        // The slide overview takes keyboard focus (and so first responder)
        // while it's open, which hides the PencilKit tool picker; hand it back
        // to the canvas once the overview closes.
        slideCanvas.onOverviewChanged = { [weak self] open in
            if open {
                self?.slideCanvas.resetZoom(animated: false)
            } else {
                self?.restoreToolPicker()
            }
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
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: slideCanvas.canvasView)
        slideCanvas.canvasView.becomeFirstResponder()
        updatePresentButtonTitle()
    }

    /// The tool picker is only shown while the canvas is first responder, so
    /// anything else that takes first responder (the slide overview's web
    /// content, a dismissed sheet) leaves it hidden until this runs.
    private func restoreToolPicker() {
        guard !slideCanvas.isOverviewOpen else { return }
        toolPicker.setVisible(true, forFirstResponder: slideCanvas.canvasView)
        slideCanvas.canvasView.becomeFirstResponder()
    }

    private func reloadDeckFromStore() {
        let store = PresentationStore.shared
        slideCanvas.loadDeck(htmlURL: store.deckHTMLURL, directory: store.deckDirectory, at: store.currentPosition)
        slideCanvas.configure(position: store.currentPosition, drawing: store.drawing(for: store.currentIndex))
    }

    @objc private func previousTapped() {
        NotificationCenter.default.post(name: .stepRequested, object: nil, userInfo: ["forward": false])
    }

    /// Opens (or closes) Marp's slide overview, a grid of every slide; tapping
    /// one jumps there and closes it. Only on the iPad: the external display
    /// stays on the current slide until a new one is picked, then follows.
    @objc private func slidesTapped() {
        slideCanvas.setOverviewOpen(!slideCanvas.isOverviewOpen)
    }

    @objc private func nextTapped() {
        NotificationCenter.default.post(name: .stepRequested, object: nil, userInfo: ["forward": true])
    }

    @objc private func clearTapped() {
        let store = PresentationStore.shared
        let index = store.currentIndex
        #if DEBUG
        print("[imarp clear] slide \(index), strokes before: \(slideCanvas.canvasView.drawing.strokes.count)")
        #endif
        applyDrawing(PKDrawing(), forSlideIndex: index, actionName: "Clear")
        // Right after a stroke, PencilKit keeps showing it even though the
        // drawing is now empty (the canvas's last stroke lingers on screen
        // until something makes it redraw). Assigning the empty drawing again
        // once things settle does; still one Undo step.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, store.currentIndex == index, store.drawing(for: index).strokes.isEmpty else { return }
            #if DEBUG
            print("[imarp clear] slide \(index), strokes after: \(slideCanvas.canvasView.drawing.strokes.count), refreshing")
            #endif
            slideCanvas.setDrawing(PKDrawing())
        }
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

    @objc private func pointerToggleTapped() {
        let store = PresentationStore.shared
        store.setPointerEnabled(!store.pointerEnabled)
    }

    /// In pointer mode the Pencil drives the laser dot rather than drawing.
    private func updatePointerMode() {
        let enabled = PresentationStore.shared.pointerEnabled
        pencilPointer.isEnabled = enabled
        slideCanvas.isDrawingSuspended = enabled
        #if DEBUG
        print("[imarp pointer] mode \(enabled ? "on" : "off")")
        #endif
    }

    @objc private func handlePointerGesture(_ recognizer: UIGestureRecognizer) {
        let store = PresentationStore.shared
        guard store.pointerEnabled else { return }
        switch recognizer.state {
        case .began, .changed:
            // Accounts for zoom, so the dot lands on the same part of the
            // slide on both screens.
            guard let normalized = slideCanvas.normalizedSlidePoint(for: recognizer) else { return }
            // Only show the pointer while actually over the slide itself,
            // not the letterbox bars around it.
            guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else {
                store.setPointerPosition(nil)
                return
            }
            store.setPointerPosition(normalized)
        case .ended, .cancelled, .failed:
            store.setPointerPosition(nil)
        default:
            break
        }
    }

    @objc private func hideAnnotationsTapped() {
        let store = PresentationStore.shared
        let hidden = !store.annotationsHidden
        store.setAnnotationsHidden(hidden)
        hideAnnotationsButton?.title = hidden ? "Show Ink" : "Hide Ink"
        slideCanvas.annotationsHidden = hidden
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
        PDFExporter.export { [weak self] url in
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
        // Don't step the deck hidden behind the slide overview.
        guard !slideCanvas.isOverviewOpen else { return }
        // The new position arrives through contentView.onPositionChanged.
        slideCanvas.step(forward: forward)
    }
}

extension MainViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pencilPointer
    }
}

extension MainViewController: PKToolPickerObserver {
    /// A finger on the slide (playing a video, tapping a link) makes the
    /// web page first responder, which hides the tool picker. Whenever it
    /// disappears during plain presenting, hand first responder straight
    /// back to the canvas so the tools come back. Not while the overview, a
    /// sheet (file picker, the full-screen video player...) is up, or the
    /// app is going inactive: those hide the picker on purpose.
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        guard !toolPicker.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !toolPicker.isVisible,
                  view.window != nil,
                  presentedViewController == nil,
                  UIApplication.shared.applicationState == .active
            else { return }
            restoreToolPicker()
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
