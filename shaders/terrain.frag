// Voxel-terrain surface: procedural per-fragment shading by SLOPE + ALTITUDE,
// with a sun Lambert term. No texture assets yet — the triplanar blend weights
// are computed here so tileable rock/sand/snow textures can drop in later
// behind the same code (sample per axis, weight by |normal|). Distances are in
// SCENE UNITS (km), matching v_position. Opaque pass.
//
// Receives the scene's cascaded directional shadow map (so the craft casts a
// real shadow on the ground): ShadowInfo carries the cascade matrices + params
// and shadow_map is the depth atlas. The PCF lookup below is the same algorithm
// the engine's material_lighting.glsl uses, packed against our own compact
// block instead of the engine's FragInfo (see terrain_nodes.dart _packShadow).

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
  // x: tile size (m) for triplanar detail. y: sand amount, z: grass amount
  // (per-body caps; the shader modulates them by latitude+altitude). w: unused.
  vec4 detail;
  // xyz: body spin-axis (pole) in the SAME world frame as v_position, so
  // dot(up, pole) = the body-fixed latitude sine regardless of body rotation.
  vec4 pole;
}
terrain;

// Cascaded directional shadow map, matching the engine's layout/semantics.
uniform ShadowInfo {
  mat4 light_space_matrix[4]; // world -> cascade clip, near..far
  vec4 cascade_box_sizes;     // per-cascade world box side (x..w = 0..3)
  vec4 light_dir_count;       // xyz: light travel dir (world); w: cascade count
  vec4 sp0;                   // x: texel size; y: normal bias; z: softness;
                              // w: depth bias  (all scene units)
  vec4 sp1;                   // x: fade range; y: casts_shadow (1/0); zw unused
}
sh;

uniform sampler2D shadow_map; // fp32 depth-in-.r cascade atlas (horizontal strip)

// Tileable material tiles (procedural, generated in terrain_textures.dart),
// sampled triplanar so slopes/caves don't stretch.
uniform sampler2D tex_regolith;
uniform sampler2D tex_rock;
uniform sampler2D tex_sand;
uniform sampler2D tex_grass;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

// --- Shadow sampling (ported from flutter_scene material_lighting.glsl) ------

// One rotated Poisson-disk PCF tap into a cascade's atlas tile.
float ShadowTap(vec2 p, float ca, float sa, float radius, vec2 uv, int cascade,
                float inv_count, float receiver_depth) {
  vec2 offset = vec2(p.x * ca - p.y * sa, p.x * sa + p.y * ca) * radius;
  vec2 cuv = clamp(uv + offset, vec2(sh.sp0.x), vec2(1.0 - sh.sp0.x));
  vec2 atlas_uv = vec2((float(cascade) + cuv.x) * inv_count, cuv.y);
  // The atlas is stored top-down; flip V to sample the matching row.
  atlas_uv.y = 1.0 - atlas_uv.y;
  float caster_depth = texture(shadow_map, atlas_uv).r;
  return receiver_depth <= caster_depth ? 1.0 : 0.0;
}

// Samples one cascade's tile with a rotated 16-tap Poisson-disk PCF.
float SampleCascade(int cascade, int count, mat4 cascade_matrix, float box,
                    vec3 world_pos, vec3 n) {
  // Normal-offset bias: lift the receiver along its normal so the soft kernel
  // clears the surface at grazing sun angles.
  vec3 light_toward = -normalize(sh.light_dir_count.xyz);
  float ndotl = max(dot(n, light_toward), 0.15);
  float slope = min(sqrt(max(1.0 - ndotl * ndotl, 0.0)) / (ndotl * ndotl), 8.0);
  float normal_offset = sh.sp0.y + sh.sp0.z * slope;
  vec3 biased = world_pos + n * normal_offset;

  vec4 light_clip = cascade_matrix * vec4(biased, 1.0);
  vec3 proj = light_clip.xyz / light_clip.w;
  vec2 uv = proj.xy * 0.5 + 0.5;
  // World-space depth bias -> this cascade's clip-z (its depth range is 7*box).
  float receiver_depth = proj.z - sh.sp0.w / (7.0 * box);

  float radius = max(sh.sp0.z / box, sh.sp0.x);
  float inv_count = 1.0 / float(count);

  float noise = fract(
      52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  float angle = noise * 6.28318530718;
  float ca = cos(angle);
  float sa = sin(angle);

#define _SHADOW_TAP(px, py) \
  ShadowTap(vec2(px, py), ca, sa, radius, uv, cascade, inv_count, receiver_depth)
  float lit = 0.0;
  lit += _SHADOW_TAP(-0.94201624, -0.39906216);
  lit += _SHADOW_TAP(0.94558609, -0.76890725);
  lit += _SHADOW_TAP(-0.09418410, -0.92938870);
  lit += _SHADOW_TAP(0.34495938, 0.29387760);
  lit += _SHADOW_TAP(-0.91588581, 0.45771432);
  lit += _SHADOW_TAP(-0.81544232, -0.87912464);
  lit += _SHADOW_TAP(-0.38277543, 0.27676845);
  lit += _SHADOW_TAP(0.97484398, 0.75648379);
  lit += _SHADOW_TAP(0.44323325, -0.97511554);
  lit += _SHADOW_TAP(0.53742981, -0.47373420);
  lit += _SHADOW_TAP(-0.26496911, -0.41893023);
  lit += _SHADOW_TAP(0.79197514, 0.19090188);
  lit += _SHADOW_TAP(-0.24188840, 0.99706507);
  lit += _SHADOW_TAP(-0.81409955, 0.91437590);
  lit += _SHADOW_TAP(0.19984126, 0.78641367);
  lit += _SHADOW_TAP(0.14383161, -0.14100790);
#undef _SHADOW_TAP
  float shadow = lit / 16.0;

  // Fade the last cascade back to lit at its outer edge (no next cascade).
  if (cascade == count - 1 && sh.sp1.x > 0.0) {
    float fade = sh.sp1.x / box;
    vec2 edge = smoothstep(vec2(0.0), vec2(fade), uv) *
                smoothstep(vec2(0.0), vec2(fade), vec2(1.0) - uv);
    shadow = mix(1.0, shadow, edge.x * edge.y);
  }
  return shadow;
}

// Picks the first (highest-res) cascade whose tile contains the fragment.
// Unrolled with literal indices (no dynamic uniform-array indexing in ES 1.00).
#define _TRY_CASCADE(IDX)                                                     \
  if (!found && count > IDX) {                                                \
    mat4 cascade_matrix = sh.light_space_matrix[IDX];                         \
    float box = sh.cascade_box_sizes[IDX];                                    \
    vec4 light_clip = cascade_matrix * vec4(world_pos, 1.0);                  \
    vec3 proj = light_clip.xyz / light_clip.w;                                \
    vec2 uv = proj.xy * 0.5 + 0.5;                                            \
    float margin = max(sh.sp0.z / box, sh.sp0.x);                             \
    if (!(uv.x < margin || uv.x > 1.0 - margin || uv.y < margin ||           \
          uv.y > 1.0 - margin || proj.z < 0.0 || proj.z > 1.0)) {            \
      result = SampleCascade(IDX, count, cascade_matrix, box, world_pos, n);  \
      found = true;                                                           \
    }                                                                         \
  }

float SampleShadow(vec3 world_pos, vec3 n) {
  int count = int(sh.light_dir_count.w);
  float result = 1.0;
  bool found = false;
  _TRY_CASCADE(0)
  _TRY_CASCADE(1)
  _TRY_CASCADE(2)
  _TRY_CASCADE(3)
  return result;
}
#undef _TRY_CASCADE

// --- Triplanar material sampling ---------------------------------------------

// Sample a tileable material at world position, projected on the three axis
// planes and blended by the (sharpened) normal so no axis stretches. v_position
// is in SCENE km; convert to metres, then to tile units by the tile size.
vec3 triplanar(sampler2D tex, vec3 wpos_m, vec3 n, float tile_m) {
  vec3 uvw = wpos_m / max(tile_m, 0.001);
  vec3 bw = abs(n);
  bw = pow(bw, vec3(4.0));         // sharpen so seams between planes are narrow
  bw /= (bw.x + bw.y + bw.z + 1e-5);
  vec3 cx = texture(tex, uvw.yz).rgb; // plane facing X
  vec3 cy = texture(tex, uvw.zx).rgb; // plane facing Y
  vec3 cz = texture(tex, uvw.xy).rgb; // plane facing Z
  return cx * bw.x + cy * bw.y + cz * bw.z;
}

// -----------------------------------------------------------------------------

void main() {
  vec3 rel = v_position - terrain.centre_radius.xyz;
  float dist = length(rel);
  vec3 up = dist > 1e-6 ? rel / dist : vec3(0.0, 0.0, 1.0);

  // The mesher's gradient normals already point OUT of the surface (density
  // rises solid->air), so use them as-is. Do NOT flip toward the viewer: that
  // makes the sun term view-dependent and lights night-side / away-facing
  // ground whenever the camera sits on the sunny side of it. Trusting the
  // outward normal keeps night terrain dark and stays correct for caves.
  vec3 n = normalize(v_normal);

  // Slope: 1 = flat (normal along up), 0 = vertical cliff.
  float slope = clamp(dot(n, up), 0.0, 1.0);
  // Normalised altitude above sea, in units of relief amplitude.
  float amp = max(terrain.sun_amp.w, 1e-6);
  float altN = clamp((dist - terrain.params.x) / amp, -1.0, 1.0);

  // Triplanar material tiles at this fragment (world metres = scene km * 1000).
  vec3 wpos_m = v_position * 1000.0;
  float tile_m = terrain.detail.x;
  vec3 c_reg = triplanar(tex_regolith, wpos_m, n, tile_m);
  vec3 c_rock = triplanar(tex_rock, wpos_m, n, tile_m);
  vec3 c_sand = triplanar(tex_sand, wpos_m, n, tile_m);
  vec3 c_grass = triplanar(tex_grass, wpos_m, n, tile_m);

  // FLAT ground material: regolith by default, with grass/sand auto-selected by
  // LATITUDE + ALTITUDE up to the body's caps (both 0 on the Moon -> regolith).
  float latSin = clamp(dot(up, terrain.pole.xyz), -1.0, 1.0);
  float warm = sqrt(max(1.0 - latSin * latSin, 0.0)); // cos(lat): 1 eq .. 0 pole
  float lowland = 1.0 - smoothstep(0.0, 0.5, altN);    // near/below the datum
  float grassW = clamp(terrain.detail.z, 0.0, 1.0) * warm * lowland;
  float sandW = clamp(terrain.detail.y, 0.0, 1.0) *
                smoothstep(0.6, 0.95, warm) * lowland; // hot, dry, low
  vec3 flat_col = c_reg;
  flat_col = mix(flat_col, c_grass, grassW);
  flat_col = mix(flat_col, c_sand, sandW); // desert paints over grass
  // Subtle altitude brightening (highs catch more light/dust); textures carry
  // the base albedo, so this is a gentle ramp, not a full recolor.
  flat_col *= mix(0.9, 1.12, smoothstep(-0.2, 0.6, altN));

  // Snow caps up high on gentle slopes.
  float snow = smoothstep(terrain.params.z, terrain.params.z + 0.25, altN);
  flat_col = mix(flat_col, terrain.col_snow.rgb, snow * smoothstep(0.4, 0.9, slope));

  // Steep faces are rock regardless of altitude.
  float rockw = 1.0 - smoothstep(terrain.params.w, terrain.params.w + 0.15, slope);
  vec3 albedo = mix(flat_col, c_rock, rockw);

  // Sun Lambert + ambient. Light travels along sun_amp.xyz, so a surface is
  // lit by the component facing back toward the sun (-dir).
  float lit = max(dot(n, -terrain.sun_amp.xyz), 0.0);
  // Cast-shadow occlusion (1 lit .. 0 shadowed) from the craft/terrain atlas.
  float shadow = sh.sp1.y > 0.5 ? SampleShadow(v_position, n) : 1.0;
  float shade = terrain.params.y + (1.0 - terrain.params.y) * lit * shadow;

  frag_color = vec4(albedo * shade, 1.0);
}
