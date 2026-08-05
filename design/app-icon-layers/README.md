# App icon — SVG layers

These are the vector layers used to author `Sources/AppIcon.icon` in Apple's
Icon Composer. That `.icon` document is the app's single icon source (actool
generates the macOS ≤15 fallbacks from it); these SVGs are kept so the icon
can be re-assembled if the geometry or composition ever changes.

The layers are generated — don't hand-edit. `Scripts/export-icon-layers.swift`
is the geometry source of truth (proportions measured from the official
Syncthing logo SVG) and rewrites this folder when run.

Bottom → top in the Icon Composer document:

1. `1-mark.svg` — the white Syncthing ring/nodes/hub/spokes
2. `2-panel.svg` — the menu panel (Liquid Glass material applied in IC)
3. `3-row-highlight.svg` — the selected menu row (white, ~95% opacity)
4. `4-rows-quiet.svg` — the four quiet rows (white, ~62% opacity)

Not captured in any SVG: the background is a vertical linear gradient set
directly in Icon Composer, `#25A8D3` (top) → `#106EBC` (bottom) — sampled
from Syncthing's own app icon so the two read as siblings.
