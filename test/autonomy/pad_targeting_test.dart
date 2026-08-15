// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/autonomy/landing_guidance.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A shuttle's descent is aimed at a pad the colony actually built, derived
/// from the same parcels everything else stands on.
void main() {
  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'port',
      );

  test('a colony with no spaceport offers nowhere to land', () {
    expect(colony().landingPads(), isEmpty);
  });

  test('building a starport creates a pad the guidance can aim at', () {
    final city = colony();
    final port = kUtilCatalog.firstWhere((s) => s.label == 'Starport (3×6)');
    city.placeUtil(city.hubKey, port);

    final pads = city.landingPads().toList();
    expect(pads.length, 1);
    expect(pads.first.$2.siteKind, SiteKind.pad);

    final body = RealSolarSystem.build().body(city.body.id)!;
    final padBF = city.localToBodyFixed(
      pads.first.$1.centroid,
      bodyRadiusM: body.radius,
    );
    // The pad sits on the surface of the host body.
    expect(padBF.length, closeTo(body.radius, 1));

    // And guidance aimed at it from directly overhead comes down on it.
    const guidance = LandingGuidance();
    final cmd = guidance.command(
      posBF: padBF.normalized * (body.radius + 400),
      velBF: padBF.normalized * -8,
      padBF: padBF,
      mu: body.mu,
      mass: 12000,
      maxThrust: 400000,
    );
    expect(cmd.crossRangeM, lessThan(1));
    expect(cmd.altitudeM, closeTo(400, 1));
    expect(cmd.phase, isNot(LandingPhase.unrecoverable));
  });
}
