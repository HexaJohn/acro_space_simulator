#version 460 core
#include <flutter/runtime_effect.glsl>

// Per-pixel atmospheric glow by LINE-OF-SIGHT PATH LENGTH through a spherical
// atmosphere shell [1 .. uRa] (in units of the planet radius). For each pixel we
// reconstruct the camera-space view ray, intersect it with the atmosphere shell
// and the surface, and the length of ray inside the atmosphere (before it hits
// the surface) drives the glow. This is correct at EVERY altitude — from orbit
// (a soft ring on the limb) down to standing on the ground (a soft band along the
// local horizon) — because it's a true 3-D ray test, not a screen-space circle.
//
// All distances are in PLANET RADII (the painter passes the centre scaled by
// 1/R) so float32 keeps precision even at interplanetary range.

uniform vec2 uSize;     // viewport size, px
uniform vec3 uCenter;   // planet centre relative to the eye, in radii (camera space: x=right, y=up, z=forward)
uniform float uRa;      // atmosphere top radius, in radii (e.g. 1.05)
uniform float uFocal;   // focal length, px
uniform vec3 uTint;     // atmosphere colour, linear rgb 0..1
uniform vec3 uWarm;     // warm terminator colour, linear rgb 0..1
uniform vec3 uSun;      // sun direction in camera space (unit)
uniform float uStrength;// overall opacity multiplier

out vec4 fragColor;

void main() {
  vec2 frag = FlutterFragCoord().xy;
  // Centre-origin, +y up (screen y is down).
  vec2 p = vec2(frag.x - uSize.x * 0.5, (uSize.y * 0.5) - frag.y);
  // View ray in camera space: the camera looks along +z (forward); a pixel at
  // screen offset (px,py) corresponds to ray direction (px, py, focal).
  vec3 dir = normalize(vec3(p, uFocal));

  vec3 oc = uCenter;            // eye(origin) -> centre
  float b = dot(dir, oc);       // projection of centre onto the ray
  float oc2 = dot(oc, oc);

  // Intersect the atmosphere-top sphere (radius uRa).
  float discA = b * b - oc2 + uRa * uRa;
  if (discA <= 0.0) {           // ray misses the atmosphere entirely
    fragColor = vec4(0.0);
    return;
  }
  float sA = sqrt(discA);
  float ta0 = b - sA;           // atmosphere entry along the ray
  float ta1 = b + sA;           // atmosphere exit

  // Intersect the surface sphere (radius 1).
  float enter = max(ta0, 0.0);  // start in front of the eye
  float exitT;
  float discS = b * b - oc2 + 1.0;
  if (discS > 0.0) {
    float sS = sqrt(discS);
    float ts0 = b - sS;         // first surface hit
    exitT = (ts0 > enter) ? ts0 : ta1; // hit the surface, else pass through
  } else {
    exitT = ta1;                // misses the surface -> full chord
  }
  float path = max(0.0, exitT - enter);

  // Normalise by the longest possible chord (a grazing ray at the surface limb).
  float maxChord = 2.0 * sqrt(max(uRa * uRa - 1.0, 1e-4));
  float glow = clamp(path / maxChord, 0.0, 1.0);
  glow = pow(glow, 0.75);       // soft shoulder

  // Day/night + warm terminator from the atmosphere point nearest the limb along
  // this ray (closest approach to the centre), lit vs the sun.
  vec3 nearPt = dir * b - oc;   // closest-approach point relative to centre
  float nl = length(nearPt);
  vec3 nrm = nl > 1e-4 ? nearPt / nl : vec3(0.0, 0.0, 1.0);
  float lit = clamp(dot(nrm, uSun), -1.0, 1.0);
  float dayF = smoothstep(-0.25, 0.25, lit);     // 0 night -> 1 day
  float warmF = 1.0 - smoothstep(0.05, 0.6, lit); // warm low sun / terminator
  vec3 col = mix(uTint, uWarm, warmF);

  float a = glow * uStrength * (0.25 + 0.75 * dayF);
  a = clamp(a, 0.0, 1.0);
  // Premultiplied output for srcOver compositing.
  fragColor = vec4(col * a, a);
}
