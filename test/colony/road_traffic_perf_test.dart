// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The traffic model's caps hold at city scale: on a network of five
/// thousand roads and twenty thousand built lots, one tick of it costs
/// about two milliseconds, however long the whole pass takes.
///
/// `CitySim.advance` runs once per fixed step — up to twenty-five times a
/// frame when the world is catching up — so anything it does per call is
/// multiplied. The model is sliced so a call does a bounded slice of a
/// pass; this is the test that says the slice is small.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_traffic_model.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tick of traffic on a 5,000-road, 20,000-lot city costs ~2 ms', () {
    final c = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'perf',
    );
    c.layout.settings = const ParcelSettings(frontageM: 12);
    const n = 50;
    const spacing = 100.0;
    const half = (n - 1) * spacing / 2;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final x = -half + i * spacing;
      c.layout.commitRoad(
          controls: [Vec2(x, -half - 30), Vec2(x, half + 30)],
          regenerateLots: false);
      c.layout.commitRoad(
          controls: [Vec2(-half - 30, x), Vec2(half + 30, x)],
          regenerateLots: false);
    }
    c.layout.regenerate();
    final platMs = sw.elapsedMilliseconds;
    final lots = c.layout.autoParcels;
    expect(c.layout.roads.length, greaterThanOrEqualTo(5000));
    expect(lots.length, greaterThanOrEqualTo(20000));

    // Built out: mostly homes, then shops, works, and a police station or
    // a clinic every few blocks.
    final homes = kZoneSpecs['residential']![Density.medium]!;
    final shops = kZoneSpecs['commercial']![Density.low]!;
    final works = kZoneSpecs['industrial']![Density.low]!;
    final police = kUtilCatalog.firstWhere((s) => s.type == 'police');
    final clinic = kUtilCatalog.firstWhere((s) => s.type == 'clinic');
    for (var i = 0; i < lots.length; i++) {
      final k = i % 97;
      final spec = k == 0
          ? police
          : k == 1
              ? clinic
              : k < 60
                  ? homes
                  : k < 85
                      ? shops
                      : works;
      c.parcelBuildings[lots[i].id] = spec;
    }

    // A pass as soon as the last one ends, so every measured tick works.
    final traffic =
        CityRoadTraffic(c, tuning: const TrafficTuning(cadenceSec: 0));
    sw.reset();
    final g = traffic.graph;
    final graphMs = sw.elapsedMilliseconds;

    // Warm up: a whole pass, so the JIT has seen every phase.
    sw.reset();
    var warmCalls = 0;
    while (traffic.model.passes < 1 && warmCalls < 200000) {
      traffic.advance(0.02);
      warmCalls++;
    }
    final passMs = sw.elapsedMilliseconds;
    expect(traffic.hasRun, isTrue);
    expect(traffic.peakCongestion, greaterThan(0));

    // Measure.
    const measured = 1500;
    var maxWork = 0;
    var worstUs = 0;
    final total = Stopwatch()..start();
    final one = Stopwatch();
    for (var k = 0; k < measured; k++) {
      one
        ..reset()
        ..start();
      traffic.advance(0.02);
      one.stop();
      worstUs = math.max(worstUs, one.elapsedMicroseconds);
      maxWork = math.max(maxWork, traffic.model.lastStepWork);
    }
    final avgMs = total.elapsedMicroseconds / 1000 / measured;
    // ignore: avoid_print
    print('traffic perf: ${c.layout.roads.length} roads, ${lots.length} lots, '
        '${g.nodeCount} nodes, ${g.edgeCount} edges; plat $platMs ms, '
        'graph $graphMs ms; first pass $warmCalls ticks / $passMs ms; '
        'tick avg ${avgMs.toStringAsFixed(3)} ms, worst '
        '${(worstUs / 1000).toStringAsFixed(2)} ms, max work $maxWork; '
        'passes ${traffic.model.passes}');

    // ~2 ms a tick, with room for a slow CI machine running a debug VM.
    expect(avgMs, lessThan(4.0));
    // A step stops at its budget: every stage resumes where the last step
    // stopped, and the most one overruns by is the routes it keeps as a
    // kind of trip finishes.
    const tuning = TrafficTuning();
    expect(
        maxWork,
        lessThanOrEqualTo(tuning.workPerStep +
            tuning.routesPerOrigin * tuning.maxSettled +
            1000));
    // And a whole pass is minutes of play, not hours: at one tick a frame
    // it lands well inside a colony day.
    expect(warmCalls, lessThan(6000));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
