// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_planner.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/path_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';

/// The edge A* and the queue its searches wait in (docs/plans/
/// agent-traffic.md §4.1, §4.3, §4.8; §17.1 path_search_test; §17.3 #2).
///
/// A route is the cheapest by §4.1's seconds — checked against Dijkstra and
/// against the design's tables written out again below — and the same
/// whatever budget the search is given, however ties fall, on every run.
/// The queue serves re-plans first and each priority in order, and never
/// lets a car trip half searched hold up a re-plan.
void main() {
  tearDown(AgentTuning.reset);

  group('the edge A*', () {
    test('returns the optimum: its cost is Dijkstra\'s, and §4.1\'s worked '
        'out independently, on 200 random trips', () {
      var trips = 0, found = 0, aStarWork = 0, dijkstraWork = 0;
      for (var town = 1; town <= 8; town++) {
        final lg = lanesOf(randomTownLayout(TrafficRng(town)));
        final cost = RouteCost(lg);
        final rng = TrafficRng(700 + town);
        final aStar = SearchContext(), dijkstra = SearchContext();
        final ends = PathEnds();
        for (var i = 0; i < 25; i++) {
          final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
          final to = rng.nextUnit() * lg.edgeLen[o];
          final tg = rng.nextUnit() * lg.edgeLen[g];
          ends
            ..clear()
            ..addOrigin(o, to)
            ..addGoal(g, tg);
          aStar
            ..begin(cost, ends)
            ..step(1 << 30);
          dijkstra
            ..begin(cost, ends, heuristic: false)
            ..step(1 << 30);
          aStarWork += aStar.expansions;
          dijkstraWork += dijkstra.expansions;
          trips++;
          final want = _referenceCost(lg, o, to, g, tg);
          final why = 'town $town trip $i: $o@$to -> $g@$tg';
          if (want.isInfinite) {
            expect(aStar.status, SearchStatus.noPath, reason: why);
            expect(dijkstra.status, SearchStatus.noPath, reason: why);
            continue;
          }
          found++;
          final tol = 1e-9 * math.max(1.0, want);
          expect(aStar.status, SearchStatus.found, reason: why);
          expect(aStar.cost, closeTo(want, tol), reason: why);
          expect(dijkstra.cost, closeTo(want, tol), reason: why);
          final path = aStar.path.sublist(0, aStar.pathLength);
          expect(path.first, o);
          expect(path.last, g);
          // The route it returns costs what it says it costs.
          expect(_pathCost(lg, path, to, tg), closeTo(aStar.cost, 1e-6),
              reason: why);
        }
      }
      expect(trips, 200);
      expect(found, greaterThan(100));
      expect(aStarWork, lessThan(dijkstraWork),
          reason: 'the heuristic should spare work');
    });

    test('the route is the same whatever the budget: a search stopped '
        'after 1 or 17 expansions carries on where it stopped', () {
      var compared = 0;
      for (var town = 1; town <= 4; town++) {
        final lg = lanesOf(randomTownLayout(TrafficRng(20 + town)));
        final cost = RouteCost(lg);
        final rng = TrafficRng(900 + town);
        final ends = PathEnds();
        for (var i = 0; i < 12; i++) {
          final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
          ends
            ..clear()
            ..addOrigin(o, rng.nextUnit() * lg.edgeLen[o])
            ..addGoal(g, rng.nextUnit() * lg.edgeLen[g]);
          final whole = SearchContext()
            ..begin(cost, ends)
            ..step(4000);
          expect(whole.status, isNot(SearchStatus.running));
          for (final budget in [1, 17]) {
            final part = SearchContext()..begin(cost, ends);
            var steps = 0;
            while (part.step(budget) == SearchStatus.running) {
              expect(part.lastStepExpansions, budget);
              steps++;
            }
            expect(steps, lessThan(100000));
            expect(part.status, whole.status);
            expect(part.expansions, whole.expansions);
            if (whole.status == SearchStatus.found) {
              expect(part.cost, whole.cost);
              expect(part.path.sublist(0, part.pathLength),
                  whole.path.sublist(0, whole.pathLength));
            }
          }
          compared++;
        }
      }
      expect(compared, 48);
    });

    test('ties fall the same way every time: on a grid of equal streets, '
        'one route of many, from a fresh search or a reused one', () {
      final lg = lanesOf(_gridLayout(4));
      final cost = RouteCost(lg);
      final from = edgeNear(lg, const Vec2(-350, -300), const Vec2(1, 0));
      final to = edgeNear(lg, const Vec2(350, 300), const Vec2(1, 0));
      final ends = PathEnds()
        ..addOrigin(from, 20)
        ..addGoal(to, 20);
      final first = SearchContext()
        ..begin(cost, ends)
        ..step(1 << 30);
      final route = first.path.sublist(0, first.pathLength);
      final reused = SearchContext();
      final other = PathEnds()
        ..addOrigin(to, 10)
        ..addGoal(from, 10);
      for (var i = 0; i < 5; i++) {
        // Another search first, on the same context: stamps and heap must
        // carry nothing over.
        reused
          ..begin(cost, other)
          ..step(1 << 30)
          ..begin(cost, ends);
        var steps = 0;
        while (reused.step(3 + i) == SearchStatus.running) {
          steps++;
        }
        expect(steps, greaterThan(0));
        expect(reused.path.sublist(0, reused.pathLength), route);
        final fresh = SearchContext()
          ..begin(cost, ends)
          ..step(1 << 30);
        expect(fresh.path.sublist(0, fresh.pathLength), route);
        expect(fresh.cost, first.cost);
      }
    });

    test('the heuristic never overestimates — not where a node lies metres '
        'off its road ends, nor on the fastest road', () {
      final layouts = <CityLayout>[
        _interchange(),
        for (var t = 1; t <= 6; t++) randomTownLayout(TrafficRng(40 + t)),
      ];
      var checked = 0;
      final goal = Float64List(2);
      for (final layout in layouts) {
        final lg = lanesOf(layout);
        final cost = RouteCost(lg);
        for (var e = 0; e < lg.edgeCount; e++) {
          expect(cost.hPerM, lessThanOrEqualTo(cost.edgePerM[e]));
        }
        final rng = TrafficRng(9 + checked);
        final search = SearchContext();
        final ends = PathEnds();
        for (var i = 0; i < 40; i++) {
          final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
          final tg = rng.nextUnit() * lg.edgeLen[g];
          ends
            ..clear()
            ..addOrigin(o, 0)
            ..addGoal(g, tg);
          search.begin(cost, ends, heuristic: false);
          if (search.step(1 << 30) != SearchStatus.found) continue;
          // From the start of edge o, the route costs search.cost: the
          // heuristic at o's start node may not claim more.
          cost.pointAt(g, tg, goal);
          final h = cost.heuristic(lg.edgeFrom[o], goal, 1);
          expect(h, lessThanOrEqualTo(search.cost + 1e-9),
              reason: 'from edge $o to $g');
          checked++;
        }
      }
      expect(checked, greaterThan(150));
      // An attach node lies metres off the ramp end it joins: the slack is
      // what keeps the heuristic below the truth there.
      final lg = lanesOf(_interchange());
      final cost = RouteCost(lg);
      final ramp = edgeOf(lg, 'on');
      expect(cost.nodeSlack[lg.edgeTo[ramp]], greaterThan(5));
    });

    test('a metre of each road costs §4.1\'s seconds: a 1,000 m street '
        '90 s, a 1,150 m avenue 80.3 s', () {
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'street', controls: [Vec2(0, 0), Vec2(1000, 0)]))
        ..addRoad(const RoadSpline(
            id: 'avenue',
            controls: [Vec2(0, 500), Vec2(1150, 500)],
            roadClass: RoadClass.avenue));
      final lg = lanesOf(layout);
      final cost = RouteCost(lg);
      final s = edgeOf(lg, 'street'), a = edgeOf(lg, 'avenue');
      expect(lg.edgeLen[s], closeTo(1000, 0.01));
      expect(cost.edgeTime[s], closeTo(90.0, 0.01)); // 1000 m / 40 km/h × 1.00
      expect(lg.edgeLen[a], closeTo(1150, 0.01));
      expect(cost.edgeTime[a], closeTo(80.3, 0.05)); // 82.8 s × 0.97
      // wVeh: a lorry pays half again on a minor road, and only there.
      expect(cost.fullCost(s, true, null), closeTo(1.5 * cost.edgeTime[s], 1e-9));
      expect(cost.fullCost(a, true, null), cost.edgeTime[a]);
      // D, slice 2's seam: the whole of an edge pays its measured delay,
      // and a part of it its share.
      final delays = Float32List(lg.edgeCount)..[a] = 20;
      expect(cost.fullCost(a, false, delays),
          closeTo(cost.edgeTime[a] + 20, 1e-4));
      expect(cost.partialCost(a, 575, delays),
          closeTo(cost.edgeTime[a] / 2 + 10, 1e-4));
      expect(cost.partialCost(a, 575, null), closeTo(cost.edgeTime[a] / 2, 1e-9));
    });

    test('J and T are §4.1\'s tables', () {
      expect(junctionPenaltyS(NodeControlKind.continuation), 0);
      expect(junctionPenaltyS(NodeControlKind.rampMerge, yields: true), 1.5);
      expect(junctionPenaltyS(NodeControlKind.rampMerge), 0);
      expect(junctionPenaltyS(NodeControlKind.stop, stops: true, yields: true),
          5.0);
      expect(junctionPenaltyS(NodeControlKind.stop), 0.5);
      expect(junctionPenaltyS(NodeControlKind.allWayStop, stops: true), 5.0);
      expect(junctionPenaltyS(NodeControlKind.signals), 6.0);
      expect(junctionPenaltyS(NodeControlKind.roundabout, yields: true), 3.0);
      expect(junctionPenaltyS(NodeControlKind.deadEnd), 20.0);
      expect(junctionPenaltyS(NodeControlKind.danglingDeck), 20.0);

      expect(turnPenaltyS(TurnClass.straight, NodeControlKind.signals), 0);
      expect(turnPenaltyS(TurnClass.right, NodeControlKind.stop), 2.0);
      expect(turnPenaltyS(TurnClass.left, NodeControlKind.signals), 4.0);
      expect(turnPenaltyS(TurnClass.left, NodeControlKind.allWayStop), 7.0);
      expect(turnPenaltyS(TurnClass.sharp, NodeControlKind.signals), 6.0);
      expect(turnPenaltyS(TurnClass.uTurn, NodeControlKind.roundabout), 20.0);
      expect(turnPenaltyS(TurnClass.uTurn, NodeControlKind.deadEnd), 0);

      for (final k in AgentKind.values) {
        expect(paysMinorSurcharge(k),
            k == AgentKind.truck || k == AgentKind.semi || k == AgentKind.deliveryVan,
            reason: '$k');
      }
    });

    test('a lorry pays half again on minor roads — but not on the street it '
        'starts or ends on — and takes the avenue a car would not', () {
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'in', controls: [Vec2(-200, 0), Vec2(0, 0)]))
        ..addRoad(const RoadSpline(
            id: 'st', controls: [Vec2(0, 0), Vec2(1000, 0)]))
        ..addRoad(const RoadSpline(
            id: 'av',
            roadClass: RoadClass.avenue,
            controls: [Vec2(0, 0), Vec2(0, 200), Vec2(1000, 200), Vec2(1000, 0)]))
        ..addRoad(const RoadSpline(
            id: 'out', controls: [Vec2(1000, 0), Vec2(1200, 0)]));
      final lg = lanesOf(layout);
      final cost = RouteCost(lg);
      final from = edgeOf(lg, 'in'), to = edgeOf(lg, 'out');
      final st = edgeOf(lg, 'st'), av = edgeOf(lg, 'av');
      final ends = PathEnds()
        ..addOrigin(from, 100)
        ..addGoal(to, 100);
      final car = SearchContext()
        ..begin(cost, ends)
        ..step(1 << 30);
      final lorry = SearchContext()
        ..begin(cost, ends, kind: AgentKind.semi)
        ..step(1 << 30);
      expect(car.path.sublist(0, car.pathLength), [from, st, to]);
      expect(lorry.path.sublist(0, lorry.pathLength), [from, av, to]);
      expect(car.cost, closeTo(_pathCost(lg, [from, st, to], 100, 100), 1e-6));
      expect(lorry.cost,
          closeTo(_pathCost(lg, [from, av, to], 100, 100, heavy: true), 1e-6));
      // The street a lorry starts and ends on costs it what it costs a car.
      expect(_pathCost(lg, [from, av, to], 100, 100, heavy: true),
          _pathCost(lg, [from, av, to], 100, 100));
    });

    test('§17.3 #2: the slightly longer but faster road is chosen — and 20 s '
        'measured on it sends new trips the other way', () {
      // Two ways from P = (0, 0) to Q = (1000, 0): a 1,000 m street, and an
      // avenue some 15% longer bowed to the north. Both leave P and reach Q
      // within 30° of straight on, and both junctions have lights, so the
      // junction penalties are equal and the roads alone decide.
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'in', controls: [Vec2(-200, 0), Vec2(0, 0)]))
        ..addRoad(const RoadSpline(
            id: 'st', controls: [Vec2(0, 0), Vec2(1000, 0)]))
        ..addRoad(const RoadSpline(id: 'av', roadClass: RoadClass.avenue, controls: [
          Vec2(0, 0),
          Vec2(100, 25),
          Vec2(500, 272),
          Vec2(900, 25),
          Vec2(1000, 0),
        ]))
        ..addRoad(const RoadSpline(
            id: 'out', controls: [Vec2(1000, 0), Vec2(1200, 0)]));
      final lg = lanesOf(layout, overrides: const [
        JunctionOverride(at: Vec2(0, 0), lights: true),
        JunctionOverride(at: Vec2(1000, 0), lights: true),
      ]);
      final from = edgeOf(lg, 'in'), to = edgeOf(lg, 'out');
      final st = edgeOf(lg, 'st'), av = edgeOf(lg, 'av');
      expect(lg.kindOf(lg.edgeTo[from]), NodeControlKind.signals);
      expect(lg.kindOf(lg.edgeTo[st]), NodeControlKind.signals);
      expect(lg.edgeTo[av], lg.edgeTo[st]);
      for (final (a, b) in [(from, st), (from, av), (st, to), (av, to)]) {
        expect(_turn(lg, a, b), TurnClass.straight, reason: '$a -> $b');
      }
      expect(lg.edgeLen[st], closeTo(1000, 0.5));
      expect(lg.edgeLen[av] / lg.edgeLen[st], inInclusiveRange(1.10, 1.20));

      final cost = RouteCost(lg);
      expect(cost.edgeTime[st], closeTo(90.0, 0.1));
      expect(cost.edgeTime[av], lessThan(cost.edgeTime[st] - 5));
      final ends = PathEnds()
        ..addOrigin(from, 100)
        ..addGoal(to, 100);
      final planned = SearchContext()
        ..begin(cost, ends)
        ..step(1 << 30);
      expect(planned.path.sublist(0, planned.pathLength), [from, av, to]);

      // Slice 2 publishes a measured delay: 20 s on the avenue, which makes
      // it dearer than the street. A NEW search prices it, and goes by the
      // street.
      final published = Float32List(lg.edgeCount)..[av] = 20;
      expect(cost.edgeTime[av] + 20, greaterThan(cost.edgeTime[st]));
      final after = SearchContext()
        ..begin(cost, ends, delays: published)
        ..step(1 << 30);
      expect(after.path.sublist(0, after.pathLength), [from, st, to]);

      // A search begun before that publish keeps the buffer it began with:
      // a publish is a fresh buffer, never a write into a held one.
      final before = Float32List(lg.edgeCount);
      final inFlight = SearchContext()..begin(cost, ends, delays: before);
      inFlight.step(1);
      expect(inFlight.delays, same(before));
      inFlight.step(1 << 30);
      expect(inFlight.path.sublist(0, inFlight.pathLength), [from, av, to]);
    });
  });

  group('the path queue', () {
    test('serves re-plans first, then service legs, then car trips — each '
        'first come, first served', () {
      final lg = lanesOf(_gridLayout(3));
      final q = PathQueue()..bind(RouteCost(lg));
      final rng = TrafficRng(5);
      void add(PathPriority p, int who) {
        final o = rng.nextInt(lg.edgeCount), d = rng.nextInt(lg.edgeCount);
        expect(
            q.enqueue(p,
                requester: who,
                fixedStart: p == PathPriority.replan,
                origin: o,
                originS: 1,
                dest: d,
                destS: lg.edgeLen[d] / 2,
                tag: lg.laneOf(o, 0)),
            isTrue);
      }

      add(PathPriority.car, 1);
      add(PathPriority.car, 2);
      add(PathPriority.service, 3);
      add(PathPriority.replan, 4);
      add(PathPriority.car, 5);
      add(PathPriority.service, 6);
      expect(q.length, 6);
      expect(q.lengthOf(PathPriority.car), 3);
      final log = _Log();
      q.pump(1 << 30, _ByEdge(), log);
      expect(log.order, [4, 3, 6, 1, 2, 5]);
      expect(q.idle, isTrue);
    });

    test('the budget is counted in expansions and shared: searches that run '
        'out resume on the next pump, and plan the routes one pump would', () {
      final lg = lanesOf(_gridLayout(4));
      final cost = RouteCost(lg);
      final rng = TrafficRng(77);
      final trips = [
        for (var i = 0; i < 8; i++)
          (rng.nextInt(lg.edgeCount), rng.nextInt(lg.edgeCount)),
      ];
      _Log run(int budget) {
        final q = PathQueue()..bind(cost);
        for (var i = 0; i < trips.length; i++) {
          q.enqueue(PathPriority.car,
              requester: i,
              origin: trips[i].$1,
              originS: 5,
              dest: trips[i].$2,
              destS: 30);
        }
        final log = _Log();
        var pumps = 0;
        while (!q.idle) {
          final used = q.pump(budget, _ByEdge(), log);
          expect(used, lessThanOrEqualTo(budget));
          if (!q.idle) {
            expect(used, budget,
                reason: 'a pump with work left spends its whole budget');
          }
          expect(++pumps, lessThan(100000));
        }
        return log;
      }

      final whole = run(4000), one = run(1), some = run(17);
      expect(whole.order, hasLength(trips.length));
      expect(one.order, whole.order);
      expect(some.order, whole.order);
      expect(one.routes, whole.routes);
      expect(some.routes, whole.routes);
    });

    test('a re-plan does not wait behind a car trip half searched: it takes '
        'a context of its own, and the car trip resumes unchanged', () {
      final lg = lanesOf(_gridLayout(4));
      final cost = RouteCost(lg);
      final far = edgeNear(lg, const Vec2(-350, -300), const Vec2(1, 0));
      final farGoal = edgeNear(lg, const Vec2(350, 300), const Vec2(1, 0));
      final near = edgeNear(lg, const Vec2(-250, -100), const Vec2(1, 0));
      final nearGoal = edgeNear(lg, const Vec2(-50, -100), const Vec2(1, 0));
      void car(PathQueue q) => q.enqueue(PathPriority.car,
          requester: 1, origin: far, originS: 10, dest: farGoal, destS: 10);

      final alone = PathQueue()..bind(cost);
      car(alone);
      final reference = _Log();
      alone.pump(1 << 30, _ByEdge(), reference);

      final q = PathQueue()..bind(cost);
      car(q);
      final log = _Log();
      expect(q.pump(5, _ByEdge(), log), 5);
      expect(log.order, isEmpty);
      expect(q.searching, 1);
      q.enqueue(PathPriority.replan,
          requester: 2,
          fixedStart: true,
          origin: near,
          originS: 10,
          dest: nearGoal,
          destS: 10,
          tag: lg.laneOf(near, 0));
      q.pump(1 << 30, _ByEdge(), log);
      expect(log.order, [2, 1]);
      expect(log.outcome[2], PathOutcome.found);
      expect(log.routes[1], reference.routes[1]);
      expectDrivable(lg, log.routes[2]!);
      expect(log.routes[2]!.first, lg.laneOf(near, 0));
    });

    test('no path, no access and a cancelled request are told apart, and a '
        'full queue refuses — but never a re-plan', () {
      final layout = CityLayout()
        ..commitRoad(
            controls: const [Vec2(0, 0), Vec2(300, 0)], regenerateLots: false)
        ..commitRoad(
            controls: const [Vec2(0, 1000), Vec2(300, 1000)],
            regenerateLots: false);
      final lg = lanesOf(layout);
      final a = edgeOf(lg, 'r0'), b = edgeOf(lg, 'r1');
      final q = PathQueue()..bind(RouteCost(lg));
      q
        ..enqueue(PathPriority.car,
            requester: 1, origin: a, originS: 10, dest: b, destS: 10)
        ..enqueue(PathPriority.car, requester: 2, dest: b, destS: 10)
        ..enqueue(PathPriority.car,
            requester: 3, origin: a, originS: 10, dest: a, destS: 200)
        ..enqueue(PathPriority.car,
            requester: 4, origin: a, originS: 10, dest: a, destS: 250);
      expect(q.cancel(3), 1);
      expect(q.length, 3);
      final log = _Log();
      q.pump(1 << 30, _ByEdge(), log);
      expect(log.order, [1, 2, 4]);
      expect(log.outcome[1], PathOutcome.noPath);
      expect(log.outcome[2], PathOutcome.noAccess);
      expect(log.outcome[4], PathOutcome.found);
      expect(log.routes[4], [lg.laneOf(a, 0)]);

      AgentTuning.maxQueuedPaths = 2;
      AgentTuning.maxQueuedServicePaths = 1;
      bool add(PathPriority p, int who) => q.enqueue(p,
          requester: who,
          fixedStart: p == PathPriority.replan,
          origin: a,
          dest: a,
          destS: 100,
          tag: lg.laneOf(a, 0));
      expect(add(PathPriority.car, 5), isTrue);
      expect(add(PathPriority.car, 6), isTrue);
      expect(add(PathPriority.car, 7), isFalse);
      expect(add(PathPriority.service, 8), isTrue);
      expect(add(PathPriority.service, 9), isFalse);
      for (var i = 0; i < 300; i++) {
        expect(add(PathPriority.replan, 100 + i), isTrue);
      }
      expect(q.lengthOf(PathPriority.replan), 300);
      q.pump(1 << 30, _ByEdge(), log);
      expect(log.order.sublist(3, 303), [for (var i = 0; i < 300; i++) 100 + i]);
      expect(log.order.sublist(303), [8, 5, 6]);
    });

    test('a new graph restarts the searches in flight and re-roots the '
        'queued ones: every route comes back in the new graph\'s ids', () {
      final layout = _gridLayout(4);
      var lg = lanesOf(layout);
      final resolver = _ByPlace(const [
        (Vec2(-350, -300), Vec2(1, 0)),
        (Vec2(350, 300), Vec2(1, 0)),
        (Vec2(-300, 350), Vec2(0, 1)),
        (Vec2(300, -350), Vec2(0, -1)),
      ])
        ..lg = lg;
      final q = PathQueue()..bind(RouteCost(lg));
      for (var i = 0; i < 4; i++) {
        q.enqueue(PathPriority.car, requester: i, origin: i, dest: (i + 1) % 4);
      }
      final log = _Log();
      expect(q.pump(3, resolver, log), 3);
      expect(q.searching, 1);
      expect(log.order, isEmpty);
      // A road across the town: every street it crosses is split, and every
      // id renumbered.
      layout.commitRoad(
          controls: const [Vec2(-400, 50), Vec2(400, 50)],
          regenerateLots: false);
      lg = lanesOf(layout);
      resolver.lg = lg;
      q.bind(RouteCost(lg));
      var pumps = 0;
      while (!q.idle && pumps++ < 1000) {
        q.pump(500, resolver, log);
      }
      expect(log.order, [0, 1, 2, 3]);
      for (var i = 0; i < 4; i++) {
        expect(log.outcome[i], PathOutcome.found);
        final route = log.routes[i]!;
        expectDrivable(lg, route, reason: 'request $i');
        expect(lg.laneEdge[route.first], resolver.edgeAt(i));
        expect(lg.laneEdge[lanesAlong(lg, route).last],
            resolver.edgeAt((i + 1) % 4));
      }
    });

    test('a trip whose cheapest edges no lanes can drive is planned by the '
        'state search instead, and drives', () {
      // A ramp merges into the kerb lane of an expressway that runs on,
      // lane for lane, into an avenue; the avenue ends at a street where a
      // left needs its inner lane, and no junction between lets a car
      // change: §3.5's one known gap.
      final layout = CityLayout()
        ..addRoad(const RoadSpline(
            id: 'x',
            controls: [Vec2(-600, 0), Vec2(0, 0)],
            roadClass: RoadClass.expressway4))
        ..addRoad(const RoadSpline(
            id: 'av',
            controls: [Vec2(0, 0), Vec2(400, 0)],
            roadClass: RoadClass.avenue))
        ..addRoad(const RoadSpline(
            id: 'n', controls: [Vec2(400, 0), Vec2(400, 200)]))
        ..addRoad(const RoadSpline(
            id: 's', controls: [Vec2(400, -200), Vec2(400, 0)]))
        ..addRoad(const RoadSpline(
            id: 'r',
            controls: [Vec2(-450, -60), Vec2(-300, -12.8)],
            roadClass: RoadClass.ramp));
      final lg = lanesOf(layout);
      final cost = RouteCost(lg);
      final ramp = edgeOf(lg, 'r'), north = edgeOf(lg, 'n');
      final ends = PathEnds()
        ..addOrigin(ramp, 10)
        ..addGoal(north, 100, laneMask: 1);
      final edges = SearchContext()
        ..begin(cost, ends)
        ..step(1 << 30);
      expect(edges.status, SearchStatus.found);
      final path = edges.path.sublist(0, edges.pathLength);
      expect(path.first, ramp);
      expect(path.last, north);
      expect(
          LanePlanner().plan(lg, edges.path, edges.pathLength, destMask: 1),
          isFalse,
          reason: 'the fixture must reproduce the gap: $path');

      final q = PathQueue()..bind(cost);
      q.enqueue(PathPriority.car,
          requester: 7, origin: ramp, originS: 10, dest: north, destS: 100);
      final log = _Log();
      q.pump(1 << 30, _ByEdge(), log);
      expect(log.outcome[7], PathOutcome.found);
      final route = log.routes[7]!;
      expectDrivable(lg, route);
      expect(lg.laneEdge[route.first], ramp);
      expect(lanesAlong(lg, route).last, lg.laneOf(north, 0));
      expect(q.fallbacks, 1);
    });
  });
}

/// A grid of [n] × [n] streets [spacing] apart, centred on the origin, each
/// running half a block past the outermost crossing.
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

/// An expressway with a ramp joining it and one leaving it, 12.8 m off its
/// line — nodes the graph places metres from the ramp ends they join — a
/// street between the ramps, and a motorway on its own: the fastest road.
CityLayout _interchange() => CityLayout()
  ..addRoad(const RoadSpline(
      id: 'x',
      controls: [Vec2(-600, 0), Vec2(600, 0)],
      roadClass: RoadClass.expressway6))
  ..addRoad(const RoadSpline(
      id: 'on',
      controls: [Vec2(-300, -120), Vec2(-100, -12.8)],
      roadClass: RoadClass.ramp))
  ..addRoad(const RoadSpline(
      id: 'off',
      controls: [Vec2(100, -12.8), Vec2(300, -120)],
      roadClass: RoadClass.ramp))
  ..addRoad(const RoadSpline(
      id: 'a', controls: [Vec2(-300, -120), Vec2(300, -120)]))
  ..addRoad(const RoadSpline(
      id: 'b', controls: [Vec2(-600, 0), Vec2(-600, -300)]))
  ..addRoad(const RoadSpline(
      id: 'm',
      controls: [Vec2(-600, 300), Vec2(600, 300)],
      roadClass: RoadClass.motorway));

double _perM(LaneGraph lg, int e) => lg.edgeWType[e] / lg.edgeLimit[e];

/// §4.1's J and T for movement [i] out of edge [e], from the design's
/// tables, written out again.
double _movePenalty(LaneGraph lg, int e, int i) {
  final kind = lg.kindOf(lg.edgeTo[e]);
  final stops = lg.controls.edgeStops[e] == 1;
  final yields = lg.controls.edgeYields[e] == 1;
  final j = switch (kind) {
    NodeControlKind.continuation => 0.0,
    NodeControlKind.rampMerge || NodeControlKind.uncontrolled => yields ? 1.5 : 0.0,
    NodeControlKind.stop => stops ? 5.0 : 0.5,
    NodeControlKind.allWayStop => 5.0,
    NodeControlKind.signals => 6.0,
    NodeControlKind.roundabout => 3.0,
    NodeControlKind.deadEnd ||
    NodeControlKind.stub ||
    NodeControlKind.danglingDeck =>
      20.0,
  };
  final t = switch (TurnClass.values[lg.moveTurn[i]]) {
    TurnClass.straight => 0.0,
    TurnClass.right => 2.0,
    TurnClass.left => kind == NodeControlKind.signals ? 4.0 : 7.0,
    TurnClass.sharp => 6.0,
    TurnClass.uTurn => isTurningPlace(kind) ? 0.0 : 20.0,
  };
  return j + t;
}

/// The cheapest trip from travel arc [fromT] of [from] to [toT] of [to] by
/// a plain Dijkstra over edges with §4.1 written out again: the reference
/// the A* is held to.
double _referenceCost(
    LaneGraph lg, int from, double fromT, int to, double toT) {
  final nE = lg.edgeCount;
  final g = List<double>.filled(nE, double.infinity);
  final done = List<bool>.filled(nE, false);
  var best = double.infinity;
  g[from] = (lg.edgeLen[from] - fromT) * _perM(lg, from);
  if (from == to && toT >= fromT) best = (toT - fromT) * _perM(lg, from);
  while (true) {
    var u = -1;
    for (var e = 0; e < nE; e++) {
      if (done[e] || g[e].isInfinite) continue;
      if (u < 0 || g[e] < g[u]) u = e;
    }
    if (u < 0 || g[u] >= best) break;
    done[u] = true;
    for (var i = lg.moveStart[u]; i < lg.moveStart[u + 1]; i++) {
      final o = lg.moveOut[i];
      final base = g[u] + _movePenalty(lg, u, i);
      if (o == to) best = math.min(best, base + toT * _perM(lg, o));
      final gn = base + lg.edgeLen[o] * _perM(lg, o);
      if (gn < g[o]) g[o] = gn;
    }
  }
  return best;
}

/// What [path] costs by §4.1 written out again, from [fromT] on its first
/// edge to [toT] on its last; [heavy] for a lorry.
double _pathCost(LaneGraph lg, List<int> path, double fromT, double toT,
    {bool heavy = false}) {
  if (path.length == 1) return (toT - fromT) * _perM(lg, path[0]);
  var c = (lg.edgeLen[path[0]] - fromT) * _perM(lg, path[0]);
  for (var k = 1; k < path.length; k++) {
    final e = path[k - 1], o = path[k];
    var i = lg.moveStart[e];
    while (lg.moveOut[i] != o) {
      i++;
    }
    c += _movePenalty(lg, e, i);
    if (k == path.length - 1) {
      c += toT * _perM(lg, o);
    } else {
      final minor = lg.edgeTier[o] == RoadTier.minor.rank;
      c += lg.edgeLen[o] * _perM(lg, o) * (heavy && minor ? 1.5 : 1.0);
    }
  }
  return c;
}

/// The turn from [from] onto [to].
TurnClass _turn(LaneGraph lg, int from, int to) {
  for (var i = lg.moveStart[from]; i < lg.moveStart[from + 1]; i++) {
    if (lg.moveOut[i] == to) return TurnClass.values[lg.moveTurn[i]];
  }
  throw StateError('no movement $from -> $to');
}

/// Requests that name their ends by edge id and arc; a fixed start's lane
/// rides in the tag. Every goal is the kerb lane.
class _ByEdge implements PathResolver {
  @override
  bool resolve(PathRequest request, PathEnds ends) {
    if (request.origin < 0 || request.dest < 0) return false;
    ends
      ..addOrigin(request.origin, request.originS,
          lane: request.fixedStart ? request.tag : -1)
      ..addGoal(request.dest, request.destS, laneMask: 1);
    return true;
  }
}

/// Requests that name their ends as places, found on whatever graph is
/// current — as a building is found by its access point.
class _ByPlace implements PathResolver {
  _ByPlace(this.places);

  final List<(Vec2, Vec2)> places;
  late LaneGraph lg;

  int edgeAt(int i) => edgeNear(lg, places[i].$1, places[i].$2);

  @override
  bool resolve(PathRequest request, PathEnds ends) {
    final o = edgeAt(request.origin), d = edgeAt(request.dest);
    ends
      ..addOrigin(o, arcNear(lg, o, places[request.origin].$1))
      ..addGoal(d, arcNear(lg, d, places[request.dest].$1), laneMask: 1);
    return true;
  }
}

/// Every outcome the queue delivers, in order.
class _Log implements PathSink {
  final List<int> order = [];
  final Map<int, PathOutcome> outcome = {};
  final Map<int, List<int>> routes = {};

  @override
  void onPath(PathRequest request, PathOutcome o, PlannedRoute route) {
    order.add(request.requester);
    outcome[request.requester] = o;
    routes[request.requester] = route.elems.sublist(0, route.length);
  }
}
