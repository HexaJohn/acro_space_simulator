// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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
  // (per-body caps; the shader modulates them by latitude+altitude).
  // w: debug view — 0 normal, 1 height bands, 2 raw albedo, 3 albedo+contour
  // alignment overlay (see TerrainNodes.debugView).
  vec4 detail;
  // xyz: body spin-axis (pole) in the SAME world frame as v_position, so
  // dot(up, pole) = the body-fixed latitude sine regardless of body rotation.
  vec4 pole;
  // xyz: the body's PRIME MERIDIAN axis (body +X) in that same world frame.
  // Latitude alone cannot index an equirectangular map — longitude needs a
  // second body-fixed axis to measure from, and v_position is world-space, so
  // it has to be supplied rather than derived. w: albedo strength (0 = the
  // procedural blend alone, as before; 1 = full real albedo).
  vec4 meridian_albedo;
  // Detail-normal (tex_normal) controls. x: strength (0 = off — bodies with
  // no baked map). y/z: camera-distance fade near/far (scene units): below y
  // the MESH carries the relief so the map stays out (double-counting the
  // same ridge in geometry AND lighting exaggerates it); above z coarse
  // chunks have lost the relief and the map takes over fully. w: unused.
  vec4 normal_params;
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

// Real per-body surface colour, equirectangular in the BODY-FIXED frame
// (tool/bake_albedo.dart). Carries what no procedural blend can invent: where
// the maria actually are. The tiles above still supply close-up grain, because
// this map is only ~5 km per texel.
uniform sampler2D tex_albedo;

// DEM-derived tangent-space normal map (tool/bake_normals.dart), same equirect
// body-fixed layout as tex_albedo. r/g = east/north components ([0,1] biased),
// z reconstructed. Restores crater-rim lighting on coarse LOD chunks whose
// triangles can no longer carry the relief; silhouettes stay mesh-bound.
uniform sampler2D tex_normal;

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

  float inv_count = 1.0 / float(count);

  float noise = fract(
      52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
  float angle = noise * 6.28318530718;
  float ca = cos(angle);
  float sa = sin(angle);

  // Contact hardening (PCSS-lite). Search the max-penumbra disk for occluders,
  // then scale the PCF radius by how far the receiver sits BELOW them: gap ~ 0
  // right where the caster meets the ground -> a crisp edge; a receiver well
  // below a tall caster (the far end of its shadow) -> a soft edge. sp1.w = max
  // penumbra (world), sp1.z = hardness (UV penumbra per unit clip-z gap).
  float maxR = max(sh.sp1.w / box, sh.sp0.x);
  float bsum = 0.0;
  float bcount = 0.0;
  // Loops over const arrays, NOT macro expansion: each textual copy of the
  // tap body survives into the translated HLSL, and the downstream compile
  // cost scales with it — unrolling 8+16 taps inline (plus 4 cascade copies
  // of this whole function, see SampleShadow) took ~30 s of the UI thread at
  // first draw. Same offsets, same result, a fraction of the compile.
  const vec2 kBlocker[8] = vec2[8](
      vec2(-0.7, -0.7), vec2(0.7, -0.7), vec2(-0.7, 0.7), vec2(0.7, 0.7),
      vec2(0.0, -1.0), vec2(0.0, 1.0), vec2(-1.0, 0.0), vec2(1.0, 0.0));
  for (int i = 0; i < 8; i++) {
    vec2 p = kBlocker[i];
    vec2 o = vec2(p.x * ca - p.y * sa, p.x * sa + p.y * ca) * maxR;
    vec2 cuv = clamp(uv + o, vec2(sh.sp0.x), vec2(1.0 - sh.sp0.x));
    vec2 auv = vec2((float(cascade) + cuv.x) * inv_count, 1.0 - cuv.y);
    float d = texture(shadow_map, auv).r;
    if (d < receiver_depth) {
      bsum += d;
      bcount += 1.0;
    }
  }
  if (bcount < 0.5) return 1.0; // nothing occludes here -> fully lit
  float gap = max(receiver_depth - bsum / bcount, 0.0);
  float radius = clamp(gap * sh.sp1.z, sh.sp0.x, maxR);

  const vec2 kPoisson[16] = vec2[16](
      vec2(-0.94201624, -0.39906216), vec2(0.94558609, -0.76890725),
      vec2(-0.09418410, -0.92938870), vec2(0.34495938, 0.29387760),
      vec2(-0.91588581, 0.45771432), vec2(-0.81544232, -0.87912464),
      vec2(-0.38277543, 0.27676845), vec2(0.97484398, 0.75648379),
      vec2(0.44323325, -0.97511554), vec2(0.53742981, -0.47373420),
      vec2(-0.26496911, -0.41893023), vec2(0.79197514, 0.19090188),
      vec2(-0.24188840, 0.99706507), vec2(-0.81409955, 0.91437590),
      vec2(0.19984126, 0.78641367), vec2(0.14383161, -0.14100790));
  float lit = 0.0;
  for (int i = 0; i < 16; i++) {
    lit += ShadowTap(kPoisson[i], ca, sa, radius, uv, cascade, inv_count,
                     receiver_depth);
  }
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
//
// SELECTION ONLY — the heavy sampler runs once, after. With SampleCascade
// called inside each cascade's branch, the translator inlined its ~96-tap
// body four times and the downstream HLSL compile took ~30 s of the UI
// thread at first draw (the flight-mode "loading hang"). One call site
// compiles in a fraction of that; same math, same picture.
#define _TRY_CASCADE(IDX)                                                     \
  if (cascade < 0 && count > IDX) {                                           \
    mat4 m = sh.light_space_matrix[IDX];                                      \
    float b = sh.cascade_box_sizes[IDX];                                      \
    vec4 light_clip = m * vec4(world_pos, 1.0);                               \
    vec3 proj = light_clip.xyz / light_clip.w;                                \
    vec2 uv = proj.xy * 0.5 + 0.5;                                            \
    float margin = max(sh.sp1.w / b, sh.sp0.x);                               \
    if (!(uv.x < margin || uv.x > 1.0 - margin || uv.y < margin ||           \
          uv.y > 1.0 - margin || proj.z < 0.0 || proj.z > 1.0)) {            \
      cascade = IDX;                                                          \
      cascade_matrix = m;                                                     \
      box = b;                                                                \
    }                                                                         \
  }

float SampleShadow(vec3 world_pos, vec3 n) {
  int count = int(sh.light_dir_count.w);
  int cascade = -1;
  mat4 cascade_matrix = mat4(1.0);
  float box = 1.0;
  _TRY_CASCADE(0)
  _TRY_CASCADE(1)
  _TRY_CASCADE(2)
  _TRY_CASCADE(3)
  if (cascade < 0) return 1.0; // outside every cascade -> fully lit
  return SampleCascade(cascade, count, cascade_matrix, box, world_pos, n);
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

// --- Debug-view helpers ------------------------------------------------------

// Hypsometric tint for a normalised altitude t in [0,1]:
// deep blue -> cyan -> green -> yellow -> red -> white.
vec3 Hypso(float t) {
  vec3 c = mix(vec3(0.05, 0.15, 0.60), vec3(0.00, 0.70, 0.80),
      smoothstep(0.00, 0.25, t));
  c = mix(c, vec3(0.10, 0.60, 0.15), smoothstep(0.25, 0.45, t));
  c = mix(c, vec3(0.90, 0.85, 0.20), smoothstep(0.45, 0.65, t));
  c = mix(c, vec3(0.85, 0.25, 0.10), smoothstep(0.65, 0.85, t));
  c = mix(c, vec3(1.00), smoothstep(0.85, 1.00, t));
  return c;
}

// 1 on an iso-line of `v` at integer multiples of `step`, 0 elsewhere.
// Fixed fractional width (no derivatives — this profile has none), so line
// thickness varies with slope; fine for a debug view.
float IsoLine(float v, float step_, float width) {
  float f = fract(v / step_);
  return 1.0 - smoothstep(0.0, width, min(f, 1.0 - f));
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

  // Real surface colour, where the body has a baked map.
  //
  // Applied as a MODULATION rather than a replacement: the map is ~5 km per
  // texel, so on its own it is a flat wash with no close-up structure, while
  // the procedural blend has all the grain and none of the truth. Dividing the
  // procedural colour by its own mean turns it into a detail ratio around 1.0,
  // which then multiplies the real albedo — maria come out dark and highlands
  // bright, and both keep their texture.
  // Body-fixed latitude/longitude + the equirect uv. Needed by the real-albedo
  // path AND the debug views below, so computed unconditionally.
  vec3 mer = normalize(terrain.meridian_albedo.xyz);
  vec3 pol = normalize(terrain.pole.xyz);
  // Complete the body-fixed frame. east = pole x meridian is already unit
  // (both are unit and perpendicular).
  vec3 east = cross(pol, mer);
  float sinLat = clamp(dot(up, pol), -1.0, 1.0);
  float lat = asin(sinLat);
  float lon = atan(dot(up, east), dot(up, mer));
  vec2 uv = vec2(lon / 6.2831853 + 0.5, 0.5 - lat / 3.14159265);

  float albedoMix = clamp(terrain.meridian_albedo.w, 0.0, 1.0);
  if (albedoMix > 0.0) {
    vec3 real = texture(tex_albedo, uv).rgb;
    float m = max((albedo.r + albedo.g + albedo.b) / 3.0, 1e-3);
    vec3 detailRatio = albedo / m;
    albedo = mix(albedo, real * detailRatio, albedoMix);
  }

  // Detail normal: fade the baked map in with CAMERA DISTANCE. The map is the
  // full-relief normal (every frequency the DEM has), so at full strength it
  // REPLACES the geometric normal rather than perturbing it — near the ground
  // the mesh resolves the same ridges and the map must stay out or they'd be
  // counted twice. Material/slope selection above stays on the geometric
  // normal: it only matters close up, where the map is faded out anyway.
  float nStrength = clamp(terrain.normal_params.x, 0.0, 1.0);
  if (nStrength > 0.0) {
    // v_viewvector = camera - fragment (scene units).
    float eyeDist = length(v_viewvector);
    float w =
        nStrength *
        smoothstep(terrain.normal_params.y, terrain.normal_params.z, eyeDist);
    // Local east degenerates at the poles (cross of near-parallel vectors);
    // the guard leaves the geometric normal there.
    vec3 eastL = cross(pol, up);
    float el = length(eastL);
    if (w > 0.001 && el > 1e-4) {
      eastL /= el;
      vec3 northL = cross(up, eastL);
      vec2 t = texture(tex_normal, uv).rg * 2.0 - 1.0;
      float tz = sqrt(max(1.0 - dot(t, t), 0.0));
      vec3 mapN = normalize(t.x * eastL + t.y * northL + tz * up);
      n = normalize(mix(n, mapN, w));
    }
  }

  // Sun Lambert + ambient. Light travels along sun_amp.xyz, so a surface is
  // lit by the component facing back toward the sun (-dir).
  float lit = max(dot(n, -terrain.sun_amp.xyz), 0.0);

  // Debug views (detail.w, cycled from the debug panel). Placed before the
  // shadow tap so the map views stay readable on the night side.
  float dbg = terrain.detail.w;
  if (dbg > 0.5) {
    // Altitude in metres above the DATUM radius (scene km -> m).
    float alt_m = (dist - terrain.centre_radius.w) * 1000.0;
    float amp_m = max(terrain.sun_amp.w, 1e-6) * 1000.0;
    if (dbg < 1.5) {
      // HEIGHT: hypsometric bands of the meshed field + 1 km contours,
      // lightly sun-shaded so relief still reads as 3D.
      vec3 c = Hypso(clamp(alt_m / amp_m, -1.0, 1.0) * 0.5 + 0.5);
      c *= 1.0 - 0.5 * IsoLine(alt_m, 1000.0, 0.05);
      frag_color = vec4(c * (0.55 + 0.45 * lit), 1.0);
    } else if (dbg < 2.5) {
      // ALBEDO: the raw baked map through the shader's own uv path — unlit
      // and unmodulated, so what's on screen IS the mapping.
      frag_color = vec4(texture(tex_albedo, uv).rgb, 1.0);
    } else if (dbg < 3.5) {
      // ALIGN: albedo as a grey underlay, 1 km altitude contours in orange,
      // 15-degree body-fixed graticule in blue. Contours hugging the maria
      // edges = the height field and the colour map agree.
      float lum = dot(texture(tex_albedo, uv).rgb, vec3(1.0 / 3.0));
      vec3 c = vec3(lum);
      float grid = max(IsoLine(degrees(lat), 15.0, 0.03),
                       IsoLine(degrees(lon), 15.0, 0.03));
      c = mix(c, vec3(0.28, 0.47, 1.00), 0.55 * grid);
      c = mix(c, vec3(1.00, 0.51, 0.08), IsoLine(alt_m, 1000.0, 0.04));
      frag_color = vec4(c, 1.0);
    } else {
      // NRM: the raw detail-normal map through the shader's own uv path
      // (flat = lavender 128/128/255, slopes tint toward red/green).
      frag_color = vec4(texture(tex_normal, uv).rgb, 1.0);
    }
    return;
  }

  // Cast-shadow occlusion (1 lit .. 0 shadowed) from the craft/terrain atlas.
  float shadow = sh.sp1.y > 0.5 ? SampleShadow(v_position, n) : 1.0;
  float shade = terrain.params.y + (1.0 - terrain.params.y) * lit * shadow;

  frag_color = vec4(albedo * shade, 1.0);
}
