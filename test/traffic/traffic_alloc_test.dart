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
/// asked (`--enable-vmservice`, heap_probe.dart). The merge gate asks
/// (§18), with the run marked as one that must weigh:
///
///     fvm flutter test --enable-vmservice --dart-define=ACRO_ALLOC=true test/traffic/traffic_alloc_test.dart
///
/// Marked so, a run without the service FAILS rather than skips, so the
/// gate is never read as met because it was not weighed. Any other run
/// skips the weighing and says why, and says where the gate stands: §15.2
/// records it as not met (below). The structural half of the rule needs
/// nothing and always runs: in steady state no column, arena, queue,
/// search context or frame set is ever reallocated. Every table keeps the
/// very buffers it warmed up with.
///
/// The weighing is done in the debug JIT `flutter test` runs, and it counts
/// what that compiler allocates as well as what the code does. The JIT
/// boxes every double it passes to a call it did not inline. On a
/// compressed-pointer build like the tester's, it also boxes every int past
/// 2³⁰ passed that way, which the agent clock's microseconds are after
/// 1,074 s. So the report says where the bytes go: the planner's pull-out
/// queue and the mover, weighed one call at a time, beside the rest. Today
/// that is about 64 B a sub-step for every route waiting to pull out and
/// about 95 B for every vehicle stepped — 33.7 MB beyond the frames over
/// the window — and so the gate is not met.
void main() {
  // The whole town's commutes at ten times the design rate: cars pulling
  // out, queuing at the crossroads, turning and arriving on every sub-step
  // weighed.
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('in steady state nothing is reallocated: every column, the route '
      'arena, the pull-out queue, the path queue and its searches, the '
      'junction books, the delay table and its pools, the readout\'s pass, '
      'the frame sets', () {
    final a = agentsOn(town());
    runAgents(a, 600);
    final before = _buffers(a);
    final arena = a.vehicles!.arena;
    final growths = arena.growths, capacity = arena.capacity;
    final spawned = a.stats.spawned, arrived = a.stats.arrived;
    final publishes = a.delays!.publishes;
    final passes = a.readout.publishedPasses;
    expect(a.planner!.waiting, greaterThan(64),
        reason: 'the pull-out queue is past its first size, so a column '
            'that grew with it has grown');
    final frames = <AgentFrame>[];
    for (var i = 0; i < 1000; i++) {
      a.advance(kStepS);
      frames.add(a.frame);
    }
    expect(a.stats.spawned - spawned, greaterThan(20),
        reason: 'the window did work');
    expect(a.stats.arrived - arrived, greaterThan(20));
    expect(a.delays!.publishes - publishes, 100,
        reason: 'a delay buffer every congestion epoch, from the pool');
    expect(a.readout.publishedPasses - passes, greaterThan(20),
        reason: 'the readout\'s pass ran in the sub-steps weighed');
    final after = _buffers(a);
    expect(after.keys.toList(), before.keys.toList(),
        reason: 'no buffer, nor search context, made in steady state');
    // Matched by identity as a set: a twin swapped (the statistics'
    // window books change places at every window's end) is no allocation.
    final warm = Set<Object>.identity()..addAll(before.values);
    for (final name in after.keys) {
      expect(warm.contains(after[name]), isTrue,
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
      if (_mustWeigh) {
        fail('§15.2 must be weighed on this run (ACRO_ALLOC), and the tester '
            'has no VM service: ${HeapProbe.howToRun}');
      }
      markTestSkipped('§15.2 not weighed on this run, and recorded as not '
          'met (docs/plans/agent-traffic.md §15.2). The merge gate weighs '
          'it: $_mergeGate');
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
    // One frame wrapper, weighed on the path that makes one —
    // `AgentFrameBuilder.publish`, from a builder of its own over the same
    // table — and from a caller warmed past the optimisation threshold, as
    // the sub-step's own call is: an unoptimised caller boxes what it
    // passes, and its boxes would be forgiven as frames. The columns are
    // written in place and allocate nothing, so what is left is the wrapper
    // and whatever the optimised publish boxes for it.
    final cal = AgentFrameBuilder();
    final table = a.vehicles!;
    final timeUs = a.timeUs, epochS = a.worldEpochS, rev = a.graphRev;
    void publish() => _sink =
        cal.publish(table, timeUs: timeUs, worldEpochS: epochS, graphRev: rev);
    for (var i = 0; i < _warmSteps; i++) {
      publish();
    }
    final wrapper = await probe.bytesEach(250, publish);
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
        'each, weighed on publish); ${(beyond / 1024).toStringAsFixed(1)} KB '
        'beyond them. $where';
    // ignore: avoid_print
    print(report);
    expect(a.stats.spawned - spawned, greaterThan(20),
        reason: 'the window did work');
    expect(beyond, lessThan(64 * 1024), reason: report);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// Whether this run must weigh: set by the merge gate's command, where a
/// tester without the VM service is a failure, not a skip.
const bool _mustWeigh = bool.fromEnvironment('ACRO_ALLOC');

/// The merge gate's command (§18).
const String _mergeGate = 'fvm flutter test --enable-vmservice '
    '--dart-define=ACRO_ALLOC=true test/traffic/traffic_alloc_test.dart';

/// Sub-steps of warm-up before weighing, and calls of the frame
/// calibration: past the JIT's optimisation threshold (thirty thousand
/// calls) for a function called once a sub-step.
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

/// Every buffer the agents keep from one sub-step to the next, by name: the
/// tables' columns, and what the planner, the path queue and its search
/// contexts, the mover, the junction rules, the statistics and the delay
/// table (its EMAs, flows and both pools of published buffers) and the
/// readout's pass (its reach fields and noise pictures) hold.
Map<String, Object> _buffers(CityAgents a) {
  final t = a.vehicles!, b = a.buildings!, c = a.commutes!, m = a.mover!;
  final out = <String, Object>{
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
    'housing': b.housing,
    'jobs': b.jobs,
    'accCount': b.accCount,
    'accEdge': b.accEdge,
    'accT': b.accT,
    'commuteOwed': b.commuteOwed,
    'home': c.home,
    'job': c.job,
    'vehicle': c.vehicle,
    'stage': c.stage,
    'wakeUs': c.wakeUs,
  };
  a.planner!.collectBuffers(out, 'planner');
  a.pathQueue!.collectBuffers(out, 'paths');
  // The site half (T4a): the site table, the site vehicle rows, the access
  // events, the parked cars, the kerb slots and the mover's scratch. A13
  // gates them on a town whose cars are cycling the lots; here they ride
  // along, so a buffer this town replaces shows up wherever it happens.
  a.collectSiteBuffers(out);
  m.collectBuffers(out, 'mover');
  m.arbiter.collectBuffers(out, 'arbiter');
  a.stats.collectBuffers(out, 'stats');
  a.delays!.collectBuffers(out, 'delays');
  a.readout.collectBuffers(out, 'readout');
  return out;
}
