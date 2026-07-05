// Voxel-terrain surface: procedural per-fragment shading by SLOPE + ALTITUDE,
// with a sun Lambert term. No texture assets yet — the triplanar blend weights
// are computed here so tileable rock/sand/snow textures can drop in later
// behind the same code (sample per axis, weight by |normal|). Distances are in
// SCENE UNITS (km), matching v_position. Opaque pass.

uniform TerrainInfo {
  // xyz: body centre (scene, focus-relative). w: datum radius (scene).
  vec4 centre_radius;
  // xyz: sun travel direction (scene, unit; light goes FROM sun toward the
  // scene). w: relief amplitude (scene).
  vec4 sun_amp;
  // x: sea radius (scene). y: ambient. z: snow altitude start (0..1 of relief
  // above sea). w: rock slope threshold (cos angle; below this = cliff rock).
  vec4 params;
  // Straight RGB palette (a = unused): low flat ground, high flat ground,
  // steep rock, snow.
  vec4 col_low;
  vec4 col_high;
  vec4 col_rock;
  vec4 col_snow;
}
terrain;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

void main() {
  vec3 rel = v_position - terrain.centre_radius.xyz;
  float dist = length(rel);
  vec3 up = dist > 1e-6 ? rel / dist : vec3(0.0, 0.0, 1.0);

  // Geometric normal, flipped to face the viewer so both windings light right.
  vec3 n = normalize(v_normal);
  if (dot(n, v_viewvector) < 0.0) n = -n;

  // Slope: 1 = flat (normal along up), 0 = vertical cliff.
  float slope = clamp(dot(n, up), 0.0, 1.0);
  // Normalised altitude above sea, in units of relief amplitude.
  float amp = max(terrain.sun_amp.w, 1e-6);
  float altN = clamp((dist - terrain.params.x) / amp, -1.0, 1.0);

  // Flat ground: low->high by altitude. Snow blends in up high.
  vec3 flat_col = mix(terrain.col_low.rgb, terrain.col_high.rgb,
                      smoothstep(-0.2, 0.6, altN));
  float snow = smoothstep(terrain.params.z, terrain.params.z + 0.25, altN);
  flat_col = mix(flat_col, terrain.col_snow.rgb, snow * smoothstep(0.4, 0.9, slope));

  // Steep faces are rock regardless of altitude.
  float rockw = 1.0 - smoothstep(terrain.params.w, terrain.params.w + 0.15, slope);
  vec3 albedo = mix(flat_col, terrain.col_rock.rgb, rockw);

  // Sun Lambert + ambient. Light travels along sun_amp.xyz, so a surface is
  // lit by the component facing back toward the sun (-dir).
  float lit = max(dot(n, -terrain.sun_amp.xyz), 0.0);
  float shade = terrain.params.y + (1.0 - terrain.params.y) * lit;

  frag_color = vec4(albedo * shade, 1.0);
}
