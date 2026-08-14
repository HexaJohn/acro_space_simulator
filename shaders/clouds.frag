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
  // x: swirl strength — the domain-warp drag, in feature units. y: swirl
  // frequency, as a fraction of the base noise frequency (storm-system
  // scale). z: swirl speed — scroll rate of the warp field's own domain, so
  // the cyclone arms themselves curl and reform over time (0 = arms frozen
  // in the wind-carried domain). w: GLOBAL wind — eastward precession of the
  // whole sample domain about the spin axis, radians per sim-second (the
  // planet-scale advection; the LOCAL wind in wind_detail_amb_int.x is the
  // noise-domain scroll that morphs weather in place).
  vec4 swirl_global;
  // Zonal wind BANDS: the global drift is multiplied by a latitude profile
  // of (1 - shear * equatorBump), so the hemispheres run the full global
  // wind (eastward for positive windGlobal) while the equatorial band lags
  // (shear 0..1), stalls (1) or counter-flows westward (>1, trade-wind
  // style). x: band shear. y: equatorial band half-width (radians of
  // latitude; the profile blends over the outer half of it). z, w: unused.
  vec4 band_info;
}
cloud_info;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

// Hard CAP on the view march — the actual count adapts to the shell chord
// (see main) so a nadir ray, whose chord is ~1 shell thickness, stops paying
// the same 40-sample bill as a limb ray whose chord is ~40 thicknesses.
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

// 2-octave FBM — warp field for the LIGHT march only, where the swirl arms
// need to be POSITIONED right for self-shadowing but not fully detailed.
// The +0.0625 stands in for the dropped third octave's mean so this field
// stays CENTRED on fbm3 — without it the 5x warp drag shifts the whole lo
// domain ~0.3 feature units sideways and shadows detach from their clouds.
float fbm2(vec3 p) {
  return 0.5 * vnoise(p) + 0.25 * vnoise(p * 2.03) + 0.0625;
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
  // frequency is "cycles per radius" (resolution-independent). The LOCAL
  // wind scrolls the domain for slow in-place evolution.
  vec3 local = qrot(vec4(-cloud_info.orient.xyz, cloud_info.orient.w), op);
  // GLOBAL wind: weather ADVECTS eastward relative to the surface — precess
  // the sample domain about the spin axis over time. Without this the
  // co-rotating noise is locked to geography, so a longitude that starts
  // clear stays clear forever (North America / China / Egypt never cloud
  // over). Latitude is preserved, so the (gentle) bands stay put while
  // cloud systems drift through them.
  // Latitude BEFORE the drift rotation — the rotation is about the spin
  // axis, so z (and with it the latitude) is invariant and the band profile
  // stays glued to its latitudes as the domain precesses.
  float lat = asin(clamp(local.z / max(r, 1e-4), -1.0, 1.0));
  // Zonal band profile: 1 in the hemispheres, (1 - shear) inside the
  // equatorial band. The latitude-dependent drift SHEARS the domain at the
  // band edges over time — the smoothstep keeps that continuous, so it
  // reads as zonal streaking rather than tearing.
  float bandW = max(cloud_info.band_info.y, 1e-3);
  float band = 1.0 - cloud_info.band_info.x *
      (1.0 - smoothstep(bandW * 0.5, bandW, abs(lat)));
  float drift = time * cloud_info.swirl_global.w * band;  // radians
  float cd = cos(drift), sd = sin(drift);
  local = vec3(local.x * cd - local.y * sd, local.x * sd + local.y * cd, local.z);
  vec3 sp = local / planetR;
  vec3 wind = vec3(time * windSpeed, time * windSpeed * 0.3, 0.0);

  // Primary sample coordinate, in feature units.
  vec3 P = sp * freq + wind;

  // DOMAIN WARP: drag the sample by a lower-frequency vector noise. This is
  // what turns isotropic blobs into the stretched, swirled cyclonic
  // filaments of a real cloud map (iq-style fbm-of-fbm). The warp field
  // runs at swirl-frequency (a fraction of the base — storm-system scale)
  // with a STRONG drag so the swirl arms stay bold even under dense
  // coverage + the cirrus veil. Swirl SPEED scrolls the warp field's own
  // domain so the arms curl and reform instead of riding the wind frozen.
  vec3 sw = vec3(time * cloud_info.swirl_global.z,
                 time * cloud_info.swirl_global.z * -0.6, 0.0);
  float sfreq = cloud_info.swirl_global.y;
  vec3 Q = vec3(fbm3(P * sfreq + 11.5 + sw),
                fbm3(P * sfreq + 31.7 + sw),
                fbm3(P * sfreq + 57.1 + sw));
  vec3 Pw = P + cloud_info.swirl_global.x * (Q - 0.5);

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
  // veil accumulates over the whole march column. The veil term can never
  // exceed 0.008, so once d has beaten that the max() is decided and the
  // three noise octaves behind it are pure waste — skip them.
  if (d < 0.008) {
    float veil = smoothstep(0.42, 0.82, fbm3(Pw * 0.32 + 7.3));
    d = max(d, veil * 0.008);
  }

  return clamp(d, 0.0, 1.0) * vert;
}

// Low-fidelity density for the LIGHT march. The sun tau is an INTEGRAL that
// Beer's law then exponentiates — fine edge sculpting is invisible in it, so
// this drops exactly the terms that only shape edges: ridged erosion, the
// cirrus veil, and the warp's third octave (fbm2 positions the swirl arms;
// the missing octave only wobbled their outline). Skipping erosion slightly
// OVERSTATES tau inside thick systems (erosion only removed density), which
// deepens core shadows a touch — the safe direction for the look.
float cloudDensityLo(vec3 p) {
  vec3 centre = cloud_info.center_radius.xyz;
  float planetR = cloud_info.center_radius.w;
  float topR = cloud_info.sun_top.w;
  float baseR = cloud_info.base_cov_dens_t.x;
  float coverage = cloud_info.base_cov_dens_t.y;
  float time = cloud_info.base_cov_dens_t.w;
  float windSpeed = cloud_info.wind_detail_amb_int.x;
  float freq = cloud_info.tint_freq.w;

  vec3 op = p - centre;
  float r = length(op);
  float ha = (r - baseR) / max(topR - baseR, 1e-4);
  if (ha <= 0.0 || ha >= 1.0) return 0.0;
  float vert = smoothstep(0.0, 0.25, ha) * (1.0 - smoothstep(0.5, 1.0, ha));

  vec3 local = qrot(vec4(-cloud_info.orient.xyz, cloud_info.orient.w), op);
  float lat = asin(clamp(local.z / max(r, 1e-4), -1.0, 1.0));
  float bandW = max(cloud_info.band_info.y, 1e-3);
  float band = 1.0 - cloud_info.band_info.x *
      (1.0 - smoothstep(bandW * 0.5, bandW, abs(lat)));
  float drift = time * cloud_info.swirl_global.w * band;
  float cd = cos(drift), sd = sin(drift);
  local = vec3(local.x * cd - local.y * sd, local.x * sd + local.y * cd, local.z);
  vec3 sp = local / planetR;
  vec3 wind = vec3(time * windSpeed, time * windSpeed * 0.3, 0.0);

  vec3 P = sp * freq + wind;
  vec3 sw = vec3(time * cloud_info.swirl_global.z,
                 time * cloud_info.swirl_global.z * -0.6, 0.0);
  float sfreq = cloud_info.swirl_global.y;
  vec3 Q = vec3(fbm2(P * sfreq + 11.5 + sw),
                fbm2(P * sfreq + 31.7 + sw),
                fbm2(P * sfreq + 57.1 + sw));
  vec3 Pw = P + cloud_info.swirl_global.x * (Q - 0.5);

  float base = fbm(Pw);
  float cov = clamp(coverage * latBands(lat), 0.0, 1.0);
  float d = base - (1.0 - cov);
  if (d <= 0.0) return 0.0;
  d = d / max(cov, 1e-3);
  d = smoothstep(0.02, 0.45, d);
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

  // Adaptive march: hold the sample PITCH (samples per shell thickness of
  // chord) constant instead of the sample COUNT. A nadir ray's chord is ~1
  // thickness and keeps ~10 samples; only the long limb chords climb to the
  // 40-sample cap. The density field has no structure finer than the shell
  // profile, so the coarser interior pitch resolves everything it did before.
  float chord = t1 - t0;
  float samplesF =
      clamp(chord / max(topR - baseR, 1e-4) * 10.0, 10.0, float(VIEW_SAMPLES));
  int samples = int(samplesF + 0.5);
  float stepLen = chord / float(samples);
  float mu = dot(rd, sunDir);
  float phase = hgPhase(mu, 0.2);
  float sunStep = (topR - baseR) / float(LIGHT_SAMPLES);

  // Half-amplitude per-pixel jitter of the march phase: decorrelates the
  // sample lattice between neighbouring pixels so the coarser adaptive pitch
  // reads as faint grain instead of contour bands. Half-strength keeps the
  // grain under the noise floor of the density field itself.
  float jitter =
      fract(sin(dot(gl_FragCoord.xy, vec2(12.9898, 78.233))) * 43758.5453);
  float marchPhase = 0.25 + 0.5 * jitter;

  vec3 scatter = vec3(0.0);
  float transmittance = 1.0;

  for (int i = 0; i < VIEW_SAMPLES; i++) {
    if (i >= samples) break;
    vec3 p = ro + rd * (t0 + (float(i) + marchPhase) * stepLen);
    float density = cloudDensity(p) * densMul;
    if (density <= 0.0) continue;

    // Powder term: darkens the illuminated edges toward the core, the cue
    // that reads as cloud VOLUME rather than a flat lit shell.
    float powder = 1.0 - exp(-density * stepLen * 2.0);

    float vis = sunVisibility(p, sunDir, centre, planetR);
    // Self-shadow: march a few steps toward the sun, accumulate density,
    // Beer's law — but only where sunlight actually reaches: past the
    // terminator the direct term is multiplied to nothing by `vis`, so the
    // whole light march is skipped on the night side. Inside the march,
    // exp(-6) is invisible — stop integrating once tau is past it.
    vec3 sun = vec3(0.0);
    if (vis > 0.004) {
      float sunTau = 0.0;
      for (int j = 0; j < LIGHT_SAMPLES; j++) {
        vec3 q = p + sunDir * ((float(j) + 0.5) * sunStep);
        sunTau += cloudDensityLo(q) * densMul * sunStep;
        if (sunTau > 6.0) break;
      }
      sun = sunI * tint * exp(-sunTau) * phase * powder * vis;
    }
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
