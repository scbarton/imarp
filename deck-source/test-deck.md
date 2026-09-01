---
marp: true
theme: imarp-test
paginate: true
---

<!-- _class: title -->

## iMarp

# Rendering Test Deck

### Fonts, colors, and images

---

# Custom font & colors

This slide uses a **custom `@font-face`** heading font (Lobster) and
theme-defined accent colors via CSS variables.

- <span style="color:#ffb43c">**orange accent**</span>
- <span style="color:#59c1bd">**teal accent**</span>
- Regular body text in the theme's base color

---

# Image slide

![center width:500px](assets/test-image.png)

A locally-referenced PNG, rendered inline.

---

# Full-bleed background

![bg fit](assets/test-image.png)

---

# Incremental bullets

* First point appears
* Second point appears
* Third point appears

---

# Last slide

If fonts, colors, and images all rendered correctly above, the `WKWebView`
pipeline is solid enough to build the annotation layer on top of.
