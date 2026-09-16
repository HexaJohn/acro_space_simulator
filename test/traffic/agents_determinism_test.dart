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

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
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

  group('A11: with site movers active', () {
    // STRIP and LOOP on the starter kit's own lots: cars turn in at their
    // cuts, drive their aisles, park on their stalls and pull out again, so
    // every column T4a added is moving while the digests are compared
    // (site-access.md §7.9 A11).
    Map<String, SyntheticTemplate> byLot() => {
          lotOf(SyntheticTemplate.strip): SyntheticTemplate.strip,
          lotOf(SyntheticTemplate.loop): SyntheticTemplate.loop,
          lotOf(SyntheticTemplate.home): SyntheticTemplate.home,
        };

    /// Everything a rendered host asks the agents between ticks: the frame,
    /// a vehicle's description, the readout's answers, the site columns and
    /// the wire's own lists. None of it may move the history (§17.4).
    void capture(CityAgents a) {
      a.frame;
      a.readout.hasRun;
      a.readout.peakCongestion;
      a.agentManaged;
      a.agentManagedRev;
      a.sites?.syncedSitesRev;
      a.parkedCars?.parkedRev;
      a.accessEvents?.count;
      a.siteStats.enters;
      final t = a.vehicles;
      if (t == null) return;
      for (var sl = 0; sl < t.highWater; sl++) {
        if (t.isSlotLive(sl)) a.describe(t.handleOf(sl));
      }
    }

    ({int digest, CityAgents agents}) drive(List<double> dts,
        {required bool asked}) {
      final city = town();
      final a = agentsOn(city);
      final plans = FixturePlanSource(city.roadGraph, byLot());
      a.debugPlans = plans;
      var t = 0.0;
      var edited = false;
      for (final dt in dts) {
        // A plan change mid-run: the strip is re-planned as a loop, so the
        // §7.6 row-1 and row-2 moves (snap, relocate, garage) run inside the
        // window the digests cover.
        if (!edited && t >= 120) {
          plans.replace(
              lotOf(SyntheticTemplate.strip), SyntheticTemplate.homeTandem);
          edited = true;
        }
        a.advance(dt);
        if (asked) capture(a);
        t += dt;
      }
      return (digest: a.digest(), agents: a);
    }

    test('twin runs with a plan change mid-run, and capture calls '
        'interleaved, make one history', () {
      final dts = _ticks(TrafficRng(0x51E), 300);
      final quiet = drive(dts, asked: false);
      final asked = drive(dts, asked: true);
      expect(asked.digest, quiet.digest);
      final a = quiet.agents;
      expect(a.siteStats.enters, greaterThan(0), reason: 'cars turned in');
      expect(a.siteStats.parkedLot, greaterThan(0), reason: 'and parked');
      expect(a.sites!.syncs, greaterThan(1), reason: 'the plan changed');
      expect(a.digest(), asked.agents.digest(),
          reason: 'and asking again after the run moves nothing');
    });

    test('partition invariance holds with sites: 3000 ticks of 0.02 s and '
        '120 of 0.5 s agree', () {
      final fine = _sited(), coarse = _sited();
      for (var i = 0; i < 120; i++) {
        for (var k = 0; k < 25; k++) {
          fine.advance(0.02);
        }
        coarse.advance(0.5);
        expect(fine.timeUs, coarse.timeUs, reason: 'after ${(i + 1) / 2} s');
        if (i % 20 == 19) expect(fine.digest(), coarse.digest());
      }
      expect(coarse.siteStats.enters, greaterThan(0));
      expect(fine.digest(), coarse.digest());
    });

    test('frame-hold invariance holds with sites, at 1, 4 and 12 sub-steps '
        'a frame', () {
      final dts = _ticks(TrafficRng(0xF0), 120);
      final inline = _sited();
      for (final dt in dts) {
        inline.advance(dt);
      }
      expect(inline.siteStats.enters, greaterThan(0));
      for (final budget in [1, 4, 12]) {
        AgentTuning.maxAgentSubStepsPerFrame = budget;
        final held = _heldSited();
        final frames = TrafficRng(budget);
        var i = 0;
        while (i < dts.length) {
          final k = 1 + frames.nextInt(25);
          for (var j = 0; j < k && i < dts.length; j++, i++) {
            if (!held.holdTick(dts[i])) held.advance(dts[i]);
          }
          held.endFrame();
        }
        held.flushHeld();
        expect(held.timeUs, inline.timeUs, reason: 'budget $budget');
        expect(held.digest(), inline.digest(), reason: 'budget $budget');
      }
    });
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
        // The design's bound itself (D35, §5.7): under the overflow, a
        // frame runs its budget and one tick past it at most.
        expect(queued, lessThanOrEqualTo(AgentTuning.maxHeldCityS),
            reason: 'frame $frame at $fps fps: under the overflow');
        expect(steps,
            lessThanOrEqualTo(AgentTuning.maxAgentSubStepsPerFrame + _tickSteps),
            reason: 'frame $frame at $fps fps ran $steps sub-steps with '
                '${queued.toStringAsFixed(2)} s held');
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
      expect(r.maxSteps, lessThanOrEqualTo(4 + _tickSteps));
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
        'no frame, the hitch frame included, past the budget and one tick — '
        'and worked off in the frames that follow', () {
      final r = paced(60, 4, hitchAt: 60);
      expect(r.worstS, greaterThan(5),
          reason: 'the hitch was queued, not run at once');
      expect(r.worstS, lessThan(AgentTuning.maxHeldCityS),
          reason: 'under the overflow: the budget spreads it, not the '
              'overflow rule');
      expect(r.maxSteps, lessThanOrEqualTo(4 + _tickSteps),
          reason: 'D35: four sub-steps a frame, and a tick past them at most');
      expect(r.endS, lessThanOrEqualTo(0.5), reason: 'and worked off');
    });
  });
}

/// The most sub-steps one tick of 0.5 s runs, from any leftover on the
/// agent clock: what a frame of the hold may run past its budget (D35).
const int _tickSteps = 3;

/// A town whose starter lots carry STRIP, LOOP and HOME plans, with agents
/// of the test's own driving into them (A11).
CityAgents _sited() {
  final city = town();
  final a = agentsOn(city);
  a.debugPlans = FixturePlanSource(city.roadGraph, {
    lotOf(SyntheticTemplate.strip): SyntheticTemplate.strip,
    lotOf(SyntheticTemplate.loop): SyntheticTemplate.loop,
    lotOf(SyntheticTemplate.home): SyntheticTemplate.home,
  });
  return a;
}

/// [_sited], held to a frame budget as [_held] holds one.
CityAgents _heldSited() {
  final a = _sited()..frameBudgeted = true;
  a.replayTick = (_, simDt) =>
      a.advance((simDt * a.city.eventSimWarp).clamp(0.0, 0.5));
  return a;
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

/// A safety bound on the sub-steps a frame of the hold may run with
/// [queuedS] colony seconds held, for the invariance test's frames at
/// random boundaries, which may pass `maxHeldCityS`: its budget, at most
/// one more carried from the frame before, its share of the backlog,
/// whatever is past `maxHeldCityS` — and one tick (three sub-steps at most)
/// past all that, since a frame always runs its oldest tick. Looser than
/// the design's bound, which [paced] holds each frame to.
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
