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
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
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

    // Warm up: a whole window — every share of the origins routed once,
    // and the first publication — so the JIT has seen every phase.
    sw.reset();
    var warmCalls = 0;
    while (!traffic.hasRun && warmCalls < 200000) {
      traffic.advance(0.02);
      warmCalls++;
    }
    final passMs = sw.elapsedMilliseconds;
    expect(traffic.hasRun, isTrue);
    expect(traffic.peakCongestion, greaterThan(0));
    final shares = traffic.model.shares;
    expect(shares, greaterThan(1), reason: 'a city this size is split');

    // Measure, passes back to back: the sweeps that open and close every
    // pass — the stretch loads, the reach fields, the tables reset — fall
    // inside the measured ticks.
    const measured = 3000;
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
        'graph $graphMs ms; $shares shares; first window $warmCalls ticks / '
        '$passMs ms; tick avg ${avgMs.toStringAsFixed(3)} ms, worst '
        '${(worstUs / 1000).toStringAsFixed(2)} ms, max work $maxWork; '
        'passes ${traffic.model.passes}');

    // Wall-clock bounds only on a perf run (`--dart-define=ACRO_PERF=true`,
    // the machine otherwise quiet): the whole suite runs files in parallel
    // on every core, and a tick measured under that load read 8.5 ms where
    // alone it reads 2.8 — a timing test that fails on its neighbours says
    // nothing about the code. The work bound below is the deterministic
    // form of the same promise, and it always holds.
    if (const bool.fromEnvironment('ACRO_PERF')) {
      // ~2 ms a tick, with room for a slow CI machine running a debug VM.
      expect(avgMs, lessThan(4.0));
      // And the WORST tick, not only the average: no stage boundary sweeps
      // the network in one go (the tick that builds the graph, before the
      // warm-up, is not measured). Room again for a debug VM and a
      // collection landing in a tick.
      expect(worstUs / 1000, lessThan(6.0));
    }
    // A step stops at its budget: every stage resumes where the last step
    // stopped, and the most one overruns by is the routes it keeps as a
    // kind of trip finishes.
    const tuning = TrafficTuning();
    expect(
        maxWork,
        lessThanOrEqualTo(tuning.workPerStep +
            tuning.routesPerOrigin * tuning.maxSettled +
            1000));
    // And a whole window is minutes of play, not hours: at one tick a frame
    // it lands well inside a colony day.
    expect(warmCalls, lessThan(6000));

    // The window is the whole city's traffic, not a sample scaled up: the
    // same loads, road by road, as one pass that routes every origin.
    final whole = CityRoadTraffic(c,
        tuning: const TrafficTuning(
            workPerStep: 1 << 30, maxOriginsPerPass: 1 << 30));
    whole.advance(0.02);
    expect(whole.model.shares, 1);
    expect(traffic.peakCongestion, closeTo(whole.peakCongestion, 1e-9));
    for (final road in c.layout.roads) {
      final w = whole.volumeOf(road.id);
      expect(traffic.volumeOf(road.id), closeTo(w, 1e-9 * (1 + w)));
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test("a reach field's search is forgotten inside the step budget", () {
    // The goods field reaches every node in the city. Forgetting that
    // search all at once — as the next field seeds, or as the first origin
    // is searched — put the whole network into one step: on this grid of
    // 1,760 junctions, a step more than 300 units past the most the
    // budget allows.
    final c = CitySim.found(
      const CityConfig(bodyId: 'earth', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'sweep',
    );
    const n = 40;
    const spacing = 100.0;
    const half = (n - 1) * spacing / 2;
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
    final lots = c.layout.autoParcels;
    final police = kUtilCatalog.firstWhere((s) => s.type == 'police');
    final homes = kZoneSpecs['residential']![Density.low]!;
    c.parcelBuildings[lots[lots.length ~/ 2].id] = police;
    for (var i = 0; i < lots.length; i += 7) {
      c.parcelBuildings.putIfAbsent(lots[i].id, () => homes);
    }

    const tuning = TrafficTuning(
        workPerStep: 500, maxSettled: 100, routesPerOrigin: 1, cadenceSec: 0);
    final traffic = CityRoadTraffic(c, tuning: tuning);
    expect(traffic.graph.nodeCount, greaterThan(1700));
    var maxWork = 0;
    for (var guard = 0; traffic.model.passes < 3 && guard < 100000; guard++) {
      traffic.advance(0.02);
      maxWork = math.max(maxWork, traffic.model.lastStepWork);
    }
    expect(traffic.model.passes, greaterThanOrEqualTo(3));
    expect(traffic.hasRun, isTrue);
    expect(
        maxWork,
        lessThanOrEqualTo(tuning.workPerStep +
            tuning.routesPerOrigin * tuning.maxSettled +
            1000));
  });

  test('a pass dropped inside a reach field leaves the next no sweep', () {
    // A pass dropped while a reach field is searched or read off leaves
    // that search holding every node the field reached, and the next
    // pass's seeding forgot them all in one step: on this grid of 1,760
    // junctions, a step over a thousand units past its budget. Dropped at
    // every step of a pass in turn, no step of the next overruns.
    final layout = CityLayout();
    const n = 40;
    const spacing = 100.0;
    const half = (n - 1) * spacing / 2;
    for (var i = 0; i < n; i++) {
      final x = -half + i * spacing;
      layout.commitRoad(
          controls: [Vec2(x, -half - 30), Vec2(x, half + 30)],
          regenerateLots: false);
      layout.commitRoad(
          controls: [Vec2(-half - 30, x), Vec2(half + 30, x)],
          regenerateLots: false);
    }
    final g = RoadGraph.of(layout);
    expect(g.nodeCount, greaterThan(1700));
    // A police station mid-town (the service and fire fields reach most of
    // the grid) and a works near the edge (the goods field, all of it).
    TrafficSite siteOn(int road, CityBuildingSpec spec) {
      final p = (g.roadFirstPiece[road] + g.roadFirstPiece[road + 1]) ~/ 2;
      return TrafficSite(spec,
          piece: p,
          sM: (g.pieceS0[p] + g.pieceS1[p]) / 2,
          dirs: RoadGraph.forwardBit | RoadGraph.backwardBit);
    }

    final sites = [
      siteOn(g.roadCount ~/ 2, kUtilCatalog.firstWhere((s) => s.type == 'police')),
      siteOn(3, kZoneSpecs['industrial']![Density.low]!),
    ];
    TrafficLot? none(String _) => null;
    const tuning =
        TrafficTuning(workPerStep: 500, maxSettled: 100, routesPerOrigin: 1);
    final m = CityTrafficModel(g, tuning: tuning);
    m.beginPass(none, sites: sites);
    var steps = 0;
    while (m.passing) {
      m.step();
      steps++;
    }
    expect(m.hasRun, isTrue);
    var maxWork = 0;
    for (var k = 1; k < steps; k++) {
      m.beginPass(none, sites: sites);
      for (var j = 0; j < k; j++) {
        m.step();
        maxWork = math.max(maxWork, m.lastStepWork);
      }
      // Dropped k steps in.
      m.beginPass(none, sites: sites);
      while (m.passing) {
        m.step();
        maxWork = math.max(maxWork, m.lastStepWork);
      }
    }
    expect(
        maxWork,
        lessThanOrEqualTo(tuning.workPerStep +
            tuning.routesPerOrigin * tuning.maxSettled +
            1000));
  });
}
