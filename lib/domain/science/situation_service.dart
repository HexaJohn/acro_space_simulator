// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
