import { Marp } from '@marp-team/marp-core'
import { Element } from '@marp-team/marpit'

window.MarpEngine = {
  render(markdown, themeCSS) {
    const marp = new Marp({ html: true, container: new Element('div', { id: ':$p' }) })
    if (themeCSS) {
      marp.themeSet.add(themeCSS)
    }
    return marp.render(markdown)
  },
}
