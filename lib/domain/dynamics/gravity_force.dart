import '../shared/vector3.dart';
import '../universe/celestial_body.dart';
import 'force.dart';
import 'force_model.dart';
import 'mass_properties.dart';
import 'state_vector.dart';

/// Two-body point-mass gravity from the vessel's dominant [body]. The only
/// gravitational contributor under patched conics — exactly one body acts at a
/// time. F = m * a, a = -mu r / |r|^3. Acts through the CoM, so no torque.
class GravityForce implements ForceContributor {
  final CelestialBody body;
  const GravityForce(this.body);

  @override
  GeneralizedForce evaluate(StateVector state, MassProperties mass) {
    final a = body.gravityAt(state.position);
    return GeneralizedForce(a * mass.mass, Vector3.zero);
  }
}
