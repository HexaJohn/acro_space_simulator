// Raymarched volumetric clouds in a thin spherical shell over a planet.
//
// Runs on flutter_scene's unlit ShaderMaterial path over an exterior shell
// sphere at the cloud TOP radius (same rig as shaders/atmosphere.frag). The
// fragment reconstructs the camera ray, marches the annulus between the
// cloud base and top radii, and accumulates a procedural cloud density with
// Beer/powder self-shadowing toward the sun. The planet is an analytic
// occluder in the uniforms, so no depth buffer is consulted for the layer's
// own shape; the opaque planet (drawn first) still depth-culls cloud pixels
// behind it via the normal lessEqual test.
//
// HARD CONSTRAINT: this stack has NO sampler3D / texture arrays / compute
// (see the flutter_scene backend notes), so the "3D noise texture" every
// cloud tutorial reaches for is impossible — the density field is fully
// PROCEDURAL (hash value-noise FBM) evaluated per march sample.
//
// Distances are in SCENE UNITS (kilometres — see coord_convert.dart).
// Output is premultiplied linear HDR (the engine tonemaps after).

uniform CloudInfo {
  // xyz: planet centre (scene units, focus-relative). w: planet radius
  // (scene) — the analytic occluder / ground clip.
  vec4 center_radius;
  // xyz: unit direction from the planet TOWARD the sun. w: cloud TOP radius
  // (scene) — the outer shell the ray enters.
  vec4 sun_top;
  // x: cloud BASE radius (scene). y: coverage 0..1 (higher = more sky
  // covered). z: density multiplier (optical thickness). w: time (seconds)
  // for the wind domain scroll.
  vec4 base_cov_dens_t;
  // x: wind speed (scene units/sec of noise-domain drift). y: detail-erosion
  // strength 0..1. z: ambient/sky fill strength. w: sun intensity.
  vec4 wind_detail_amb_int;
  // xyz: cloud tint (near-white, straight rgb, pre-scaled by the CPU).
  // w: base noise frequency (cycles per planet radius).
  vec4 tint_freq;
  // xyzw: body orientation quaternion (vector_math order x,y,z,w), scene
  // frame. The sample is INVERSE-rotated by this so the noise domain is the
  // body's rotating frame — clouds co-rotate with the surface instead of
  // swimming across it as the planet spins.
  vec4 orient;
}
cloud_info;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

const int VIEW_SAMPLES = 40;
const int LIGHT_SAMPLES = 5;
const float PI = 3.14159265;

// Ray/sphere: returns (tNear, tFar), tFar < tNear when missed.
vec2 raySphere(vec3 ro, vec3 rd, vec3 c, float r) {
  vec3 oc = ro - c;
  float b = dot(oc, rd);
  float h = b * b - (dot(oc, oc) - r * r);
  if (h < 0.0) return vec2(1.0, -1.0);
  float s = sqrt(h);
  return vec2(-b - s, -b + s);
}

// Rotate v by quaternion q (Hamilton, xyz=vector, w=scalar).
vec3 qrot(vec4 q, vec3 v) {
  return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

// iq-style integer-lattice value noise + FBM. Cheap, tileless, and (unlike a
// texture) works on a backend with no 3D samplers.
float hash(vec3 p) {
  p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
      mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
          mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
      mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
          mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y),
      f.z);
}

float fbm(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 5; i++) {
    sum += amp * vnoise(p);
    p *= 2.02;
    amp *= 0.5;
  }
  return sum;
}

// Henyey-Greenstein phase — forward-scatter "silver lining" toward the sun.
float hgPhase(float cosT, float g) {
  float g2 = g * g;
  return (1.0 - g2) / (4.0 * PI * pow(1.0 + g2 - 2.0 * g * cosT, 1.5));
}

// Soft planet shadow as a smooth function of the sun's elevation against the
// local horizon (same continuous form as the atmosphere shader — a binary
// horizon test cuts the terminator to a hard line across the disc).
float sunVisibility(vec3 p, vec3 sunDir, vec3 c, float planetR) {
  vec3 op = p - c;
  float r = max(length(op), planetR);
  float x = dot(op, sunDir) / r;
  float horiz = -sqrt(max(1.0 - (planetR * planetR) / (r * r), 0.0));
  float w = 0.03; // twilight half-width in cosine units
  return smoothstep(horiz - w, horiz + w, x);
}

// 3-octave FBM — the cheaper field that drives the domain warp below.
float fbm3(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 3; i++) {
    sum += amp * vnoise(p);
    p *= 2.03;
    amp *= 0.5;
  }
  return sum;
}

// Ridged turbulence: sum of squared |signed noise|, which builds SHARP
// filament ridges (the torn wisps of real weather) instead of the round
// lumps plain value noise gives.
float ridged(vec3 p) {
  float sum = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 4; i++) {
    float n = 1.0 - abs(2.0 * vnoise(p) - 1.0);
    sum += amp * n * n;
    p *= 2.03;
    amp *= 0.5;
  }
  return sum;
}

// Planetary latitude coverage: a GENTLE tendency toward clearer subtropical
// highs (~+/-25 deg) and cloudier storm belts, NOT hard bands. Kept shallow
// (never below ~0.75) so no latitude is ever a permanent dead zone — the
// domain warp + drift do most of the shaping. [lat] is radians.
float latBands(float lat) {
  float a = abs(lat) * 0.63662;  // |lat| / (pi/2): 0 equator .. 1 pole
  float subtrop =
      0.22 * smoothstep(0.14, 0.34, a) * (1.0 - smoothstep(0.40, 0.62, a));
  float belt = 0.14 * smoothstep(0.50, 0.72, a) * (1.0 - smoothstep(0.86, 1.0, a));
  return clamp(1.0 + belt - subtrop, 0.75, 1.2);
}

// Cloud density at a scene-space point. Zero outside the [base, top] shell;
// a rounded vertical profile inside. The horizontal pattern is shaped to
// look like PLANETARY weather (see the equirect reference): domain-warped
// FBM for swirled cyclonic filaments, a latitude-banded coverage threshold,
// and ridged-turbulence erosion for torn wispy edges.
float cloudDensity(vec3 p) {
  vec3 centre = cloud_info.center_radius.xyz;
  float planetR = cloud_info.center_radius.w;
  float topR = cloud_info.sun_top.w;
  float baseR = cloud_info.base_cov_dens_t.x;
  float coverage = cloud_info.base_cov_dens_t.y;
  float time = cloud_info.base_cov_dens_t.w;
  float windSpeed = cloud_info.wind_detail_amb_int.x;
  float detail = cloud_info.wind_detail_amb_int.y;
  float freq = cloud_info.tint_freq.w;

  vec3 op = p - centre;
  float r = length(op);
  float ha = (r - baseR) / max(topR - baseR, 1e-4);
  if (ha <= 0.0 || ha >= 1.0) return 0.0;

  // Rounded vertical profile: builds up off the base, thins toward the top.
  float vert = smoothstep(0.0, 0.25, ha) * (1.0 - smoothstep(0.5, 1.0, ha));

  // Sample in the body's rotating frame, normalised by planet radius so the
  // frequency is "cycles per radius" (resolution-independent). Wind scrolls
  // the domain for slow evolution + drift.
  vec3 local = qrot(vec4(-cloud_info.orient.xyz, cloud_info.orient.w), op);
  // Weather ADVECTS eastward relative to the surface: precess the sample
  // domain about the spin axis over time. Without this the co-rotating noise
  // is locked to geography, so a longitude that starts clear stays clear
  // forever (North America / China / Egypt never cloud over). Latitude is
  // preserved, so the (gentle) bands stay put while cloud systems drift
  // through them. Tied to the wind knob.
  float drift = time * windSpeed * 1.5;  // radians
  float cd = cos(drift), sd = sin(drift);
  local = vec3(local.x * cd - local.y * sd, local.x * sd + local.y * cd, local.z);
  float lat = asin(clamp(local.z / max(r, 1e-4), -1.0, 1.0));
  vec3 sp = local / planetR;
  vec3 wind = vec3(time * windSpeed, time * windSpeed * 0.3, 0.0);

  // Primary sample coordinate, in feature units.
  vec3 P = sp * freq + wind;

  // DOMAIN WARP: drag the sample by a lower-frequency vector noise. This is
  // what turns isotropic blobs into the stretched, swirled cyclonic
  // filaments of a real cloud map (iq-style fbm-of-fbm). The warp field runs
  // at ~0.28x frequency (storm-system scale) and a STRONG drag so the swirl
  // arms stay bold even under dense coverage + the cirrus veil.
  vec3 Q = vec3(fbm3(P * 0.28 + 11.5),
                fbm3(P * 0.28 + 31.7),
                fbm3(P * 0.28 + 57.1));
  vec3 Pw = P + 5.0 * (Q - 0.5);

  float base = fbm(Pw);

  // Latitude-banded coverage threshold: `coverage` slides the split, the
  // band profile carves the ITCZ / subtropics / storm-belt structure.
  float cov = clamp(coverage * latBands(lat), 0.0, 1.0);
  float d = base - (1.0 - cov);
  if (d <= 0.0) return 0.0;
  d = d / max(cov, 1e-3);

  // Erode with ridged turbulence -> torn filament edges (not round blobs).
  float fine = ridged(Pw * 3.0 - wind * 1.7);
  d -= detail * (1.0 - d) * fine;

  // Soft transition instead of a hard pillow edge. Low floor keeps thin
  // wisps so the sky isn't split into hard cloud/clear regions.
  d = smoothstep(0.02, 0.45, d);

  // Thin CIRRUS VEIL: a broad, low-frequency field capped at a tiny optical
  // depth, filling the gaps between the thick systems with hazy, half-
  // transparent cloud (the gauzy grey layer that covers most of a real cloud
  // map). max() so it only ADDS translucency where the structured clouds are
  // absent — it never thins the bright cores. The cap is tiny because the
  // veil accumulates over the whole march column.
  float veil = smoothstep(0.42, 0.82, fbm3(Pw * 0.32 + 7.3));
  d = max(d, veil * 0.008);

  return clamp(d, 0.0, 1.0) * vert;
}

void main() {
  vec3 centre = cloud_info.center_radius.xyz;
  float planetR = cloud_info.center_radius.w;
  float topR = cloud_info.sun_top.w;
  float baseR = cloud_info.base_cov_dens_t.x;
  vec3 sunDir = normalize(cloud_info.sun_top.xyz);
  float densMul = cloud_info.base_cov_dens_t.z;
  float ambient = cloud_info.wind_detail_amb_int.z;
  float sunI = cloud_info.wind_detail_amb_int.w;
  vec3 tint = cloud_info.tint_freq.xyz;

  // Camera ray. v_viewvector = camera - fragment.
  vec3 ro = v_position + v_viewvector;
  vec3 rd = normalize(-v_viewvector);

  vec2 shell = raySphere(ro, rd, centre, topR);
  if (shell.y <= max(shell.x, 0.0)) {
    frag_color = vec4(0.0);
    return;
  }
  float t0 = max(shell.x, 0.0);
  float t1 = shell.y;

  // The opaque planet blocks the far part of the ray. GUARD the miss
  // sentinel (raySphere returns tNear=1 on a miss, which would read as a
  // phantom hit 1 unit ahead and clip the whole limb — see the atmosphere
  // shader's raySphere note).
  vec2 ground = raySphere(ro, rd, centre, planetR);
  if (ground.y >= ground.x && ground.x > 0.0 && ground.x < t1) {
    t1 = ground.x;
  }
  if (t1 <= t0) {
    frag_color = vec4(0.0);
    return;
  }

  float stepLen = (t1 - t0) / float(VIEW_SAMPLES);
  float mu = dot(rd, sunDir);
  float phase = hgPhase(mu, 0.2);

  vec3 scatter = vec3(0.0);
  float transmittance = 1.0;

  for (int i = 0; i < VIEW_SAMPLES; i++) {
    vec3 p = ro + rd * (t0 + (float(i) + 0.5) * stepLen);
    float density = cloudDensity(p) * densMul;
    if (density <= 0.0) continue;

    // Self-shadow: march a few steps toward the sun, accumulate density,
    // Beer's law. Steps grow (geometric) so a short march still reaches the
    // top of a thick tower.
    float sunTau = 0.0;
    float sunStep = (topR - baseR) / float(LIGHT_SAMPLES);
    for (int j = 0; j < LIGHT_SAMPLES; j++) {
      vec3 q = p + sunDir * ((float(j) + 0.5) * sunStep);
      sunTau += cloudDensity(q) * densMul * sunStep;
    }
    float sunT = exp(-sunTau);
    // Powder term: darkens the illuminated edges toward the core, the cue
    // that reads as cloud VOLUME rather than a flat lit shell.
    float powder = 1.0 - exp(-density * stepLen * 2.0);

    float vis = sunVisibility(p, sunDir, centre, planetR);
    vec3 sun = sunI * tint * sunT * phase * powder * vis;
    // Sky/ambient fill is scattered SUNLIGHT — gate it by the same day/night
    // visibility as the direct term, else the shadowed hemisphere glows at
    // full ambient (clouds bright on the night side). A small floor keeps a
    // hint of earthshine so the dark limb isn't pure black.
    vec3 sky = ambient * tint * (0.06 + 0.94 * vis);
    vec3 lit = sun + sky;

    // Front-to-back accumulation (premultiplied): the extinction over this
    // step attenuates everything behind it.
    float dt = density * stepLen;
    float stepT = exp(-dt);
    scatter += transmittance * lit * (1.0 - stepT);
    transmittance *= stepT;
    if (transmittance < 0.01) break;
  }

  float alpha = clamp(1.0 - transmittance, 0.0, 1.0);
  frag_color = vec4(scatter, alpha); // premultiplied
}
