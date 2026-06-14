import 'dart:math' as math;

/// Seasonal solar geometry for a body, driven by axial tilt (obliquity) and the
/// position in its orbit. Pure domain: no Flutter/IO. Feeds [PlanetSurface] and
/// the weather context with the current *subsolar latitude* (where the sun is
/// directly overhead) and a relative *insolation factor* per latitude.
///
/// Convention: [orbitalPhase] is a fraction of the orbital year in [0,1).
///   - phase 0.0  -> northern winter solstice  -> subsolar latitude = -tilt
///   - phase 0.25 -> northern spring equinox    -> subsolar latitude =  0
///   - phase 0.5  -> northern summer solstice    -> subsolar latitude = +tilt
///   - phase 0.75 -> northern autumn equinox      -> subsolar latitude =  0
/// The subsolar latitude therefore traces a sine that swings between -tilt and
/// +tilt over the year. A zero-tilt body has no seasons (subsolar latitude is
/// always 0 and insolation is constant through the year).
class SeasonModel {
  /// Obliquity / axial tilt in radians. Earth ~0.41 (23.4 deg).
  final double axialTilt;

  const SeasonModel({this.axialTilt = 0});

  /// Latitude (rad) where the sun is overhead for the given [orbitalPhase]
  /// (0..1 fraction of the year). Oscillates between -[axialTilt] and
  /// +[axialTilt]; equals 0 at both equinoxes and for a zero-tilt body.
  double subsolarLatitude(double orbitalPhase) {
    // sin is 0 at phase 0 (winter solstice), rising through +tilt at mid-year.
    // Shift by a quarter year so phase 0 sits at the southern extreme (-tilt).
    return axialTilt * math.sin(2 * math.pi * (orbitalPhase - 0.25));
  }

  /// Relative solar heating in [0,1] at [latitude] (rad) for the season at
  /// [orbitalPhase]. 1.0 means the sun is directly overhead at this latitude;
  /// it falls off with the cosine of the angle between the latitude and the
  /// current subsolar latitude (Lambert's cosine law), and is clamped to 0 on
  /// the night/polar-winter side where the sun never rises high enough.
  double insolationFactor(double latitude, double orbitalPhase) {
    final subsolar = subsolarLatitude(orbitalPhase);
    final incidence = math.cos(latitude - subsolar);
    return incidence.clamp(0.0, 1.0).toDouble();
  }

  /// True when the body experiences no seasonal variation (no axial tilt).
  bool get hasNoSeasons => axialTilt == 0;
}
