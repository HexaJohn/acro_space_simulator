// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// One seed, one input, one history (docs/plans/agent-traffic.md §17.4):
/// two colonies fed the same ticks agree to the bit however those ticks were
/// cut, whether a host held them back to a frame budget, and across a road
/// drawn mid-run. The economy stands still here (the agents are advanced
/// directly), which is the scope §17.4 gives the partition test.
void main() {
  // Ten times the design's demand, so the town has traffic to disagree about.
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('twin runs: one seed, one tick sequence, a road drawn mid-run — one '
      'history', () {
    final dts = _ticks(TrafficRng(2026), 300);
    ({int digest, CityAgents agents}) run() {
      final city = town();
      final a = agentsOn(city);
      var t = 0.0;
      var edited = false;
      var mid = 0;
      for (final dt in dts) {
        if (!edited && t >= 150) {
          mid = a.digest();
          // An east–west street across the crossroads' north arm.
          commit(city,
              const FixtureRoad([Vec2(-250, 150), Vec2(250, 150)]));
          edited = true;
        }
        a.advance(dt);
        t += dt;
      }
      expect(a.digest(), isNot(mid), reason: 'the history moved on');
      return (digest: a.digest(), agents: a);
    }

    final first = run(), second = run();
    expect(second.digest, first.digest);
    final a = first.agents;
    expect(a.graphRev, 2, reason: 'the road rebuilt the lane graph once');
    expect(a.stats.spawned, greaterThan(20));
    expect(a.stats.arrived, greaterThan(5));
  });

  test('partition invariance: 3000 ticks of 0.02 s and 120 of 0.5 s run the '
      'same sub-steps and make the same history', () {
    final fine = agentsOn(town()), coarse = agentsOn(town());
    for (var i = 0; i < 120; i++) {
      for (var k = 0; k < 25; k++) {
        fine.advance(0.02);
      }
      coarse.advance(0.5);
      expect(fine.timeUs, coarse.timeUs, reason: 'after ${(i + 1) / 2} s');
      if (i % 20 == 19) expect(fine.digest(), coarse.digest());
    }
    expect(coarse.timeUs, 60 * kUsPerSecond);
    expect(coarse.stats.spawned, greaterThan(5));
    expect(fine.digest(), coarse.digest());
  });

  test('frame-hold invariance: held to 1, 4 or 12 sub-steps a frame, at '
      'random frame boundaries, the history is the inline one', () {
    final dts = _ticks(TrafficRng(35), 120);
    final inline = agentsOn(town());
    for (final dt in dts) {
      inline.advance(dt);
    }
    for (final budget in [1, 4, 12]) {
      AgentTuning.maxAgentSubStepsPerFrame = budget;
      final held = _held(town());
      final frames = TrafficRng(budget);
      var i = 0;
      var frameCount = 0;
      while (i < dts.length) {
        final k = 1 + frames.nextInt(25);
        for (var j = 0; j < k && i < dts.length; j++, i++) {
          // The host's tick: E3b first.
          if (!held.holdTick(dts[i])) held.advance(dts[i]);
        }
        final before = held.timeUs;
        final queued = held.heldCityS;
        held.endFrame();
        frameCount++;
        final steps = (held.timeUs - before) ~/ kStepUs;
        expect(steps, lessThanOrEqualTo(_frameCap(budget, queued)),
            reason: 'frame $frameCount ran $steps sub-steps');
      }
      held.flushHeld();
      expect(held.timeUs, inline.timeUs, reason: 'budget $budget');
      expect(held.digest(), inline.digest(), reason: 'budget $budget');
    }
  });

  group('the frame hold keeps pace', () {
    /// Frames at [fps] against the host's 50 ticks a second, every tick
    /// 0.5 s — 25× warp — for [wallS] seconds: the colony seconds still
    /// held after the worst frame and after the last, and the most
    /// sub-steps any frame ran.
    ({double worstS, double endS, int maxSteps}) paced(double fps, double wallS,
        {int hitchAt = -1}) {
      final a = _held(town());
      var worst = 0.0;
      var maxSteps = 0;
      var owed = 0.0;
      final frames = (fps * wallS).round();
      for (var frame = 0; frame < frames; frame++) {
        owed += 50 / fps;
        // A hitch: the host catches up 25 ticks at once, its cap.
        final ticks = frame == hitchAt ? 25 : owed.floor();
        owed -= owed.floor();
        for (var k = 0; k < ticks; k++) {
          if (!a.holdTick(0.5)) a.advance(0.5);
        }
        final before = a.timeUs;
        final queued = a.heldCityS;
        a.endFrame();
        final steps = (a.timeUs - before) ~/ kStepUs;
        expect(steps, lessThanOrEqualTo(_frameCap(4, queued)),
            reason: 'frame $frame at $fps fps ran $steps sub-steps');
        if (steps > maxSteps) maxSteps = steps;
        if (a.heldCityS > worst) worst = a.heldCityS;
      }
      return (worstS: worst, endS: a.heldCityS, maxSteps: maxSteps);
    }

    test('at 40 fps — five ticks of 0.5 s every four frames, two ticks '
        'dearer together than one frame\'s budget — the colony stays a '
        'tick or two behind, and never reaches maxHeldCityS', () {
      final r = paced(40, 20);
      expect(r.worstS, lessThan(1.5));
      expect(r.maxSteps, lessThanOrEqualTo(2 * 4 + 1));
    });

    test('at 60 fps it keeps up inside the budget', () {
      final r = paced(60, 10);
      expect(r.worstS, lessThanOrEqualTo(0.5));
      expect(r.maxSteps, lessThanOrEqualTo(4));
    });

    test('at 30 fps, more than the budget a frame, it falls a bounded way '
        'behind and works that off, never spilling', () {
      final r = paced(30, 20);
      expect(r.worstS, lessThan(AgentTuning.maxHeldCityS / 2));
    });

    test('a 25-tick hitch at 60 fps is spread over the frames after it — '
        'not run in one, and worked off in the frames that follow', () {
      final r = paced(60, 4, hitchAt: 60);
      expect(r.worstS, greaterThan(5),
          reason: 'the hitch was queued, not run at once');
      expect(r.maxSteps, lessThan(25 * 5 ~/ 2),
          reason: 'no frame ran the whole hitch');
      expect(r.endS, lessThanOrEqualTo(0.5), reason: 'and worked off');
    });
  });
}

/// Agents of the test's own on [city] held to a frame budget, replaying a
/// tick as `CitySim.advance` would once E3a and E3b are in: clamped, and
/// the agents advanced by it.
CityAgents _held(CitySim city) {
  final a = agentsOn(city)..frameBudgeted = true;
  a.replayTick = (_, simDt) =>
      a.advance((simDt * a.city.eventSimWarp).clamp(0.0, 0.5));
  return a;
}

/// The most sub-steps a frame of the hold may run with [queuedS] colony
/// seconds held (city_agents.dart, `endFrame`): its budget, at most one more
/// carried from the frame before, its share of the backlog, whatever is
/// past `maxHeldCityS` — and one tick (three sub-steps at most) past all
/// that, since a frame always runs its oldest tick.
int _frameCap(int budget, double queuedS) {
  final pendingSteps = queuedS / kStepS + 1;
  final over = math.max(0.0, (queuedS - AgentTuning.maxHeldCityS) / kStepS);
  return (2 * budget + pendingSteps / 32 + over).floor() + 3;
}

/// A tick sequence of about [seconds]: mostly the 0.5 s of the warp clamp,
/// some of the fixed step's 0.02 s, some in between.
List<double> _ticks(TrafficRng rng, double seconds) {
  final out = <double>[];
  var t = 0.0;
  while (t < seconds) {
    final r = rng.nextInt(10);
    final dt = r < 6 ? 0.5 : (r < 8 ? 0.02 : 0.1 + 0.3 * rng.nextUnit());
    out.add(dt);
    t += dt;
  }
  return out;
}
