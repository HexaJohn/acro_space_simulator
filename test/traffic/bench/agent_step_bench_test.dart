// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:flutter_test/flutter_test.dart';

import '../heap_probe.dart';
import '../movement_fixture.dart';
import 'bench_support.dart';

/// §15.5 benchmark 3 (docs/plans/agent-traffic.md §5.2–5.4, §15.1, §15.2):
/// 2,000 and 4,000 vehicles driving random trips on the 30 × 30 grid for
/// 1,000 sub-steps — car-following, the junction rules, the hand-overs,
/// the stuck clocks. Reported: nanoseconds per vehicle per sub-step, and
/// what 1,000 sub-steps leave in new space (the §15.2 gate, weighed when the
/// VM service is there: heap_probe.dart). The clock starts at nought, so
/// the microseconds stay inside a small integer and nothing is weighed but
/// the doubles the debug JIT boxes.
///
/// §15.1 budgets the vehicle step at 80 ns a vehicle. Held under
/// ACRO_PERF, and the allocation gate whenever it can be weighed. The fleet
/// is topped up between sub-steps, outside the clock, as arrivals thin it.
void main() {
  test('bench: vehicle step, 2,000 and 4,000 vehicles on the grid '
      '(§15.5 #3)', () async {
    final lg = LaneGraphBuilder.build(RoadGraph.of(gridLayout(30)));
    final probe = await HeapProbe.connect();
    // Every size is measured and reported before any gate is held, so one
    // reading carries every number.
    final missed = <String>[];
    try {
      for (final n in const [2000, 4000]) {
        final d = Drive(lg, capacity: 4096);
        final rng = TrafficRng(n);
        final sink = _Quiet();
        void step() {
          d.nowUs += kStepUs;
          d.mover.step(d.nowUs, sink);
        }

        for (var i = 0; i < 400 && d.table.liveCount < n; i++) {
          d.topUp(rng, n, perStep: 400);
          step();
        }
        for (var i = 0; i < 300; i++) {
          d.topUp(rng, n, perStep: 50);
          step();
        }
        final us = <double>[];
        var vehicleSteps = 0;
        var totalUs = 0.0;
        for (var i = 0; i < 1000; i++) {
          d.topUp(rng, n, perStep: 50);
          vehicleSteps += d.table.liveCount;
          final sw = Stopwatch()..start();
          step();
          final t = sw.elapsedMicroseconds.toDouble();
          us.add(t);
          totalUs += t;
        }
        final nsPerVehicle = totalUs * 1000 / vehicleSteps;
        String weighed = 'not weighed (${HeapProbe.howToRun})';
        int? grew;
        if (probe != null) {
          grew = await probe.growthOver(20, () {
            for (var i = 0; i < 50; i++) {
              step();
            }
          });
          weighed = '${f(grew / 1024, 1)} KB in new space over 1,000 more '
              'sub-steps (${f(grew / 1000, 0)} B a sub-step)';
        }
        report('vehicle step, $n vehicles on the grid: '
            '${f(vehicleSteps / 1000, 0)} live on average; a sub-step '
            'median ${f(percentile(us, 0.5) / 1000)} ms, p99 '
            '${f(percentile(us, 0.99) / 1000)} ms; '
            '${f(nsPerVehicle, 0)} ns a vehicle; ${d.mover.handOvers} '
            'hand-overs, ${d.arbiter.commits} passes, '
            '${d.arbiter.forcedGrants} forced; $weighed');
        expect(vehicleSteps / 1000, greaterThan(0.9 * n));
        if (grew != null && grew >= 64 * 1024) {
          missed.add('$n vehicles: ${f(grew / 1024, 1)} KB in new space over '
              '1,000 sub-steps (§15.2: under 64 KB)');
        }
        if (kPerf && nsPerVehicle > 80) {
          missed.add('$n vehicles: ${f(nsPerVehicle, 0)} ns a vehicle '
              '(§15.1: 80 ns)');
        }
      }
    } finally {
      await probe?.close();
    }
    expect(missed, isEmpty);
  }, skip: benchSkip, timeout: benchTimeout);
}

/// A sink that keeps nothing: the fixture's own records every arrival in a
/// list, which would be weighed with the step.
class _Quiet implements VehicleSink {
  @override
  void arrived(int handle) {}

  @override
  void despawned(int handle, DespawnReason reason) {}
}
