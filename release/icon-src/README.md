# The Radiant icon and logo (main only; not shipped)

- `radiant.py OUT_DIR` writes `radiant-tile.svg` (the dark rounded tile) and
  `radiant.svg` (transparent): a goal DAG as glowing lines, finished goals
  mint, the goal in progress a gold core, the rest hollow blue.
- `wordmark.py` (run in OUT_DIR) writes `radiant-logo-light.svg` and
  `radiant-logo-dark.svg`: the tile with "Radiant" in Avenir Next beside it.
- PNGs: `rsvg-convert -w 512 radiant-tile.svg -o radiant-tile-512.png` (and
  256); the logos at `-w 1732`. The shipped copies live in `release/overlay/assets/`.
