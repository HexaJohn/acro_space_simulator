// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_trips.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

/// §6.1's rush-hour multiplier: two peaks in the day, a flat rate everywhere
/// else, and the SAME number of trips either way.
///
/// The last of those is the property that makes rush hour a shape and not a
/// demand knob. `rush` divides the two dwells §6.4 marks, so the wake-up
/// RATE it produces is proportional to it, and a day's throughput is its
/// integral over the day. A positive bump alone would raise that integral by
/// 15% — a colony with rush hour would simply make more trips — so the table
/// carries a shallow trough either side of each peak, and the kernel sums to
/// nothing. Rush hour borrows its trips from the hours around it.
void main() {
  tearDown(AgentTuning.reset);

  test('it peaks at day phase 0.30 and 0.72, and reads 1 away from them', () {
    expect(CitizenTrips.rush(0.30), closeTo(1 + AgentTuning.rushAmp, 1e-12));
    expect(CitizenTrips.rush(0.72), closeTo(1 + AgentTuning.rushAmp, 1e-12));
    // Each peak is a maximum, not merely a high value.
    for (final d in const [0.01, 0.02, 0.05, 0.1, 0.2]) {
      expect(CitizenTrips.rush(0.30 - d), lessThan(CitizenTrips.rush(0.30)));
      expect(CitizenTrips.rush(0.30 + d), lessThan(CitizenTrips.rush(0.30)));
      expect(CitizenTrips.rush(0.72 - d), lessThan(CitizenTrips.rush(0.72)));
      expect(CitizenTrips.rush(0.72 + d), lessThan(CitizenTrips.rush(0.72)));
    }
    // A quarter day either side of a peak the bump is over: the small hours
    // and the very start of the day run at the flat rate exactly.
    for (final p in const [0.0, 0.01, 0.05, 0.97, 0.99]) {
      expect(CitizenTrips.rush(p), 1.0, reason: 'phase $p is off both bumps');
    }
  });

  test('over a day it integrates to the flat rate: the same trips, clustered',
      () {
    // A midpoint sum of 65,536 samples. The curve is piecewise linear with
    // 128 kinks, so the sum is exact to about 1e-10; the tolerance below is
    // 1e-6, which is four orders of room and still far tighter than the 15%
    // an unnormalised Gaussian bump would show.
    expect(_meanOverDay(), closeTo(1.0, 1e-6));

    // And it is an average of something that moves: half again as busy at
    // the peak, a quarter quieter in the lull between.
    var lo = 9.0, hi = -9.0;
    for (var i = 0; i < 4096; i++) {
      final v = CitizenTrips.rush((i + 0.5) / 4096);
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    expect(hi, closeTo(1.6, 1e-3));
    expect(lo, inInclusiveRange(0.6, 0.9));
  });

  test('rushAmp is the height of the bumps, and 0 is a flat day', () {
    AgentTuning.rushAmp = 0;
    for (final p in const [0.0, 0.1, 0.30, 0.5, 0.72, 0.9]) {
      expect(CitizenTrips.rush(p), 1.0);
    }
    AgentTuning.rushAmp = 1.5;
    expect(CitizenTrips.rush(0.30), closeTo(2.5, 1e-12));
    // Raising it cannot break the promise: the kernel still sums to nothing,
    // so the day's throughput is unchanged however tall the peaks are.
    expect(_meanOverDay(), closeTo(1.0, 1e-6));
  });

  test('the phase wraps, and nonsense reads as the flat rate', () {
    expect(CitizenTrips.rush(1.30), closeTo(CitizenTrips.rush(0.30), 1e-15));
    expect(CitizenTrips.rush(-0.70), closeTo(CitizenTrips.rush(0.30), 1e-15));
    expect(CitizenTrips.rush(7.72), closeTo(CitizenTrips.rush(0.72), 1e-15));
    // The distance is circular, so midnight is read from both sides and
    // reads the same either way.
    expect(CitizenTrips.rush(-0.01), closeTo(CitizenTrips.rush(0.99), 1e-15));
    // The shoulders, where rush hour's trips were borrowed from, are the
    // part of the day that runs BELOW the flat rate.
    expect(CitizenTrips.rush(0.45), lessThan(1.0));
    expect(CitizenTrips.rush(0.50), lessThan(1.0));
    expect(CitizenTrips.rush(0.87), lessThan(1.0));
    expect(CitizenTrips.rush(double.nan), 1.0);
    expect(CitizenTrips.rush(double.infinity), 1.0);
  });

  test('no exp runs for it, in the tick or at init: the bump is a table', () {
    final src = File(_source).readAsStringSync();
    expect(src.contains("import 'dart:math'"), isFalse,
        reason: 'citizen_trips.dart must not reach for the platform maths: '
            'exp and log are free to round differently per build target '
            '(D27), so the bump ships as 64 written-out samples');
    expect(RegExp(r'\bexp\s*\(').hasMatch(src), isFalse);
    expect(RegExp(r'\bmath\.').hasMatch(src), isFalse);
  });
}

/// The mean of `rush` over one whole day, by midpoint sum.
double _meanOverDay() {
  const n = 1 << 16;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += CitizenTrips.rush((i + 0.5) / n);
  }
  return sum / n;
}

const String _source =
    'lib/domain/colony/city/traffic/citizen_trips.dart';
