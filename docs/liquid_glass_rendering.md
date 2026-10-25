# Liquid Glass rendering (player controls)

How Nextup makes the video‑player chrome look like Apple's "Liquid Glass":
frosted panes that **refract the moving video behind them**, bend it at the
curved edge like a real lens, and split the colour channels into a chromatic
fringe along that edge — plus a specular highlight on the rim.

This documents the technique, the online references it's based on, and exactly
where it lives in our code so it can be tuned without re‑deriving it.

> Apple does **not** publish its shader. Everything below is the community
> consensus reconstruction of the effect, adapted to Flutter. Treat the
> "edge mask + per‑channel offset + refraction + specular rim" pattern as the
> agreed recipe, not as Apple's confirmed method.

## What Apple's material actually looks like

From Apple's own description and hands‑on reviews — so we aim at the right thing:

- **Refraction by curvature is the hero.** Light "bends in different directions
  based on the curvature of the glass," so content *underneath* a control gets
  distorted and blurred as it passes beneath the curved edge. This — not blur
  alone — is what separates Liquid Glass from ordinary glassmorphism, which
  "blurs the backdrop but does not refract it." ([Apple newsroom][apple],
  [MacStories][macstories])
- **Specular highlights that react to motion.** The material "dynamically
  reacts to movement with specular highlights"; convex shapes are reinforced by
  a bright edge catch, usually from a light near the top‑left, that shifts as
  the device tilts. ([Apple newsroom][apple])
- **Colour adapts, it doesn't rainbow.** The tint is "informed by surrounding
  content and intelligently adapts between light and dark." Chromatic aberration
  is at most a *subtle* trait of real glass — "subtly bending and bleeding
  colour around motion" — never a bold rainbow outline. Keep it a whisper,
  **radial** and confined to the curved edge.
- **Accessibility.** Reduce Transparency flattens the lensing to a solid plate;
  Reduce Motion tones down the highlight/animation.

So the priority order for "looks like Apple" is: **clean edge refraction →
specular rim → adaptive frost/tint → a faint radial edge dispersion.** If the
colour fringe is the first thing you notice, it's wrong.

---

## The five ingredients

A convincing liquid‑glass pane is five layered effects, in this order:

1. **Frost** — a Gaussian blur of the backdrop. Light, not milky. This is the
   "a little frosted" look; the backdrop colours must still read through. On the
   shader path it *ramps*: near‑sharp and registered in the interior, smearing
   more toward the curved rim (a 4‑tap blur weighted by the edge mask), like
   thick glass.
2. **Refraction / lens distortion** — the backdrop is *displaced* toward the
   pane's centre, strongest at the rounded edge and fading to nothing in the
   middle. This is what makes it read as a thick piece of glass rather than a
   blurred rectangle.
3. **Chromatic aberration** — a faint, **radial** colour split: red and blue
   sampled with opposite offsets *along the edge normal*, with a magnitude that
   follows the refraction's own edge‑bend profile (`edge*edge`) so it lives only
   where the lens is actually distorting the image and is zero across the flat
   interior. Not a gradient transitioning through the whole band, and never a
   flat painted outline.
4. **Specular rim** — a bright hairline on the top‑left, fading along the sides,
   a faint return bottom‑right: where a light would catch the bevel.
5. **Tint + shade** — a restrained neutral veil so white controls stay legible
   over any colour grade, without burying the backdrop under an opaque plate.

Two details separate "premium glass" from "gimmick":

- **Edge‑concentrated, not uniform.** Refraction and aberration are driven by a
  signed‑distance mask of the rounded‑rect; the interior barely moves. A
  uniform rainbow tint over the whole pane looks fake.
- **Render order matters.** Tint/colour → blur → lens pass **last**. Blurring
  after the lens smears the displaced edges.

---

## Pipeline order

```
backdrop ──▶ saturation/tint ──▶ Gaussian frost ──▶ lens (refraction + CA) ──▶ specular rim ──▶ icon/text on top
```

The glyphs (icon + label) are painted **after** the backdrop filter, so text
never warps — only the video behind the glass does.

---

## How Nextup implements it

There are two render paths, chosen at runtime by the renderer:

| Path | When | What it does |
|------|------|--------------|
| **Impeller shader** (full effect) | Impeller is the active renderer | `ImageFilter.shader` runs `assets/shaders/player_liquid_glass.frag` as a `BackdropFilter`, doing **real** per‑channel refraction of the live composited backdrop. This is "chromatic aberration *of the image*." |
| **Skia fallback** (approximation) | Impeller is off (`ImageFilter.shader` throws) | Gaussian frost + a **whisper** of affine `ImageFilter.matrix` zoom (1.02 — kept near‑identity so the backdrop stays registered, not sliding out from under the glass) + a **painted radial** R/G/B edge fringe (`rrect.inflate`, additive) + the specular rim. It never claims to refract the backdrop per‑channel; Skia can't, and a large zoom only makes the content look offset. Spatial edge‑blur ramp is Impeller‑only. |

`ImageFilter.shader` is only supported when **Impeller** is enabled
(`ImageFilter.isShaderFilterSupported == _impellerEnabled`); on any other
backend it throws `UnsupportedError`, and we fall back. See the Flutter
[fragment‑shader docs][flutter-frag] and the [`ImageFilter.shader`][if-shader]
/ [`isShaderFilterSupported`][if-supported] API.

### ⚠️ macOS needs Impeller turned on explicitly

The macOS embedder defaults `FLTEnableImpeller` to **`NO`** when the Info.plist
key is absent — i.e. macOS runs **Skia** unless told otherwise, so the shader
never runs and you get the painted fallback. We enable it in
`macos/Runner/Info.plist`:

```xml
<key>FLTEnableImpeller</key>
<true/>
```

iOS and Android already default to Impeller, so they get the shader path for
free. If macOS rendering ever regresses, removing that key reverts to Skia (and
the fallback) with no other code change.

### File map

| File | Role |
|------|------|
| `lib/screens/video_player/widgets/liquid_glass.dart` | `GlassSurface` widget, both render paths, the `_RimPainter` specular rim + Skia dispersion fringe, the motion clock, brightness probe. |
| `assets/shaders/player_liquid_glass.frag` | The Impeller fragment shader: rounded‑rect SDF, edge refraction, edge blur ramp, radial per‑channel split, saturation. |
| `assets/design/glass_tokens.json` | Every tunable number (blur, tint, rim, shadow, **optics**). |
| `macos/Runner/Info.plist` | `FLTEnableImpeller` → shader on macOS. |
| `test/glass_tokens_test.dart` | Guards that the JSON and the compiled `GlassTokens.defaults` never drift apart. |
| `lib/screens/video_player/widgets/glass_dock.dart` | The player chrome that consumes `GlassSurface` (panel, circle buttons, ghost buttons, More sheet). |

---

## Tuning

All optics live in `assets/design/glass_tokens.json` under `"optics"`. **If you
change them you must change the matching `GlassTokens.defaults` constant in
`liquid_glass.dart` identically** — the drift test enforces it.

| Token | Meaning | Subtle → Pronounced |
|-------|---------|---------------------|
| `refractionPx` / `strongRefractionPx` | Max edge displacement (logical px); also scales the edge blur ramp. `strong` is the play button. | currently 14 / 18 |
| `dispersionPx` / `strongDispersionPx` | Radial chromatic split at the rim. | currently 2.8 / 3.8 |
| `shaderBlurFraction` / `shaderMaxBlur` | Base frost on the shader path (kept low; the edge ramp adds the rest). Higher = milkier. | currently 0.14 / 3.0 |
| `fallbackMaxBlur` | Frost cap on the Skia path. | 16 |

The shader has internal clamps so a large token can't tear the image; raise them
in lockstep if you push the tokens further:

- `lensBand` — width of the edge deformation band (`clamp(radius * 1.0, 8, 26)`).
- `flex` — faint convex‑bend motion only (`0.06`); the glass is a steady lens,
  not a rippling liquid.
- `interior = (1 - edge) * 0.06` — keep this small so the interior stays
  registered with the video.
- `min(u_refraction_px, 22.0)` — hard cap on displacement; also drives the edge
  blur ramp (`edge*edge * cap * 0.5`).
- `min(u_dispersion_px, 5.0) * edge * edge` — radial dispersion, keyed to the
  edge‑bend profile so it lives only on the distorted rim.
- `mix(body, blurAcc * 0.25, edge * 0.7)` — how strongly the edge blur ramp
  takes over toward the rim.

The Skia fallback fringe is painted in `_RimPainter`: pure R/G/B strokes under
`BlendMode.plus`, split **radially** (`rrect.inflate(±spread)`, red out / blue
in) so overlaps sum back toward white and only the rim carries colour. Two
passes (a broad faint halo + a tight brighter core) make it fade out instead of
reading as a hard second outline.

### Variants

- `frosted` — high blur, subtle tint. Sheets and menus.
- `translucent` — low blur, strong base. Small buttons that must read on any frame.
- `dynamic` — follows backdrop brightness (`GlassBrightnessProbe`): clear and
  saturated over dark scenes, denser over bright ones so white stays legible.

---

## Gotchas

- **Each pane owns its own lens.** Don't use `BackdropFilter.grouped` / a shared
  backdrop key — it turns every button into a mask cut out of one screen‑wide
  distortion. Each `GlassSurface` measures its own paint bounds
  (`_LocalGlassGeometry`) and feeds them to the shader as `u_lens_origin` /
  `u_lens_size` in physical pixels.
- **Motion is gated.** The edge shape flexes at ≤10 Hz, only while primary
  player chrome is mounted and the app is foregrounded, and never under
  "reduce motion". Static glass with aberration left on looks fake, and it costs
  GPU. The moving *video* is re‑sampled by the compositor every frame regardless.
- **Never read pixels from the video.** No screenshots per frame; the shader
  samples whatever Flutter actually composited behind the glass. Platform video
  overlays that bypass Flutter composition aren't guaranteed as filter input.
- **High contrast / reduce transparency** → a solid legible plate, no blur, no
  fringe.

---

## References

Third‑party reconstructions and the Flutter APIs we rely on. None is Apple
source; they agree on the edge‑mask + per‑channel‑offset pattern and disagree on
exact falloff curves.

- [Liquid Glass: iOS Effect Explanation — Medium (aghajari)][medium] — GLSL
  edge‑SDF mask with per‑channel offset strongest at the rim.
- [apple‑liquid‑glass‑guide — GitHub (sitong‑zhang)][guide] — real‑time
  refraction, chromatic aberration, edge highlights; notes that aberration
  should be active mainly during interaction and that order is colour → blur →
  lens last.
- [StreamUP LucidGlass (OBS shader)][lucid] — exposes the edge falloff as a
  tunable power curve.
- [WebGL liquid‑glass library — DEV.to][devto] — samples R/G/B with opposite
  offsets at the edge, limits aberration to edge pixels for performance.
- [Liquid Glass in CSS and WebGL — html‑in‑canvas.dev][canvas] — refraction pass
  layered over the aberration.
- [liquid_glass_widgets — Flutter (sdegenaar)][flutterpkg] — a Flutter UI kit
  taking the shader‑based approach; falls back to a plain blur where backdrop
  shaders are unavailable.
- [Flutter: Writing and using fragment shaders][flutter-frag] ·
  [`ImageFilter.shader`][if-shader] · [`isShaderFilterSupported`][if-supported].

[medium]: https://medium.com/@aghajari/liquid-glass-ios-effect-explanation-dabadd6414ae
[guide]: https://github.com/sitong-zhang/apple-liquid-glass-guide
[lucid]: https://docs.streamup.tips/obs-shaders/streamup_lucid_glass.html
[devto]: https://dev.to/maxgeris/webgl-based-javascript-library-for-pixel-perfect-ios-liquid-glass-effect-with-refractions-and-3p8m
[canvas]: https://html-in-canvas.dev/liquid-glass-effect/
[flutterpkg]: https://github.com/sdegenaar/liquid_glass_widgets
[flutter-frag]: https://docs.flutter.dev/ui/design/graphics/fragment-shaders
[if-shader]: https://api.flutter.dev/flutter/dart-ui/ImageFilter/ImageFilter.shader.html
[if-supported]: https://api.flutter.dev/flutter/dart-ui/ImageFilter/isShaderFilterSupported.html
