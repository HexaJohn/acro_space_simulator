// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

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
      final held = agentsOn(town())..frameBudgeted = true;
      // What CitySim.advance does with a replayed tick once E3a and E3b are
      // in: clamp it, and advance the agents with it.
      held.replayTick = (simDt) =>
          held.advance((simDt * held.city.eventSimWarp).clamp(0.0, 0.5));
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
        if (queued <= AgentTuning.maxHeldCityS) {
          expect(steps, lessThanOrEqualTo(math.max(budget, 3)),
              reason: 'frame $frameCount ran $steps sub-steps');
        }
      }
      while (held.heldTicks > 0) {
        held.endFrame();
      }
      expect(held.timeUs, inline.timeUs, reason: 'budget $budget');
      expect(held.digest(), inline.digest(), reason: 'budget $budget');
    }
  });
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
