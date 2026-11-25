# Third-party notices

## Coopanion

The character rig, animation engine, and whale artwork under `web/kit` and
`web/whale` come from **Coopanion**:

- Source: https://github.com/Pal-AI-Lab/Coopanion
- Copyright (c) the Coopanion contributors
- License: GNU Affero General Public License v3.0 or later, with the additional
  permission under section 7 reproduced at the top of
  `LICENSE-Coopanion.txt` (bundled with this app).

`web/whale/figure.js` is modified from upstream:

1. Added an optional `canvasHost` mount mode that places the WebGL canvas in an
   HTML layer instead of an SVG `<foreignObject>`, because WKWebView on macOS 12
   does not apply the parent SVG transform to a nested WebGL canvas.
2. Added `syncCanvas()` to mirror the pet group's SVG transform onto the canvas
   as a CSS transform, keeping the whale aligned with its shadow and bubble.
3. `dispose()` now detaches the hosted canvas.

`web/stage/index.html` is adapted from Coopanion's stage demo. It adds the
DeepSeek balance bubble, the Electron `coo://app/` host bridge
(`window.cooHost`), press/release messages used by the click-through window,
free-ground dragging on a full-screen transparent stage, a reduced animation
rate on large stages, and recovery when a pointer release arrives outside the
window.

`web/kit/body.js` is modified from upstream: free roaming keeps the body on the
ground line where it was dropped (walks and runs no longer pick a random height
between `minY()` and `floorY`).

All other files copied from Coopanion are unmodified. The corresponding source
of the modified library is included in the `web/` directory of this project and
in the built app under `resources/app/web`.

The Electron shell, the DeepSeek balance client, the encrypted key store, and
the settings window are original to this project (Coo for Windows).