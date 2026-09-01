import { Marp } from '@marp-team/marp-core'

window.MarpEngine = {
  Marp,
  render(markdown, themeCSS) {
    const marp = new Marp({ html: true })
    if (themeCSS) {
      marp.themeSet.add(themeCSS)
    }
    return marp.render(markdown)
  },
}
