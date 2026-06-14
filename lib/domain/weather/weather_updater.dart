import 'dart:math' as math;

import 'weather_system.dart';

/// Evolves a [WeatherSystem] one tick: cells advect (drift) under their own
/// prevailing wind, precipitation/turbulence decay, and fully-spent cells are
/// removed. Domain service — pure, returns a new immutable system.
///
/// Advection model: the east component of the wind moves the cell in longitude,
/// the north component moves it in latitude, scaled by the surface circumference
/// so a faster wind drifts a cell faster. Longitude wraps to [-pi, pi); latitude
/// clamps to the poles.
class WeatherUpdater {
  /// Fractional decay of precipitation/turbulence per hour.
  final double decayPerSecond;
  const WeatherUpdater({this.decayPerSecond = 1.0e-4});

  WeatherSystem advance(
    WeatherSystem system, {
    required double bodyRadius,
    required double dt,
  }) {
    final circumference = 2 * math.pi * bodyRadius;
    final evolved = <WeatherCell>[];

    for (final c in system.cells) {
      // Metres moved this tick from the surface wind.
      final dEastM = c.wind.x * dt;
      final dNorthM = c.wind.y * dt;

      // Convert to angular drift. Longitude scale shrinks toward the poles.
      final cosLat = math.max(0.05, math.cos(c.latitude));
      final dLon = (dEastM / (circumference * cosLat)) * 2 * math.pi;
      final dLat = (dNorthM / circumference) * 2 * math.pi;

      final decay = math.exp(-decayPerSecond * dt);
      final next = c.copyWith(
        longitude: _wrapPi(c.longitude + dLon),
        latitude: (c.latitude + dLat).clamp(-math.pi / 2, math.pi / 2),
        precipitation: c.precipitation * decay,
        turbulence: c.turbulence * decay,
      );

      if (!next.isSpent) evolved.add(next);
    }

    return WeatherSystem(
      body: system.body,
      cells: evolved,
      globalWindShearPerMetre: system.globalWindShearPerMetre,
    );
  }

  double _wrapPi(double a) {
    final twoPi = 2 * math.pi;
    var r = (a + math.pi) % twoPi;
    if (r < 0) r += twoPi;
    return r - math.pi;
  }
}
