import '../universe/celestial_body.dart';
import '../vessel/vessel.dart';

/// Classifies a vessel's flight situation into a science "situation" string
/// (e.g. `surface:earth`, `lowOrbit:moon`). Domain service — the bridge between
/// the physics state and the science context, so experiment value depends on
/// *where* it was run.
class SituationService {
  /// Altitude (m) above which an orbit counts as "high".
  final double highOrbitAltitude;
  const SituationService({this.highOrbitAltitude = 250000});

  String classify(Vessel vessel, CelestialBody body) {
    final name = body.id.value;
    if (vessel.landed) return 'surface:$name';

    final altitude = body.altitudeOf(vessel.state.position);

    if (body.hasAtmosphere && body.atmosphere!.hasAtmosphere(altitude)) {
      return 'atmosphere:$name';
    }
    if (altitude < highOrbitAltitude) return 'lowOrbit:$name';
    return 'highOrbit:$name';
  }
}
