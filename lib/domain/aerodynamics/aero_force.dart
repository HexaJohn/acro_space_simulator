import '../dynamics/force.dart';
import '../dynamics/force_model.dart';
import '../dynamics/mass_properties.dart';
import '../dynamics/state_vector.dart';
import '../shared/vector3.dart';
import '../universe/atmosphere_model.dart';

/// Aerodynamic drag (and a crude lift) force from the vessel moving through an
/// atmosphere. Force contributor injected into the model when the vessel is
/// inside an atmosphere.
///
/// Drag: F_d = -0.5 * rho * |v_rel|^2 * Cd * A * v_hat.
/// Mach effects raise Cd transonically (drag divergence) — approximated by a
/// bump near Mach 1. [windVelocity] comes from the weather context so storms
/// and jet streams actually push ships around.
class AeroForce implements ForceContributor {
  final AtmosphereSample atmosphere;
  final Vector3 windVelocity; // m/s, inertial (surface-relative wind)
  final double dragCoefficient; // Cd, vessel total
  final double referenceArea; // m^2
  final double liftCoefficient; // Cl, simple

  const AeroForce({
    required this.atmosphere,
    required this.dragCoefficient,
    required this.referenceArea,
    this.windVelocity = Vector3.zero,
    this.liftCoefficient = 0,
  });

  @override
  GeneralizedForce evaluate(StateVector state, MassProperties mass) {
    if (atmosphere.density <= 0) return GeneralizedForce.zero;

    final vRel = state.velocity - windVelocity;
    final speed = vRel.length;
    if (speed < 1e-6) return GeneralizedForce.zero;

    final dynPressure = 0.5 * atmosphere.density * speed * speed; // q

    // Mach number and transonic drag rise.
    final mach = atmosphere.speedOfSound > 0 ? speed / atmosphere.speedOfSound : 0.0;
    final cd = dragCoefficient * _machDragFactor(mach);

    final dragMag = dynPressure * cd * referenceArea;
    final drag = vRel.normalized * (-dragMag);

    // Lift perpendicular to velocity, in the plane containing "up" (+Z).
    var lift = Vector3.zero;
    if (liftCoefficient != 0) {
      final liftDir = vRel.cross(Vector3.unitZ).cross(vRel).normalized;
      lift = liftDir * (dynPressure * liftCoefficient * referenceArea);
    }

    // Aero acts at the centre of pressure; torque modelling deferred (returns
    // zero torque) until parts carry a CoP offset.
    return GeneralizedForce(drag + lift, Vector3.zero);
  }

  /// Cd multiplier vs Mach: ~1 subsonic, peak near Mach 1, settling supersonic.
  double _machDragFactor(double mach) {
    if (mach < 0.8) return 1.0;
    if (mach < 1.2) return 1.0 + (mach - 0.8) * 1.5; // rise through transonic
    return 1.6 - (mach - 1.2) * 0.2 < 1.0 ? 1.0 : 1.6 - (mach - 1.2) * 0.2;
  }
}
