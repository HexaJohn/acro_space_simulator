// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Spacetime-distortion grid: a polar graticule over the funnel disc under a
// body (see GravityGridNodes). The mesh's texture coords carry the grid
// parameterisation — u = angle / 2pi, v = normalised planar radius (hole rim
// at shape.z, outer rim at 1) — so the lines are drawn per fragment with
// screen-space (fwidth) anti-aliasing: crisp at any zoom, no texture, no
// tessellation dependence.
//
// Runs on the engine's standard vertex outputs (both windings, translucent
// pass). Output premultiplied.

uniform GridInfo {
  // xyz: line colour (unpremultiplied). w: overall opacity — keyed on the
  // body's surface gravity by the Dart side (plus apparent-size fade).
  vec4 color_alpha;
  // x: ring count between hole rim and outer rim. y: spoke count.
  // z: hole radius r0 (normalised planar units, = 1/extent multiplier).
  // w: rim fade start (normalised radius; alpha reaches 0 at 1.0).
  vec4 shape;
}
grid_info;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

// Anti-aliased distance to the nearest integer multiple of 1/count in
// coord's 0..1 span: ~1.2 px wide lines whatever the zoom.
float gridLine(float coord, float count) {
  float x = coord * count;
  float dist = abs(x - floor(x + 0.5));      // distance to nearest integer
  float px = fwidth(x);                      // integer units per pixel
  return 1.0 - smoothstep(0.0, max(px * 1.2, 1e-6), dist);
}

void main() {
  float u = v_texture_coords.x; // angle / 2pi
  float v = v_texture_coords.y; // planar radius, r0..1
  float r0 = grid_info.shape.z;

  // Radial position normalised across the sheet (0 = hole rim, 1 = outer).
  float t = clamp((v - r0) / (1.0 - r0), 0.0, 1.0);

  // Rings evenly spaced in radius; spokes evenly spaced in angle. The u
  // seam duplicates vertices at u=0/u=1, and integer spoke counts put a
  // line on both sides of it, so the seam is invisible.
  float lines = max(gridLine(t, grid_info.shape.x),
                    gridLine(u, grid_info.shape.y));
  if (lines <= 1e-3) {
    frag_color = vec4(0.0);
    return;
  }

  // Deeper in the well reads denser (local gravity is stronger); the outer
  // rim dissolves so the sheet has no hard edge.
  float depthBoost = mix(1.0, 0.4, t);
  float rim = 1.0 - smoothstep(grid_info.shape.w, 1.0, v);

  float alpha = clamp(
      grid_info.color_alpha.w * lines * depthBoost * rim, 0.0, 1.0);
  frag_color = vec4(grid_info.color_alpha.rgb * alpha, alpha); // premultiplied
}
