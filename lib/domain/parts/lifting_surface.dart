import 'dart:math' as math;

/// A lifting surface (wing, canard, tail, control surface). Produces lift that
/// rises ~linearly with angle of attack up to a [stallAngle], beyond which flow
/// separates and lift collapses — the reason aircraft stall. Real-airfoil
/// grounded via the thin-airfoil lift-curve slope.
class LiftingSurface {
  final String name;

  /// Planform area, m^2.
  final double area;

  /// Lift-curve slope dCl/dAoA, per radian (~2*pi ideal; less for real/swept).
  final double liftCurveSlope;

  /// Angle of attack (rad) at which the wing stalls.
  final double stallAngle;

  /// Parasitic drag coefficient contributed by this surface.
  final double dragCoefficient;

  const LiftingSurface({
    required this.name,
    required this.area,
    this.liftCurveSlope = 5.7,
    this.stallAngle = 0.26,
    this.dragCoefficient = 0.02,
  });

  /// Lift coefficient at the given angle of attack [aoa] (rad). Linear below
  /// stall; past stall it decays toward zero as flow separates.
  double liftCoefficient(double aoa) {
    final absA = aoa.abs();
    final sign = aoa < 0 ? -1.0 : 1.0;
    if (absA <= stallAngle) {
      return liftCurveSlope * aoa;
    }
    // Post-stall: peak Cl at the stall angle, decaying linearly to ~0 by 2x.
    final peak = liftCurveSlope * stallAngle;
    final over = (absA - stallAngle) / stallAngle; // 0 at stall, 1 at 2x stall
    final decayed = peak * math.max(0.0, 1.0 - over);
    return sign * decayed;
  }

  /// Lift force magnitude (N) = q * Cl * area.
  double liftForce({required double dynamicPressure, required double angleOfAttack}) =>
      dynamicPressure * liftCoefficient(angleOfAttack) * area;
}
