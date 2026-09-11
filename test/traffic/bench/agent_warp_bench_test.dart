// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic_fixture.dart';
import 'bench_support.dart';

/// §15.5 benchmark 4 (docs/plans/agent-traffic.md §5.7, §15.1): the headless
/// starter colony at the 25× clamp, ticked `advance(0.5)` for ten
/// agent-minutes; and the catch-up frame, when the host runs its cap of 25
/// ticks of 0.5 s in one frame.
///
/// Slice 1 has no citizens: `CommuteSynth` stands in for them, its rate
/// scaled so the town's homes send what 5,000 residents would. The town is
/// the starter kit's two 600 m streets, which hold about 340 cars standing,
/// so this saturates the town — it weighs the tick and the hold at the
/// town's own limit, not §15.1's 2,000-vehicle design point, which the
/// sub-step bench (benchmark 1) weighs by vehicle count.
///
/// - Without the frame hold, the catch-up frame runs every sub-step it owes
///   (about 62) inline: the worst-case hitch, reported.
/// - With it (`frameBudgeted`), the ticks are queued whole and replayed at
///   the ends of frames. The bound is the policy's, not `endFrame`'s credit
///   arithmetic: a frame runs its budget (`maxAgentSubStepsPerFrame`, §15.5
///   #4's "at most 4 sub-steps a frame") and, since ticks replay whole
///   (D35), at most one tick past it — plus whatever the queue holds past
///   `maxHeldCityS`, which a frame drains on the spot rather than drop.
///
/// Held under ACRO_PERF: every frame's agent work with the hold at no more
/// than §15.1's 3.2 ms.
void main() {
  tearDown(AgentTuning.reset);

  test('bench: the starter town saturated at 25x, and the catch-up frame '
      '(§15.5 #4)', () {
    final probe = agentsOn(town())..advance(0.5);
    final b = probe.buildings!;
    var housing = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl)) housing += b.housing[sl];
    }
    AgentTuning.commuteRatePerResident =
        AgentTuning.commuteRatePerResident * 5000 / housing;

    // Ten agent-minutes of the 25× clamp's tick.
    final a = agentsOn(town());
    final tickMs = <double>[];
    var maxLive = 0, sumLive = 0;
    for (var i = 0; i < 1200; i++) {
      final sw = Stopwatch()..start();
      a.advance(0.5);
      tickMs.add(sw.elapsedMicroseconds / 1000);
      maxLive = math.max(maxLive, a.liveVehicles);
      sumLive += a.liveVehicles;
    }
    final warm = tickMs.sublist(200);
    report('warp, the starter town (its $housing homes sending what 5,000 '
        'residents would; its two streets hold about 340 cars standing), 10 '
        'agent-minutes of advance(0.5): per tick p50 '
        '${f(percentile(warm, 0.5))} ms, p99 ${f(percentile(warm, 0.99))} ms, '
        'max ${f(percentile(warm, 1))} ms; ${f(sumLive / 1200, 0)} vehicles '
        'live on average, $maxLive at most; ${a.stats.spawned} spawned, '
        '${a.stats.arrived} arrived, ${a.stats.despawnStuck} stuck, '
        '${a.stats.despawnWedge} wedged, ${a.stats.deferred} deferred');

    // The catch-up frame, inline: 25 ticks of 0.5 s in one frame.
    final hitchMs = <double>[];
    for (var frame = 0; frame < 20; frame++) {
      final sw = Stopwatch()..start();
      for (var k = 0; k < 25; k++) {
        a.advance(0.5);
      }
      hitchMs.add(sw.elapsedMicroseconds / 1000);
    }
    report('catch-up frame without the hold: 25 x advance(0.5), about 62 '
        'sub-steps, median ${f(percentile(hitchMs, 0.5))} ms, worst '
        '${f(percentile(hitchMs, 1))} ms');

    // The same frame held: queued whole, replayed at the ends of frames.
    a
      ..frameBudgeted = true
      ..replayTick = (city, simDt) =>
          a.advance((simDt * city.eventSimWarp).clamp(0.0, 0.5));
    final budget = AgentTuning.maxAgentSubStepsPerFrame;
    final frameMs = <double>[];
    var maxSteps = 0, maxOverBudget = 0, drainFrames = -1;
    var owed = 0.0;
    for (var frame = 0; frame < 600; frame++) {
      // A 25-tick hitch first, then 60 Hz at 25×: 50 ticks a second.
      var ticks = 25;
      if (frame > 0) {
        owed += 50 / 60;
        ticks = owed.floor();
        owed -= ticks;
      }
      for (var k = 0; k < ticks; k++) {
        if (!a.holdTick(0.5)) a.advance(0.5);
      }
      final queued = a.heldCityS;
      final before = a.timeUs;
      final sw = Stopwatch()..start();
      a.endFrame();
      frameMs.add(sw.elapsedMicroseconds / 1000);
      final steps = (a.timeUs - before) ~/ kStepUs;
      maxSteps = math.max(maxSteps, steps);
      final overflow = _overflowSteps(queued);
      if (overflow == 0) maxOverBudget = math.max(maxOverBudget, steps - budget);
      expect(steps, lessThanOrEqualTo(budget + _tickSteps + overflow),
          reason: 'frame $frame ran $steps sub-steps with ${f(queued)} s '
              'held: its budget of $budget, one tick past it at most, and '
              '$overflow owed past maxHeldCityS');
      if (drainFrames < 0 && frame > 0 && a.heldTicks <= 1) {
        drainFrames = frame;
      }
    }
    a.flushHeld();
    report('catch-up frame with the hold: the hitch frame '
        '${f(frameMs.first)} ms; over 600 frames at 60 Hz and 25x, worst '
        '${f(percentile(frameMs, 1))} ms, p99 ${f(percentile(frameMs, 0.99))} '
        'ms, median ${f(percentile(frameMs, 0.5))} ms, at most $maxSteps '
        'sub-steps a frame ($maxOverBudget past the budget of $budget when '
        'nothing was overdue); the queue back to a tick or less after '
        '$drainFrames frames (${f(drainFrames / 60)} s)');
    expect(drainFrames, greaterThan(0), reason: 'the queue drained');
    if (kPerf) {
      expect(percentile(frameMs, 1), lessThanOrEqualTo(3.2),
          reason: '§15.1: every frame at 25x ≤ 3.2 ms with the hold');
    }
  }, skip: benchSkip, timeout: benchTimeout);
}

/// Sub-steps in one tick at most: `CitySim.advance` clamps a tick to 0.5 s,
/// which from any leftover on the agent clock is two 0.2 s sub-steps or
/// three.
const int _tickSteps = 3;

/// Sub-steps a frame owes past `maxHeldCityS` with [queuedS] colony seconds
/// held: the part of the queue the hold may not keep, drained on the spot.
int _overflowSteps(double queuedS) {
  final over = queuedS - AgentTuning.maxHeldCityS;
  return over <= 0 ? 0 : (over / kStepS).ceil();
}
