# marp-engine-build (prototype)

Not yet wired into the app. Proves that on-device Marp rendering is
feasible: `@marp-team/marp-core` bundles to plain browser JS with no Node/DOM
dependencies, and its output can be spliced into `marp-cli`'s bespoke.js
presentation shell to get full interactive navigation (including fragments)
without ever touching a Mac.

- `entry.js` / `marp-engine.min.js` — `marp-core` bundled via esbuild,
  exposes `window.MarpEngine.render(markdown, themeCSS?) -> { html, css }`.
  Rebuild with `npm install && npx esbuild entry.js --bundle --minify --format=iife --platform=browser --outfile=marp-engine.min.js`.
- `shell-src/placeholder.md` — trivial one-slide deck rendered once via
  `marp-cli` to capture its bespoke.js/CSS chrome.
- `shell.html` — that chrome with the placeholder's own content stripped out
  and replaced with two markers: `<!--IMARP_SLIDES-->` and
  `<!--IMARP_STYLE-->`. Splice in `MarpEngine.render()`'s `html`/`css` output
  at those markers to get a fully interactive presentation page.

Key detail: `marp-core`'s default output isn't scoped to marp-cli's
container id, so it won't match the shell's CSS. Render with:

```js
new Marp({ html: true, container: new Element('div', { id: ':$p' }) })
```

(`Element` from `@marp-team/marpit`) to get byte-compatible output.

Next step: wire this into the app as `MarpRenderer.swift` (a hidden
`WKWebView` running `marp-engine.min.js`) and extend `.imarpbundle` to carry
`source/deck.md` for on-device rendering, per the plan discussed in-session.
