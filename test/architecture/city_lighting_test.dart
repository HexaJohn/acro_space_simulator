// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/architecture/city_lighting.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colony lighting is driven by the real sun, not a clock: a polar colony sits
/// in months of dusk and a tidally locked one never sees night, and a
/// time-of-day curve gets both wrong.
void main() {
  const lighting = CityLighting();

  CitySim colony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'lit',
      );

  double sinOf(double degrees) => math.sin(degrees * math.pi / 180);

  test('street lamps follow the road at a spacing set by its class', () {
    final city = colony();
    city.layout.addRoad(const RoadSpline(
      id: 'street',
      controls: [Vec2(0, 0), Vec2(0, 400)],
    ));
    final street = lighting.lamps(city);
    expect(street, isNotEmpty);

    // Spaced along the run, and set off the carriageway rather than in it.
    final road = city.layout.roads.first;
    for (final lamp in street) {
      expect(road.distanceTo(lamp.position),
          greaterThanOrEqualTo(road.halfWidth));
    }
    // A residential street lights from alternating sides.
    final east = street.where((l) => l.position.e > 0).length;
    final west = street.where((l) => l.position.e < 0).length;
    expect((east - west).abs(), lessThanOrEqualTo(1));

    // A highway of the same length gets taller columns, lit from both sides.
    final hw = colony()
      ..layout.addRoad(const RoadSpline(
        id: 'hw',
        roadClass: RoadClass.highway,
        controls: [Vec2(0, 0), Vec2(0, 400)],
      ));
    final highway = lighting.lamps(hw);
    expect(highway.first.heightM, greaterThan(street.first.heightM));
    expect(highway.where((l) => l.position.e > 0).length,
        highway.where((l) => l.position.e < 0).length);
  });

  test('lamps follow a curve without leaving the verge', () {
    final city = colony();
    city.layout.addRoad(const RoadSpline(
      id: 'bend',
      controls: [Vec2(0, 0), Vec2(80, 120), Vec2(-40, 240), Vec2(60, 360)],
    ));
    final road = city.layout.roads.first;
    for (final lamp in lighting.lamps(city)) {
      final d = road.distanceTo(lamp.position);
      expect(d, greaterThanOrEqualTo(road.halfWidth));
      expect(d, lessThan(road.halfWidth + 6),
          reason: 'a lamp must stay on the verge, not drift into a garden');
    }
  });

  test('lights come on through dusk and off after dawn, with hysteresis', () {
    final city = colony();

    final noon = lighting.stateFor(city, sunUpComponent: sinOf(60));
    expect(noon.nightFactor, 0);
    expect(noon.lampsOn, isFalse);
    expect(noon.windowLitFraction, 0);

    final midnight = lighting.stateFor(city, sunUpComponent: sinOf(-40));
    expect(midnight.nightFactor, 1);
    expect(midnight.lampsOn, isTrue);

    // Dusk ramps rather than snapping.
    final dusk = lighting.stateFor(city, sunUpComponent: sinOf(-2));
    expect(dusk.nightFactor, greaterThan(0));
    expect(dusk.nightFactor, lessThan(1));

    // Hysteresis: sitting between the thresholds, the grid holds its state
    // instead of flickering as the elevation dithers.
    final marginal = sinOf(1.0);
    expect(
        lighting
            .stateFor(city, sunUpComponent: marginal, previousLampsOn: true)
            .lampsOn,
        isTrue);
    expect(
        lighting
            .stateFor(city, sunUpComponent: marginal, previousLampsOn: false)
            .lampsOn,
        isFalse);
  });

  test('an empty colony has dark windows; a full one has lit ones', () {
    final empty = colony()
      ..housing = 500
      ..population = 0;
    final full = colony()
      ..housing = 500
      ..population = 500;

    final night = sinOf(-30);
    expect(lighting.stateFor(empty, sunUpComponent: night).windowLitFraction,
        lessThan(lighting.stateFor(full, sunUpComponent: night).windowLitFraction));
    // Never fully lit — some part of any building is always empty.
    expect(lighting.stateFor(full, sunUpComponent: night).windowLitFraction,
        lessThan(0.8));
  });

  test('a brownout dims the whole colony', () {
    final city = colony()
      ..housing = 100
      ..population = 100
      ..powerOut = 20
      ..powerDraw = 100;
    final dim = lighting.stateFor(city, sunUpComponent: sinOf(-30));

    final healthy = colony()
      ..housing = 100
      ..population = 100
      ..powerOut = 200
      ..powerDraw = 100;
    final bright = lighting.stateFor(healthy, sunUpComponent: sinOf(-30));

    expect(dim.powerDim, lessThan(bright.powerDim));
    expect(dim.lampIntensity, lessThan(bright.lampIntensity));
  });

  test('car parks get their own cold-light masts', () {
    final city = colony();
    final mall = kUtilCatalog.firstWhere((s) => s.label == 'Data Center');
    city.placeUtil(city.hubKey + 1, mall);

    final masts = lighting.lamps(city).where((l) => !l.warm).toList();
    expect(masts, isNotEmpty);
    expect(masts.first.radiusM, greaterThan(25));
  });
}
