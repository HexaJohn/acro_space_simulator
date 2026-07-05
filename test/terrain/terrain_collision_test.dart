import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/terrain_config.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final withTerrain = CelestialBody(
    id: const BodyId('t'),
    name: 'T',
    mu: 4.9e12,
    radius: 1.7374e6,
    soiRadius: 6.6e7,
    siderealRotationPeriod: 2.36e6,
    parent: const BodyId('earth'),
    terrain: const TerrainConfig(seed: 0x11A00, amplitude: 3000, featureScale: 18000),
  );
  final noTerrain = CelestialBody(
    id: const BodyId('n'),
    name: 'N',
    mu: 4.9e12,
    radius: 1.7374e6,
    soiRadius: 6.6e7,
    siderealRotationPeriod: 2.36e6,
    parent: const BodyId('earth'),
  );

  test('no terrain -> ground radius is the datum sphere', () {
    final r = Vector3(2e6, 3e5, 1e5);
    expect(noTerrain.terrainGroundRadius(r, Epoch.zero), noTerrain.radius);
    expect(noTerrain.terrainAltitude(r, Epoch.zero), r.length - noTerrain.radius);
  });

  test('terrain ground radius sits within radius +/- amplitude', () {
    final rng = math.Random(11);
    for (var i = 0; i < 200; i++) {
      final v = Vector3(rng.nextDouble() * 2 - 1, rng.nextDouble() * 2 - 1,
          rng.nextDouble() * 2 - 1);
      if (v.length < 1e-6) continue;
      final gr = withTerrain.terrainGroundRadius(v.normalized * 2e6, Epoch.zero);
      expect(gr, inInclusiveRange(1.7374e6 - 3000, 1.7374e6 + 3000));
    }
  });

  test('altitude is negative below the terrain surface, positive above', () {
    final dir = Vector3(0.3, 0.6, 0.74).normalized;
    final gr = withTerrain.terrainGroundRadius(dir * 2e6, Epoch.zero);
    expect(withTerrain.terrainAltitude(dir * (gr - 500), Epoch.zero), lessThan(0));
    expect(withTerrain.terrainAltitude(dir * (gr + 500), Epoch.zero), greaterThan(0));
  });

  test('orientationAt is a unit quaternion and spins with time', () {
    final q0 = withTerrain.orientationAt(Epoch.zero);
    final n = math.sqrt(q0.w * q0.w + q0.x * q0.x + q0.y * q0.y + q0.z * q0.z);
    expect(n, closeTo(1.0, 1e-9));
    // A later epoch rotates the body -> a different body-fixed ground point for
    // the same inertial position (terrain is body-fixed).
    final r = Vector3(2e6, 0, 0);
    final early = withTerrain.terrainGroundRadius(r, Epoch.zero);
    final late = withTerrain.terrainGroundRadius(r, const Epoch(1.0e6));
    expect((early - late).abs(), greaterThan(0.0));
  });
}
