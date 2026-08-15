// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/shuttle_cargo.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vessel resource model and the colony supply chain meet at the pad, and
/// nowhere else.
void main() {
  const service = ShuttleCargoService();

  /// A loaded craft sitting at [at] (body-fixed metres).
  Vessel parkedAt(Vector3 at) {
    final craft = SampleWorld.buildVessel(altitude: 0)
      ..landed = true
      ..updateState(StateVector(position: at, velocity: Vector3.zero));
    for (final part in craft.allParts) {
      for (final tank in part.resources) {
        tank.amount = tank.capacity;
      }
    }
    return craft;
  }

  ({CitySim city, double bodyRadius}) colonyWithPort() {
    final bodies =
        RealSolarSystem.build().all.where((b) => !b.isStar).toList();
    final city = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: bodies,
      id: 'port',
    );
    final port = kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
    city.placeUtil(city.hubKey, port);
    final body = bodies.firstWhere((b) => b.id.value == 'earth');
    return (city: city, bodyRadius: body.radius);
  }

  test('a craft on the pad hands its cargo to the colony', () {
    final setup = colonyWithPort();
    final city = setup.city;
    final pad = city.landingPads().first.$1;
    final padBF = city.localToBodyFixed(
      pad.centroid,
      bodyRadiusM: setup.bodyRadius,
    );

    final craft = parkedAt(padBF);
    city.stock[Commodity.ore] = 0;

    final moved = service.unload(city, craft, bodyRadiusM: setup.bodyRadius);
    expect(moved, isNotNull);
    expect(moved!.padId, pad.id);
    expect(moved.totalDelivered, greaterThan(0));
    expect(city.stock[Commodity.fuel]! + city.stock[Commodity.ore]!,
        greaterThan(0));
  });

  test('a lander keeps enough propellant to leave again', () {
    final setup = colonyWithPort();
    final city = setup.city;
    final padBF = city.localToBodyFixed(
      city.landingPads().first.$1.centroid,
      bodyRadiusM: setup.bodyRadius,
    );
    final craft = parkedAt(padBF);

    service.unload(city, craft, bodyRadiusM: setup.bodyRadius);

    var fuelLeft = 0.0;
    for (final part in craft.allParts) {
      for (final tank in part.resources) {
        if (tank.type.name == 'liquidFuel') fuelLeft += tank.amount;
      }
    }
    expect(fuelLeft, greaterThan(0),
        reason: 'draining the tanks strands the shuttle that brought the cargo');
  });

  test('a craft parked off the pad delivers nothing', () {
    final setup = colonyWithPort();
    final city = setup.city;
    final pad = city.landingPads().first.$1;
    // 5 km along the surface from the pad — landed, loaded, and not serviced.
    final away = city.localToBodyFixed(
      Vec2(pad.centroid.e + 5000, pad.centroid.n),
      bodyRadiusM: setup.bodyRadius,
    );
    expect(
      service.unload(city, parkedAt(away), bodyRadiusM: setup.bodyRadius),
      isNull,
    );
  });

  test('a craft still in flight delivers nothing', () {
    final setup = colonyWithPort();
    final craft = SampleWorld.buildVessel(altitude: 200000);
    expect(service.unload(setup.city, craft, bodyRadiusM: setup.bodyRadius),
        isNull);
  });

  test('a full stockpile does not swallow the cargo', () {
    final setup = colonyWithPort();
    final city = setup.city;
    final padBF = city.localToBodyFixed(
      city.landingPads().first.$1.centroid,
      bodyRadiusM: setup.bodyRadius,
    );
    final craft = parkedAt(padBF);
    // Fill every store to the cap.
    for (final c in Commodity.ordered) {
      city.stock[c] = city.stockCap;
    }

    final moved = service.unload(city, craft, bodyRadiusM: setup.bodyRadius);
    expect(moved, isNull, reason: 'nothing fits, so nothing moves');
    // And the cargo is still aboard.
    var aboard = 0.0;
    for (final part in craft.allParts) {
      for (final tank in part.resources) {
        aboard += tank.amount;
      }
    }
    expect(aboard, greaterThan(0));
  });
}
