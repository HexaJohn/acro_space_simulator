// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:flutter_test/flutter_test.dart';

/// Agent time and the tables that stand in for `exp` and `log`.
///
/// The clock's one promise is the one the determinism tests stand on: however
/// the host slices a stretch of time into ticks, the agents run the same
/// sub-steps at the same agent times.
void main() {
  group('AgentClock', () {
    /// The agent times at which the sub-steps [dts] make ready end.
    List<int> stepsOf(Iterable<double> dts, AgentClock clock) {
      final ends = <int>[];
      for (final dt in dts) {
        clock.feed(dt);
        while (clock.takeStep()) {
          ends.add(clock.timeUs);
        }
      }
      return ends;
    }

    test('a sub-step is 0.2 s of whole microseconds', () {
      expect(kStepUs, 200000);
      expect(kStepS, 0.2);
      expect(usOf(0.02), 20000);
      expect(usOf(0.0000004), 0, reason: 'rounded, not truncated up');
      expect(secondsOf(500000), 0.5);
    });

    test('any partition of the same time runs the same sub-steps', () {
      final fine = AgentClock();
      final coarse = AgentClock();
      final steps = stepsOf(List.filled(3000, 0.02), fine);
      expect(stepsOf(List.filled(120, 0.5), coarse), steps);
      expect(steps, hasLength(300));
      expect(steps.last, 60 * kUsPerSecond);
      expect(coarse.accumUs, fine.accumUs);

      // And a ragged partition of the same 60 s: pieces of up to half a
      // second, down to one microsecond.
      final rng = TrafficRng(11);
      final pieces = <double>[];
      for (var left = 60 * kUsPerSecond; left > 0;) {
        final us = math.min(left, 1 + rng.nextInt(500000));
        pieces.add(us / kUsPerSecond);
        left -= us;
      }
      final ragged = AgentClock();
      expect(stepsOf(pieces, ragged), steps);
      expect(ragged.accumUs, fine.accumUs);
    });

    test('a tick of at most 0.5 s makes at most three sub-steps ready', () {
      final clock = AgentClock();
      var most = 0;
      for (var i = 0; i < 100; i++) {
        clock.feed(0.5);
        var n = 0;
        while (clock.takeStep()) {
          n++;
        }
        most = math.max(most, n);
      }
      expect(most, 3);
      expect(clock.timeUs, 50 * kUsPerSecond);
      expect(clock.pendingSteps, 0);
    });

    test('stepsOnFeed prices a tick exactly as feeding it would', () {
      final clock = AgentClock();
      final rng = TrafficRng(4);
      for (var i = 0; i < 500; i++) {
        final dt = rng.nextBetween(0, 0.5);
        final priced = clock.stepsOnFeed(dt);
        clock.feed(dt);
        var n = 0;
        while (clock.takeStep()) {
          n++;
        }
        expect(n, priced);
      }
    });

    test('a tick that is not a positive time feeds nothing', () {
      final clock = AgentClock()..feed(0.1);
      for (final dt in const [0.0, -0.5, double.nan, double.infinity]) {
        clock.feed(dt);
        expect(clock.stepsOnFeed(dt), 0);
      }
      expect(clock.accumUs, 100000);
    });

    test('every fifth sub-step ends on a whole agent second', () {
      final clock = AgentClock();
      final whole = <int>[];
      for (var i = 1; i <= 20; i++) {
        clock.feed(0.2);
        expect(clock.takeStep(), isTrue);
        if (clock.onWholeSecond) whole.add(i);
      }
      expect(whole, const [5, 10, 15, 20]);
      expect(clock.timeS, 4.0);
    });
  });

  group('Lut', () {
    test('expNeg tracks e^-x within 1e-5, falling, and holds its ends', () {
      var worst = 0.0;
      var last = double.infinity;
      var falls = true;
      for (var i = 0; i <= 20000; i++) {
        final x = i * Lut.expNegMaxX / 20000;
        final v = Lut.expNeg(x);
        worst = math.max(worst, (v - math.exp(-x)).abs());
        if (v > last) falls = false;
        last = v;
      }
      expect(worst, lessThan(1e-5));
      expect(falls, isTrue);
      expect(Lut.expNeg(0), 1.0);
      expect(Lut.expNeg(-3), 1.0);
      expect(Lut.expNeg(1e9), closeTo(0, 1e-6));
    });

    test('gumbel is the minimum-type Gumbel: falling, with mean −γ', () {
      final g = [for (var i = 0; i < Lut.gumbelSize; i++) Lut.gumbel(i)];
      for (var i = 1; i < g.length; i++) {
        expect(g[i], lessThan(g[i - 1]));
      }
      expect(g.reduce((a, b) => a + b) / g.length, closeTo(-0.5772, 0.01));
      expect(g.first, closeTo(2.03, 0.01));
      expect(g.last, closeTo(-7.62, 0.01));
      expect(Lut.gumbel(Lut.gumbelSize + 3), g[3], reason: 'indices wrap');
    });

    test('argmin(cost + β·G) chooses as the logit does', () {
      // Every pair of table entries, weighed exactly: how often the cheap
      // option (cost 0) beats a dearer one. The logit says 1/(1 + e^-Δ/β).
      const beta = 45.0;
      final g = [for (var i = 0; i < Lut.gumbelSize; i++) beta * Lut.gumbel(i)];
      for (final gap in const [0.0, 20.0, 45.0, 90.0]) {
        var cheap = 0;
        for (var i = 0; i < g.length; i++) {
          for (var k = 0; k < g.length; k++) {
            if (g[i] < gap + g[k]) cheap++;
          }
        }
        expect(cheap / (g.length * g.length),
            closeTo(1 / (1 + math.exp(-gap / beta)), 0.01),
            reason: 'Δ = $gap s');
      }
    });
  });
}
