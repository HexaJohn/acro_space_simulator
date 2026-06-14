import 'force.dart';
import 'mass_properties.dart';
import 'state_vector.dart';

/// A single physical contributor to the net force on a body — gravity, thrust,
/// aerodynamic drag/lift, etc. Each context (dynamics, aerodynamics, vessel)
/// supplies its own implementations; the [ForceModel] composes them.
///
/// This is the open seam for the physics: adding weather wind or a new engine
/// type means adding a contributor, not editing the integrator.
abstract class ForceContributor {
  GeneralizedForce evaluate(StateVector state, MassProperties mass);
}

/// Composes the active force contributors for one vessel into a single net
/// generalized force the integrator can consume. Pure; rebuilt per tick because
/// contributors depend on current throttle, atmosphere, etc.
class ForceModel {
  final List<ForceContributor> contributors;
  const ForceModel(this.contributors);

  static const ForceModel empty = ForceModel([]);

  GeneralizedForce netForce(StateVector state, MassProperties mass) {
    var sum = GeneralizedForce.zero;
    for (final c in contributors) {
      sum = sum + c.evaluate(state, mass);
    }
    return sum;
  }
}
