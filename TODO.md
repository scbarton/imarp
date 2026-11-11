# To do

- [ ] **Progress bar for PDF export.** Export PDF gives no feedback while it works, and a long deck takes a while: `PDFExporter` steps an offscreen web view through every slide and snapshots each one before the share sheet appears. Show progress ("Exporting slide 12 of 40") with a bar, ideally with a Cancel button, on both the iPad and the Mac. `PDFExporter.export` would need to report each finished slide (e.g. a progress callback, or a `Progress` object).
