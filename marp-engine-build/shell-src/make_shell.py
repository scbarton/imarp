"""Turns a marp-cli render of placeholder.md into imarp's presentation shell.

Usage: python make_shell.py shell_raw.html ../shell.html

The deck-specific parts are swapped for markers that MarpBundleLoader.assemble
fills with MarpEngine.render() output: the theme <style> becomes
<!--IMARP_STYLE--> and the slide container <div id=":$p">...</div> becomes
<!--IMARP_SLIDES-->. Everything else (bespoke.js and its CSS) is kept as is.
"""
import sys

raw = open(sys.argv[1], encoding="utf-8").read()

theme_start = raw.index('<style>div#\\:\\$p > svg')
theme_end = raw.index("</style>", theme_start) + len("</style>")
shell = raw[:theme_start] + '<style id="imarp-theme-style"><!--IMARP_STYLE--></style>' + raw[theme_end:]

slides_start = shell.index('<div id=":$p">')
slides_end = shell.index("<script>/*!! License", slides_start)
shell = shell[:slides_start] + "<!--IMARP_SLIDES-->" + shell[slides_end:]

open(sys.argv[2], "w", encoding="utf-8").write(shell)
