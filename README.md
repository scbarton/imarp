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
  finger) via a `PKCanvasView` overlaid on a `WKWebView`. Ink is persisted back
  into the bundle as `ink/<slideIndex>.drawing` — see the format below —
  debounced to once per slide shortly after a stroke settles, and flushed
  immediately if the app backgrounds. A deck is opened in place (not copied),
  which is what makes both this and the rendered-HTML cache actually stick
  across relaunches.
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

## The `.marpbundle` format

A package directory (opens as a single item from Files/iCloud), laid out
flat so `source.html` and `assets/` are plain siblings — no `<base href>` or
asset-copying trick needed for images to resolve:

```
MyDeck.marpbundle/
  source.md           the actual Markdown — what an external editor touches
  source.html         cache, regenerated on-device when source.md is newer
  theme.css           optional; registered with marp-core by name
  assets/             images/fonts source.md (and so source.html) refer to
  ink/                Apple Pencil annotations, one file per slide index
    0.drawing         (PKDrawing.dataRepresentation()) — a slide with no
    ...               ink has no file, so a clean deck has no ink/ at all
```

`ink/` is kept separate from `source.md`/`source.html` so that re-exporting
the deck (which only touches those two — see `tools/bbedit/`) never wipes
annotations.

The app is still presentation-only — it never writes `source.md`. Keeping the
Markdown in the bundle is what lets a separate editor (iA Writer, Obsidian, …)
edit the deck in place via Files/iCloud.

A bundle with only `source.html` (static HTML, no editable source) also opens
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

- Ink is stored in the authoring canvas's coordinates, not normalized slide
  coordinates — it's rescaled for the external display at display time (see
  `SlideCanvasView.slideRect`), but a saved `.drawing` file is tied to the
  canvas size it was drawn on. In practice this only matters across a
  Split View/Stage Manager resize or a future iPad with a different screen;
  full-screen use on one device is unaffected.
- The app doesn't remember which deck was open across a relaunch — there's no
  "recent decks" list, so re-opening currently means picking the bundle again
  via Open…. (Ink and the rendered cache themselves persist fine; it's only
  the "which bundle was I looking at" state that isn't remembered.)
- The external display uses `UISceneAccessory`, which is iOS 27+. A legacy
  path for iOS 17–26 is present but untested.
