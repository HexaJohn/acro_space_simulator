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
/// starter colony at the demand of 5,000 citizens, ticked `advance(0.5)` for
/// ten agent-minutes; and the catch-up frame, when the host runs its cap of
/// 25 ticks of 0.5 s in one frame.
///
/// Slice 1 has no citizens: `CommuteSynth` stands in for them, and its rate
/// is scaled so the town's homes send what 5,000 residents would.
///
/// - Without the frame hold, the catch-up frame runs every sub-step it owes
///   (about 62) inline: the worst-case hitch, reported.
/// - With it (`frameBudgeted`), the ticks are queued whole and replayed at
///   the ends of frames: every frame runs no more than the hold's credit
///   allows (city_agents.dart, `endFrame`), and the queue drains back to
///   empty in the frames after.
///
/// Held under ACRO_PERF: every frame's agent work with the hold at no more
/// than §15.1's 3.2 ms.
void main() {
  tearDown(AgentTuning.reset);

  test('bench: 5,000 citizens\' traffic at 25x, and the catch-up frame '
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
    report('warp, the starter town ($housing homes\' worth scaled to 5,000 '
        'residents), 10 agent-minutes of advance(0.5): per tick p50 '
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
    var maxSteps = 0, drainFrames = -1;
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
      expect(steps, lessThanOrEqualTo(_frameCap(budget, queued)),
          reason: 'frame $frame ran $steps sub-steps with ${f(queued)} s held');
      if (drainFrames < 0 && frame > 0 && a.heldTicks <= 1) {
        drainFrames = frame;
      }
    }
    a.flushHeld();
    report('catch-up frame with the hold: the hitch frame '
        '${f(frameMs.first)} ms; over 600 frames at 60 Hz and 25x, worst '
        '${f(percentile(frameMs, 1))} ms, p99 ${f(percentile(frameMs, 0.99))} '
        'ms, median ${f(percentile(frameMs, 0.5))} ms, at most $maxSteps '
        'sub-steps a frame; the queue back to a tick or less after '
        '$drainFrames frames (${f(drainFrames / 60)} s)');
    expect(drainFrames, greaterThan(0), reason: 'the queue drained');
    if (kPerf) {
      expect(percentile(frameMs, 1), lessThanOrEqualTo(3.2),
          reason: '§15.1: every frame at 25x ≤ 3.2 ms with the hold');
    }
  }, skip: benchSkip, timeout: benchTimeout);
}

/// The most sub-steps a frame of the hold may run with [queuedS] colony
/// seconds held (city_agents.dart, `endFrame`): its budget, at most one more
/// carried from the frame before, its share of the backlog, whatever is
/// past `maxHeldCityS`, and one tick past all that (three sub-steps at
/// most), since a frame always runs its oldest tick.
int _frameCap(int budget, double queuedS) {
  final pendingSteps = queuedS / kStepS + 1;
  final over = math.max(0.0, (queuedS - AgentTuning.maxHeldCityS) / kStepS);
  return (2 * budget + pendingSteps / 32 + over).floor() + 3;
}
