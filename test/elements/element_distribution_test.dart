import 'dart:math' as math;

import 'package:acro_space_simulator/domain/elements/element_distribution.dart';
import 'package:acro_space_simulator/domain/elements/periodic_table.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final table = PeriodicTable.standard();
  const surface = PlanetSurface(
    seed: 99,
    meanSurfaceTemperature: 288,
    albedo: 0.3,
    solarFlux: 1361,
  );
  final dist = ElementDistribution(surface: surface, table: table);

  double deg(double d) => d * math.pi / 180.0;

  test('abundant elements occur at higher average concentration than rare ones', () {
    // Sample many points; iron (common) should beat gold (rare) on average.
    var ironSum = 0.0, goldSum = 0.0;
    var n = 0;
    for (var lat = -60; lat <= 60; lat += 20) {
      for (var lon = 0; lon < 360; lon += 30) {
        ironSum += dist.concentrationAt(
            latitude: deg(lat.toDouble()), longitude: deg(lon.toDouble()), symbol: 'Fe');
        goldSum += dist.concentrationAt(
            latitude: deg(lat.toDouble()), longitude: deg(lon.toDouble()), symbol: 'Au');
        n++;
      }
    }
    expect(ironSum / n, greaterThan(goldSum / n));
  });

  test('concentration is deterministic and in [0,1]', () {
    final a = dist.concentrationAt(latitude: 0.3, longitude: 0.7, symbol: 'Ti');
    final b = dist.concentrationAt(latitude: 0.3, longitude: 0.7, symbol: 'Ti');
    expect(a, b);
    expect(a, inInclusiveRange(0.0, 1.0));
  });

  test('an unknown symbol yields zero', () {
    expect(dist.concentrationAt(latitude: 0, longitude: 0, symbol: 'Zz'), 0);
  });

  test('the richest elements at a point can be ranked', () {
    final top = dist.richestAt(latitude: deg(10), longitude: deg(20), count: 3);
    expect(top.length, 3);
    // Sorted descending by concentration.
    expect(top[0].concentration, greaterThanOrEqualTo(top[1].concentration));
    expect(top[1].concentration, greaterThanOrEqualTo(top[2].concentration));
  });
}
