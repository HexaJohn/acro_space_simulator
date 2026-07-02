// Planetary ring sheet: per-fragment radial band profile with fuzzy band
// edges, plus a camera-centred hole where the instanced asteroid field
// spawns (the rocks REPLACE the sheet up close; the hole radius tracks the
// field's visibility/vertical fade from the Dart side, so sheet and rocks
// cross-fade symmetrically).
//
// Runs on the engine's standard vertex outputs over a flat annulus mesh
// (both windings, translucent pass). Distances in SCENE UNITS (km).
// Output premultiplied.

uniform RingInfo {
  // xyz: ring centre (scene, focus-relative). w: inner radius (scene).
  vec4 centre_inner;
  // xyz: ring-plane U basis (unit). w: outer radius (scene).
  vec4 axis_u;
  // xyz: ring-plane V basis (unit). w: hole radius around the eye (scene;
  // 0 disables the hole).
  vec4 axis_v;
  // xyz: eye position (scene, focus-relative). w: band edge fuzz, in
  // normalised t units (fraction of the inner->outer span).
  vec4 eye_fuzz;
  // 12 x (t0, t1, alpha, unused): band extents normalised across
  // [inner, outer] with an opacity multiplier...
  vec4 band_a[12];
  // ...and 12 x (r, g, b, unused): straight (unpremultiplied) band colour,
  // already scaled by the ring's base intensity on the CPU.
  vec4 band_c[12];
  // x: band count. yzw: unused.
  vec4 counts;
  // xyz: unit direction from the ring centre TOWARD the sun.
  // w: planet radius (scene units) — the shadow caster.
  vec4 sun_planet;
}
ring_info;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

void main() {
  vec3 rel = v_position - ring_info.centre_inner.xyz;
  float inner = ring_info.centre_inner.w;
  float outer = ring_info.axis_u.w;
  float r = length(vec2(dot(rel, ring_info.axis_u.xyz),
                        dot(rel, ring_info.axis_v.xyz)));
  float t = (r - inner) / (outer - inner);
  float fuzz = max(ring_info.eye_fuzz.w, 1e-4);

  float alpha = 0.0;
  vec3 colour = vec3(0.0);
  int n = int(ring_info.counts.x);
  for (int i = 0; i < 12; i++) {
    if (i >= n) break;
    vec4 b = ring_info.band_a[i];
    float w = smoothstep(b.x - fuzz, b.x + fuzz, t) *
        (1.0 - smoothstep(b.y - fuzz, b.y + fuzz, t));
    float wa = b.z * w;
    alpha += wa;
    colour += ring_info.band_c[i].rgb * wa;
  }
  if (alpha <= 1e-4) {
    frag_color = vec4(0.0);
    return;
  }
  colour /= alpha; // opacity-weighted band colour

  // Camera hole: the asteroid field takes over inside it. Ease from 55%
  // of the radius so the sheet dissolves under the rocks, not at a rim.
  float hole = ring_info.axis_v.w;
  if (hole > 0.0) {
    float d = distance(v_position, ring_info.eye_fuzz.xyz);
    alpha *= smoothstep(hole * 0.55, hole, d);
  }

  // Planet shadow: a fragment whose sun ray dips into the planet sphere
  // sits in the umbra. Closest-approach altitude gives a soft penumbra
  // edge (a few percent of the planet radius); the floor keeps the
  // shadowed arc readable rather than pitch black.
  vec3 sunDir = ring_info.sun_planet.xyz;
  float planetR = ring_info.sun_planet.w;
  if (planetR > 0.0) {
    vec3 op = rel; // fragment relative to the ring/planet centre
    float tStar = -dot(op, sunDir);
    if (tStar > 0.0) {
      float minAlt = length(op + sunDir * tStar) - planetR;
      float lit = smoothstep(0.0, planetR * 0.04, minAlt);
      colour *= 0.12 + 0.88 * lit;
    }
  }

  alpha = clamp(alpha, 0.0, 1.0);
  frag_color = vec4(colour * alpha, alpha); // premultiplied
}
