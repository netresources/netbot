# Vendored chart library

One chart library is shipped with the live page. Nothing is loaded from a network at runtime.

| | |
|---|---|
| Name | uPlot |
| Version | 1.6.32 |
| License | MIT |
| License file | `LICENSE` (copyright 2022 Leon Sorokin) |
| Shipped file | `uPlot.iife.min.js` |

The live page loads that file as a classic script (`/assets/uplot.js`). It assigns one global, `uPlot`. The upstream stylesheet is not included. Chart chrome uses NetBot tokens in `netbot/theme/netbot-live.css`.

The shipped script is the upstream file, unmodified.

## Checksums (sha256)

Shipped script, same bytes as upstream `dist/uPlot.iife.min.js`:

`19c8d4c6ad88929a79f4ae49d6f7161566dfd0ba3d15cc495e974f787eb78f1f` (51081 bytes)

License file:

`8f989229699b4fe2f1a0432d0e9edc338a8a911e250e2d1b01ecd770a5f5b1bd` (1078 bytes)

## Where it came from

npm package `uplot@1.6.32`, file `dist/uPlot.iife.min.js`.

The same file is in the leeoniya/uPlot repository at tag `1.6.32`, path `dist/uPlot.iife.min.js`. The license file is in that repository at the same tag.

The sha256 of `dist/uPlot.iife.min.js` in the npm package matches the file at that tag. The copy in this directory is those bytes.
