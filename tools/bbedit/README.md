# BBEdit → .marpbundle export

Packages a Marp deck (`.md` or `.marp`) authored in BBEdit into a
`.marpbundle`, in the same flat layout the app renders on-device.

## Install

```sh
tools/bbedit/install.sh
```

This copies `make-marpbundle.sh` to `~/Library/Application Support/imarp/`
and compiles the AppleScript into BBEdit's Scripts folder.

## Use

In BBEdit, open the deck you want to export, then choose **Scripts → Export
to marpbundle**. The bundle is created (or updated) next to the source file
and revealed in Finder. Move or sync it into iCloud Drive to open it on the
iPad.

If a `theme.css` or `assets/` folder sits next to the deck file, they're
copied in alongside `source.md`, matching the layout `MarpBundleLoader`
expects.

Re-running on the same deck updates the bundle in place and clears any
cached `source.html` output, so the app re-renders from the latest source.
