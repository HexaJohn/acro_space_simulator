// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_traffic_readout.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic_fixture.dart';
import 'bench_support.dart';

/// What the readout's pass costs in the agents' sub-step (docs/plans/
/// agent-traffic.md §12.2 step 7, §15.1; 474c7aa): reach, noise and land
/// value, `AgentTuning.readoutWorkPerStep` work units every sub-step, on the
/// generator's sprawls — the 2-mile one the graph bench derives, and the
/// 12-mile one the road agent's R-B1 bench builds, the biggest any bench
/// uses — with the agents on and their commuters driving.
///
/// The readout's own tick is timed ALONE. The colony's readout runs inside
/// `CityAgents.advance`, where no clock can reach it, so the agents are
/// advanced a sub-step at a time with the budget at 0 — their readout begins
/// its pass at a picture and never does a unit of it — and a second readout
/// over the same agents ([AgentTrafficReadout] reads the agents and writes
/// nothing of theirs) is ticked right after, with the real budget and the
/// sub-step's picture flag: the same code on the same tables at the same
/// sub-step, only after the frame is published rather than before it.
/// `advance`'s time is then the REST of the sub-step, to hold the two
/// together against §15.1's gates:
///
/// - inline agent work ≤ 1.5 ms in every frame at 1×, where a frame runs at
///   most one sub-step;
/// - ≤ 3.2 ms in every frame at 25×, where the frame hold runs
///   `maxAgentSubStepsPerFrame` (4) sub-steps a frame — and, past its
///   budget, one tick (up to 3) more.
///
/// Work units are counted, not timed: a pass is run to its end on a third
/// readout in calls of a small budget, asking between calls (a zero-budget
/// tick at a picture) whether it has finished — the calls bracket its units.
/// A whole pass is timed in one call on a fourth, beside it.
///
/// Reported only: the numbers are a debug JIT test VM's, and no gate is held
/// under ACRO_PERF — the budget is proposed from them, and the tuning test
/// pins it.
void main() {
  tearDown(AgentTuning.reset);

  for (final miles in const [2, 12]) {
    test('bench: the readout pass in the sub-step, the $miles-mile sprawl '
        '(§12.2 step 7, §15.1)', () {
      _bench(miles);
    }, skip: benchSkip, timeout: benchTimeout);
  }
}

/// §15.1's hard gates, µs.
const double _gate1x = 1500, _gate25x = 3200;

/// Sub-steps a frame of the hold runs: its budget, and one tick past it.
const int _holdSteps = 4, _tickSteps = 3;

void _bench(int miles) {
  final city = quiet(const CityGenerator().generate(
      CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: miles.toDouble()),
      bodies: fixtureBodies));
  final g = city.roadGraph;
  final sampled = _sampledLots(city);
  final a = agentsOn(city);
  final shipped = AgentTuning.readoutWorkPerStep;

  final shadow = AgentTrafficReadout(a, city.roadTraffic);
  // 150 s: the spawn ramp, and the commuters out on the roads.
  final warm = _drive(a, shadow, _before, 750);
  final firstPass = warm.published.isEmpty ? -1 : warm.published.first;
  final firstMs = firstPass < 0
      ? double.nan
      : warm.read.sublist(0, firstPass + 1).fold(0.0, (s, x) => s + x) / 1000;

  final run = _drive(a, shadow, _before, 3000);
  final lg = a.laneGraph!;
  report('readout pass, the $miles-mile sprawl: ${g.roadCount} roads, '
      '${g.pieceCount} pieces, ${g.lotCount} lots ($sampled zoned or built, '
      'sampled for noise), ${lg.edgeCount} edges, ${lg.laneCount} lanes, '
      '${a.buildings!.liveCount} buildings; ${f(run.meanLive, 0)} vehicles '
      'live on average, ${run.maxLive} at most (JIT test VM)');
  report('  the first pass (reach searched, JIT cold): published at sub-step '
      '${firstPass + 1}, ${f(firstMs)} ms of ticks');

  report('  at 474c7aa\'s budget:');
  final s = run.summary();
  s.show(_before);

  // Work units: counted on one readout, a whole pass timed on another, at
  // the same pictures.
  final units = _countUnits(a, city, 2000);
  final perUnitNs = units.wholeMs * 1e6 / units.steady.mid;
  report('  a pass counted: the first (reach searched) '
      '${units.first.lo}..${units.first.hi} units, a steady one (loads moved, '
      'reach unchanged) ${units.steady.lo}..${units.steady.hi}; a steady pass '
      'whole in one call ${f(units.wholeMs)} ms (median of 5) = '
      '${f(perUnitNs, 1)} ns a unit; from the sub-steps at full budget '
      '${f(s.fullP50Us * 1000 / _before, 1)} ns (p50), '
      '${f(s.fullP95Us * 1000 / _before, 1)} ns (p95)');

  // The largest budget the gates leave room for, at the measured rest and at
  // the rest §15.1's table budgets (0.8 ms a sub-step: step, pump, peds).
  final usPerUnit = s.fullP95Us / _before;
  int fits(double allowanceUs) =>
      allowanceUs <= 0 ? 0 : (allowanceUs / usPerUnit).floor();
  final at1x = fits(_gate1x - s.restP99Us);
  final at25x = fits((_gate25x - s.rest4P99Us) / _holdSteps);
  final paper1x = fits(_gate1x - 800);
  const paper25x = 0; // 4 × 0.8 ms is the whole 3.2 ms
  report('  budgets that fit (a unit at its p95 cost, the rest at its p99): '
      '1x ${_units(at1x)}; 25x with the hold ${_units(at25x)}; on §15.1\'s '
      'table rest (0.8 ms a sub-step) 1x ${_units(paper1x)}, 25x '
      '${_units(paper25x)}');
  final passUnits = units.steady.mid;
  final epochSteps = usOf(AgentTuning.congestionEpochS) ~/ kStepUs;
  for (final b in {_before, shipped, at1x, at25x, 12000, 6000}) {
    if (b <= 0) continue;
    report('    at ${_units(b)} a steady pass is '
        '${f(passUnits / b, 1)} sub-steps of work, publishing every '
        '${(passUnits / b / epochSteps).ceil()} pictures');
  }

  // The shipped default, held: the per-sub-step cost scales with it, and the
  // pass still publishes.
  expect(run.published, isNotEmpty, reason: 'the pass publishes');
  if (shipped != _before) {
    final now = _drive(a, shadow, shipped, 2000);
    report('  at the shipped default:');
    now.summary().show(shipped);
    expect(now.published, isNotEmpty, reason: 'the pass publishes');
  }
}

/// The budget 474c7aa shipped, before it was benched.
const int _before = 24000;

String _units(int u) => u >= 1000 ? '${f(u / 1000, 1)}k units' : '$u units';

/// Street lots someone zoned or built on: the lots the pass samples noise at.
int _sampledLots(CitySim city) {
  final g = city.roadGraph;
  var n = 0;
  for (var i = 0; i < g.lotCount; i++) {
    final id = g.lotIds[i];
    if (city.parcelBuildings.containsKey(id)) {
      n++;
      continue;
    }
    final p = city.layout.parcelById(id);
    if (p != null && p.use != ParcelUse.unzoned) n++;
  }
  return n;
}

/// [steps] sub-steps of [a], each followed by [shadow]'s tick at [budget]:
/// both timed apart.
_Run _drive(
    CityAgents a, AgentTrafficReadout shadow, int budget, int steps) {
  final epochUs = usOf(AgentTuning.congestionEpochS);
  final run = _Run();
  final sw = Stopwatch();
  final usPerTick = 1e6 / sw.frequency;
  for (var i = 0; i < steps; i++) {
    final t0 = a.timeUs;
    AgentTuning.readoutWorkPerStep = 0;
    sw
      ..reset()
      ..start();
    a.advance(kStepS);
    sw.stop();
    run.rest.add(sw.elapsedTicks * usPerTick);
    expect(a.timeUs - t0, kStepUs, reason: 'one sub-step');
    final picture = a.timeUs % epochUs == 0;
    final before = shadow.publishedPasses;
    AgentTuning.readoutWorkPerStep = budget;
    sw
      ..reset()
      ..start();
    shadow.tick(picture: picture);
    sw.stop();
    run.read.add(sw.elapsedTicks * usPerTick);
    run.picture.add(picture);
    if (shadow.publishedPasses != before) run.published.add(i);
    run.sumLive += a.liveVehicles;
    run.maxLive = math.max(run.maxLive, a.liveVehicles);
  }
  AgentTuning.readoutWorkPerStep = budget;
  return run;
}

class _Run {
  final read = <double>[], rest = <double>[];
  final picture = <bool>[];
  final published = <int>[];
  int sumLive = 0, maxLive = 0;

  double get meanLive => read.isEmpty ? 0 : sumLive / read.length;

  _Summary summary() => _Summary(this);
}

class _Summary {
  _Summary(_Run r) {
    final n = r.read.length;
    read = r.read;
    rest = r.rest;
    total = [for (var i = 0; i < n; i++) r.read[i] + r.rest[i]];
    // A sub-step with the pass at work: at least a tenth of the p95 tick. A
    // pass that finished waits for its picture at a few µs a tick.
    final cut = 0.1 * percentile(r.read, 0.95);
    working = [
      for (final x in r.read)
        if (x >= cut) x,
    ];
    // At full budget: a working sub-step whose neighbours both work too, so
    // neither the pass's first nor its last, partial one.
    full = [
      for (var i = 1; i + 1 < n; i++)
        if (r.read[i - 1] >= cut && r.read[i] >= cut && r.read[i + 1] >= cut)
          r.read[i],
    ];
    read4 = _windows(r.read, _holdSteps);
    total4 = _windows(total, _holdSteps);
    rest4 = _windows(r.rest, _holdSteps);
    read3 = _windows(r.read, _tickSteps);
    total7 = _windows(total, _holdSteps + _tickSteps);
    final gaps = [
      for (var k = 1; k < r.published.length; k++)
        (r.published[k] - r.published[k - 1]).toDouble(),
    ];
    final epochSteps = usOf(AgentTuning.congestionEpochS) ~/ kStepUs;
    picturesPerPassP50 = percentile(gaps, 0.5) / epochSteps;
    picturesPerPassMax = percentile(gaps, 1) / epochSteps;
    passes = r.published.length;
    workingShare = n == 0 ? 0 : working.length / n;
    restAtPicture = [
      for (var i = 0; i < n; i++)
        if (r.picture[i]) r.rest[i],
    ];
    restElse = [
      for (var i = 0; i < n; i++)
        if (!r.picture[i]) r.rest[i],
    ];
    readAtPicture = [
      for (var i = 0; i < n; i++)
        if (r.picture[i]) r.read[i],
    ];
  }

  late final List<double> restAtPicture, restElse, readAtPicture;
  late final List<double> read, rest, total, working, full;
  late final List<double> read4, total4, rest4, read3, total7;
  late final double picturesPerPassP50, picturesPerPassMax, workingShare;
  late final int passes;

  double get restP99Us => percentile(rest, 0.99);
  double get rest4P99Us => percentile(rest4, 0.99);
  double get fullP50Us => percentile(full.isEmpty ? working : full, 0.5);
  double get fullP95Us => percentile(full.isEmpty ? working : full, 0.95);

  static String _ms(double us) => f(us / 1000, 3);

  static String _pct(List<double> xs) => 'p50 ${_ms(percentile(xs, 0.5))} / '
      'p95 ${_ms(percentile(xs, 0.95))} / p99 ${_ms(percentile(xs, 0.99))} / '
      'max ${_ms(percentile(xs, 1))} ms';

  void show(int budget) {
    report('  at ${_units(budget)}, over ${read.length} sub-steps, $passes '
        'passes published, one every ${f(picturesPerPassP50, 1)} pictures '
        '(p50; max ${f(picturesPerPassMax, 1)}); the pass at work in '
        '${f(workingShare * 100, 0)}% of sub-steps');
    report('    readout tick, every sub-step: ${_pct(read)}');
    report('    readout tick, sub-steps at work: ${_pct(working)}; at full '
        'budget ${_pct(full)}');
    report('    readout tick at a picture (publish, begin): '
        '${_pct(readAtPicture)}');
    report('    the rest of the sub-step: ${_pct(rest)}; at a picture (the '
        'building sync, the epoch) ${_pct(restAtPicture)}, else '
        '${_pct(restElse)}');
    report('    1x frame (one sub-step, rest + readout): ${_pct(total)} '
        'against 1.5 ms: ${_verdict(total, _gate1x)}');
    report('    25x hold frame (4 sub-steps): readout ${_pct(read4)}; rest '
        '${_pct(rest4)}; together ${_pct(total4)} against 3.2 ms: '
        '${_verdict(total4, _gate25x)} (the readout alone: '
        '${_verdict(read4, _gate25x)})');
    report('    25x tick (3 sub-steps) readout ${_pct(read3)}; a hold frame '
        'one tick past its budget (7 sub-steps) together ${_pct(total7)}');
  }

  static String _verdict(List<double> xs, double gateUs) {
    final max = percentile(xs, 1), p99 = percentile(xs, 0.99);
    if (max <= gateUs) return 'PASS (every frame)';
    if (p99 <= gateUs) return 'FAIL at max, PASS at p99';
    return 'FAIL (p99 too)';
  }
}

/// Sums of every [w] consecutive samples.
List<double> _windows(List<double> xs, int w) {
  if (xs.length < w) return const [];
  final out = <double>[];
  var sum = 0.0;
  for (var i = 0; i < xs.length; i++) {
    sum += xs[i];
    if (i >= w) sum -= xs[i - w];
    if (i >= w - 1) out.add(sum);
  }
  return out;
}

typedef _Bracket = ({int lo, int hi});

extension on _Bracket {
  double get mid => (lo + hi) / 2;
}

/// The work units of a first pass and of a steady one, each bracketed to
/// within [b], and a steady pass timed whole.
({_Bracket first, _Bracket steady, double wholeMs}) _countUnits(
    CityAgents a, CitySim city, int b) {
  final counter = AgentTrafficReadout(a, city.roadTraffic);
  final whole = AgentTrafficReadout(a, city.roadTraffic);
  const all = 1 << 30;
  final epochSteps = usOf(AgentTuning.congestionEpochS) ~/ kStepUs;
  void toNextPicture() {
    AgentTuning.readoutWorkPerStep = 0;
    final epochUs = usOf(AgentTuning.congestionEpochS);
    do {
      a.advance(kStepS);
    } while (a.timeUs % epochUs != 0);
  }

  toNextPicture();
  // The first pass, on both: counted on one, run whole on the other.
  AgentTuning.readoutWorkPerStep = 0;
  counter.tick(picture: true);
  final first = _countToDone(counter, b);
  AgentTuning.readoutWorkPerStep = all;
  whole.tick(picture: true);
  // The counter began again on the same picture: finish that pass, which
  // carried every lot, so the next is begun on loads that moved.
  counter.tick(picture: false);

  final wholeMs = <double>[];
  _Bracket? steady;
  for (var k = 0; k < 5; k++) {
    for (var i = 0; i < epochSteps; i++) {
      AgentTuning.readoutWorkPerStep = 0;
      a.advance(kStepS);
    }
    expect(a.timeUs % usOf(AgentTuning.congestionEpochS), 0);
    AgentTuning.readoutWorkPerStep = all;
    final before = whole.publishedPasses;
    final sw = Stopwatch()..start();
    whole.tick(picture: true);
    wholeMs.add(sw.elapsedMicroseconds / 1000);
    expect(whole.publishedPasses, before + 1, reason: 'a pass, whole');
    if (k == 0) {
      AgentTuning.readoutWorkPerStep = 0;
      counter.tick(picture: true); // publishes the carried pass, begins anew
      steady = _countToDone(counter, b);
    }
  }
  return (first: first, steady: steady!, wholeMs: percentile(wholeMs, 0.5));
}

/// Work units of the pass [r] has just begun (none done), to within [b]:
/// calls of [b] until a zero-budget tick at a picture publishes it. Each call
/// does at least [b] units but the last, and overruns by one item at most
/// (a lot's noise sample), so the pass is (calls − 1)·b .. calls·b units.
_Bracket _countToDone(AgentTrafficReadout r, int b) {
  final before = r.publishedPasses;
  var calls = 0;
  while (true) {
    AgentTuning.readoutWorkPerStep = b;
    r.tick(picture: false);
    calls++;
    AgentTuning.readoutWorkPerStep = 0;
    r.tick(picture: true);
    if (r.publishedPasses != before) break;
    if (calls > 1 << 22) throw StateError('the pass never finished');
  }
  return (lo: (calls - 1) * b, hi: calls * b);
}
