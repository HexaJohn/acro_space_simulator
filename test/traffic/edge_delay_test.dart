// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/edge_delay.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_planner.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_state_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/path_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// §17.1 `edge_delay_test` (docs/plans/agent-traffic.md §4.2, D11): what a
/// new trip is priced by. Signed observations against the driver's own free
/// time and the expected control delay, an EMA weighted by the edge's flow
/// from the e^-x table, the live queue beyond the first car of each lane, a
/// fresh buffer every 2 s that no reader ever sees written — and an empty
/// network that prices exactly as slice 1's free flow did.
void main() {
  tearDown(AgentTuning.reset);

  group('the EMA', () {
    test('its weight is 1 − e^(−1/nEff) from the table, nEff the last '
        'window\'s departures clamped to 8–40', () {
      for (var n = -3; n <= 60; n++) {
        final k = n < kMinEffectiveFlow
            ? kMinEffectiveFlow
            : (n > kMaxEffectiveFlow ? kMaxEffectiveFlow : n);
        expect(EdgeDelayTable.alphaFor(n), 1 - Lut.expNeg(1 / k),
            reason: 'flow $n');
      }
      expect(EdgeDelayTable.alphaFor(8),
          greaterThan(EdgeDelayTable.alphaFor(40)),
          reason: 'a busy edge averages over more observations');
    });

    test('takes signed observations one at a time — less J through a node, '
        'as they are at a stop — rolls flowPerMin every 60 s, and halves '
        'where a whole window saw no departure', () {
      final lg = crossroads();
      final d = Drive(lg)..step(); // sizes the mover's log
      final t = EdgeDelayTable()..bind(lg);
      final into = edgeNear(lg, const Vec2(-100, 0), const Vec2(1, 0));
      expect(lg.kindOf(lg.edgeTo[into]), NodeControlKind.allWayStop);
      expect(t.expectedControlDelayOf(into), kStopPenaltyS);

      final a8 = EdgeDelayTable.alphaFor(8);
      _book(d.mover, into, 9.0); // four seconds over the stop's five
      _book(d.mover, into, -3.0); // quicker than the stop: signed
      _book(d.mover, into, 2.0, atNode: false); // stopped on the edge
      t.absorb(d.mover);
      expect(d.mover.observationCount, 0, reason: 'the log is taken');
      var ema = 0.0;
      ema += a8 * (4.0 - ema);
      ema += a8 * (-8.0 - ema);
      ema += a8 * (2.0 - ema);
      expect(t.emaOf(into), closeTo(ema, 1e-9));
      expect(t.emaOf(into), lessThan(0), reason: 'signed, never clamped');

      // Departures fill the window running now; the minute's end makes them
      // the flow the next observations are weighed by.
      d.mover.edgeDeparts[into] = 20;
      t.epoch(d.mover, d.table, windowEnd: false);
      expect(t.flowThisWindow(into), 20);
      expect(t.flowPerMin(into), 0);
      expect(d.mover.edgeDeparts[into], 0, reason: 'the book is taken');
      t.epoch(d.mover, d.table, windowEnd: true);
      expect(t.flowPerMin(into), 20);
      expect(t.flowThisWindow(into), 0);
      expect(t.emaOf(into), closeTo(ema, 1e-9),
          reason: 'departures in the window: no decay');
      _book(d.mover, into, 25.0);
      t.absorb(d.mover);
      ema += EdgeDelayTable.alphaFor(20) * (20.0 - ema);
      expect(t.emaOf(into), closeTo(ema, 1e-9));

      // A minute nobody left the edge in: halved, and the flow is 0.
      t.epoch(d.mover, d.table, windowEnd: true);
      expect(t.flowPerMin(into), 0);
      expect(t.emaOf(into), closeTo(ema / 2, 1e-9));
    });

    test('a slow driver (f = 0.92) and a quick one (1.05) through a free '
        'edge each report about nothing: their own free time, not the '
        'limit\'s', () {
      for (final f in const [0.92, 1.05]) {
        final lg = _inLine();
        final d = Drive(lg);
        final t = EdgeDelayTable()..bind(lg);
        final a = edgeOf(lg, 'r0'), b = edgeOf(lg, 'r1'), c = edgeOf(lg, 'r2');
        expect(lg.kindOf(lg.edgeTo[b]), NodeControlKind.continuation);
        expect(t.expectedControlDelayOf(b), 0);
        final h = d.trip(a, 100, c, 400,
            speedFactor: f, speed: lg.edgeLimit[a] * f);
        expect(h, greaterThanOrEqualTo(0));
        final seen = <int, List<double>>{};
        d.run(200, () {
          for (var i = 0; i < d.mover.observationCount; i++) {
            (seen[d.mover.obsEdge[i]] ??= []).add(d.mover.obsS[i]);
          }
          t.absorb(d.mover);
        });
        expect(d.arrivedHandles, [h]);
        expect(seen[a], isNull,
            reason: 'it pulled out part way along r0: nothing to observe');
        expect(seen[b], hasLength(1));
        expect(seen[b]!.single.abs(), lessThan(0.25),
            reason: 'f = $f: within a sub-step of its own free time');
        expect(seen[c], hasLength(1), reason: 'its arrival on r2');
        expect(t.emaOf(b).abs(), lessThan(0.05));
      }
    });
  });

  group('the live queue', () {
    test('charges 2 s for every car standing beyond the first of each lane, '
        'shared by the lanes, clamped to 600 s', () {
      final lg = straightRoad(cls: RoadClass.avenue);
      final e = edgeOf(lg, 'r0');
      expect(lg.edgeLaneCount[e], 2);
      final d = Drive(lg);
      final t = EdgeDelayTable()..bind(lg);
      void standIn(int lane, int n, double from) {
        for (var i = 0; i < n; i++) {
          final h = d.trip(e, from - 12.0 * i, e, 1900,
              destMask: 1 << lane, checkRoom: false);
          expect(h, greaterThanOrEqualTo(0));
          d.table.stall(h);
        }
      }

      expect(t.publishNow(d.table), isTrue);
      expect(t.published![e], 0);
      standIn(1, 1, 900);
      t.publishNow(d.table);
      expect(t.published![e], 0, reason: 'one car: the red wait J prices');
      standIn(1, 9, 800);
      t.publishNow(d.table);
      expect(t.published![e], closeTo((10 - 2) * kQueueVehicleS / 2, 1e-6));
      standIn(0, 3, 900);
      t.publishNow(d.table);
      expect(t.published![e], closeTo((13 - 2) * kQueueVehicleS / 2, 1e-6));
      expect(t.published![lg.edgeReverse[e]], 0);

      // A measured delay above the queue is published as it is — and never
      // past 600 s.
      d.step();
      for (var i = 0; i < 40; i++) {
        _book(d.mover, e, 5000);
      }
      t.absorb(d.mover);
      t.publishNow(d.table);
      expect(t.published![e], kMaxDelayS);
    });
  });

  group('publishing', () {
    test('every 2 s of agent time a fresh buffer, never the last one, and '
        'the path queue prices by it', () {
      AgentTuning.commuteRatePerResident = 0.004;
      final a = livedIn();
      a.advance(kStepS);
      final t = a.delays!;
      final seen = <Float32List>{};
      var last = t.published;
      var publishes = t.publishes;
      for (var i = 0; i < 300; i++) {
        a.advance(kStepS);
        final now = t.published;
        if (a.timeUs % usOf(AgentTuning.congestionEpochS) == 0) {
          expect(t.publishes, publishes + 1, reason: 'at ${a.timeUs}');
          expect(now, isNot(same(last)), reason: 'a fresh buffer');
          publishes = t.publishes;
        } else {
          expect(now, same(last), reason: 'between epochs, at ${a.timeUs}');
        }
        expect(a.pathQueue!.delays, same(now));
        if (now != null) seen.add(now);
        last = now;
      }
      expect(t.publishes, a.timeUs ~/ usOf(AgentTuning.congestionEpochS));
      expect(t.skippedPublishes, 0);
      expect(Set<Float32List>.identity()..addAll(seen),
          hasLength(lessThanOrEqualTo(kDelayPoolSize)),
          reason: 'a pool of three, rotated');
      expect(a.stats.spawned, greaterThan(5), reason: 'the town drove');
    });

    test('a suspended search keeps pricing by the buffer it began with '
        'across publishes; no buffer a search holds, nor the last published, '
        'is written; with all three held, the publish is skipped', () {
      final lg = lanesOf(_gridLayout(4));
      final cost = RouteCost(lg);
      final d = Drive(lg)..step();
      final q = PathQueue()..bind(cost);
      final t = EdgeDelayTable(holders: q)..bind(lg);
      final from = edgeNear(lg, const Vec2(-350, -300), const Vec2(1, 0));
      final to = edgeNear(lg, const Vec2(350, 300), const Vec2(1, 0));
      final ends = PathEnds()
        ..addOrigin(from, 10)
        ..addGoal(to, 10, laneMask: 1);

      expect(t.publishNow(d.table), isTrue);
      final b0 = q.delays = t.published!;
      final free = SearchContext()
        ..begin(cost, ends, delays: b0)
        ..step(1 << 30);
      final freeRoute = free.path.sublist(0, free.pathLength);

      // The car trip begins on b0 and stops at the end of its budget.
      q.enqueue(PathPriority.car,
          requester: 1, origin: from, originS: 10, dest: to, destS: 10);
      final log = _Log();
      expect(q.pump(5, _ByEdge(), log), 5);
      expect(q.searching, 1);
      expect(q.holdsDelays(b0), isTrue);
      final was0 = Float32List.fromList(b0);

      // Then its route jams: every edge of it but its ends, dear.
      for (var k = 0; k < 60; k++) {
        for (var i = 1; i + 1 < freeRoute.length; i++) {
          _book(d.mover, freeRoute[i], 300);
        }
        t.absorb(d.mover);
      }
      expect(t.publishNow(d.table), isTrue);
      final b1 = q.delays = t.published!;
      expect(b1, isNot(same(b0)));
      expect(b0, was0, reason: 'held by the car trip: never written');
      expect(b1[freeRoute[1]], greaterThan(100));

      // A service leg begins on b1, in a second context, and stops too.
      final from2 = edgeNear(lg, const Vec2(350, -300), const Vec2(-1, 0));
      final to2 = edgeNear(lg, const Vec2(-350, 300), const Vec2(-1, 0));
      q.enqueue(PathPriority.service,
          requester: 2, origin: from2, originS: 10, dest: to2, destS: 10);
      expect(q.pump(5, _ByEdge(), log), 5);
      expect(q.searching, 2);
      expect(q.holdsDelays(b1), isTrue);
      final was1 = Float32List.fromList(b1);

      expect(t.publishNow(d.table), isTrue);
      final b2 = q.delays = t.published!;
      expect(b2, isNot(same(b0)));
      expect(b2, isNot(same(b1)));
      // Every buffer held or last published: nothing is written.
      expect(t.publishNow(d.table), isFalse);
      expect(t.skippedPublishes, 1);
      expect(t.published, same(b2));
      expect(b0, was0);
      expect(b1, was1);

      // Both finish. The car trip is the route b0 priced — the free one,
      // jam or no jam — while a search begun now goes round the jam.
      q.pump(1 << 30, _ByEdge(), log);
      expect(log.order, [2, 1]);
      expect(edgesAlong(lg, log.routes[1]!), freeRoute);
      final now = SearchContext()
        ..begin(cost, ends, delays: b2)
        ..step(1 << 30);
      expect(now.path.sublist(0, now.pathLength), isNot(freeRoute));
      expect(q.holdsDelays(b0), isFalse);
      expect(t.publishNow(d.table), isTrue);
      expect(t.published, same(b0), reason: 'back in the pool once let go');
    });
  });

  group('an empty network', () {
    test('publishes D = +0.0 on every edge, and every plan prices and routes '
        'bit for bit as with no delay table at all', () {
      AgentTuning.commuteRatePerResident = 0;
      final a = agentsOn(town());
      runAgents(a, 30);
      final pub = a.delays!.published!;
      expect(a.pathQueue!.delays, same(pub));
      expect(pub.length, a.laneGraph!.edgeCount);
      for (var e = 0; e < pub.length; e++) {
        expect(pub[e], 0);
        expect(pub[e].isNegative, isFalse, reason: 'edge $e: +0.0');
      }

      // Free-flow plans, against the same plans priced by an all-zero
      // buffer: the same edges, lanes and cost, to the bit.
      final rng = TrafficRng(2026);
      for (var town = 0; town < 4; town++) {
        final lg = lanesOf(randomTownLayout(rng));
        final cost = RouteCost(lg);
        final zeros = Float32List(lg.edgeCount);
        for (var k = 0; k < 50; k++) {
          final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
          final ot = lg.edgeLen[o] * rng.nextUnit();
          final gt = lg.edgeLen[g] * rng.nextUnit();
          final ends = PathEnds()
            ..addOrigin(o, ot)
            ..addGoal(g, gt);
          final bare = SearchContext()
            ..begin(cost, ends)
            ..step(1 << 30);
          final priced = SearchContext()
            ..begin(cost, ends, delays: zeros)
            ..step(1 << 30);
          expect(priced.status, bare.status);
          if (bare.status != SearchStatus.found) continue;
          expect(priced.path.sublist(0, priced.pathLength),
              bare.path.sublist(0, bare.pathLength));
          expect(priced.cost, bare.cost, reason: 'to the bit');
          final p1 = LanePlanner(), p2 = LanePlanner();
          final ok1 = p1.plan(lg, bare.path, bare.pathLength);
          final ok2 = p2.plan(lg, priced.path, priced.pathLength);
          expect(ok2, ok1);
          if (ok1) {
            expect(p2.route.sublist(0, p2.routeLength),
                p1.route.sublist(0, p1.routeLength));
          }
          final fixed = PathEnds()
            ..addOrigin(o, ot, lane: lg.laneOf(o, 0))
            ..addGoal(g, gt);
          final s1 = LaneStateSearch()
            ..begin(cost, fixed)
            ..step(1 << 30);
          final s2 = LaneStateSearch()
            ..begin(cost, fixed, delays: zeros)
            ..step(1 << 30);
          expect(s2.status, s1.status);
          if (s1.status == SearchStatus.found) {
            expect(s2.route.sublist(0, s2.routeLength),
                s1.route.sublist(0, s1.routeLength));
            expect(s2.cost, s1.cost);
          }
        }
      }
    });

    test('with light traffic for 10 agent-minutes, a signalised crossing\'s '
        'approaches publish |D| < 1 s: the lights\' J is their mean control '
        'delay', () {
      var sumObs = 0.0, sumD = 0.0;
      var nObs = 0;
      for (final seed in _seeds) {
        final lg = lanesOf(_crossing(RoadClass.avenue));
        final d = Drive(lg);
        final t = EdgeDelayTable()..bind(lg);
        final centre = lg.edgeTo[edgeNear(lg, const Vec2(-100, 0), _dirs[0])];
        expect(lg.kindOf(centre), NodeControlKind.signals);
        for (var e = 0; e < lg.edgeCount; e++) {
          if (lg.edgeTo[e] != centre) continue;
          expect(t.expectedControlDelayOf(e), kSignalPenaltyS);
        }
        final (s, n, meanD) = _lightTraffic(d, t, centre, seed: seed);
        expect(n, greaterThan(60), reason: 'every approach observed');
        expect(d.despawns, isEmpty);
        sumObs += s;
        nObs += n;
        sumD += meanD;
      }
      final meanObs = sumObs / nObs, meanD = sumD / _seeds.length;
      // Signed: through on green is quicker than J, a red slower; their
      // mean is what a light costs beyond J. Each crossing's own ten
      // minutes are a few dozen lights per approach, so the four are
      // pooled — deterministic all the same.
      expect(meanObs.abs(), lessThan(1.0),
          reason: 'the mean observation beyond J: $meanObs');
      expect(meanD, lessThan(1.0),
          reason: 'the mean published delay over each crossing\'s last '
              'five minutes: $meanD');
    });
  });

  group('lane speeds', () {
    test('a 60 s EMA of v / limit per lane: a lane driven at its limit reads '
        'green, a stalled one red within a minute and a half and green again '
        'once cleared; a buffer of a pool of three per epoch', () {
      final lg = straightRoad(lengthM: 4000, cls: RoadClass.avenue);
      final e = edgeOf(lg, 'r0');
      final free = lg.laneOf(e, 0), jammed = lg.laneOf(e, 1);
      final d = Drive(lg);
      final t = EdgeDelayTable()..bind(lg);
      final lim = lg.edgeLimit[e].toDouble();
      for (var i = 0; i < 5; i++) {
        d.trip(e, 400.0 - 70 * i, e, 3900, speed: lim, destMask: 1);
      }
      final stalled = <int>[];
      for (var i = 0; i < 5; i++) {
        final h = d.trip(e, 2000.0 - 12 * i, e, 3900,
            destMask: 2, checkRoom: false);
        d.table.stall(h);
        stalled.add(h);
      }
      expect(t.laneSpeedPct, isNull);
      final published = <Uint8List>[];
      var steps = 0;
      void run(double s) => d.run(s, () {
            t.absorb(d.mover);
            if (++steps % 10 == 0) {
              final rev = t.laneSpeedRev;
              t.epoch(d.mover, d.table, windowEnd: steps % 300 == 0);
              expect(t.laneSpeedRev, rev + 1);
              published.add(t.laneSpeedPct!);
            }
          });
      run(90);
      final pct = t.laneSpeedPct!;
      expect(pct.length, lg.laneCount);
      expect(pct[free], greaterThanOrEqualTo(90));
      expect(AgentLaneSpeeds.band(pct[free]), 2);
      expect(pct[jammed], lessThan(40));
      expect(AgentLaneSpeeds.band(pct[jammed]), 0);
      final back = lg.edgeReverse[e];
      expect(pct[lg.laneOf(back, 0)], 100, reason: 'nothing on it: free');
      for (var i = 0; i + 3 < published.length; i++) {
        expect(published[i + 3], same(published[i]));
        expect(published[i + 1], isNot(same(published[i])));
      }

      for (final h in stalled) {
        d.mover.despawn(h, DespawnReason.edit);
      }
      run(180);
      expect(t.laneSpeedPct![jammed], greaterThanOrEqualTo(90),
          reason: 'cleared, it is free again');
    });

    test('what the Lane speed view reads: the percentages and their '
        'revision, the lane graph and its revision, and each lane\'s line', () {
      AgentTuning.commuteRatePerResident = 0.004;
      final a = CityAgents(town());
      final view = a.laneSpeeds;
      expect(view.pct, isNull);
      expect(view.revision, 0);
      expect(view.laneGraph, isNull);
      expect(view.laneCount, 0);
      expect(view.laneLine(0), isEmpty);
      a.enabled = true;
      runAgents(a, 10);
      final lg = view.laneGraph!;
      expect(view.graphRev, a.graphRev);
      expect(view.pct!.length, lg.laneCount);
      expect(view.revision, 5, reason: 'one a congestion epoch');
      final first = view.pct;
      runAgents(a, 2);
      expect(view.revision, 6);
      expect(view.pct, isNot(same(first)));

      // A lane's line runs from its stop bar behind to the one ahead, its
      // lane's offset right of travel.
      final lane = lg.laneOf(0, 0);
      final e = lg.laneEdge[lane];
      final line = view.laneLine(lane, stepM: 5);
      expect(line.length, greaterThanOrEqualTo(2));
      expect(view.roadOfLane(lane), lg.graph.roads[lg.edgeRoad[e]].id);
      final start = pointOnEdge(lg, e, lg.edgeLaneS0[e].toDouble());
      final end = pointOnEdge(lg, e, lg.edgeLaneS1[e].toDouble());
      expect(line.first.distanceTo(start), closeTo(lg.laneOff[lane], 0.05));
      expect(line.last.distanceTo(end), closeTo(lg.laneOff[lane], 0.05));
      for (var i = 1; i < line.length; i++) {
        expect(line[i].distanceTo(line[i - 1]), lessThanOrEqualTo(5.01));
      }

      // Off and on again: the tables go, and the revision only climbs.
      final before = view.revision;
      a.enabled = false;
      expect(view.pct, isNull);
      expect(view.revision, greaterThan(before));
      a.enabled = true;
      runAgents(a, 2);
      expect(view.revision, greaterThan(before + 1));
      expect(view.pct, isNotNull);

      expect(AgentLaneSpeeds.band(100), 2);
      expect(AgentLaneSpeeds.band(70), 2);
      expect(AgentLaneSpeeds.band(69), 1);
      expect(AgentLaneSpeeds.band(40), 1);
      expect(AgentLaneSpeeds.band(39), 0);
    });
  });

  test('bound like the statistics: a graph that only re-planned a junction '
      'keeps every measurement and re-reads J; a rebuilt one starts afresh', () {
    final layout = CityLayout()
      ..commitRoad(
          controls: const [Vec2(0, -200), Vec2(0, 200)], regenerateLots: false)
      ..commitRoad(
          controls: const [Vec2(-200, 0), Vec2(200, 0)], regenerateLots: false);
    final g = RoadGraph.of(layout);
    final at = g.nodeNear(const Vec2(0, 0))!;
    final lg0 = LaneGraphBuilder.build(g);
    final d = Drive(lg0)..step();
    final t = EdgeDelayTable()..bind(lg0);
    final into = edgeNear(lg0, const Vec2(-100, 0), const Vec2(1, 0));
    expect(t.expectedControlDelayOf(into), kStopPenaltyS);
    for (var i = 0; i < 30; i++) {
      _book(d.mover, into, 40);
    }
    t.absorb(d.mover);
    t.epoch(d.mover, d.table, windowEnd: false);
    final ema = t.emaOf(into);
    final pub = t.published!, speeds = t.laneSpeedPct!;
    expect(pub[into], greaterThan(10));

    final lit = g.withOverrides([JunctionOverride(at: at.at, lights: true)]);
    final lg1 = LaneGraphBuilder.refresh(lg0, lit)!;
    t.bind(lg1);
    expect(t.emaOf(into), ema);
    expect(t.published, same(pub));
    expect(t.laneSpeedPct, same(speeds));
    expect(t.expectedControlDelayOf(into), kSignalPenaltyS,
        reason: 'J follows the controls');

    final rev = t.laneSpeedRev;
    final lg2 = lanesOf(_gridLayout(3));
    t.bind(lg2);
    expect(t.published, isNull);
    expect(t.laneSpeedPct, isNull);
    expect(t.laneSpeedRev, greaterThan(rev));
    for (var e = 0; e < lg2.edgeCount; e++) {
      expect(t.emaOf(e), 0);
      expect(t.flowPerMin(e), 0);
    }
  });
}

// ---- Helpers --------------------------------------------------------------------

/// Books an observation of [seconds] over free time on [edge] in [m]'s log,
/// as the mover does: through a node, or ([atNode] false) stopped on it.
void _book(VehicleMover m, int edge, double seconds, {bool atNode = true}) {
  final i = m.observationCount++;
  m.obsEdge[i] = edge;
  m.obsS[i] = seconds;
  m.obsAtNode[i] = atNode ? 1 : 0;
}

/// Streets r0, r1, r2 end to end along y = 0 — 0 to 500, 500 to 1,500 and
/// 1,500 to 2,000 m — joined at two seams that control nothing.
LaneGraph _inLine() => lanesOf(CityLayout()
  ..commitRoad(
      controls: const [Vec2(0, 0), Vec2(500, 0)], regenerateLots: false)
  ..commitRoad(
      controls: const [Vec2(500, 0), Vec2(1500, 0)], regenerateLots: false)
  ..commitRoad(
      controls: const [Vec2(1500, 0), Vec2(2000, 0)], regenerateLots: false));

/// The crossings [_lightTraffic] is run on, one seed each.
const List<int> _seeds = [11, 12, 13, 14];

/// East, west, north, south.
const List<Vec2> _dirs = [Vec2(1, 0), Vec2(-1, 0), Vec2(0, 1), Vec2(0, -1)];

/// Two [cls] roads crossing at the origin, each drawn in three pieces
/// joined at seams 300 m out, so a car reaches each approach at its limit:
/// what an approach delays it by is the crossing's, and nothing of pulling
/// out or turning round.
CityLayout _crossing(RoadClass cls) {
  final layout = CityLayout();
  for (final c in const [
    [Vec2(-900, 0), Vec2(-300, 0)],
    [Vec2(-300, 0), Vec2(300, 0)],
    [Vec2(300, 0), Vec2(900, 0)],
    [Vec2(0, -900), Vec2(0, -300)],
    [Vec2(0, -300), Vec2(0, 300)],
    [Vec2(0, 300), Vec2(0, 900)],
  ]) {
    layout.commitRoad(controls: c, roadClass: cls, regenerateLots: false);
  }
  return layout;
}

/// Ten agent-minutes of light traffic over [d]'s crossing: every 7 s a car
/// at its limit on a far piece, three in five on through the crossing, one
/// right and one left, each to a far piece. The signed observations beyond
/// J of the approaches into [centre], summed and counted, and the mean
/// delay [t] published on them over the last five minutes.
(double, int, double) _lightTraffic(
    Drive d, EdgeDelayTable t, int centre, {required int seed}) {
  final lg = d.lg;
  final rng = TrafficRng(seed);
  final ins = [
    edgeNear(lg, const Vec2(-600, 0), _dirs[0]),
    edgeNear(lg, const Vec2(600, 0), _dirs[1]),
    edgeNear(lg, const Vec2(0, -600), _dirs[2]),
    edgeNear(lg, const Vec2(0, 600), _dirs[3]),
  ];
  final outs = [
    edgeNear(lg, const Vec2(600, 0), _dirs[0]),
    edgeNear(lg, const Vec2(-600, 0), _dirs[1]),
    edgeNear(lg, const Vec2(0, 600), _dirs[2]),
    edgeNear(lg, const Vec2(0, -600), _dirs[3]),
  ];
  const right = [3, 2, 0, 1], left = [2, 3, 1, 0];
  var sum = 0.0, dSum = 0.0;
  var n = 0, dN = 0, steps = 0;
  d.run(600, () {
    steps++;
    for (var i = 0; i < d.mover.observationCount; i++) {
      final e = d.mover.obsEdge[i];
      if (lg.edgeTo[e] != centre) continue;
      sum += d.mover.obsS[i] - t.expectedControlDelayOf(e);
      n++;
    }
    t.absorb(d.mover);
    if (steps % 10 == 0) {
      t.epoch(d.mover, d.table, windowEnd: steps % 300 == 0);
      if (steps > 1500) {
        for (var e = 0; e < lg.edgeCount; e++) {
          if (lg.edgeTo[e] != centre) continue;
          dSum += t.published![e];
          dN++;
        }
      }
    }
    if (steps % 35 == 0) {
      final k = rng.nextInt(4);
      final r = rng.nextInt(5);
      final o = r == 0 ? right[k] : (r == 1 ? left[k] : k);
      d.trip(ins[k], 100, outs[o], 400,
          kind: AgentKind.car, speed: lg.edgeLimit[ins[k]].toDouble());
    }
  });
  return (sum, n, dSum / dN);
}

/// An [n] × [n] grid of streets, [spacing] apart, overrunning the rim by
/// half a block.
CityLayout _gridLayout(int n, {double spacing = 200}) {
  final layout = CityLayout();
  final half = (n - 1) * spacing / 2;
  final lo = -half - spacing / 2, hi = half + spacing / 2;
  for (var i = 0; i < n; i++) {
    final at = -half + i * spacing;
    layout.commitRoad(
        controls: [Vec2(at, lo), Vec2(at, hi)], regenerateLots: false);
    layout.commitRoad(
        controls: [Vec2(lo, at), Vec2(hi, at)], regenerateLots: false);
  }
  return layout;
}

/// Requests whose ends are edges: `origin` and `dest` edge ids, arriving in
/// the kerb lane.
class _ByEdge implements PathResolver {
  @override
  bool resolve(PathRequest request, PathEnds ends) {
    if (request.origin < 0 || request.dest < 0) return false;
    ends
      ..addOrigin(request.origin, request.originS)
      ..addGoal(request.dest, request.destS, laneMask: 1);
    return true;
  }
}

class _Log implements PathSink {
  final List<int> order = [];
  final Map<int, List<int>> routes = {};

  @override
  void onPath(PathRequest request, PathOutcome o, PlannedRoute route) {
    order.add(request.requester);
    routes[request.requester] = route.elems.sublist(0, route.length);
  }
}
