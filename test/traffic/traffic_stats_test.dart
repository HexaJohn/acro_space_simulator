// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_stats.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';

/// What the agents measure for the economy and the views (docs/plans/
/// agent-traffic.md §4.2, §12.3 E4): commute efficiency by the design's
/// formula, and congestion read from vehicle speeds — near nothing on a
/// free road, near everything behind a car that will not move.
void main() {
  tearDown(AgentTuning.reset);

  test('commuteEff is 1 with nothing measured, and follows the design\'s '
      'formula after', () {
    final s = TrafficStats();
    expect(s.commuteEff, 1.0);
    expect(s.failedShare, 0);
    for (var i = 0; i < 9; i++) {
      s.tripDone(150, 100);
    }
    s.tripFailed();
    expect(s.tripRatio, closeTo(1.5, 1e-9));
    expect(s.avgTripS, closeTo(150, 1e-9));
    expect(s.failedShare, closeTo(0.1, 1e-9));
    expect(s.commuteEff, closeTo(1 - 0.4 * (0.5 * 0.5 + 0.1), 1e-9));

    // A trip ten times its free-flow time counts as three: the floor.
    final slow = TrafficStats()..tripDone(1000, 100);
    expect(slow.tripRatio, kTripRatioCap);
    expect(slow.commuteEff, closeTo(0.6, 1e-9));
    final lost = TrafficStats();
    for (var i = 0; i < 5; i++) {
      lost.tripFailed();
    }
    expect(lost.commuteEff, kCommuteEffFloor);
  });

  test('the failed share forgets what is older than ten minutes', () {
    final d = Drive(straightRoad());
    final s = TrafficStats()..bind(d.lg);
    s.tripFailed();
    s.tripDone(100, 100);
    for (var i = 0; i < 9; i++) {
      s.epoch(d.mover, windowEnd: true);
    }
    expect(s.failedShare, closeTo(0.5, 1e-9), reason: 'nine minutes on');
    s.epoch(d.mover, windowEnd: true);
    expect(s.failedShare, 0, reason: 'ten minutes on, it has fallen out');
  });

  test('congestion reads near nothing on a free road, and near everything '
      'behind a car that will not move', () {
    // Free: cars at the limit, far from their stops.
    final free = Drive(straightRoad(lengthM: 4000));
    final e = edgeOf(free.lg, 'r0');
    final lim = free.lg.edgeLimit[e].toDouble();
    for (var i = 0; i < 5; i++) {
      free.trip(e, 20.0 + 60 * i, e, 3900, speed: lim);
    }
    final sf = _measure(free, 60);
    expect(sf.congestionIndex, lessThan(0.05));
    expect(sf.congestionOf('r0'), lessThan(0.05));
    expect(sf.hasRun, isTrue);

    // Jammed: a car stalled at the front, ten queued behind it.
    final jam = Drive(straightRoad(lengthM: 2000));
    final j = edgeOf(jam.lg, 'r0');
    final lead = jam.trip(j, 400, j, 1900, checkRoom: false);
    jam.table.stall(lead);
    for (var i = 1; i <= 10; i++) {
      jam.trip(j, 400.0 - 12 * i, j, 1900, checkRoom: false);
    }
    final sj = _measure(jam, 60);
    expect(sj.congestionIndex, greaterThan(0.9));
    expect(sj.congestionOf('r0'), greaterThan(0.9));
    expect(sj.peakCongestion, sj.congestionOf('r0'));
    expect(sj.averageCongestion, sj.congestionIndex);
    expect(sj.congestionOf('no-such-road'), 0);
  });
}

/// Runs [d] for [seconds], rolling a [TrafficStats] every 2 s epoch and
/// closing its window every minute, as the facade does.
TrafficStats _measure(Drive d, double seconds) {
  final s = TrafficStats()..bind(d.lg);
  var steps = 0;
  d.run(seconds, () {
    steps++;
    if (steps % 10 == 0) s.epoch(d.mover, windowEnd: steps % 300 == 0);
  });
  return s;
}
