// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic_laws.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// docs/plans/desire-paths.md §8's gates: each traffic law moves its own
/// number, and a colony under none drives as it always did.
void main() {
  test('no traffic law reads as no policy at all', () {
    expect(TrafficPolicy.of({}), same(TrafficPolicy.lawless));
    expect(TrafficPolicy.of({Law.curfew, Law.offRoadBan}),
        same(TrafficPolicy.lawless));
    final code = TrafficPolicy.of({Law.trafficCode});
    expect(code.junctionScale, 0.7);
    expect(code.crashScale, 0.35);
    final all = TrafficPolicy.of({
      Law.trafficCode,
      Law.speedLimits,
      Law.parkingOrdinance,
      Law.pedestrianPriority,
      Law.vehicleLicensing,
    });
    expect(all.junctionScale, closeTo(0.7 * 1.25, 1e-12));
    expect(all.speedScale, 0.8);
    expect(all.ownershipScale, 0.75);
    expect(all.kerbParking, isFalse);
    expect(all.crashScale, closeTo(0.35 * 0.6 * 0.8 * 0.7, 1e-12));
    expect(all.injuryScale, 0.6);
  });

  test('crashes are owed by the kilometre, whole and the same every run', () {
    final s = TrafficSafety();
    // 10,000 km in 1 km steps: five crashes with no law.
    for (var i = 0; i < 10000; i++) {
      s.advance(1, 1000, 0, TrafficPolicy.lawless);
    }
    expect(s.crashes, 5);
    expect(s.killed, closeTo(5 * kCrashFatalShare, 1e-9));
    // Off-road kilometres count half again.
    final o = TrafficSafety();
    for (var i = 0; i < 10000; i++) {
      o.advance(1, 0, 1000, TrafficPolicy.lawless);
    }
    expect(o.crashes, 7);
    // The code cuts them.
    final c = TrafficSafety();
    final code = TrafficPolicy.of({Law.trafficCode});
    for (var i = 0; i < 10000; i++) {
      c.advance(1, 1000, 0, code);
    }
    expect(c.crashes, 1);
    // And the count survives a save.
    final back = TrafficSafety.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.crashes, s.crashes);
    expect(back.crashesPerDay, s.crashesPerDay);
  });

  group('twin towns, one law apart', () {
    // A technocracy: a democracy's voters repeal what a quiet town has no
    // call for, and the twins would be one town again.
    CitySim grow(Set<Law> laws) {
      final city = town(agentTraffic: true)..govt = Govt.technocracy;
      city.laws.addAll(laws);
      run(city, 1800);
      return city;
    }

    late final CitySim plain = grow({});

    test('a parking ordinance keeps the kerbs empty', () {
      final ruled = grow({Law.parkingOrdinance});
      expect(plain.agents.parkedCars!.kerbCars, greaterThan(0),
          reason: 'the plain town parks at its kerbs');
      expect(ruled.agents.parkedCars!.kerbCars, 0);
    });

    test('speed limits make the same trips take longer', () {
      final ruled = grow({Law.speedLimits});
      expect(ruled.agents.stats.tripRatio,
          greaterThan(plain.agents.stats.tripRatio));
    });

    test('vehicle licensing means fewer people own a car', () {
      final ruled = grow({Law.vehicleLicensing});
      int owners(CitySim c) {
        final p = c.agents.parkedCars!;
        return p.lotCars + p.kerbCars + p.garagedCars;
      }

      expect(owners(ruled), lessThan(owners(plain)));
    });

    test('the town has driven, and the crash model has counted it', () {
      expect(plain.agents.stats.totalDrivenM, greaterThan(0));
      expect(plain.safety.crashes + plain.safety.crashesPerDay, isNonNegative);
      final j = plain.toJson();
      expect(jsonEncode(j), isNotEmpty);
    });
  });
}
