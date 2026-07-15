/// Seeded 3D value noise with fractal (fBm) summation. Deterministic: the same
/// seed + coordinate always yields the same value, so it is safe to sample
/// identically in the domain (collision) and the renderer (meshing). Pure Dart,
/// isolate-safe.
///
/// Value noise (hash the 8 lattice corners, quintic-interpolate) rather than
/// gradient/Perlin — cheaper, no gradient table, and adequate for terrain
/// relief. [noise] returns 0..1; [fbm] returns 0..1.
class ValueNoise3 {
  const ValueNoise3(this.seed);

  final int seed;

  /// Integer lattice hash -> 0..1. A cheap avalanche mix of the coordinate and
  /// seed (masked to 32 bits so it behaves the same on the web's doubles).
  double _hash(int x, int y, int z) {
    var h = seed & 0xffffffff;
    h = (h ^ (x * 0x9e3779b1)) & 0xffffffff;
    h = (h ^ (y * 0x85ebca6b)) & 0xffffffff;
    h = (h ^ (z * 0xc2b2ae35)) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    h = (h * 0x2c1b3c6d) & 0xffffffff;
    h = (h ^ (h >> 12)) & 0xffffffff;
    h = (h * 0x297a2d39) & 0xffffffff;
    h = (h ^ (h >> 15)) & 0xffffffff;
    return h / 0xffffffff;
  }

  static double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10); // quintic

  /// Trilinear value noise in 0..1 at a continuous coordinate.
  double noise(double x, double y, double z) {
    final xi = x.floor(), yi = y.floor(), zi = z.floor();
    final xf = x - xi, yf = y - yi, zf = z - zi;
    final u = _fade(xf), v = _fade(yf), w = _fade(zf);

    final c000 = _hash(xi, yi, zi), c100 = _hash(xi + 1, yi, zi);
    final c010 = _hash(xi, yi + 1, zi), c110 = _hash(xi + 1, yi + 1, zi);
    final c001 = _hash(xi, yi, zi + 1), c101 = _hash(xi + 1, yi, zi + 1);
    final c011 = _hash(xi, yi + 1, zi + 1), c111 = _hash(xi + 1, yi + 1, zi + 1);

    final x00 = c000 + (c100 - c000) * u;
    final x10 = c010 + (c110 - c010) * u;
    final x01 = c001 + (c101 - c001) * u;
    final x11 = c011 + (c111 - c011) * u;
    final y0 = x00 + (x10 - x00) * v;
    final y1 = x01 + (x11 - x01) * v;
    return y0 + (y1 - y0) * w;
  }

  /// Fractal Brownian motion: [octaves] layers of noise at rising frequency
  /// ([lacunarity]) and falling amplitude ([gain]). Normalised back to 0..1.
  double fbm(
    double x,
    double y,
    double z, {
    int octaves = 4,
    double lacunarity = 2.0,
    double gain = 0.5,
  }) {
    var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0;
    for (var i = 0; i < octaves; i++) {
      sum += amp * noise(x * freq, y * freq, z * freq);
      norm += amp;
      amp *= gain;
      freq *= lacunarity;
    }
    return norm > 0 ? sum / norm : 0.0;
  }

  /// Ridged fBm (1 - |2n-1| folded) — sharper crests, for mountains/ridges.
  /// Returns 0..1. Not used by the smooth foundation but handy for tuning.
  double ridged(
    double x,
    double y,
    double z, {
    int octaves = 4,
    double lacunarity = 2.0,
    double gain = 0.5,
  }) {
    var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0;
    for (var i = 0; i < octaves; i++) {
      final n = 1.0 - (2.0 * noise(x * freq, y * freq, z * freq) - 1.0).abs();
      sum += amp * n * n;
      norm += amp;
      amp *= gain;
      freq *= lacunarity;
    }
    return norm > 0 ? (sum / norm).clamp(0.0, 1.0) : 0.0;
  }
}

/// A tiny helper: value noise sampled from a unit direction times a world-space
/// feature wavelength, so feature size is independent of planet radius.
double directionFbm(
  ValueNoise3 n,
  double dx,
  double dy,
  double dz,
  double radius,
  double featureScale, {
  int octaves = 5,
}) {
  final s = radius / (featureScale <= 0 ? 1.0 : featureScale);
  return n.fbm(dx * s, dy * s, dz * s, octaves: octaves);
}
