# imarp

An iPadOS app for presenting pre-rendered [Marp](https://marp.app) slide decks
with Apple Pencil annotation, an external-display presenter mode, and PDF
export — annotation and presentation only, no in-app deck editing.

## How it works

- Decks render **on-device**: `@marp-team/marp-core` is bundled (as an esbuild
  browser build) and run in a hidden `WKWebView`, so editing a deck's Markdown
  in any Files-aware editor and reopening it is enough — no Mac round-trip. The
  rendered HTML is cached inside the bundle and reused until the Markdown is
  newer.
- Each slide gets its own `PKDrawing` ink layer, drawn with Apple Pencil (or
  finger) via a `PKCanvasView` overlaid on a `WKWebView`.
- Navigation (including Marp's incremental bullet builds) is driven by
  simulating the same arrow-key presses Marp's own bespoke presentation mode
  responds to — this is fragment-aware, unlike jumping via `location.hash`,
  which always resets a slide's bullets back to hidden.
- Connecting an external display opens a second `UIWindowScene` showing just
  the slide + ink, no toolbar — it stays in lockstep with the main screen by
  reacting to the same navigation/ink events rather than being told a slide
  index. Ink is remapped slide-rect to slide-rect on the way across, since the
  two screens letterbox the slide differently.
- **Export PDF** composites each slide's fully-built state (all bullets
  revealed) with its ink overlay into one page per slide.

## The `.imarpbundle` format

A package directory (opens as a single item from Files/iCloud):

```
MyDeck.imarpbundle/
  source/
    deck.md           the actual Markdown — what an external editor touches
    theme.css         optional; registered with marp-core by name
    assets/           images/fonts deck.md references locally
  rendered/           cache, regenerated on-device when deck.md is newer
    deck.html
    assets/
```

The app is still presentation-only — it never writes `source/`. Keeping the
Markdown in the bundle is what lets a separate editor (iA Writer, Obsidian, …)
edit the deck in place via Files/iCloud.

A bundle with only `rendered/` (static HTML, no editable source) also opens
fine. Slide count and aspect ratio are parsed from the rendered HTML, so
nothing needs to be maintained by hand.

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
- Ink is stored in the authoring canvas's coordinates and rescaled for display.
  Storing it in normalized slide coordinates would be more durable, and is
  worth doing alongside ink persistence.
- The external display uses `UISceneAccessory`, which is iOS 27+. A legacy
  path for iOS 17–26 is present but untested.
