import 'dart:math' as math;

import '../../domain/shared/vector3.dart';

/// Ultra-basic Lambert shading for a celestial body drawn as a flat disc in the
/// top-down XY view. PURE math — no Flutter. The painter samples this per pixel
/// (or per ring) to tint the disc, picking the actual colour itself.
///
/// A point on the disc is given as a fraction offset from the centre
/// `(dx, dy)`, each in `[-1, 1]` where `(0, 0)` is the centre and the rim is at
/// `dx^2 + dy^2 == 1`. We lift that flat point onto the front hemisphere of a
/// unit sphere to approximate the surface normal:
///
///   nz = sqrt(max(0, 1 - dx^2 - dy^2))
///   normal = (dx, dy, nz)
///
/// Brightness is `max(0, normal . sunDirection)` — the standard Lambert
/// cosine term, clamped so the dark side reads as 0.
class BodyShading {
  const BodyShading();

  /// Brightness `0..1` of the disc point `(dx, dy)` given a [sunDirection].
  ///
  /// [sunDirection] is expected normalised and to lie in the XY render plane
  /// (its Z component contributes through the hemispherical normal). Points
  /// outside the disc (`dx^2 + dy^2 > 1`) are not on the body, so return 0.
  double brightnessAt(double dx, double dy, Vector3 sunDirection) {
    final r2 = dx * dx + dy * dy;
    if (r2 > 1.0) return 0.0;

    final nz = math.sqrt(math.max(0.0, 1.0 - r2));
    final normal = Vector3(dx, dy, nz);
    final lambert = normal.dot(sunDirection);
    if (lambert <= 0.0) return 0.0;
    return lambert > 1.0 ? 1.0 : lambert;
  }

  /// Brightness at the terminator — the great circle where the surface is
  /// edge-on to the sun (normal perpendicular to [sunDirection]). With an ideal
  /// Lambert model this is exactly 0; exposed as a named convenience so painters
  /// and tuning code don't hardcode the magic number.
  double terminatorBrightness(Vector3 sunDirection) => 0.0;
}
