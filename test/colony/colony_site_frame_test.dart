// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// A colony's lat/lon is BODY-FIXED; a craft's position is body-centred
/// INERTIAL. Founding a town straight off the inertial vector plants it at
/// whatever longitude faced that way at epoch zero — up to half a planet from
/// the craft that founded it.
void main() {
  test('the site must be read in the body-fixed frame, not the inertial one',
      () {
    final system = SampleWorld.realSystem();
    final earth = system.body(RealSolarSystem.build().all
        .firstWhere((b) => b.id.value == 'earth')
        .id)!;

    // A craft somewhere over the planet, at an epoch where it has turned.
    final craftInertial = SampleWorld.buildVessel(altitude: 0).state.position;
    final epoch = Epoch(6 * 3600); // six hours in: ~90 degrees of spin

    double lonOf(bool bodyFixed) {
      final p = bodyFixed
          ? earth.orientationAt(epoch).conjugate.rotate(craftInertial)
          : craftInertial;
      final d = p.normalized;
      return math.atan2(d.y, d.x) * 180 / math.pi;
    }

    final inertialLon = lonOf(false);
    final fixedLon = lonOf(true);
    // They disagree, and that disagreement IS the bug.
    expect((fixedLon - inertialLon).abs(), greaterThan(1.0));
  });

  test('a colony sited body-fixed puts its buildings under that site', () {
    final bodies =
        RealSolarSystem.build().all.where((b) => !b.isStar).toList();
    final earth = bodies.firstWhere((b) => b.id.value == 'earth');

    // Found at a known body-fixed site and put a spaceport on the hub.
    const lat = 28.5, lon = -80.6; // the Cape
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', latitude: lat, longitude: lon),
      bodies: bodies,
      id: 'cape',
    );
    city.placeUtil(city.hubKey, kUtilCatalog.firstWhere((s) => s.label == 'Spaceport'));

    final snap = WorldSnapshot.capture(
      0,
      InMemoryVesselRepository(const []),
      system: SampleWorld.realSystem(),
      cities: InMemoryCityRepository([city]),
    );
    expect(snap.buildings, isNotEmpty);

    // Every building sits within a few km of the site it was founded at —
    // measured in the SAME body-fixed frame the snapshot stores.
    final latRad = lat * math.pi / 180, lonRad = lon * math.pi / 180;
    final siteDir = [
      math.cos(latRad) * math.cos(lonRad),
      math.cos(latRad) * math.sin(lonRad),
      math.sin(latRad),
    ];
    for (final b in snap.buildings.values) {
      final r = math.sqrt(b.px * b.px + b.py * b.py + b.pz * b.pz);
      final dot =
          (b.px * siteDir[0] + b.py * siteDir[1] + b.pz * siteDir[2]) / r;
      final arcM = math.acos(dot.clamp(-1.0, 1.0)) * earth.radius;
      expect(arcM, lessThan(5000),
          reason: 'a building ${(arcM / 1000).toStringAsFixed(0)} km from its '
              'own colony is the frame bug');
    }
  });
}
