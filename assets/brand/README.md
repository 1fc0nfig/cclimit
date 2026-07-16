# CClimit brand mark: the spark meter

An eight-ray asterisk whose rays fill clockwise from 12 o'clock; the last two stay
faint (30% alpha) as remaining capacity. Spark = Claude homage, faded rays = the limit.
Canonical implementation on the web side: `cclimit-web/components/ui/asterisk.tsx`.

## Files

| File | Use |
|---|---|
| `mark.svg` | Coral mark on transparent. Docs, README, web. |
| `mark-black.svg` | Black mark. **Menu bar template source**: black + per-ray alpha is exactly what `NSImage.isTemplate` wants. |
| `mark-white.svg` | For dark surfaces where template rendering doesn't apply. |
| `app-icon.svg` | 1024 grid: cream rounded-rect (r 232) + coral mark. Base for the `.icns` / Asset Catalog. |
| `asterisk.svg` | Plain spark, all rays full. Decorative uses only, not the logo. |
| `app-icon-1024.png`, `mark-512.png`, `mark-white-512.png` | Rasterized from the SVGs (ImageMagick, transparent except app icon). |

## Geometry (viewBox 24×24, center 12,12)

Rays are lines from inner radius **2.6** to outer radius **2.6 + 7.4 × length**,
stroke **2.4**, round caps. Lengths vary so it reads hand-drawn:

| angle° (SVG, y-down) | direction | length | lit |
|---|---|---|---|
| 270 | up | 0.94 | yes |
| 315 | up-right | 0.68 | yes |
| 0 | right | 1.00 | yes |
| 45 | down-right | 0.72 | yes |
| 90 | down | 0.94 | yes |
| 135 | down-left | 0.70 | yes |
| 180 | left | 1.00 | **dim 0.3** |
| 225 | up-left | 0.74 | **dim 0.3** |

Clockwise order from 12: 270, 315, 0, 45, 90, 135, 180, 225. First six lit, last two
at **0.3 alpha**. Don't change which rays are dim; the mark reads "meter" because the
fade lands at the end of the clockwise sweep.

## Colors

- Coral: `#D97757` (Claude terracotta)
- Cream: `#FAF9F5` (backgrounds, app icon plate)
- Ink: `#141413`

## Swift notes (menu bar)

Draw natively in `IconRenderer` rather than loading the SVG: 8 `NSBezierPath` lines
using the table above, black with alpha 1.0 / 0.3, `isTemplate = true` so macOS tints
it for menu bar appearance and highlight states. This becomes the app's identity glyph
(About window, onboarding); the *usage* icon styles (dualBars/gauge/…) stay as they are.

Animation signature (used on the website, reusable in-app): rays appear clockwise,
one per ~55-100 ms, ease-out; the two dim rays settle at 0.3.
