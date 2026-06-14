import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../universe/star_system.dart';
import 'orbit.dart';
import 'orbital_elements.dart';
import 'state_vector_converter.dart';

/// Computes where celestial bodies are at a given epoch. Domain service.
///
/// Bodies follow a full Keplerian orbit about their parent, defined by the
/// body's orbital elements ([CelestialBody.orbitRadius] = semi-major axis,
/// eccentricity, inclination, RAAN, argument of periapsis, and
/// [CelestialBody.orbitPhase] = mean anomaly at epoch 0). Propagation reuses the
/// same [StateVectorOrbitConverter] vessels use, so body and vessel motion share
/// one tested code path. A circular, equatorial orbit (e=0, i=0) reduces to the
/// original simple model.
class BodyEphemeris {
  final StateVectorOrbitConverter converter;
  const BodyEphemeris([this.converter = const StateVectorOrbitConverter()]);

  /// Body position relative to its parent's centre, at [epoch]. Root bodies
  /// (no parent) return the origin.
  Vector3 positionRelativeToParent(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) {
    final parent = system.parentOf(body);
    if (parent == null || body.orbitRadius == 0) return Vector3.zero;
    return converter.toStateVector(_orbitOf(body, parent), epoch).position;
  }

  /// Body orbital velocity relative to its parent, at [epoch].
  Vector3 velocityRelativeToParent(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) {
    final parent = system.parentOf(body);
    if (parent == null || body.orbitRadius == 0) return Vector3.zero;
    return converter.toStateVector(_orbitOf(body, parent), epoch).velocity;
  }

  /// Body position relative to the SYSTEM ROOT, chaining up the parent tree.
  Vector3 positionRelativeToRoot(
    CelestialBody body,
    StarSystem system,
    Epoch epoch,
  ) {
    var pos = Vector3.zero;
    CelestialBody? cur = body;
    while (cur != null && system.parentOf(cur) != null) {
      pos = pos + positionRelativeToParent(cur, system, epoch);
      cur = system.parentOf(cur);
    }
    return pos;
  }

  Orbit _orbitOf(CelestialBody body, CelestialBody parent) => Orbit(
        elements: OrbitalElements(
          semiMajorAxis: body.orbitRadius,
          eccentricity: body.orbitEccentricity,
          inclination: body.orbitInclination,
          longitudeOfAscendingNode: body.orbitLongitudeAscending,
          argumentOfPeriapsis: body.orbitArgPeriapsis,
          meanAnomalyAtEpoch: body.orbitPhase,
        ),
        body: parent.id,
        mu: parent.mu,
        epoch: Epoch.zero,
      );
}
