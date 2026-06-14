/// Pure value object describing an ultra-basic atmosphere glow ring around a
/// body drawn in the top-down view. No Flutter `Color` — alpha is returned as a
/// plain `double` 0..1 and the painter picks the hue. Interface-adapter layer:
/// pure math, no rendering deps.
///
/// The ring spans from the body surface ([innerRadius]) out to
/// `innerRadius * (1 + thicknessFraction)` ([outerRadius]). Alpha is full at the
/// surface and falls linearly to 0 at the outer edge, so the glow reads densest
/// where it hugs the body and vanishes into space.
class AtmosphereHalo {
  /// Body radius in pixels (inner edge of the halo, at the surface).
  final double bodyRadiusPx;

  /// Atmosphere thickness as a fraction of the body radius (must be > 0 for a
  /// visible ring). E.g. 0.15 => the glow extends 15% of the radius outward.
  final double thicknessFraction;

  const AtmosphereHalo({
    required this.bodyRadiusPx,
    required this.thicknessFraction,
  });

  /// Inner edge of the halo (the body surface), in pixels.
  double get innerRadius => bodyRadiusPx;

  /// Outer edge of the halo, in pixels.
  double get outerRadius => bodyRadiusPx * (1.0 + thicknessFraction);

  /// Width of the glow band, in pixels.
  double get thicknessPx => outerRadius - innerRadius;

  /// Alpha `0..1` of the glow at [radiusPx] from the body centre.
  ///
  /// Full at (and inside) the surface, fading linearly to 0 at [outerRadius];
  /// 0 for anything at or beyond the outer edge. Monotonically decreasing across
  /// the band.
  double alphaAt(double radiusPx) {
    if (radiusPx <= innerRadius) return 1.0;
    if (radiusPx >= outerRadius) return 0.0;
    final span = outerRadius - innerRadius;
    if (span <= 0.0) return 0.0;
    final t = (radiusPx - innerRadius) / span; // 0 at surface, 1 at outer edge
    return 1.0 - t;
  }
}
