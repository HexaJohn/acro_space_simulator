// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'heap_probe.dart';
import 'traffic_fixture.dart';

/// Steady state allocates nothing (docs/plans/agent-traffic.md §15.2 and the
/// hard gates of §15.1): a working town's agents, warmed up, run 1,000
/// sub-steps and leave under 64 KB in new space beyond the one frame wrapper
/// each sub-step hands the renderer (§13.2).
///
/// The weighing needs the VM service, which `flutter test` starts only when
/// asked (`--enable-vmservice`, heap_probe.dart); without it that test
/// skips. The structural half of the rule needs nothing and always runs: in
/// steady state no column, arena or frame set is ever reallocated. Every
/// table keeps the very buffers it warmed up with.
///
/// The weighing is done in the debug JIT `flutter test` runs, and it counts
/// what that compiler allocates as well as what the code does. The JIT
/// boxes every double it passes to a call it did not inline. On a
/// compressed-pointer build like the tester's, it also boxes every int past
/// 2³⁰ passed that way, which the agent clock's microseconds are after
/// 1,074 s. So the report says where the bytes go: the planner's pull-out
/// queue and the mover, weighed one call at a time, beside the rest.
void main() {
  // The whole town's commutes at ten times the design rate: cars pulling
  // out, queuing at the crossroads, turning and arriving on every sub-step
  // weighed.
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('in steady state nothing is reallocated: every column, the route '
      'arena, the frame sets', () {
    final a = agentsOn(town());
    runAgents(a, 600);
    final before = _buffers(a);
    final arena = a.vehicles!.arena;
    final growths = arena.growths, capacity = arena.capacity;
    final spawned = a.stats.spawned, arrived = a.stats.arrived;
    final frames = <AgentFrame>[];
    for (var i = 0; i < 1000; i++) {
      a.advance(kStepS);
      frames.add(a.frame);
    }
    expect(a.stats.spawned - spawned, greaterThan(20),
        reason: 'the window did work');
    expect(a.stats.arrived - arrived, greaterThan(20));
    final after = _buffers(a);
    for (final name in before.keys) {
      expect(identical(after[name], before[name]), isTrue,
          reason: '$name was reallocated');
    }
    // A compaction swaps the arena's two buffers; growth replaces them.
    expect(arena.growths, growths);
    expect(arena.capacity, capacity);
    // Three column sets written in turn: frame i and frame i + 3 share
    // every list, and no two frames in a row share one.
    for (var i = 0; i + 3 < frames.length; i++) {
      final f = frames[i], g = frames[i + 3];
      expect(
          identical(f.handle, g.handle) &&
              identical(f.elem, g.elem) &&
              identical(f.s, g.s) &&
              identical(f.flags, g.flags),
          isTrue,
          reason: 'frames $i and ${i + 3}');
      expect(identical(f.s, frames[i + 1].s), isFalse, reason: 'frame $i');
    }
  });

  test('1,000 sub-steps after warm-up leave under 64 KB beyond their frames',
      () async {
    final probe = await HeapProbe.connect();
    if (probe == null) {
      markTestSkipped(HeapProbe.howToRun);
      return;
    }
    addTearDown(probe.close);
    // The building sync may allocate (§15.2): it runs on edits and every
    // `buildingSyncS`. Pushed past the window, so what is weighed is the
    // sub-step itself.
    AgentTuning.buildingSyncS = 1e7;
    final a = agentsOn(town());
    for (var i = 0; i < _warmSteps; i++) {
      a.advance(kStepS);
    }
    // One frame wrapper, made as `AgentFrameBuilder.publish` makes one.
    final cols = a.frame;
    var k = 0;
    final wrapper = await probe.bytesEach(250, () {
      _sink = AgentFrame.fromColumns(
        count: cols.count,
        timeUs: (a.timeUs + ++k * kStepUs).toDouble(),
        worldEpochS: a.worldEpochS,
        graphRev: cols.graphRev,
        handle: cols.handle,
        elem: cols.elem,
        next: cols.next,
        s: cols.s,
        v: cols.v,
        a: cols.a,
        lat: cols.lat,
        kind: cols.kind,
        variant: cols.variant,
        flags: cols.flags,
      );
    });
    expect(_sink, isA<AgentFrame>());
    final spawned = a.stats.spawned, arrived = a.stats.arrived;
    final waiting = a.planner!.waiting;
    // 1,000 sub-steps, weighed fifty at a time.
    final grew = await probe.growthOver(20, () {
      for (var i = 0; i < 50; i++) {
        a.advance(kStepS);
      }
    });
    final beyond = grew - 1000 * wrapper;
    final where = await _where(probe, a);
    final report = 'traffic alloc: 1,000 sub-steps with ${a.liveVehicles} '
        'vehicles live, ${a.stats.spawned - spawned} spawned and '
        '${a.stats.arrived - arrived} arrived, $waiting routes waiting to '
        'pull out: ${grew ~/ 1024} KB in new space, of which frames '
        '${(1000 * wrapper) ~/ 1024} KB (${wrapper.toStringAsFixed(0)} B '
        'each); ${(beyond / 1024).toStringAsFixed(1)} KB beyond them. $where';
    // ignore: avoid_print
    print(report);
    expect(a.stats.spawned - spawned, greaterThan(20),
        reason: 'the window did work');
    expect(beyond, lessThan(64 * 1024), reason: report);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Sub-steps of warm-up before weighing: past the JIT's optimisation
/// threshold (thirty thousand calls) for a function called once a sub-step.
const int _warmSteps = 40000;

/// Where the calibration's frames go, so none is optimised away.
Object? _sink;

/// Where a sub-step's bytes go: its two per-item loops, each called on its
/// own at the state the window left, per call. Run after the weighing, since
/// calling them out of turn moves the vehicles on outside the sub-step.
Future<String> _where(HeapProbe probe, CityAgents a) async {
  final planner = a.planner!, commutes = a.commutes!, mover = a.mover!;
  var now = a.timeUs;
  final pull = await probe.bytesEach(
      50, () => planner.spawnReady(a.timeUs, commutes));
  final move = await probe.bytesEach(50, () => mover.step(now += kStepUs));
  return 'The pull-out queue ${pull.toStringAsFixed(0)} B a sub-step over '
      '${planner.waiting} waiting routes; the mover '
      '${move.toStringAsFixed(0)} B a sub-step over ${a.liveVehicles} '
      'vehicles.';
}

/// Every buffer the agents keep from one sub-step to the next, by name.
Map<String, Object> _buffers(CityAgents a) {
  final t = a.vehicles!, m = a.mover!, b = a.buildings!, c = a.commutes!;
  return {
    'kind': t.kind,
    'variant': t.variant,
    'state': t.state,
    'purpose': t.purpose,
    'flags': t.flags,
    'grant': t.grant,
    'elem': t.elem,
    'routeCur': t.routeCur,
    'routeOff': t.routeOff,
    'routeLen': t.routeLen,
    'prev': t.prev,
    'next': t.next,
    'pass': t.pass,
    'owner': t.owner,
    'stuckUs': t.stuckUs,
    'waitUs': t.waitUs,
    's': t.s,
    'v': t.v,
    'a': t.a,
    'v0': t.v0,
    'f': t.f,
    'len': t.len,
    'destS': t.destS,
    'movedM': t.movedM,
    'freeFlowS': t.freeFlowS,
    'sPre': t.sPre,
    'vPre': t.vPre,
    'odo': t.odo,
    'edgeEnterUs': t.edgeEnterUs,
    'tripT0Us': t.tripT0Us,
    'elemHead': t.elemHead,
    'elemTail': t.elemTail,
    'elemCount': t.elemCount,
    'originT': a.planner!.originT,
    'edgeDrivenM': m.edgeDrivenM,
    'edgeLimitM': m.edgeLimitM,
    'edgeExits': m.edgeExits,
    'edgeStuck': m.edgeStuck,
    'housing': b.housing,
    'jobs': b.jobs,
    'accFwd': b.accFwd,
    'accBwd': b.accBwd,
    'commuteOwed': b.commuteOwed,
    'home': c.home,
    'job': c.job,
    'vehicle': c.vehicle,
    'stage': c.stage,
    'wakeUs': c.wakeUs,
  };
}
