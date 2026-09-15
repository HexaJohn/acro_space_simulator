// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
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

  group('each piece is pictured on its own (§12.3)', () {
    // A long road with a dead end lying against it part way, laid raw so
    // nothing is split (road_graph_directed_test): two pieces of one road.
    // The mover's books are written by hand, an epoch at a time, so every
    // count is known.
    ({Drive d, TrafficStats s, int west, int east}) tee() {
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'main', controls: [Vec2(0, 0), Vec2(2000, 0)]))
        ..addRoad(const RoadSpline(
            id: 'stub', controls: [Vec2(1000, 5), Vec2(1000, 300)]));
      final d = Drive(lanesOf(layout));
      final g = d.lg.graph;
      var road = -1;
      for (var r = 0; r < g.roadCount; r++) {
        if (g.roadFirstPiece[r + 1] - g.roadFirstPiece[r] == 2) road = r;
      }
      expect(road, greaterThanOrEqualTo(0), reason: 'a road of two pieces');
      final west = g.roadFirstPiece[road];
      return (d: d, s: TrafficStats()..bind(d.lg), west: west, east: west + 1);
    }

    /// [epochs] congestion epochs, a window closing every thirty, with
    /// [exits] vehicles leaving [edge] in each and [drivenM] of [limitM]
    /// driven on it.
    void roll(Drive d, TrafficStats s, int edge, int epochs,
        {int exits = 0, double drivenM = 0, double limitM = 0}) {
      for (var i = 0; i < epochs; i++) {
        d.mover.edgeExits[edge] = exits;
        d.mover.edgeDrivenM[edge] = drivenM;
        d.mover.edgeLimitM[edge] = limitM;
        _epochs[s] = (_epochs[s] ?? 0) + 1;
        s.epoch(d.mover, windowEnd: _epochs[s]! % 30 == 0);
      }
    }

    test('a jam on one piece is that piece\'s congestion, not its quiet '
        'neighbour\'s; the road reads its worst piece', () {
      final t = tee();
      final g = t.d.lg.graph;
      final jammed = g.pieceFwdEdge[t.west];
      roll(t.d, t.s, jammed, 30, drivenM: 10, limitM: 100);
      expect(t.s.pieceCongestion[t.west], closeTo(0.9, 1e-6));
      expect(t.s.pieceCongestion[t.east], 0);
      final id = g.roads[g.pieceRoad[t.west]].id;
      expect(t.s.congestionOf(id), t.s.pieceCongestion[t.west]);
      expect(t.s.peakCongestion, t.s.congestionOf(id));
    });

    test('flow is vehicles through a piece a minute over the time the books '
        'cover, never under one window, the last ten minutes once run', () {
      final t = tee();
      final g = t.d.lg.graph;
      final e = g.pieceFwdEdge[t.west];
      final id = g.roads[g.pieceRoad[t.west]].id;
      // One vehicle every 2 s: 30 a minute.
      roll(t.d, t.s, e, 10, exits: 1);
      expect(t.s.flowWindowS, 60,
          reason: '20 s run: taken over one window, not twenty seconds');
      expect(t.s.pieceFlowPerMin[t.west], closeTo(10, 1e-4));
      expect(t.s.pieceFlowPerMin[t.east], 0);
      roll(t.d, t.s, e, 35, exits: 1);
      expect(t.s.flowWindowS, 90);
      expect(t.s.pieceFlowPerMin[t.west], closeTo(30, 1e-4),
          reason: 'a minute and a half run: its rate, not a tenth of 45');
      expect(t.s.volumeOf(id), 45, reason: 'the road\'s volume is unchanged');
      roll(t.d, t.s, e, 270, exits: 1);
      expect(t.s.flowWindowS, 570,
          reason: 'ten minutes and a half run: the first minute dropped, '
              'nine whole ones in the books and the half of the one begun');
      expect(t.s.pieceFlowPerMin[t.west], closeTo(30, 1e-4));
      roll(t.d, t.s, e, 15);
      expect(t.s.flowWindowS, 540,
          reason: 'eleven minutes run, a window just closed: nine whole '
              'minutes in the books');
      expect(t.s.pieceFlowPerMin[t.west], closeTo(255 * 60 / 540, 1e-4),
          reason: 'thirty quiet seconds: 255 through in those nine minutes');
    });

    test('books started afresh on a new network cover only their own time',
        () {
      final t = tee();
      final g = t.d.lg.graph;
      roll(t.d, t.s, g.pieceFwdEdge[t.west], 600, exits: 1);
      expect(t.s.flowWindowS, 540);
      final other = straightRoad();
      final d = Drive(other);
      t.s.bind(other);
      roll(d, t.s, other.graph.pieceFwdEdge[0], 45, exits: 1);
      expect(t.s.flowWindowS, 90);
      expect(t.s.pieceFlowPerMin[0], closeTo(30, 1e-4));
    });
  });
}

/// Epochs each statistics has rolled in the piece tests, for their windows.
final Map<TrafficStats, int> _epochs = Map.identity();

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
