"""The horizontal Radiant logo: the icon tile with the wordmark beside it."""
import re, sys
# Run from the folder holding radiant-tile.svg (radiant.py writes it): python3 wordmark.py
tile = open("radiant-tile.svg").read()
inner = re.sub(r'^<svg[^>]*>', '', tile.strip())[:-len("</svg>")]
def logo(text_colour):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="866" height="256" viewBox="0 0 866 256">'
            '<svg x="0" y="0" width="256" height="256" viewBox="0 0 512 512">' + inner + '</svg>'
            f'<text x="296" y="182" font-family="Avenir Next" font-weight="600" font-size="156" '
            f'letter-spacing="-2" fill="{text_colour}">Radiant</text></svg>\n')
open("radiant-logo-light.svg", "w").write(logo("#1f2328"))  # for GitHub's light theme
open("radiant-logo-dark.svg", "w").write(logo("#f0f6fc"))   # for GitHub's dark theme
