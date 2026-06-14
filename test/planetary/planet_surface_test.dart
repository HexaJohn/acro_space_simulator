import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/planet_surface.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Earth-like surface: warm equator, ice caps, oceans + land, ore veins.
  final surface = PlanetSurface(
    seed: 42,
    meanSurfaceTemperature: 288,
    albedo: 0.3,
    solarFlux: 1361,
    axialTilt: 0.41, // ~23.4 deg
  );

  double deg(double d) => d * math.pi / 180.0;

  test('the equator is warmer than the poles', () {
    final equatorT = surface.temperatureAt(latitude: 0, subsolarLatitude: 0);
    final poleT = surface.temperatureAt(latitude: deg(85), subsolarLatitude: 0);
    expect(equatorT, greaterThan(poleT));
  });

  test('higher albedo lowers surface temperature', () {
    final dark = PlanetSurface(
        seed: 1, meanSurfaceTemperature: 288, albedo: 0.1, solarFlux: 1361, axialTilt: 0);
    final bright = PlanetSurface(
        seed: 1, meanSurfaceTemperature: 288, albedo: 0.6, solarFlux: 1361, axialTilt: 0);
    expect(
      bright.temperatureAt(latitude: 0, subsolarLatitude: 0),
      lessThan(dark.temperatureAt(latitude: 0, subsolarLatitude: 0)),
    );
  });

  test('biome classification: poles are icecap, equator not', () {
    final pole = surface.biomeAt(latitude: deg(88), longitude: 0);
    final equator = surface.biomeAt(latitude: 0, longitude: 0);
    expect(pole, Biome.iceCap);
    expect(equator, isNot(Biome.iceCap));
  });

  test('ore concentration is in [0,1] and deterministic for a seed', () {
    final a = surface.oreConcentrationAt(
        latitude: deg(20), longitude: deg(40), resource: ResourceType.ore);
    final b = surface.oreConcentrationAt(
        latitude: deg(20), longitude: deg(40), resource: ResourceType.ore);
    expect(a, b); // deterministic
    expect(a, inInclusiveRange(0.0, 1.0));
  });

  test('different seeds give different ore distributions', () {
    final s1 = PlanetSurface(
        seed: 1, meanSurfaceTemperature: 288, albedo: 0.3, solarFlux: 1361, axialTilt: 0);
    final s2 = PlanetSurface(
        seed: 2, meanSurfaceTemperature: 288, albedo: 0.3, solarFlux: 1361, axialTilt: 0);
    var anyDifferent = false;
    for (var lon = 0; lon < 360; lon += 30) {
      final a = s1.oreConcentrationAt(
          latitude: 0, longitude: deg(lon.toDouble()), resource: ResourceType.ore);
      final b = s2.oreConcentrationAt(
          latitude: 0, longitude: deg(lon.toDouble()), resource: ResourceType.ore);
      if ((a - b).abs() > 1e-6) anyDifferent = true;
    }
    expect(anyDifferent, isTrue);
  });

  test('axial tilt moves the warmest latitude toward the subsolar point', () {
    // Northern summer: subsolar latitude positive -> north warmer than south.
    final north = surface.temperatureAt(latitude: deg(40), subsolarLatitude: deg(23));
    final south = surface.temperatureAt(latitude: deg(-40), subsolarLatitude: deg(23));
    expect(north, greaterThan(south));
  });
}
