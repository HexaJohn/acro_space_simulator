// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The NON-ENTRANCE join, from the traffic side (docs/plans/site-access.md
/// §2.3, §2.4 V4; agent-traffic.md §3.10, D6).
///
/// R8's alley car park gives an alley-backed lot TWO joins: slot 3, the alley,
/// a cut carrying `SiteJoinRole.both`, and slot 0, the street frontage,
/// kerbside and carrying `SiteJoinRole.none`. The frontage is there to be a
/// shopfront — the sign, the pavement point and the fallback a stale plan
/// degrades to — and for no car at all. Before the role existed the frontage
/// went out as `both`, and the damage would have been silent: a street beats a
/// 20 km/h alley on cost, so every car would have aimed at the shop window,
/// arrived at a join with no lane behind it, given up at the gate, and left
/// the car park empty with no test failing.
///
/// The road side pins that the plan SAYS `none`
/// (test/colony/site_access/alley_car_park_test.dart, and the `rear_alley_slot`
/// machinery under it). This file pins what traffic DOES with it, at each of
/// the five places that read a join's role, plus the D6 lane mask on the alley
/// itself. Every one of them is a place where getting it wrong costs an
/// entrance and raises no error.
///
/// Its lot is the road side's own fixture shape — a downtown street of `c-med`
/// shops with a service alley 45 m behind them — but built out of
/// `traffic_fixture`'s colony rather than out of `alley_car_park_test`'s own
/// `_block`, which is private to that file and builds a bare `CityLayout`
/// (no `CitySim`, so no buildings, no book and no agents). The one thing
/// lifted from it is the §4.2 recipe at the end of that file: a street of
/// placed `c-med` shops, an alley committed 45 m behind them, and the book
/// drained in one sync. What is added here is a LINK road, because the pins
/// below need the block to be drivable: that file parks its street at e = 2000
/// where nothing reaches it, so every edge of it sits outside the network's
/// largest strongly connected part and no car could be sent there at all.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The starter colony's aquifer pump, which every forced trip below sets off
/// from: a built manual parcel on the crossroads, as `drive_in_and_park` uses
/// it.
const String _pump = 'lot-m3';

/// The commercial-medium shop the alley car park is planned for.
final CityBuildingSpec _shop = kZoneSpecs['commercial']![Density.medium]!;

/// A [town] with an alley-backed run of shops that cars can actually reach.
///
/// The block: a link road east from the starter kit's own north–south street
/// (which runs e = 0, n = ±300), a shop street at e = 500 crossing it, and an
/// alley 45 m behind the east row. 45 m is the road side's own spacing
/// (`rear_alley_slot_test`): the lots keep their configured 32 m depth, so
/// their back edge lands 3 m off the alley's carriageway — inside
/// `kRearAlleyReachM` — and the alley changes no lot polygon, only the
/// alley-candidate bit.
///
/// The shops are PLACED before the alley is committed, so the alley arrives
/// behind built lots and re-plans them onto slot 3, which is the §4.2 case.
CitySim _alleyTown() {
  final city = town();
  commit(city, const FixtureRoad([Vec2(-50, 250), Vec2(600, 250)]));
  commit(city, const FixtureRoad([Vec2(500, -150), Vec2(500, 400)]));
  for (final p in _shopLots(city)) {
    city.placeOnParcel(p.id, _shop);
  }
  commit(
      city,
      const FixtureRoad([Vec2(545, -150), Vec2(545, 400)],
          roadClass: RoadClass.alley));
  expect(
      city.siteAccess.sync(city, city.roadGraph,
          maxUnits: SiteAccessBook.unlimited,
          maxChecks: SiteAccessBook.unlimited),
      isTrue,
      reason: 'the book drains in one sync');
  return city;
}

/// The east row of the shop street, well clear of the link-road junction:
/// read off the geometry, because the commits split the roads and a split
/// renames every lot along them.
List<Parcel> _shopLots(CitySim city) => [
      for (final p in city.layout.autoParcels)
        if (p.centroid.e > 502 && p.centroid.e < 545 && p.centroid.n.abs() < 140)
          p,
    ];

/// One alley-backed shop, with everything traffic resolves for it.
class _AlleyLot {
  _AlleyLot() : city = _alleyTown() {
    g = city.roadGraph;
    lg = LaneGraphBuilder.build(g);
    plans = BookPlanSource(city.siteAccess);
    buildings = BuildingTable()..sync(city, lg, plans);
    final backing = [
      for (final p in _shopLots(city))
        if ((plans.planOf(p.id)?.joinCount ?? 0) == 2) p,
    ];
    expect(backing.length, greaterThanOrEqualTo(3),
        reason: 'the block really is a run of alley car parks');
    lotId = backing.first.id;
    plan = plans.planOf(lotId)!;
    slot = SlotPool.slotOf(buildings.handleOfSite(lotId)!);
    handle = buildings.handleOf(slot);
    for (final r in rowsOf(buildings, slot)) {
      (buildings.accJoin[r] == plan.joinRef(kAlley) ? alleyRows : frontRows)
          .add(r);
    }
  }

  /// The plan-local join indices: the road side emits the frontage first and
  /// the alley second (§3.2 slot order), which `alley_car_park_test` pins.
  static const int kFront = 0;
  static const int kAlley = 1;

  final CitySim city;
  late final RoadGraph g;
  late final LaneGraph lg;
  late final BookPlanSource plans;
  late final BuildingTable buildings;
  late final String lotId;
  late final SiteAccessPlan plan;
  late final int slot, handle;

  /// The building's access rows, split by which join wrote them.
  final List<int> frontRows = [], alleyRows = [];

  /// The directed edges each join is served by.
  List<int> get frontEdges => [for (final r in frontRows) buildings.accEdge[r]];
  List<int> get alleyEdges => [for (final r in alleyRows) buildings.accEdge[r]];

  /// The alley row a car pulls in from without crossing the alley: the lot is
  /// on the RIGHT of travel there ([kAccLeft] clear, D6).
  int get nearRow =>
      alleyRows.firstWhere((r) => buildings.accBits[r] & kAccLeft == 0);
  int get farRow =>
      alleyRows.firstWhere((r) => buildings.accBits[r] & kAccLeft != 0);
}

/// The access rows building [slot] owns, as absolute row indices.
List<int> rowsOf(BuildingTable t, int slot) => [
      for (var i = 0; i < t.accCount[slot]; i++) BuildingTable.accRow0(slot) + i,
    ];

void main() {
  // Nothing on the road but the trip a test asks for: no commuting demand and
  // no migration, so a car counted below is a car this file put there.
  setUp(() {
    AgentTuning.commuteRatePerResident = 0;
    noArrivals();
  });
  tearDown(AgentTuning.reset);

  group('the fixture', () {
    test('an alley-backed shop: slot 0 kerbside with role none, slot 3 the '
        'cut, and four access rows over the two of them', () {
      final f = _AlleyLot();
      final p = f.plan;
      expect(p.program, SiteProgram.carPark);
      expect(p.joinCount, 2);
      expect(p.joinSlot(_AlleyLot.kFront), 0);
      expect(p.joinKind(_AlleyLot.kFront), SiteJoinKind.kerbside);
      expect(p.joinRole(_AlleyLot.kFront), SiteJoinRole.none);
      expect(p.joinCanIn(_AlleyLot.kFront), isFalse);
      expect(p.joinCanOut(_AlleyLot.kFront), isFalse);
      expect(p.joinSlot(_AlleyLot.kAlley), kJoinSlotAlley);
      expect(p.joinKind(_AlleyLot.kAlley), SiteJoinKind.cut);
      expect(p.joinRole(_AlleyLot.kAlley), SiteJoinRole.both);

      // Two rows apiece, and the bits `_addRow` wrote: the frontage carries
      // NEITHER kAccIn nor kAccOut, because `AccessPoints.ofPlanJoin` copied
      // the role off the plan and `canIn`/`canOut` are the only sources of
      // those bits (§3.10). The alley carries both, and the cut.
      expect(f.frontRows, hasLength(2));
      expect(f.alleyRows, hasLength(2));
      for (final r in f.frontRows) {
        expect(f.buildings.accBits[r] & (kAccIn | kAccOut), 0,
            reason: 'the shopfront is no driveway');
        expect(f.buildings.accBits[r] & kAccCut, 0);
        expect(f.g.roads[f.lg.edgeRoad[f.buildings.accEdge[r]]].roadClass,
            RoadClass.street);
      }
      for (final r in f.alleyRows) {
        expect(f.buildings.accBits[r] & kAccIn, kAccIn);
        expect(f.buildings.accBits[r] & kAccOut, kAccOut);
        expect(f.buildings.accBits[r] & kAccCut, kAccCut);
        expect(f.g.roads[f.lg.edgeRoad[f.buildings.accEdge[r]]].roadClass,
            RoadClass.alley);
      }
      // And the block is drivable, which is what makes the rest of the file
      // possible at all: the colony's own network serves the lot and every
      // edge of it stands in the largest strongly connected part.
      expect(f.buildings.served[f.slot], 1);
      for (final e in [...f.frontEdges, ...f.alleyEdges]) {
        expect(f.lg.edgeInMainScc[e], 1);
      }
    });
  });

  group('rule 1: a none join is never a goal (§3.10, §5.5)', () {
    test('addGoals offers the alley\'s two rows and the frontage\'s neither, '
        'each in the lane of its own row', () {
      final f = _AlleyLot();
      final ends = PathEnds();
      expect(f.buildings.addGoals(f.handle, ends), isTrue);
      expect(ends.goalCount, 2, reason: 'one goal per serving direction');

      // Every goal is an alley row, verbatim: its edge, its arc and the one
      // lane `accLane` named (D6). `addGoals` gates on kAccIn alone, so a
      // frontage that ever carried a role would appear here and — a street
      // against a 20 km/h alley — win the route.
      final want = {
        for (final r in f.alleyRows)
          '${f.buildings.accEdge[r]} ${f.buildings.accT[r]} '
              '${1 << f.buildings.accLane[r]}',
      };
      final got = {
        for (var k = 0; k < ends.goalCount; k++)
          '${ends.goalEdge[k]} ${ends.goalT[k]} ${ends.goalMask[k]}',
      };
      expect(got, want);
      for (var k = 0; k < ends.goalCount; k++) {
        expect(f.frontEdges, isNot(contains(ends.goalEdge[k])),
            reason: 'the street is not a way in');
      }
    });

    test('and with the alley gone from the plan there would be no goal at all: '
        'the frontage never stands in for it', () {
      // The counter-case, built out of the same table: a building whose only
      // in-capable rows are the alley's offers nothing once those rows are
      // cleared. If `addGoals` read anything but kAccIn — the join's geometry,
      // the row count, the site id — the frontage would answer here.
      final f = _AlleyLot();
      for (final r in f.alleyRows) {
        f.buildings.accBits[r] &= ~kAccIn;
      }
      final ends = PathEnds();
      expect(f.buildings.addGoals(f.handle, ends), isFalse);
      expect(ends.goalCount, 0);
    });
  });

  group('rule 2: a none join is never an origin (§3.10, §5.5)', () {
    test('addOrigins offers the alley\'s two rows, from any lane', () {
      final f = _AlleyLot();
      final ends = PathEnds();
      expect(f.buildings.addOrigins(f.handle, ends), isTrue);
      expect(ends.originCount, 2);
      final want = {
        for (final r in f.alleyRows)
          '${f.buildings.accEdge[r]} ${f.buildings.accT[r]}',
      };
      final got = {
        for (var k = 0; k < ends.originCount; k++)
          '${ends.originEdge[k]} ${ends.originT[k]}',
      };
      expect(got, want);
      for (var k = 0; k < ends.originCount; k++) {
        // A car pulling out picks its lane at the access point, so an origin
        // is offered from any lane (−1); the mask is the goal's business.
        expect(ends.originLane[k], -1);
        expect(f.frontEdges, isNot(contains(ends.originEdge[k])));
      }
    });

    test('nearEdge on the frontage offers NOTHING, not the frontage', () {
      // §5.5's near-edge narrowing is what a car backing out onto a road it
      // may not cross asks for. Asked about the street the shopfront stands
      // on, the honest answer is "no way out here" — not "out through the
      // window". The rows on that edge exist; what refuses them is kAccOut.
      final f = _AlleyLot();
      for (final e in f.frontEdges) {
        final ends = PathEnds();
        expect(f.buildings.addOrigins(f.handle, ends, nearEdge: e), isFalse,
            reason: 'edge $e is the frontage');
        expect(ends.originCount, 0);
      }
      // And the narrowing itself works, so the false above is the role's
      // doing and not a broken filter: each alley edge offers its own row.
      for (final r in f.alleyRows) {
        final e = f.buildings.accEdge[r];
        final ends = PathEnds();
        expect(f.buildings.addOrigins(f.handle, ends, nearEdge: e), isTrue);
        expect(ends.originCount, 1);
        expect(ends.originEdge[0], e);
        expect(ends.originT[0], f.buildings.accT[r]);
      }
    });
  });

  group('rule 3: no car enters through the shopfront (§7.4 step 2, D17)', () {
    test('a forced trip to the shop enters at the ALLEY join, and no access '
        'event is ever logged on the street', () {
      final f = _AlleyLot();
      final a = agentsOn(f.city);
      final trip = a.forceTrip(_pump, f.lotId);
      expect(trip, isNot(SlotPool.none), reason: 'both sites are built');
      final sites = a.sites!;
      final row = sites.rowOfBuilding(
          SlotPool.slotOf(a.buildings!.handleOfSite(f.lotId)!));
      expect(row, greaterThanOrEqualTo(0));
      final lg = a.laneGraph!;
      // The agents resolve the block for themselves, off the colony's own
      // book; the frontage and alley edges are the same ones.
      final slot = SlotPool.slotOf(a.buildings!.handleOfSite(f.lotId)!);
      final street = <int>[], alley = <int>[];
      for (final r in rowsOf(a.buildings!, slot)) {
        (a.buildings!.accBits[r] & kAccIn != 0 ? alley : street)
            .add(a.buildings!.accEdge[r]);
      }
      expect(street, hasLength(2));
      expect(alley, hasLength(2));

      final events = <({int kind, int edge, int lane, int row, int join})>[];
      var parked = false;
      for (var i = 0; i < (180 / kStepS).round() && !parked; i++) {
        a.advance(kStepS);
        final log = a.accessEvents!;
        for (var k = 0; k < log.count; k++) {
          events.add((
            kind: log.kind[k],
            edge: log.edge[k],
            lane: log.lane[k],
            row: log.row[k],
            join: log.join[k],
          ));
        }
        parked = a.parkedCars!.count > 0;
      }

      // One kerb crossing, and it is the alley's cut.
      expect(events, hasLength(1), reason: 'one car, one kerb crossing');
      final e = events.single;
      expect(e.kind, AccessEventKind.enter.index);
      expect(e.row, row);
      expect(e.join, _AlleyLot.kAlley);
      expect(alley, contains(e.edge));
      expect(street, isNot(contains(e.edge)),
          reason: 'no car goes in through the shop window');
      expect(f.plan.joinCanIn(e.join), isTrue);
      expect((e.edge == f.buildings.accEdge[f.nearRow]), isTrue,
          reason: 'in from the side it does not have to cross the alley on');
      final at = lg.travelArc(e.edge, f.plan.joinRoadS(e.join));
      expect((f.plan.joinRoadS(e.join) - at).isFinite, isTrue);

      // And it is in the lot, not at a kerb and not garaged.
      expect(a.parkedCars!.lotCars, 1);
      expect(a.siteStats.enters, 1);
      expect(a.siteStats.parkedLot, 1);
      expect(a.siteStats.parkedKerb, 0);
      expect(a.siteStats.garaged, 0);
      expect(a.siteStats.gateGiveUps, 0);
    });

    test('the adversarial stop: standing at the frontage\'s own arc on the '
        'frontage\'s own edge names no in-capable join', () {
      // `CityAgents._joinOfArrival` is private, so what stands in for it is the
      // predicate it computes (§7.4 step 2): of the joins a car may turn IN by,
      // which lies on this edge within `kSiteRetargetM` of this stop. At the
      // shopfront the answer must be NONE — the arrival falls through to D17
      // step 2 and the car takes a kerb slot — and the only thing making it
      // none is the role, because the GEOMETRY there says "join 0" as loudly
      // as it can: the row is on that edge, at that arc, and `joinAt` names it.
      final f = _AlleyLot();
      final frontT = f.buildings.accT[f.frontRows.first].toDouble();
      final frontEdge = f.buildings.accEdge[f.frontRows.first];
      expect(f.buildings.joinAt(f.handle, frontEdge, frontT, 1.5),
          f.plan.joinRef(_AlleyLot.kFront),
          reason: 'geometrically it IS the frontage join');
      for (var j = 0; j < f.plan.joinCount; j++) {
        if (!f.plan.joinCanIn(j)) continue;
        final piece = f.plan.joinPiece(j);
        expect(
            f.g.pieceFwdEdge[piece] == frontEdge ||
                f.g.pieceBwdEdge[piece] == frontEdge,
            isFalse,
            reason: 'in-capable join $j stands on the frontage edge');
      }
      // Defence in depth: even a caller that picked the frontage anyway gets
      // no stall out of it (rule 4), so nothing can be reserved at a gate with
      // no lane behind it.
      final a = agentsOn(f.city);
      expect(a.forceTrip(_pump, f.lotId), isNot(SlotPool.none));
      final sites = a.sites!;
      final row = sites.rowOfBuilding(
          SlotPool.slotOf(a.buildings!.handleOfSite(f.lotId)!));
      expect(sites.firstFreeStall(row, _AlleyLot.kFront), -1);
    });
  });

  group('rule 4: a none join gets no stall order (§7.4 step 2, §7.5)', () {
    test('no in-lane, no out-lane, no hop target and no stall — while the '
        'alley join carries all four', () {
      final f = _AlleyLot();
      final a = agentsOn(f.city);
      expect(a.forceTrip(_pump, f.lotId), isNot(SlotPool.none));
      final sites = a.sites!;
      final row = sites.rowOfBuilding(
          SlotPool.slotOf(a.buildings!.handleOfSite(f.lotId)!));
      final lanes = sites.lanes[row]!;
      expect(lanes.inLane(_AlleyLot.kFront), -1,
          reason: 'a kerbside join is no lane');
      expect(lanes.outLane(_AlleyLot.kFront), -1);
      expect(lanes.inLane(_AlleyLot.kAlley), greaterThanOrEqualTo(0));
      expect(lanes.outLane(_AlleyLot.kAlley), greaterThanOrEqualTo(0));
      expect(sites.joinTarget(row, _AlleyLot.kFront), -1,
          reason: 'nothing may be routed out through the shopfront');
      expect(sites.joinTarget(row, _AlleyLot.kAlley),
          greaterThanOrEqualTo(0));

      // The order blocks. `_orders` fills EVERY join's block so a read never
      // has to check first, but it puts one in drive order only where an
      // in-lane and a role stand behind it: the frontage's is left in plain
      // index order, which is the first stall of no approach at all.
      final n = sites.stallCount[row];
      expect(n, greaterThan(1));
      final front = [
        for (var i = 0; i < n; i++)
          sites.stallOrder[sites.orderBase[row] + _AlleyLot.kFront * n + i],
      ];
      final alley = [
        for (var i = 0; i < n; i++)
          sites.stallOrder[sites.orderBase[row] + _AlleyLot.kAlley * n + i],
      ];
      expect(front, [for (var i = 0; i < n; i++) i],
          reason: 'never sorted: plain index order');
      expect(alley, isNot(front), reason: 'the alley\'s is a real drive order');
      expect(alley.toSet(), front.toSet(), reason: 'a permutation of the lot');

      // So `firstFreeStall` answers for the alley and refuses the frontage:
      // no in-lane stands behind it, and it carries no role either way. What
      // it must NOT refuse is a join that merely lost its IN role — the
      // stalls are there and the gate turns the car away (site_table_test,
      // §7.6's lost-role case) — so the gate here is the lane, not `canIn`.
      // It also refuses a join the plan does not have at all, whose order
      // block would be the next row's memory.
      expect(sites.firstFreeStall(row, _AlleyLot.kFront), -1);
      expect(sites.firstFreeStall(row, _AlleyLot.kAlley), alley.first);
      expect(sites.firstFreeStall(row, f.plan.joinCount), -1);
      expect(sites.firstFreeStall(row, -1), -1);
    });
  });

  group('rule 5: reachability is judged from the alley alone (§3.10)', () {
    test('the alley out of the main SCC isolates the lot; the frontage out of '
        'it changes nothing', () {
      // `_finishAccess` counts a role only where its row's edge stands in the
      // network's largest strongly connected part. The frontage's rows carry
      // no role, so they can neither rescue the lot nor condemn it: the whole
      // verdict rides on the alley. A fresh `BuildingTable` per case, because
      // a table re-resolves access on a new GRAPH, and these three share one.
      final f = _AlleyLot();
      final plans = f.plans;

      BuildingTable tableWith(List<int> Function(BuildingTable, int) pick) {
        final lg = LaneGraphBuilder.build(f.g);
        final probe = BuildingTable()..sync(f.city, lg, plans);
        final slot = SlotPool.slotOf(probe.handleOfSite(f.lotId)!);
        for (final e in pick(probe, slot)) {
          lg.edgeInMainScc[e] = 0;
        }
        return BuildingTable()..sync(f.city, lg, plans);
      }

      List<int> edgesOf(BuildingTable t, int slot, bool wantIn) => [
            for (final r in rowsOf(t, slot))
              if ((t.accBits[r] & kAccIn != 0) == wantIn) t.accEdge[r],
          ];

      final whole = tableWith((_, _) => const []);
      final wSlot = SlotPool.slotOf(whole.handleOfSite(f.lotId)!);
      expect(whole.accessFlags[wSlot] & kAccessIsolated, 0);
      expect(whole.reachable(wSlot), isTrue);

      final noAlley = tableWith((t, sl) => edgesOf(t, sl, true));
      final nSlot = SlotPool.slotOf(noAlley.handleOfSite(f.lotId)!);
      expect(noAlley.accessFlags[nSlot] & kAccessIsolated, kAccessIsolated,
          reason: 'the only way in and out left the network');
      expect(noAlley.reachable(nSlot), isFalse);
      // The rows are all still there: it is the ROLE on them that ran out,
      // not the access.
      expect(noAlley.accCount[nSlot], 4);

      final noStreet = tableWith((t, sl) => edgesOf(t, sl, false));
      final sSlot = SlotPool.slotOf(noStreet.handleOfSite(f.lotId)!);
      expect(noStreet.accessFlags[sSlot] & kAccessIsolated, 0,
          reason: 'the shopfront was never load-bearing');
      expect(noStreet.reachable(sSlot), isTrue);
      expect(noStreet.accCount[sSlot], 4);
    });
  });

  group('rule 6: the row budget (§3.10 kAccRows)', () {
    test('an alley plan spends 4 of the 8 rows, and accCount says so', () {
      // `_planAccess` stops writing at `kAccRows` and `_finishAccess` counts
      // what it wrote, so an overflow does not throw and does not warn — it
      // silently drops the LAST join, which on this plan is the only entrance
      // there is. The count is the tripwire: the day a plan grows a join,
      // this fails as a number rather than as a car park nobody visits.
      final f = _AlleyLot();
      expect(kAccRows, 8, reason: 'four slots, both ways (§2.2)');
      expect(f.plan.joinCount, 2);
      expect(f.buildings.accCount[f.slot], 4);
      expect(f.buildings.accCount[f.slot], f.plan.joinCount * 2);
      expect(f.plan.joinCount * 2, lessThanOrEqualTo(kAccRows),
          reason: 'every join of the plan got its rows');
      // The four rows past them are untouched, which is what "spends 4 of 8"
      // means: the cap has headroom, and nothing was clipped to fit.
      final base = BuildingTable.accRow0(f.slot);
      for (var i = f.buildings.accCount[f.slot]; i < kAccRows; i++) {
        expect(f.buildings.accEdge[base + i], -1);
        expect(f.buildings.accJoin[base + i], kJoinRefNone);
        expect(f.buildings.accBits[base + i], 0);
      }
    });
  });

  group('D6: the lane mask on the alley', () {
    test('one lane each way, so each row is offered its own direction\'s lane '
        'and never the opposing one', () {
      final f = _AlleyLot();
      final lg = f.lg;
      // The alley: one road, both directions, one lane apiece. A mask is an
      // index INTO AN EDGE's lanes, so this is where a wrong mask would be
      // invisible — bit 0 is a legal mask on every edge in the colony.
      final near = f.buildings.accEdge[f.nearRow];
      final far = f.buildings.accEdge[f.farRow];
      expect(lg.edgeRoad[near], lg.edgeRoad[far], reason: 'one alley');
      expect(lg.edgeForward[near], isNot(lg.edgeForward[far]));
      expect(lg.edgeLaneCount[near], 1);
      expect(lg.edgeLaneCount[far], 1);

      final ends = PathEnds();
      f.buildings.addGoals(f.handle, ends);
      expect(ends.goalCount, 2);
      final laneOfEdge = <int, int>{};
      for (var k = 0; k < ends.goalCount; k++) {
        final edge = ends.goalEdge[k];
        // Exactly one bit, and it names a lane OF THAT EDGE.
        final mask = ends.goalMask[k];
        expect(mask, 1, reason: 'lane 0 of a one-lane edge');
        final lane = lg.edgeLaneBase[edge];
        expect(lg.laneEdge[lane], edge,
            reason: 'the mask never names cross traffic');
        laneOfEdge[edge] = lane;
      }
      expect(laneOfEdge.keys.toSet(), {near, far});
      expect(laneOfEdge[near], isNot(laneOfEdge[far]),
          reason: 'two directions, two lane elements');

      // And the mask is the lane the side rule picks, not a constant: the
      // kerb lane where the lot is on the right of travel, the innermost
      // where a car turns in across the alley. On one lane each way those
      // coincide at 0, which is precisely why this has to be checked against
      // `destLane` rather than against the number.
      final ap = AccessPoints.ofPlanJoin(lg, f.plan, _AlleyLot.kAlley)!;
      expect(ap.rightOfTravel(lg, near), isTrue);
      expect(ap.rightOfTravel(lg, far), isFalse);
      expect(f.buildings.accLane[f.nearRow], ap.destLane(lg, near));
      expect(f.buildings.accLane[f.farRow], ap.destLane(lg, far));
      expect(ap.destLane(lg, near), 0, reason: 'the kerb lane');
      expect(ap.destLane(lg, far), lg.edgeLaneCount[far] - 1);
    });

    test('and the lane it offers is the lane the car actually pulls in from',
        () {
      // The ENTER event's lane is the road lane the arrival was in (§5.5's
      // own invariant). It must be the lane the goal mask named for that
      // edge, or the mask is decoration: a car would be routed in one lane
      // and cross the kerb from another.
      final f = _AlleyLot();
      final a = agentsOn(f.city);
      expect(a.forceTrip(_pump, f.lotId), isNot(SlotPool.none));
      final lg = a.laneGraph!;
      final slot = SlotPool.slotOf(a.buildings!.handleOfSite(f.lotId)!);
      final ends = PathEnds();
      a.buildings!.addGoals(a.buildings!.handleOf(slot), ends);
      var entered = false;
      for (var i = 0; i < (180 / kStepS).round() && !entered; i++) {
        a.advance(kStepS);
        final log = a.accessEvents!;
        for (var k = 0; k < log.count; k++) {
          if (log.kind[k] != AccessEventKind.enter.index) continue;
          entered = true;
          final edge = log.edge[k], lane = log.lane[k];
          expect(lg.laneEdge[lane], edge);
          var offered = -1;
          for (var q = 0; q < ends.goalCount; q++) {
            if (ends.goalEdge[q] == edge) offered = ends.goalMask[q];
          }
          expect(offered, isNot(-1), reason: 'it came in at an offered goal');
          expect(offered & (1 << (lane - lg.edgeLaneBase[edge])), isNot(0),
              reason: 'the mask names the lane it pulled in from');
        }
      }
      expect(entered, isTrue, reason: 'it got in');
    });
  });
}
