// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Seeded 3D GRADIENT noise carrying its own analytic derivative, plus the
/// fractal summations built on it.
///
/// Two things this has that `noise3.dart`'s value noise does not:
///
///  * **Gradient, not value.** Value noise interpolates hashed lattice CORNERS,
///    which leaves visible axis-aligned structure and a blobby, cottage-cheese
///    character once octaves stack. Gradient noise interpolates the dot product
///    of a hashed direction with the offset, so lattice points sit at zero and
///    the artefacts largely cancel.
///  * **Analytic derivatives.** Every sample returns d/dx, d/dy, d/dz exactly,
///    not by finite difference. That is what makes [erodedFbm] possible — it
///    needs the accumulated slope of the octaves it has already summed, and
///    finite-differencing that per sample would cost four evaluations instead
///    of one.
///
/// Pure, deterministic, isolate-safe: the same seed and coordinate always give
/// the same result, so collision and the render mesher can sample it
/// independently and agree.
library;

import 'dart:math' as math;

/// A noise value with its exact gradient.
class NoiseSample {
  const NoiseSample(this.value, this.dx, this.dy, this.dz);

  static const NoiseSample zero = NoiseSample(0, 0, 0, 0);

  /// Approximately `-1..1`.
  final double value;

  /// Partial derivatives with respect to the sample coordinate.
  ///
  /// Exact for [GradientNoise3.sample], [fbm3] and [ridgedFbm]. [erodedFbm]
  /// returns a slope ESTIMATE here rather than an exact derivative — see its
  /// doc comment for why.
  final double dx, dy, dz;

  /// Magnitude of the gradient — how steeply the field is changing here.
  double get slope => math.sqrt(dx * dx + dy * dy + dz * dz);

  NoiseSample operator +(NoiseSample o) =>
      NoiseSample(value + o.value, dx + o.dx, dy + o.dy, dz + o.dz);

  NoiseSample operator *(double s) =>
      NoiseSample(value * s, dx * s, dy * s, dz * s);
}

/// The 12 edge-midpoint gradients of a cube (Perlin's improved set), padded to
/// 16 with four repeats so the selection can be a cheap `hash & 15` without a
/// modulo. The repeats are the standard choice: they bias the distribution
/// negligibly and keep the table a power of two.
const List<List<double>> _gradients = [
  [1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], //
  [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1], //
  [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1], //
  [1, 1, 0], [0, -1, 1], [-1, 1, 0], [0, -1, -1], //
];

/// Scales the raw noise to roughly `-1..1`. Gradient noise in 3D with the
/// unit-edge gradient set peaks near `sqrt(3)/2`, so this lifts it to unity.
const double _normalize = 1.1547005383792515; // 2 / sqrt(3)

/// Seeded 3D gradient (Perlin-style) noise with derivatives.
class GradientNoise3 {
  const GradientNoise3(this.seed);

  final int seed;

  /// Integer lattice hash. Same avalanche mix `ValueNoise3` uses, masked to 32
  /// bits so the web's doubles-backed ints behave identically to native.
  int _hash(int x, int y, int z) {
    var h = seed & 0xffffffff;
    h = (h ^ (x * 0x9e3779b1)) & 0xffffffff;
    h = (h ^ (y * 0x85ebca6b)) & 0xffffffff;
    h = (h ^ (z * 0xc2b2ae35)) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    h = (h * 0x2c1b3c6d) & 0xffffffff;
    h = (h ^ (h >> 12)) & 0xffffffff;
    h = (h * 0x297a2d39) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    return h;
  }

  /// Quintic fade — C2 continuous, so stacked octaves have no creases.
  static double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

  /// d/dt of [_fade]: `30t^2(t-1)^2`.
  static double _dFade(double t) => 30 * t * t * (t - 1) * (t - 1);

  /// Sample the field and its gradient at a continuous coordinate.
  ///
  /// The value is a trilinear blend of the eight corner dot products
  /// `V_c = g_c . (f - c)`, weighted by `W_c`. Differentiating that is the
  /// product rule over both factors:
  ///
  ///   dValue/dx = sum_c [ (dW_c/du * du/dx) * V_c + W_c * g_c.x ]
  ///
  /// The first term is the blend weights moving, the second the corner
  /// gradients themselves. Dropping either — a mistake that looks fine on a
  /// smooth preview — leaves the derivative wrong where it matters most, on
  /// the steep faces [erodedFbm] keys off.
  NoiseSample sample(double x, double y, double z) {
    final xi = x.floor(), yi = y.floor(), zi = z.floor();
    final fx = x - xi, fy = y - yi, fz = z - zi;

    final u = _fade(fx), v = _fade(fy), w = _fade(fz);
    final du = _dFade(fx), dv = _dFade(fy), dw = _dFade(fz);

    var value = 0.0, gx = 0.0, gy = 0.0, gz = 0.0;
    for (var c = 0; c < 8; c++) {
      final cx = c & 1, cy = (c >> 1) & 1, cz = (c >> 2) & 1;
      final g = _gradients[_hash(xi + cx, yi + cy, zi + cz) & 15];

      // Corner dot product and the offset it is taken over.
      final ox = fx - cx, oy = fy - cy, oz = fz - cz;
      final dot = g[0] * ox + g[1] * oy + g[2] * oz;

      // Trilinear weight factors for this corner, and their derivatives.
      final wx = cx == 1 ? u : 1 - u;
      final wy = cy == 1 ? v : 1 - v;
      final wz = cz == 1 ? w : 1 - w;
      final sx = cx == 1 ? 1.0 : -1.0;
      final sy = cy == 1 ? 1.0 : -1.0;
      final sz = cz == 1 ? 1.0 : -1.0;

      final weight = wx * wy * wz;
      value += weight * dot;
      gx += sx * du * wy * wz * dot + weight * g[0];
      gy += wx * sy * dv * wz * dot + weight * g[1];
      gz += wx * wy * sz * dw * dot + weight * g[2];
    }

    return NoiseSample(value * _normalize, gx * _normalize, gy * _normalize,
        gz * _normalize);
  }

  /// Value only, for callers that do not need the gradient. Same field as
  /// [sample] — it simply discards the derivative rather than skipping work.
  double noise(double x, double y, double z) => sample(x, y, z).value;
}

/// Plain fractal Brownian motion with derivatives: octaves at rising frequency
/// and falling amplitude, normalised so the value stays roughly `-1..1`.
///
/// The derivative accumulates the chain rule — an octave sampled at frequency
/// `f` contributes `f` times its own gradient.
NoiseSample fbm3(
  GradientNoise3 n,
  double x,
  double y,
  double z, {
  int octaves = 5,
  double lacunarity = 2.0,
  double gain = 0.5,
}) {
  var value = 0.0, dx = 0.0, dy = 0.0, dz = 0.0;
  var amp = 1.0, freq = 1.0, norm = 0.0;
  for (var i = 0; i < octaves; i++) {
    final s = n.sample(x * freq, y * freq, z * freq);
    value += amp * s.value;
    dx += amp * freq * s.dx;
    dy += amp * freq * s.dy;
    dz += amp * freq * s.dz;
    norm += amp;
    amp *= gain;
    freq *= lacunarity;
  }
  if (norm <= 0) return NoiseSample.zero;
  final inv = 1.0 / norm;
  return NoiseSample(value * inv, dx * inv, dy * inv, dz * inv);
}

/// **Erosion-aware fBm** — the single change that most makes procedural terrain
/// read as eroded rather than as noise.
///
/// Each octave is damped by the slope accumulated from the octaves ALREADY
/// summed: `contribution *= 1 / (1 + k * |d|^2)`. Where the terrain is already
/// steep, finer detail is suppressed; where it is flat, detail lands in full.
///
/// That asymmetry is what plain fBm cannot produce. An fBm sum is statistically
/// symmetric — its hills and hollows are mirror images — whereas real relief is
/// not: steep faces are scoured clean and flat ground collects texture. Damping
/// on accumulated slope reproduces that for the cost of carrying a derivative,
/// which is why the noise underneath had to become analytic first.
///
/// [slopeDamping] is `k`. 0 degenerates exactly to plain [fbm3]; around 1 is a
/// strong, clearly eroded look.
///
/// ## The returned gradient is an ESTIMATE, not an exact derivative
///
/// It is the damping-weighted sum of the octaves' own gradients — the
/// `damp * d(n)/dx` term. The exact derivative would also need
/// `d(damp)/dx * n`, and because `damp` is a function of the ACCUMULATED
/// gradient, that term needs the noise's second derivatives: a full 3x3 Hessian
/// per octave, roughly tripling this file for a quantity nothing here consumes.
/// The mesher takes its normals by central-differencing the density field
/// (`cell_mesher.dart`), and slope-driven control fields only need a steepness
/// estimate.
///
/// So: use it as a slope/roughness signal, and do NOT expect it to integrate
/// back to [value]. Where the true derivative is required, central-difference
/// [value] directly. With `slopeDamping: 0` the two coincide, which is what
/// the tests pin.
NoiseSample erodedFbm(
  GradientNoise3 n,
  double x,
  double y,
  double z, {
  int octaves = 6,
  double lacunarity = 2.0,
  double gain = 0.5,
  double slopeDamping = 1.0,
}) {
  var value = 0.0, dx = 0.0, dy = 0.0, dz = 0.0;
  // Slope of the UNDAMPED partial sum so far — the running steepness the
  // damping term reads. Kept separate from the output gradient, which is
  // damped and would otherwise feed back on itself.
  //
  // The `amp * freq` weight is load-bearing and easy to get wrong. An octave
  // at frequency `f` and amplitude `a` contributes `a * f * grad(n)` to the
  // sum's slope. Weighting by frequency ALONE (the bare chain rule, forgetting
  // that the octave is also scaled down) makes the accumulator grow like
  // `2^i` and be dominated by the finest octave — the damping then comes out
  // near-uniform everywhere and the whole effect washes out. At the classic
  // gain 0.5 / lacunarity 2 the product is exactly 1 per octave, so every
  // scale gets an equal say, which is the behaviour this is meant to have.
  var ax = 0.0, ay = 0.0, az = 0.0;
  var amp = 1.0, freq = 1.0, norm = 0.0;

  for (var i = 0; i < octaves; i++) {
    final s = n.sample(x * freq, y * freq, z * freq);
    final w = amp * freq;
    ax += w * s.dx;
    ay += w * s.dy;
    az += w * s.dz;

    final damp = 1.0 / (1.0 + slopeDamping * (ax * ax + ay * ay + az * az));
    final scale = amp * damp;
    value += scale * s.value;
    dx += scale * freq * s.dx;
    dy += scale * freq * s.dy;
    dz += scale * freq * s.dz;

    norm += amp;
    amp *= gain;
    freq *= lacunarity;
  }
  if (norm <= 0) return NoiseSample.zero;
  final inv = 1.0 / norm;
  return NoiseSample(value * inv, dx * inv, dy * inv, dz * inv);
}

/// Ridged multifractal: each octave folded through `1 - |n|` and squared, which
/// turns the field's zero crossings into sharp crests. Returns `0..1`.
///
/// Use for mountain belts and fault scarps, blended against [erodedFbm] rather
/// than replacing it — ridges everywhere reads as artificial just as fast as
/// noise everywhere does.
double ridgedFbm(
  GradientNoise3 n,
  double x,
  double y,
  double z, {
  int octaves = 5,
  double lacunarity = 2.0,
  double gain = 0.5,
}) {
  var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0;
  for (var i = 0; i < octaves; i++) {
    final v = 1.0 - n.sample(x * freq, y * freq, z * freq).value.abs();
    sum += amp * v * v;
    norm += amp;
    amp *= gain;
    freq *= lacunarity;
  }
  return norm > 0 ? (sum / norm).clamp(0.0, 1.0) : 0.0;
}

/// A domain-warp offset: a low-frequency vector field to add to a coordinate
/// before sampling it.
///
/// Warping is what breaks fBm's tell-tale isotropy. Sampling `f(p + warp(p))`
/// bends the field's contours into sinuous, braided shapes that look
/// transported rather than deposited — the same trick that turns uniform noise
/// into something resembling flow. [strength] is in the same units as the
/// coordinate; [frequency] scales the warp field relative to it.
({double x, double y, double z}) domainWarp(
  GradientNoise3 n,
  double x,
  double y,
  double z, {
  double strength = 0.5,
  double frequency = 0.5,
  int octaves = 2,
}) {
  // Three decorrelated lookups. The large offsets keep the channels from
  // sharing lattice cells, which would make the warp collapse toward a
  // diagonal instead of covering all three axes.
  final fx = x * frequency, fy = y * frequency, fz = z * frequency;
  final a = fbm3(n, fx, fy, fz, octaves: octaves);
  final b = fbm3(n, fx + 137.31, fy + 41.77, fz + 9.13, octaves: octaves);
  final c = fbm3(n, fx + 5.29, fy + 213.07, fz + 71.59, octaves: octaves);
  return (
    x: x + a.value * strength,
    y: y + b.value * strength,
    z: z + c.value * strength,
  );
}
