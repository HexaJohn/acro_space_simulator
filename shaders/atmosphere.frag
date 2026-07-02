// Raymarched planetary atmosphere (Nishita-style single scattering).
//
// Runs on flutter_scene's unlit ShaderMaterial path over a shell sphere
// slightly larger than the planet. The planet occluder is analytic (a
// sphere in the uniforms), so no depth buffer is needed; rays clip against
// it exactly. The camera can sit outside the shell, inside it, or on the
// surface — entry distance clamps to zero, so the transition through the
// atmosphere top is seamless by construction.
//
// Distances are in SCENE UNITS (kilometres — see coord_convert.dart).
// Output is premultiplied linear HDR (the engine tonemaps after).

uniform AtmosphereInfo {
  // xyz: planet centre (scene units, world/focus-relative frame the
  // vertex outputs use). w: planet radius.
  vec4 center_radius;
  // xyz: unit direction from the planet TOWARD the sun. w: atmosphere top
  // radius (> planet radius).
  vec4 sun_atmo;
  // xyz: Rayleigh scattering coefficients per scene unit. w: density scale
  // height (scene units).
  vec4 rayleigh;
  // x: sun intensity. y: tint mix (0 = physical colour, 1 = full tint).
  // zw: tint red/green... packed: z = tint r, w = tint g (b in params2.x).
  vec4 params;
  // x: tint b. y: twilight softness (scene units) — width of the smooth
  // day/night transition band; the terminator blurs across it instead of
  // cutting at the geometric horizon. z: density normalisation (1/falloff)
  // — keeps the VERTICAL air mass constant as the falloff knob stretches
  // the scale height, so a taller glow doesn't thicken the disc haze.
  // w: unused padding.
  vec4 params2;
}
atmosphere_info;

in vec3 v_position;
in vec3 v_normal;
in vec3 v_viewvector;
in vec2 v_texture_coords;
in vec4 v_color;

out vec4 frag_color;

const int VIEW_SAMPLES = 12;
const int LIGHT_SAMPLES = 6;

// Ray/sphere: returns (tNear, tFar), tFar < tNear when missed.
vec2 raySphere(vec3 ro, vec3 rd, vec3 c, float r) {
  vec3 oc = ro - c;
  float b = dot(oc, rd);
  float h = b * b - (dot(oc, oc) - r * r);
  if (h < 0.0) return vec2(1.0, -1.0);
  float s = sqrt(h);
  return vec2(-b - s, -b + s);
}

// Soft planet shadow toward the sun. A binary horizon test cut the
// terminator to a hard line; instead attenuate by the sun ray's closest
// approach altitude over a twilight band [soft] wide — dusk glow bleeds
// smoothly past the geometric terminator. The slight negative lower edge
// keeps a little scatter alive just past grazing.
float sunVisibility(vec3 p, vec3 sunDir, vec3 c, float planetR, float soft) {
  vec3 op = p - c;
  float tStar = -dot(op, sunDir);
  if (tStar <= 0.0) return 1.0; // closest approach is behind: sun side
  float minAlt = length(op + sunDir * tStar) - planetR;
  return smoothstep(-0.3 * soft, soft, minAlt);
}

void main() {
  vec3 centre = atmosphere_info.center_radius.xyz;
  float planetR = atmosphere_info.center_radius.w;
  float atmoR = atmosphere_info.sun_atmo.w;
  vec3 sunDir = normalize(atmosphere_info.sun_atmo.xyz);
  vec3 beta = atmosphere_info.rayleigh.xyz;
  float scaleH = atmosphere_info.rayleigh.w;

  // Camera ray. v_viewvector = camera - fragment.
  vec3 ro = v_position + v_viewvector; // camera position
  vec3 rd = normalize(-v_viewvector);  // camera -> fragment

  vec2 shell = raySphere(ro, rd, centre, atmoR);
  if (shell.y <= max(shell.x, 0.0)) {
    frag_color = vec4(0.0);
    return;
  }
  float t0 = max(shell.x, 0.0);
  float t1 = shell.y;

  // The planet blocks the far part of the ray. GUARD the miss sentinel
  // (tFar < tNear): its tNear of 1.0 read as a real hit 1 unit ahead, so
  // every ray that MISSED the planet clamped to a zero-length march and
  // discarded — the limb halo never rendered at all.
  vec2 ground = raySphere(ro, rd, centre, planetR);
  if (ground.y >= ground.x && ground.x > 0.0 && ground.x < t1) {
    t1 = ground.x;
  }
  if (t1 <= t0) {
    frag_color = vec4(0.0);
    return;
  }

  float stepLen = (t1 - t0) / float(VIEW_SAMPLES);
  float densNorm = atmosphere_info.params2.z;
  vec3 inscatter = vec3(0.0);
  float viewDepth = 0.0; // optical depth along the view ray so far

  for (int i = 0; i < VIEW_SAMPLES; i++) {
    vec3 p = ro + rd * (t0 + (float(i) + 0.5) * stepLen);
    float h = max(length(p - centre) - planetR, 0.0);
    float density = exp(-h / scaleH) * densNorm * stepLen;
    viewDepth += density;

    // Sunlight reaching this sample: soft twilight shadow (see
    // sunVisibility) times the optical depth along the sun ray.
    float vis =
        sunVisibility(p, sunDir, centre, planetR, atmosphere_info.params2.y);
    if (vis <= 0.0) continue;
    vec2 sunShell = raySphere(p, sunDir, centre, atmoR);
    float sunPath = max(sunShell.y, 0.0);
    float sunStep = sunPath / float(LIGHT_SAMPLES);
    float sunDepth = 0.0;
    for (int j = 0; j < LIGHT_SAMPLES; j++) {
      vec3 q = p + sunDir * ((float(j) + 0.5) * sunStep);
      float hq = max(length(q - centre) - planetR, 0.0);
      sunDepth += exp(-hq / scaleH) * densNorm * sunStep;
    }

    vec3 transmittance = exp(-beta * (viewDepth + sunDepth));
    inscatter += density * transmittance * vis;
  }

  // Rayleigh phase.
  float mu = dot(rd, sunDir);
  float phase = 3.0 / (16.0 * 3.14159265) * (1.0 + mu * mu);

  vec3 colour = inscatter * beta * phase * atmosphere_info.params.x;

  // Optional hue pull toward the body's descriptor tint (alien skies).
  vec3 tint = vec3(atmosphere_info.params.z, atmosphere_info.params.w,
      atmosphere_info.params2.x);
  float tintMix = atmosphere_info.params.y;
  float lum = dot(colour, vec3(0.2126, 0.7152, 0.0722));
  colour = mix(colour, lum * tint * 3.0, tintMix);

  // Coverage = mean per-channel extinction along the view ray. (An earlier
  // cut summed beta across channels — 3-4x too much coverage, milky disc.)
  // Blended as: out = inscatter + (1 - alpha) * surface, the premultiplied
  // form of out = inscatter + T * surface.
  vec3 T = exp(-beta * viewDepth);
  float alpha = clamp(1.0 - dot(T, vec3(1.0 / 3.0)), 0.0, 1.0);
  frag_color = vec4(colour, alpha);
}
