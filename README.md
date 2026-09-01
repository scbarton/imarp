# imarp

An iPadOS app for presenting pre-rendered [Marp](https://marp.app) slide decks
with Apple Pencil annotation, an external-display presenter mode, and PDF
export — annotation and presentation only, no in-app deck editing.

## How it works

- Decks are rendered to HTML **offline** (via `marp-cli` on a Mac) and opened
  in the app as an `.imarpbundle` package — the app never does Marp rendering
  itself.
- Each slide gets its own `PKDrawing` ink layer, drawn with Apple Pencil (or
  finger) via a `PKCanvasView` overlaid on a `WKWebView`.
- Navigation (including Marp's incremental bullet builds) is driven by
  simulating the same arrow-key presses Marp's own bespoke presentation mode
  responds to — this is fragment-aware, unlike jumping via `location.hash`,
  which always resets a slide's bullets back to hidden.
- Connecting an external display opens a second `UIWindowScene` showing just
  the slide + ink, no toolbar — it stays in lockstep with the main screen by
  reacting to the same navigation/ink events rather than being told a slide
  index.
- **Export PDF** composites each slide's fully-built state (all bullets
  revealed) with its ink overlay into one page per slide.

## The `.imarpbundle` format

A package directory (opens as a single item from Files/iCloud):

```
MyDeck.imarpbundle/
  info.json           { "slideCount": N }
  rendered/
    deck.html         marp-cli's rendered output
    assets/           images/fonts the deck references locally
```

To produce one from a `.md` deck:

```sh
marp deck.md --html --allow-local-files --theme-set path/to/theme.css -o MyDeck.imarpbundle/rendered/deck.html
echo '{"slideCount": N}' > MyDeck.imarpbundle/info.json
```

(`N` is currently hand-counted — nothing validates it against the deck yet.)

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) —
`imarp.xcodeproj` is generated, not committed:

```sh
xcodegen generate
open imarp.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project imarp.xcodeproj -scheme imarp -configuration Debug \
  -destination 'platform=iOS Simulator,name=<a simulator name>' build
```

Building for a physical device on a beta iOS version requires the matching
Xcode beta and `-allowProvisioningUpdates` on first run (to register the
device and generate a provisioning profile).

## Known limitations

- Ink is in-memory only — it isn't written back into the `.imarpbundle`, so
  it's lost on relaunch or when opening a different deck.
- `slideCount` in `info.json` is manually maintained.
- No on-device Marp rendering or deck editing — decks must be pre-rendered.
