// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the traffic benches share (docs/plans/agent-traffic.md §15.5).
///
/// A bench is named `bench: …` and skipped unless asked for:
///
/// - `--dart-define=ACRO_PERF=true` runs it with its wall-clock gates on.
///   Take that reading with the machine otherwise quiet: the suite runs
///   files in parallel on every core, and a timing taken under that load
///   says nothing about the code (road_traffic_perf_test.dart).
/// - `--dart-define=ACRO_BENCH=true` runs it to print its numbers, holding
///   only the counted gates, which are the same on every machine.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether the wall-clock gates hold.
const bool kPerf = bool.fromEnvironment('ACRO_PERF');

/// Whether the benches run at all.
const bool kBench = kPerf || bool.fromEnvironment('ACRO_BENCH');

/// What a bench's `skip:` is: null when it runs.
const String? benchSkip = kBench
    ? null
    : 'a bench: run with --dart-define=ACRO_PERF=true (or ACRO_BENCH=true)';

/// Like the repo's other benches.
const Timeout benchTimeout = Timeout(Duration(minutes: 5));

/// Prints one line of a bench's report.
void report(String line) {
  // ignore: avoid_print
  print(line);
}

/// The [p]th percentile (0..1) of [samples], nearest rank.
double percentile(List<double> samples, double p) {
  if (samples.isEmpty) return double.nan;
  final s = [...samples]..sort();
  final k = (p * s.length).ceil() - 1;
  return s[math.max(0, math.min(s.length - 1, k))];
}

/// [x] to [digits] places.
String f(double x, [int digits = 2]) => x.toStringAsFixed(digits);

/// An [n] × [n] grid of streets [spacingM] apart, centred on the origin,
/// each overrunning the outermost cross streets by half a block: the
/// §15.5 grid. A 30 × 30 grid is 1,860 road pieces and 3,720 directed
/// edges. Laid on a bare layout with no lots, which the benches never read.
CityLayout gridLayout(int n, {double spacingM = 200}) {
  final layout = CityLayout();
  final half = (n - 1) * spacingM / 2;
  final lo = -half - spacingM / 2, hi = half + spacingM / 2;
  for (var i = 0; i < n; i++) {
    final at = -half + i * spacingM;
    layout.commitRoad(
        controls: [Vec2(at, lo), Vec2(at, hi)], regenerateLots: false);
    layout.commitRoad(
        controls: [Vec2(lo, at), Vec2(hi, at)], regenerateLots: false);
  }
  return layout;
}
