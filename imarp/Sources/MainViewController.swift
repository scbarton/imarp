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

    /// The slide sits under the toolbar, or at the top of the window while
    /// the toolbar is hidden (View › Hide Buttons, on a Mac).
    private var canvasBelowToolbar: NSLayoutConstraint!
    private var canvasAtTop: NSLayoutConstraint!
    private static let toolbarHiddenKey = "toolbarHidden"

    /// URLs currently holding a `startAccessingSecurityScopedResource` claim
    /// for the open deck (see `openDeck(at:accessing:)`), so they can be
    /// released when a different deck is opened.
    private var accessedURLs: [URL] = []

    /// Watches the open deck's Markdown and theme for live reload.
    private var deckWatcher: DeckWatcher?

    /// A Markdown deck waiting for the presenter to allow access to its
    /// folder (see askForFolder(of:)).
    private var markdownAwaitingFolder: URL?

    private lazy var pencilPointer = UILongPressGestureRecognizer(
        target: self, action: #selector(handlePointerGesture(_:))
    )

    /// A three-finger tap on the slide drops a marker in the log (see
    /// DebugLog), so the moment something odd happened is easy to find.
    private lazy var markTap = UITapGestureRecognizer(target: self, action: #selector(markTapped))
    private let markLabel = UILabel()
    private var didStartWithPen = false

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
        // On a Mac, Esc and the left and right arrows belong to the menu
        // bar's items (see buildMacMenus); the rest stay here.
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(slidesTapped))
        if onMac {
            guard !slideCanvas.isOverviewOpen else { return [] }
            return [
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextTapped)),
                UIKeyCommand(input: " ", modifierFlags: [], action: #selector(nextTapped)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousTapped)),
            ].map {
                $0.wantsPriorityOverSystemBehavior = true
                return $0
            }
        }
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

    /// Landscape on the iPad, as before. The app declares every orientation
    /// only so that macOS lets its window be resized (see project.yml).
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        ProcessInfo.processInfo.isiOSAppOnMac ? .all : .landscape
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Black, like the slide's letterbox bars, so the strip below the
        // canvas (kept clear for the home indicator) doesn't show as a band.
        view.backgroundColor = .black

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
            title: Self.pointerTitle(enabled: PresentationStore.shared.pointerEnabled),
            style: .plain, target: self, action: #selector(pointerToggleTapped)
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

            slideCanvas.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            slideCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            slideCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        canvasBelowToolbar = slideCanvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor)
        canvasAtTop = slideCanvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        canvasBelowToolbar.isActive = true
        if ProcessInfo.processInfo.isiOSAppOnMac, UserDefaults.standard.bool(forKey: Self.toolbarHiddenKey) {
            setToolbarHidden(true)
        }

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
        slideCanvas.contentView.onHighlight = { mark in
            DebugLog.write("ipad", mark == nil ? "highlight cleared" : "highlight on slide \(mark?["slide"] ?? "?")")
            NotificationCenter.default.post(name: .highlightChanged, object: nil, userInfo: mark.map { ["mark": $0] })
        }
        slideCanvas.contentView.onFormInput = { change in
            PresentationStore.shared.recordFormInput(change)
            NotificationCenter.default.post(name: .formInputChanged, object: nil, userInfo: ["change": change])
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
        // Without cancelling the touch for the page: on a widget's control
        // (a slider, a menu) the Pencil still works it in pointer mode, with
        // the dot following. Everywhere else the page ignores the Pencil in
        // pointer mode (see blockPencil in SlideCanvasView's formInputScript),
        // so it only points.
        pencilPointer.cancelsTouchesInView = false
        slideCanvas.addGestureRecognizer(pencilPointer)
        // With pointer mode on, the Pencil must never draw or erase. Switching
        // PencilKit's drawing off doesn't stick (it turns its own gesture
        // back on), so drawing may only start once the pointer gesture has
        // failed: with pointer mode on it starts the instant the tip lands,
        // so drawing never does; with it off it's disabled, so drawing starts
        // straight away as usual.
        slideCanvas.canvasView.drawingGestureRecognizer.require(toFail: pencilPointer)

        // On iPads that support Apple Pencil hover (M2 iPad Pro and later),
        // holding the tip just above the screen moves the dot too. Hover
        // never fires during a touch-down stroke, so it can't conflict with
        // drawing.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handlePointerGesture(_:)))
        slideCanvas.addGestureRecognizer(hover)
        updatePointerMode()

        markTap.numberOfTouchesRequired = 3
        markTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        markTap.cancelsTouchesInView = false
        markTap.delegate = self
        slideCanvas.addGestureRecognizer(markTap)
        markLabel.text = "  Marked in log  "
        markLabel.font = .preferredFont(forTextStyle: .headline)
        markLabel.textColor = .white
        markLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        markLabel.layer.cornerRadius = 8
        markLabel.layer.masksToBounds = true
        markLabel.alpha = 0
        markLabel.isUserInteractionEnabled = false
        markLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(markLabel)
        NSLayoutConstraint.activate([
            markLabel.centerXAnchor.constraint(equalTo: slideCanvas.centerXAnchor),
            markLabel.bottomAnchor.constraint(equalTo: slideCanvas.bottomAnchor, constant: -24),
        ])

        NotificationCenter.default.addObserver(forName: .stepRequested, object: nil, queue: .main) { [weak self] note in
            self?.handleStepRequested(note)
        }
        NotificationCenter.default.addObserver(forName: .deckDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadDeckFromStore()
        }
        NotificationCenter.default.addObserver(forName: .pointerEnabledDidChange, object: nil, queue: .main) { [weak self] note in
            guard let enabled = note.userInfo?["enabled"] as? Bool else { return }
            self?.pointerToggleButton?.title = Self.pointerTitle(enabled: enabled)
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
            DebugLog.write("ipad", "became active, re-asserting \(PresentationStore.shared.currentPosition)")
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        toolPicker.addObserver(slideCanvas.canvasView)
        toolPicker.addObserver(self)
        if !didStartWithPen {
            didStartWithPen = true
            startWithPen()
        }
        updateInkTakesTouches()
        toolPicker.setVisible(true, forFirstResponder: slideCanvas.canvasView)
        slideCanvas.canvasView.becomeFirstResponder()
        updatePresentButtonTitle()
    }

    /// The tool picker remembers its tool between launches, so the app could
    /// start with the lasso or ruler, which take every finger (see
    /// SlideCanvasView.inkTakesTouches): no swipes, links or sliders until a
    /// pen is picked. Starting a talk that way would be a nasty surprise, so
    /// the app always starts with a pen.
    private func startWithPen() {
        let lasso: Bool
        if #available(iOS 18.0, *) {
            lasso = toolPicker.selectedToolItem is PKToolPickerLassoItem
        } else {
            lasso = toolPicker.selectedTool is PKLassoTool
        }
        guard lasso || toolPicker.isRulerActive else { return }
        toolPicker.isRulerActive = false
        if lasso {
            if #available(iOS 18.0, *) {
                if let pen = toolPicker.toolItems.first(where: { $0 is PKToolPickerInkingItem }) {
                    toolPicker.selectedToolItem = pen
                }
            } else {
                toolPicker.selectedTool = PKInkingTool(.pen)
            }
        }
        DebugLog.write("ipad", "started with the \(lasso ? "lasso" : "ruler") from last time, switched to a pen")
    }

    /// The tool picker is only shown while the canvas is first responder, so
    /// anything else that takes first responder (the slide overview's web
    /// content, a dismissed sheet) leaves it hidden until this runs.
    private func restoreToolPicker() {
        guard !slideCanvas.isOverviewOpen else { return }
        DebugLog.write("focus", "restoring tool picker (canvas becomes first responder)")
        toolPicker.setVisible(true, forFirstResponder: slideCanvas.canvasView)
        slideCanvas.canvasView.becomeFirstResponder()
    }

    private func reloadDeckFromStore() {
        let store = PresentationStore.shared
        // Nothing to draw on until a deck is open (ink on the gray start
        // screen would belong to no deck and couldn't be saved). Running on a
        // Mac (as an iPad app), ink is shown but never drawn: a one-finger
        // trackpad or mouse drag would leave stray strokes, and the Mac has
        // no tool picker or undo for them.
        slideCanvas.isDrawingEnabled = store.hasDeck && !ProcessInfo.processInfo.isiOSAppOnMac
        // Behind the gray start screen, the strip kept clear for the home
        // indicator is gray too, so the gray fills the window out to its
        // rounded corners (black would leave a square-cornered gray box).
        view.backgroundColor = store.hasDeck ? .black : PresentationStore.startScreenGray
        slideCanvas.loadDeck(htmlURL: store.deckHTMLURL, directory: store.deckDirectory, at: store.currentPosition)
        slideCanvas.configure(position: store.currentPosition, drawing: store.drawing(for: store.currentIndex))
    }

    @objc private func markTapped() {
        let store = PresentationStore.shared
        DebugLog.write("mark", "==== MARK ==== slide \(store.currentPosition), canvas zoom \(String(format: "%.2f", slideCanvas.canvasView.zoomScale)), pointer \(store.pointerEnabled ? "on" : "off"), drawing suspended \(slideCanvas.isDrawingSuspended), overview \(slideCanvas.isOverviewOpen), external \(store.externalDisplayActive ? "on" : "off")")
        slideCanvas.contentView.logPageState("mark")
        markLabel.layer.removeAllAnimations()
        markLabel.alpha = 1
        UIView.animate(withDuration: 0.4, delay: 1.2, options: []) { self.markLabel.alpha = 0 }
    }

    @objc func previousTapped() {
        DebugLog.write("ipad", "Prev (toolbar button or key)")
        NotificationCenter.default.post(name: .stepRequested, object: nil, userInfo: ["forward": false])
    }

    /// Opens (or closes) Marp's slide overview, a grid of every slide; tapping
    /// one jumps there and closes it. Only on the iPad: the external display
    /// stays on the current slide until a new one is picked, then follows.
    @objc func slidesTapped() {
        DebugLog.write("ipad", "Slides (toolbar button or Esc): overview \(slideCanvas.isOverviewOpen ? "closing" : "opening")")
        slideCanvas.setOverviewOpen(!slideCanvas.isOverviewOpen)
    }

    @objc func nextTapped() {
        DebugLog.write("ipad", "Next (toolbar button or key)")
        NotificationCenter.default.post(name: .stepRequested, object: nil, userInfo: ["forward": true])
    }

    @objc func clearTapped() {
        let store = PresentationStore.shared
        let index = store.currentIndex
        DebugLog.write("ipad", "Clear: slide \(index), strokes before: \(slideCanvas.canvasView.drawing.strokes.count)")
        applyDrawing(PKDrawing(), forSlideIndex: index, actionName: "Clear")
        // Right after a stroke, PencilKit keeps showing it even though the
        // drawing is now empty (the canvas's last stroke lingers on screen
        // until something makes it redraw). Assigning the empty drawing again
        // once things settle does; still one Undo step.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, store.currentIndex == index, store.drawing(for: index).strokes.isEmpty else { return }
            DebugLog.write("ipad", "Clear: slide \(index), strokes after: \(slideCanvas.canvasView.drawing.strokes.count), refreshing")
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
    @objc func presentTapped() {
        DebugLog.write("ipad", "Present/Mirror")
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

    @objc func toggleToolbarTapped() {
        setToolbarHidden(!toolbar.isHidden)
    }

    private func setToolbarHidden(_ hidden: Bool) {
        DebugLog.write("ipad", "toolbar \(hidden ? "hidden" : "shown")")
        toolbar.isHidden = hidden
        // Deactivate before activating, so the two are never both on.
        (hidden ? canvasBelowToolbar : canvasAtTop).isActive = false
        (hidden ? canvasAtTop : canvasBelowToolbar).isActive = true
        UserDefaults.standard.set(hidden, forKey: Self.toolbarHiddenKey)
    }

    // MARK: Mac menu bar

    /// The Mac's menu bar gets an item for every toolbar button (with a
    /// keyboard shortcut), plus Hide Buttons. Called from AppDelegate's
    /// buildMenu(with:), on a Mac only. The items reach this controller
    /// through the responder chain, like the toolbar's buttons.
    static func buildMacMenus(with builder: UIMenuBuilder) {
        func item(_ title: String, _ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            // Plain arrows and Esc would otherwise go to focus movement.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        func add(_ children: [UIMenuElement], to menu: UIMenu.Identifier, title: String, after: UIMenu.Identifier) {
            let group = UIMenu(options: .displayInline, children: children)
            if builder.menu(for: menu) != nil {
                builder.insertChild(group, atStartOfMenu: menu)
            } else {
                builder.insertSibling(UIMenu(title: title, identifier: menu, children: [group]), afterMenu: after)
            }
        }
        // A group whose shortcut clashes with an existing one is dropped
        // whole, so the system items that would clash go: its Open…
        // (greyed out, for document apps) has ⌘O, Show Toolbar (for a Mac
        // toolbar this app doesn't have) ⌥⌘T, and the text styles and Format
        // menu (nothing here to format) ⌘I for Italic.
        builder.remove(menu: .open)
        builder.remove(menu: .toolbar)
        builder.remove(menu: .textStyle)
        builder.remove(menu: .format)
        add([
            item("Open…", "o", .command, #selector(openTapped)),
            item("Export PDF…", "e", [.command, .shift], #selector(exportTapped)),
        ], to: .file, title: "File", after: .application)
        add([
            item("Hide Buttons", "t", [.command, .alternate], #selector(toggleToolbarTapped)),
            item("Hide Ink", "i", .command, #selector(hideAnnotationsTapped)),
        ], to: .view, title: "View", after: .edit)
        builder.insertChild(UIMenu(options: .displayInline, children: [
            item("Clear Ink on Slide", UIKeyCommand.inputDelete, .command, #selector(clearTapped)),
        ]), atEndOfMenu: .edit)
        builder.insertSibling(UIMenu(title: "Slideshow", children: [
            UIMenu(options: .displayInline, children: [
                item("Present", "p", [.command, .alternate], #selector(presentTapped)),
                item("Laser Pointer", "l", .command, #selector(pointerToggleTapped)),
            ]),
            UIMenu(options: .displayInline, children: [
                item("Previous Slide", UIKeyCommand.inputLeftArrow, [], #selector(previousTapped)),
                item("Next Slide", UIKeyCommand.inputRightArrow, [], #selector(nextTapped)),
                item("Slide Overview", UIKeyCommand.inputEscape, [], #selector(slidesTapped)),
            ]),
        ]), afterMenu: .view)
    }

    /// Keeps the menu items' titles and checkmarks in step with the buttons.
    override func validate(_ command: UICommand) {
        super.validate(command)
        let store = PresentationStore.shared
        switch command.action {
        case #selector(toggleToolbarTapped):
            command.title = toolbar.isHidden ? "Show Buttons" : "Hide Buttons"
        case #selector(hideAnnotationsTapped):
            command.title = store.annotationsHidden ? "Show Ink" : "Hide Ink"
        case #selector(pointerToggleTapped):
            command.state = store.pointerEnabled ? .on : .off
        case #selector(slidesTapped):
            command.state = slideCanvas.isOverviewOpen ? .on : .off
        case #selector(presentTapped):
            command.title = presentButton?.title ?? "Present"
        default:
            break
        }
    }

    /// While the slide overview is open the arrows move around its grid, so
    /// Previous and Next are off (their keys then reach the overview).
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(previousTapped) || action == #selector(nextTapped) {
            return !slideCanvas.isOverviewOpen
        }
        if action == #selector(presentTapped) {
            if #available(iOS 27.0, *) { return displayRegistration != nil }
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func pointerToggleTapped() {
        let store = PresentationStore.shared
        store.setPointerEnabled(!store.pointerEnabled)
    }

    /// The dot shows the pointer's state: black when off, green (the laser
    /// dot's own color) when on. Emoji keep their own colors, so the
    /// toolbar's tint doesn't recolor them.
    private static func pointerTitle(enabled: Bool) -> String {
        enabled ? "Pointer \u{1F7E2}" : "Pointer \u{26AB}\u{FE0F}"
    }

    /// In pointer mode the Pencil drives the laser dot rather than drawing.
    private func updatePointerMode() {
        let enabled = PresentationStore.shared.pointerEnabled
        pencilPointer.isEnabled = enabled
        slideCanvas.isDrawingSuspended = enabled
        slideCanvas.contentView.blocksPencilInFrames = enabled
        DebugLog.write("ipad", "pointer mode \(enabled ? "on" : "off")")
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

    @objc func hideAnnotationsTapped() {
        DebugLog.write("ipad", "Hide/Show Ink")
        let store = PresentationStore.shared
        let hidden = !store.annotationsHidden
        store.setAnnotationsHidden(hidden)
        hideAnnotationsButton?.title = hidden ? "Show Ink" : "Hide Ink"
        slideCanvas.annotationsHidden = hidden
    }

    @objc func openTapped() {
        // A .marpbundle, or a Markdown deck (see MarpBundleLoader).
        let types = (["marpbundle"] + MarpBundleLoader.markdownExtensions.sorted())
            .compactMap { UTType(filenameExtension: $0) }
        // asCopy: false — opening in place (rather than a throwaway copy in
        // the app's Inbox) is what makes the rendered-HTML cache and ink
        // persistence actually stick: both write back beside the deck
        // MarpBundleLoader/PresentationStore were handed, so if that were a
        // copy, every write would be discarded the next time this deck opens.
        markdownAwaitingFolder = nil
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Picking a Markdown file only grants access to that one file, not the
    /// theme, assets, rendered HTML and ink beside it. So the first time a
    /// deck is opened from a folder, the presenter is asked to allow that
    /// folder (the folder picker opens on it); it's remembered from then on
    /// (see GrantedFolders), for every deck in it or below it.
    private func askForFolder(of markdownURL: URL) {
        let folder = markdownURL.deletingLastPathComponent()
        let alert = UIAlertController(
            title: "Allow Access to “\(folder.lastPathComponent)”",
            message: "To show \(markdownURL.lastPathComponent) with its theme and assets, and to save its slides and ink beside it, iMarp needs access to the folder it's in. Tap Open in the next screen. This is only asked once per folder.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
            guard let self else { return }
            markdownAwaitingFolder = markdownURL
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.directoryURL = folder
            picker.delegate = self
            present(picker, animated: true)
        })
        present(alert, animated: true)
    }

    /// Live reload: when the open deck's Markdown or theme changes, it's
    /// re-rendered and both screens reload in place, on the same slide, with
    /// ink saved first and shown again after.
    private func watchForChanges(to url: URL, files: [URL]) {
        guard !files.isEmpty else { return }
        deckWatcher = DeckWatcher(files: files) { [weak self] in self?.reloadChangedDeck(at: url) }
    }

    private var isReloading = false

    private func reloadChangedDeck(at url: URL) {
        guard !isReloading else { return }
        isReloading = true
        MarpBundleLoader.load(from: url) { [weak self] result in
            guard let self else { return }
            isReloading = false
            switch result {
            case .success(let contents):
                PresentationStore.shared.loadDeck(
                    htmlURL: contents.deckHTMLURL,
                    directory: contents.deckDirectory,
                    slideCount: contents.slideCount,
                    slideAspectRatio: contents.slideAspectRatio,
                    inkDirectory: contents.inkDirectory,
                    name: contents.name,
                    keepPosition: true
                )
            case .failure(let error):
                // Keep showing the last good version (e.g. a half-saved file).
                DebugLog.write("ipad", "live reload of \(url.lastPathComponent) failed: \(error)")
            }
        }
    }

    private func showOpenError(_ message: String) {
        let alert = UIAlertController(title: "Couldn't Open Deck", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Loads a deck, keeping security-scoped access to `accessing` (the
    /// deck, and for a Markdown deck its folder) while it stays open. Only
    /// one deck is open at a time, so the previous one's access is released.
    private func openDeck(at url: URL, accessing: [URL]) {
        deckWatcher?.stop()
        deckWatcher = nil
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedURLs = accessing

        // Rendering from Markdown happens on-device (a few JS round-trips
        // through MarpRenderer), so this isn't instant — show something
        // rather than a frozen toolbar.
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.center = view.center
        spinner.startAnimating()
        view.addSubview(spinner)

        MarpBundleLoader.load(from: url) { [weak self] result in
            guard let self else { return }
            spinner.removeFromSuperview()
            switch result {
            case .success(let contents):
                PresentationStore.shared.loadDeck(
                    htmlURL: contents.deckHTMLURL,
                    directory: contents.deckDirectory,
                    slideCount: contents.slideCount,
                    slideAspectRatio: contents.slideAspectRatio,
                    inkDirectory: contents.inkDirectory,
                    name: contents.name
                )
                watchForChanges(to: url, files: contents.sourceFiles)
            case .failure(let error):
                DebugLog.write("ipad", "couldn't open \(url.lastPathComponent): \(error)")
                accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                accessedURLs = []
                showOpenError("\(url.lastPathComponent) couldn't be read as a Marp deck: \(error)")
            }
        }
    }

    @objc func exportTapped() {
        PDFExporter.export { [weak self] url in
            guard let self, let url else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                if toolbar.isHidden {
                    popover.sourceView = view
                    popover.sourceRect = CGRect(x: view.bounds.maxX - 40, y: view.safeAreaInsets.top, width: 1, height: 1)
                } else {
                    popover.barButtonItem = toolbar.items?.last
                }
            }
            present(activity, animated: true)
        }
    }

    private func handleStepRequested(_ note: Notification) {
        guard let forward = note.userInfo?["forward"] as? Bool else { return }
        // Don't step the deck hidden behind the slide overview.
        guard !slideCanvas.isOverviewOpen else {
            DebugLog.write("ipad", "step ignored: overview open")
            return
        }
        // The new position arrives through contentView.onPositionChanged.
        slideCanvas.step(forward: forward)
    }
}

extension MainViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pencilPointer || gestureRecognizer === markTap
    }
}

extension MainViewController: PKToolPickerObserver {
    /// The lasso and ruler only work with touches on the ink layer itself,
    /// so while either is in use the ink layer takes every touch (see
    /// SlideCanvasView.inkTakesTouches); fingers go back to the slide once
    /// a pen or the eraser is picked again.
    func updateInkTakesTouches() {
        let lasso: Bool
        if #available(iOS 18.0, *) {
            lasso = toolPicker.selectedToolItem is PKToolPickerLassoItem
        } else {
            lasso = toolPicker.selectedTool is PKLassoTool
        }
        let wasTakingTouches = slideCanvas.inkTakesTouches
        slideCanvas.inkTakesTouches = lasso || toolPicker.isRulerActive
        // The tool picker hands the canvas its new tool before telling this
        // observer, so PencilKit sets the lasso up while its drawing gesture
        // is still parked outside the canvas (see inkTakesTouches), and that
        // lasso never selects anything (it draws a plain gray line instead
        // of the dashed selection loop). Now that the gesture is back on the
        // canvas, hand the lasso over again so PencilKit sets it up properly.
        if lasso, !wasTakingTouches {
            let canvas = slideCanvas.canvasView
            let tool = canvas.tool
            canvas.tool = PKInkingTool(.pen)
            canvas.tool = tool
            DebugLog.write("ink", "lasso re-applied after the drawing gesture moved back")
        }
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        updateInkTakesTouches()
    }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        updateInkTakesTouches()
    }

    func toolPickerIsRulerActiveDidChange(_ toolPicker: PKToolPicker) {
        updateInkTakesTouches()
    }

    /// A finger on the slide (playing a video, tapping a link) makes the
    /// web page first responder, which hides the tool picker. Whenever it
    /// disappears during plain presenting, hand first responder straight
    /// back to the canvas so the tools come back. Not while the overview, a
    /// sheet (file picker, the full-screen video player...) is up, or the
    /// app is going inactive: those hide the picker on purpose.
    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        DebugLog.write("focus", "tool picker \(toolPicker.isVisible ? "shown" : "hidden")")
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
    /// The tool picker hides while the file picker is up, and isn't brought
    /// back then (see toolPickerVisibilityDidChange), so bring it back once
    /// the file picker is done, whether or not a deck was picked.
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        DispatchQueue.main.async { [weak self] in self?.restoreToolPicker() }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        DispatchQueue.main.async { [weak self] in self?.restoreToolPicker() }
        guard let url = urls.first else { return }

        // The folder picker from askForFolder(of:).
        if let markdownURL = markdownAwaitingFolder {
            markdownAwaitingFolder = nil
            guard url.startAccessingSecurityScopedResource() else {
                showOpenError("iOS denied access to \(url.lastPathComponent).")
                return
            }
            guard GrantedFolders.isInside(markdownURL, folder: url) else {
                url.stopAccessingSecurityScopedResource()
                showOpenError("\(markdownURL.lastPathComponent) isn't in “\(url.lastPathComponent)”. Choose the folder the deck is in (or one containing it).")
                return
            }
            GrantedFolders.remember(url)
            DebugLog.write("ipad", "folder allowed: \(url.path)")
            let fileAccess = markdownURL.startAccessingSecurityScopedResource()
            openDeck(at: markdownURL, accessing: [url] + (fileAccess ? [markdownURL] : []))
            return
        }

        // Opening in place (see openTapped) means this URL is
        // security-scoped: reads/writes need startAccessingSecurityScopedResource
        // for as long as the deck stays open.
        guard url.startAccessingSecurityScopedResource() else {
            showOpenError("iOS denied access to \(url.lastPathComponent).")
            return
        }
        if MarpBundleLoader.markdownExtensions.contains(url.pathExtension.lowercased()) {
            guard let folder = GrantedFolders.accessFolder(containing: url) else {
                url.stopAccessingSecurityScopedResource()
                askForFolder(of: url)
                return
            }
            openDeck(at: url, accessing: [folder, url])
        } else {
            openDeck(at: url, accessing: [url])
        }
    }
}

/// Folders the presenter has allowed iMarp to use (for Markdown decks: the
/// theme, assets, rendered HTML and ink beside the deck), remembered across
/// launches as bookmarks. A deck anywhere inside an allowed folder, however
/// deep, opens without asking again.
enum GrantedFolders {
    private static let defaultsKey = "grantedFolderBookmarks"

    static func remember(_ folder: URL) {
        guard let bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        bookmarks.append(bookmark)
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    /// An allowed folder containing `url`, with its security-scoped access
    /// already started (the caller stops it when done), or nil.
    static func accessFolder(containing url: URL) -> URL? {
        let bookmarks = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        for bookmark in bookmarks {
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                  isInside(url, folder: folder),
                  folder.startAccessingSecurityScopedResource()
            else { continue }
            if stale { remember(folder) }
            return folder
        }
        return nil
    }

    static func isInside(_ url: URL, folder: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }
}
