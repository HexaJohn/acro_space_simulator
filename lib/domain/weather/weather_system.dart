import 'dart:math' as math;

import '../shared/vector3.dart';
import '../universe/celestial_body.dart';

/// One weather cell (front / storm / clear region) over a body's surface. The
/// weather context is per-body: each atmospheric body runs its own field.
class WeatherCell {
  /// Centre on the body surface, as (latitude, longitude) radians.
  final double latitude;
  final double longitude;
  final double radius; // m, footprint on the surface

  /// Prevailing wind in the local surface frame (east, north, up) m/s.
  final Vector3 wind;
  final double precipitation; // 0..1
  final double temperatureAnomaly; // K, added to the base atmosphere temp
  final double turbulence; // 0..1, gust intensity

  const WeatherCell({
    required this.latitude,
    required this.longitude,
    required this.radius,
    required this.wind,
    this.precipitation = 0,
    this.temperatureAnomaly = 0,
    this.turbulence = 0,
  });

  WeatherCell copyWith({
    double? latitude,
    double? longitude,
    double? radius,
    Vector3? wind,
    double? precipitation,
    double? temperatureAnomaly,
    double? turbulence,
  }) =>
      WeatherCell(
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        radius: radius ?? this.radius,
        wind: wind ?? this.wind,
        precipitation: precipitation ?? this.precipitation,
        temperatureAnomaly: temperatureAnomaly ?? this.temperatureAnomaly,
        turbulence: turbulence ?? this.turbulence,
      );

  /// A cell is "spent" when its activity has decayed to nothing.
  bool get isSpent => precipitation < 0.01 && turbulence < 0.01;
}

/// Aggregate of weather over one [body]. Domain owns the *state and rules* of
/// weather (how cells advect and decay); a future heavier simulation (or Rust)
/// can replace [advance] without changing how the rest of the game samples it.
class WeatherSystem {
  final BodyId body;
  final List<WeatherCell> cells;
  final double globalWindShearPerMetre; // wind grows with altitude (jet stream)

  const WeatherSystem({
    required this.body,
    required this.cells,
    this.globalWindShearPerMetre = 0.002,
  });

  /// Wind vector (surface frame, m/s) at a surface point and altitude. Sums the
  /// nearest cells weighted by distance, plus altitude shear.
  Vector3 windAt({
    required double latitude,
    required double longitude,
    required double altitude,
  }) {
    var w = Vector3.zero;
    var totalWeight = 0.0;
    for (final c in cells) {
      final d = _greatCircleApprox(latitude, longitude, c.latitude, c.longitude);
      if (d > c.radius) continue;
      final weight = 1.0 - (d / c.radius);
      w = w + c.wind * weight;
      totalWeight += weight;
    }
    if (totalWeight > 0) w = w / totalWeight;
    return w * (1 + altitude * globalWindShearPerMetre);
  }

  double _greatCircleApprox(
      double lat1, double lon1, double lat2, double lon2) {
    // Small-angle planar approximation (radians -> arbitrary surface units);
    // adequate for cell weighting at gameplay scale.
    final dLat = lat1 - lat2;
    final dLon = (lon1 - lon2) * math.cos((lat1 + lat2) / 2);
    return math.sqrt(dLat * dLat + dLon * dLon);
  }
}
