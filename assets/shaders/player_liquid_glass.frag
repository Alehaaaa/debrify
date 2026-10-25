// GlassSurface's Impeller BackdropFilter (NOT a shader painted over a fake
// screenshot). The engine supplies the size and live backdrop image.
// Flutter fragment shader rules:
//   float slots 0,1 = u_size (engine owned); sampler 0 = u_backdrop (engine).
//   Dart sets 2..10 only, in declaration order. Last four floats give the
//   LOCAL pane rectangle even when the backdrop image is window-sized.
#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform float u_radius_px;
uniform float u_refraction_px;
uniform float u_dispersion_px;
uniform float u_saturation;
uniform float u_phase;
uniform vec2 u_lens_origin;
uniform vec2 u_lens_size;
uniform sampler2D u_backdrop;

out vec4 fragColor;

vec2 sourceUV(vec2 localPx) {
  vec2 uv = clamp(localPx / max(u_size, vec2(1.0)), vec2(0.001), vec2(0.999));
  // Impeller GLES filter images have the opposite texture Y orientation.
  #ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
  #endif
  return uv;
}

void main() {
  vec2 size = max(u_size, vec2(1.0));
  vec2 p = FlutterFragCoord().xy;
  // Impeller may crop the filter input to the pane OR provide an image
  // spanning from the window origin to the clip's bottom-right. Handle both.
  // No other pane inherits this lens's origin, radius or optical focus.
  vec2 paneSize = clamp(u_lens_size, vec2(1.0), size);
  if (u_lens_size.x < 1.0 || u_lens_size.y < 1.0) paneSize = size;
  vec2 paneOrigin = size.x < paneSize.x + 3.0 && size.y < paneSize.y + 3.0
      ? vec2(0.0)
      : clamp(u_lens_origin, vec2(0.0), max(size - paneSize, vec2(0.0)));
  vec2 localP = p - paneOrigin;
  vec2 center = paneSize * 0.5;
  float radius = clamp(u_radius_px, 0.0, min(paneSize.x, paneSize.y) * 0.5);

  // Interior distance to a rounded-rect boundary. This follows the exact
  // ClipRRect silhouette of the surface; rounded corners aren't mistaken for
  // ordinary rectangular edges. No dependency on display/screen coordinates.
  vec2 q = abs(localP - center) - max(center - vec2(radius), vec2(0.0));
  float sdf = length(max(q, vec2(0.0))) +
              min(max(q.x, q.y), 0.0) - radius;
  float depth = max(0.0, -sdf);
  // Each BackdropFilter now has its OWN image-filter layer. The local
  // rounded-rectangle edge of that pane, rather than the window's centre,
  // forms the curved lens. A wide transition band makes the deformation
  // read clearly (pronounced Apple-style lensing), not a hairline bevel.
  float lensBand = clamp(radius * 1.0, 8.0, 26.0);
  float edge = 1.0 - smoothstep(0.0, lensBand, depth);
  // Keep the interior almost perfectly registered with the backdrop so the
  // video doesn't appear shifted inside the pane; only the rim bends.
  float interior = (1.0 - edge) * 0.06;

  // Use the actual nearest rounded-rect boundary normal. The old radial
  // centre direction bent the long top/bottom edges sideways on a wide dock.
  // On straight segments the normal is axis-aligned; rounded corners use the
  // vector from the arc centre. Everything is local to the filter's bounds.
  vec2 local = localP - center;
  vec2 flatHalf = max(center - vec2(radius), vec2(0.0));
  vec2 arc = local - clamp(local, -flatHalf, flatHalf);
  vec2 flatNormal = q.x > q.y
      ? vec2(local.x < 0.0 ? -1.0 : 1.0, 0.0)
      : vec2(0.0, local.y < 0.0 ? -1.0 : 1.0);
  vec2 direction = length(arc) > 0.001 ? normalize(arc) : flatNormal;
  vec2 tangent = vec2(-direction.y, direction.x);

  // Apple's material is a STEADY convex lens: strong, clean edge refraction
  // (up to 22 physical px) with only a faint motion wobble, not a rippling
  // liquid warp. UI labels/icons are overlaid by Flutter AFTER the filter, so
  // their glyphs never deform.
  float flex = 1.0 + 0.06 * sin(u_phase + localP.x * 0.018 + localP.y * 0.013);
  float ripple = sin(u_phase + localP.y * 0.027 - localP.x * 0.011);
  vec2 offset = min(u_refraction_px, 22.0) *
      (-direction * (edge * edge + interior) * flex +
       tangent * (0.05 * edge * ripple));
  vec2 refracted = p + offset;

  // Chromatic dispersion is RADIAL and lives only in the distorted edge: its
  // magnitude follows the SAME edge-bend profile as the refraction (edge*edge),
  // so colour splits exactly where the lens is bending the image and is zero
  // across the flat interior — not a gradient transitioning through the whole
  // band. The split is along `direction` (the outward edge normal), so red and
  // blue separate perpendicular to the rim all the way around.
  float split = min(u_dispersion_px, 7.5) * edge * edge;
  vec2 channelShift = direction * split;

  // Dispersed body sample: radial red/blue split, tight to the rim.
  vec4 mid = texture(u_backdrop, sourceUV(refracted));
  vec4 red = texture(u_backdrop, sourceUV(refracted + channelShift));
  vec4 blue = texture(u_backdrop, sourceUV(refracted - channelShift));
  vec3 body = vec3(red.r, mid.g, blue.b);

  // Stronger edge blur RAMP: a 4-tap box blur whose spread grows toward the
  // rim (edge*edge) and is zero in the interior, so the backdrop smears like
  // thick glass at the curved edge while the centre stays sharp and registered.
  float blurPx = edge * edge * min(u_refraction_px, 22.0) * 0.5;
  vec2 bx = vec2(blurPx, 0.0);
  vec2 by = vec2(0.0, blurPx);
  vec3 blurAcc = texture(u_backdrop, sourceUV(refracted + bx)).rgb +
                 texture(u_backdrop, sourceUV(refracted - bx)).rgb +
                 texture(u_backdrop, sourceUV(refracted + by)).rgb +
                 texture(u_backdrop, sourceUV(refracted - by)).rgb;
  vec3 refractedRGB = mix(body, blurAcc * 0.25, edge * 0.7);

  float luma = dot(refractedRGB, vec3(0.2126, 0.7152, 0.0722));
  vec3 color = mix(vec3(luma), refractedRGB, clamp(u_saturation, 0.65, 1.4));
  fragColor = vec4(color, mid.a);
}
