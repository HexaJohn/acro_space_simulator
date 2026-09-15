// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Per-join access (docs/plans/agent-traffic.md §3.10; site-access.md §2.3,
/// §7.3): a site with a plan is reached and left at THAT PLAN'S joins, each
/// with its own role, and every other building — no plan, or a plan not
/// current for the graph the vehicles drive — is kerbside at the road
/// graph's slot 0, which is today's access exactly.
///
/// The rows are one per join PER SERVING DIRECTION, forward first, because
/// the lane a car uses, the side it is on and the arc it stops at all belong
/// to the direction and not to the join. A kerbside join on a street with one
/// lane each way is therefore two rows, as `accFwd`/`accBwd` were.
///
/// Everything here stands on the road side's own fixtures — the R2a
/// templates on real join slots, and the colony's real book — so what traffic
/// is built against is what it will run on.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
import 'traffic_fixture.dart';

void main() {
  /// A built town, its road graph and the lanes the vehicles drive.
  (CitySim, RoadGraph, LaneGraph) built() {
    final city = town();
    final g = city.roadGraph;
    return (city, g, LaneGraphBuilder.build(g));
  }

  /// Every R2a template on its own starter lot.
  Map<String, SyntheticTemplate> everyTemplate() => {
        for (final t in SyntheticTemplate.values)
          SyntheticSites.starterLots[t]!.$1: t,
      };

  /// The access rows of [site] as `edge:join:bits:lane` words.
  List<String> rowsOf(BuildingTable b, String site) {
    final sl = SlotPool.slotOf(b.handleOfSite(site)!);
    final base = BuildingTable.accRow0(sl);
    return [
      for (var i = 0; i < b.accCount[sl]; i++)
        '${b.accEdge[base + i]}:${b.accJoin[base + i]}:'
            '${b.accBits[base + i]}:${b.accLane[base + i]}',
    ];
  }

  /// The join handle of each row a plan implies for [p]: one per join per
  /// serving direction, forward first.
  List<int> impliedJoins(LaneGraph lg, SiteAccessPlan p) {
    final out = <int>[];
    for (var j = 0; j < p.joinCount; j++) {
      final ap = AccessPoints.ofPlanJoin(lg, p, j);
      if (ap == null) continue;
      if (ap.fwdEdge >= 0) out.add(ap.joinRef);
      if (ap.bwdEdge >= 0) out.add(ap.joinRef);
    }
    return out;
  }

  test('a plan join and the graph slot it names resolve alike', () {
    final (_, g, lg) = built();
    final plans = FixturePlanSource(g, everyTemplate());
    var checked = 0, sideStreets = 0;
    for (final t in SyntheticTemplate.values) {
      final lot = SyntheticSites.starterLots[t]!.$1;
      final plan = plans.planOf(lot)!;
      expect(plan.joinCount, greaterThan(0));
      for (var j = 0; j < plan.joinCount; j++) {
        final a = AccessPoints.ofPlanJoin(lg, plan, j)!;
        final ref = plan.joinRef(j);
        expect(ref, isNot(kJoinRefNone), reason: '$lot join $j is a graph lot');
        // Slot 0's handle is the packed one; slot 2's is negative and the
        // graph places it on the ask (§2.3 join handles).
        expect(ref >= 0, plan.joinSlot(j) != kJoinSlotSideStreet);
        if (ref < 0) sideStreets++;
        final slot = AccessPoints.ofJoin(lg, ref)!;
        expect(a.piece, slot.piece, reason: '$lot join $j');
        expect(a.roadS, slot.roadS, reason: '$lot join $j');
        expect(a.dirs, slot.dirs, reason: '$lot join $j');
        expect(a.rightOfForward, slot.rightOfForward, reason: '$lot join $j');
        expect(a.fwdEdge, slot.fwdEdge, reason: '$lot join $j');
        expect(a.bwdEdge, slot.bwdEdge, reason: '$lot join $j');
        expect(a.joinRef, slot.joinRef);
        // The copies the plan carries ARE the slot's (V3).
        expect(a.piece, plan.joinPiece(j));
        expect(a.roadS, plan.joinRoadS(j));
        expect(a.rightOfForward, plan.joinRight(j));
        checked++;
      }
      // Slot 0 of a plan is the lot's own access, which is what ofLotIndex
      // reads.
      final lotNo = g.lotNoOf(lot)!;
      final own = AccessPoints.ofLotIndex(lg, lotNo)!;
      final zero = AccessPoints.ofPlanJoin(lg, plan, 0)!;
      expect(own.joinRef, g.joinRefOf(lotNo, 0));
      expect(own.piece, zero.piece);
      expect(own.roadS, zero.roadS);
      expect(own.rightOfForward, zero.rightOfForward);
    }
    expect(checked, SyntheticTemplate.values.length + 1,
        reason: 'one join each, and the loop\'s two');
    expect(sideStreets, 1, reason: 'only the loop uses slot 2');
  });

  test('the side is the graph\'s own, on a road drawn the other way and on a '
      'reversed one-way', () {
    /// The lot of [city] nearest (200, ±20).
    Parcel beside(CitySim city, {required bool north}) =>
        lotNearest(city, Vec2(200, north ? 20 : -20));

    // Drawn east: the south kerb is on the right of the polyline. Drawn
    // west over the same ground: the north kerb is.
    for (final east in [true, false]) {
      final city = foundFlat(roads: [
        FixtureRoad(east
            ? const [Vec2(0, 0), Vec2(400, 0)]
            : const [Vec2(400, 0), Vec2(0, 0)]),
      ]);
      final g = city.roadGraph;
      final lg = LaneGraphBuilder.build(g);
      for (final north in [true, false]) {
        final lot = beside(city, north: north);
        final i = g.lotNoOf(lot.id)!;
        final a = AccessPoints.ofLotIndex(lg, i)!;
        expect(a.rightOfForward, g.joinRight[g.lotJoinStart[i]] == 1,
            reason: 'read from joinRight, never re-derived: ${lot.id}');
        expect(a.rightOfForward, north != east, reason: lot.id);
        // One lane each way, so it is served both ways, and the side of
        // travel turns with the edge.
        expect(a.rightOfTravel(lg, a.fwdEdge), a.rightOfForward);
        expect(a.rightOfTravel(lg, a.bwdEdge), !a.rightOfForward);
      }
    }

    // A one-way road whose traffic runs against its polyline: the lot on the
    // right of the polyline is on the LEFT of travel, and is pulled up at
    // from the innermost lane (D6).
    final city = foundFlat(roads: [
      const FixtureRoad([Vec2(0, 0), Vec2(400, 0)],
          roadClass: RoadClass.streetOneWay, reversed: true),
    ]);
    final g = city.roadGraph;
    final lg = LaneGraphBuilder.build(g);
    final south = beside(city, north: false);
    final a = AccessPoints.ofLotIndex(lg, g.lotNoOf(south.id)!)!;
    expect(a.rightOfForward, isTrue);
    expect(a.fwdEdge, -1, reason: 'traffic runs the other way');
    expect(a.rightOfTravel(lg, a.bwdEdge), isFalse);
    expect(a.destLane(lg, a.bwdEdge), lg.edgeLaneCount[a.bwdEdge] - 1);
  });

  group('the loop', () {
    late CitySim city;
    late RoadGraph g;
    late LaneGraph lg;
    late BuildingTable b;
    late int lot, handle, sl, base;
    const site = 'lot-r0x1-r0';

    setUp(() {
      (city, g, lg) = built();
      final plans =
          FixturePlanSource(g, const {site: SyntheticTemplate.loop});
      b = BuildingTable()..sync(city, lg, plans);
      lot = g.lotNoOf(site)!;
      handle = b.handleOfSite(site)!;
      sl = SlotPool.slotOf(handle);
      base = BuildingTable.accRow0(sl);
    });

    test('enters at slot 0 and leaves at the side-street slot 2', () {
      final zero = g.joinRefOf(lot, 0);
      final side = g.joinRefOf(lot, kJoinSlotSideStreet);
      expect(zero, greaterThanOrEqualTo(0));
      expect(side, lessThanOrEqualTo(kJoinRefSideStreetBase));
      expect(b.accCount[sl], 4, reason: 'two joins, each served both ways');
      for (var i = 0; i < 4; i++) {
        final r = base + i;
        final into = b.accBits[r] & kAccIn != 0;
        expect(b.accJoin[r], into ? zero : side);
        expect(b.accBits[r] & kAccOut != 0, !into,
            reason: 'the loop is one way through: in at 0, out at 2');
        expect(b.accBits[r] & kAccCut, kAccCut, reason: 'both are cuts');
      }
      expect(b.accessFlags[sl], 0);
      expect(b.reachable(sl), isTrue);
    });

    test('goals come from the in-capable join, origins from the out-capable '
        'one, each from the lane its side implies', () {
      final ends = PathEnds();
      expect(b.addGoals(handle, ends), isTrue);
      expect(ends.goalCount, 2);
      for (var k = 0; k < ends.goalCount; k++) {
        final r = _rowOn(b, sl, ends.goalEdge[k]);
        expect(b.accBits[r] & kAccIn, kAccIn);
        expect(b.accJoin[r], g.joinRefOf(lot, 0));
        expect(ends.goalT[k], closeTo(b.accT[r], 1e-3));
        expect(ends.goalMask[k], 1 << b.accLane[r], reason: 'D6');
      }

      ends.clear();
      expect(b.addOrigins(handle, ends), isTrue);
      expect(ends.originCount, 2);
      for (var k = 0; k < ends.originCount; k++) {
        final r = _rowOn(b, sl, ends.originEdge[k]);
        expect(b.accBits[r] & kAccOut, kAccOut);
        expect(b.accJoin[r], g.joinRefOf(lot, kJoinSlotSideStreet));
        expect(ends.originT[k], closeTo(b.accT[r], 1e-3));
        expect(ends.originLane[k], -1, reason: 'a departure picks its lane');
      }

      // A back-out onto a road it may not cross leaves in the near
      // direction only.
      final near = ends.originEdge[1];
      ends.clear();
      expect(b.addOrigins(handle, ends, nearEdge: near), isTrue);
      expect(ends.originCount, 1);
      expect(ends.originEdge[0], near);

      // No out-capable row on that edge, no origin: the in-join's edges are
      // not a way out of this site.
      ends.clear();
      expect(b.addOrigins(handle, ends, nearEdge: b.accEdge[base]), isFalse);
      expect(ends.originCount, 0);
    });

    test('leftOfAt and joinAt resolve by (edge, T)', () {
      var lefts = 0;
      for (var i = 0; i < b.accCount[sl]; i++) {
        final r = base + i;
        final e = b.accEdge[r], t = b.accT[r].toDouble();
        final left = b.accBits[r] & kAccLeft != 0;
        if (left) lefts++;
        expect(b.leftOfAt(handle, e, t), left);
        expect(b.joinAt(handle, e, t, 1), b.accJoin[r]);
        expect(b.meetsAt(handle, e, t, 1), isTrue);
        // Far enough along the same edge is another place entirely.
        expect(b.joinAt(handle, e, t + 50, 1), kJoinRefNone);
        expect(b.meetsAt(handle, e, t + 50, 1), isFalse);
      }
      expect(lefts, 2,
          reason: 'each join is on the left of one of its two directions');
      // An edge that serves it not at all answers nothing.
      expect(b.joinAt(handle, 0, 0, 1e9), kJoinRefNone);
      expect(b.leftOfAt(handle, 0, 0), isFalse);
    });
  });

  test('a goal\'s lane mask is the lane that side is reached from (D6)', () {
    // A one-way street has two lanes and both kerbs are served: the lot on
    // the right of travel is pulled in to from the kerb lane, the one across
    // the road from the innermost.
    final city = foundFlat(roads: [
      const FixtureRoad([Vec2(0, 0), Vec2(400, 0)],
          roadClass: RoadClass.streetOneWay),
    ]);
    zoneAll(city);
    buildAll(city);
    final lg = LaneGraphBuilder.build(city.roadGraph);
    final b = BuildingTable()..sync(city, lg);
    final ends = PathEnds();
    for (final north in [true, false]) {
      final lot = lotNearest(city, Vec2(200, north ? 20 : -20));
      final h = b.handleOfSite(lot.id)!;
      final sl = SlotPool.slotOf(h);
      expect(b.accCount[sl], 1, reason: 'one way, so one row: ${lot.id}');
      ends.clear();
      expect(b.addGoals(h, ends), isTrue);
      expect(ends.goalCount, 1);
      expect(lg.edgeLaneCount[ends.goalEdge[0]], 2);
      expect(ends.goalMask[0], north ? 2 : 1, reason: lot.id);
      expect(b.accBits[BuildingTable.accRow0(sl)] & kAccLeft != 0, north,
          reason: 'north of eastbound travel is its left: ${lot.id}');
    }
  });

  test('each template resolves the rows its joins imply', () {
    final (city, g, lg) = built();
    final plans = FixturePlanSource(g, everyTemplate());
    final b = BuildingTable()..sync(city, lg, plans);
    // Every starter fixture lot is on a street with one lane each way, so
    // every join of every template is served both ways: one join is two
    // rows, and only the loop's second join adds more.
    const want = {
      SyntheticTemplate.kerbside: 2,
      SyntheticTemplate.home: 2,
      SyntheticTemplate.homeTandem: 2,
      SyntheticTemplate.strip: 2,
      SyntheticTemplate.loop: 4,
      SyntheticTemplate.yard: 2,
      SyntheticTemplate.utility: 2,
    };
    for (final t in SyntheticTemplate.values) {
      final lot = SyntheticSites.starterLots[t]!.$1;
      final sl = SlotPool.slotOf(b.handleOfSite(lot)!);
      final base = BuildingTable.accRow0(sl);
      final implied = impliedJoins(lg, plans.planOf(lot)!);
      expect(b.accCount[sl], want[t], reason: '$t on $lot');
      expect(b.accCount[sl], implied.length, reason: '$t on $lot');
      for (var i = 0; i < implied.length; i++) {
        expect(b.accJoin[base + i], implied[i], reason: '$t row $i');
      }
      // A kerbside plan is no cut; every other template cuts its kerb.
      final cut = b.accBits[base] & kAccCut != 0;
      expect(cut, t != SyntheticTemplate.kerbside, reason: '$t');
    }
  });

  test('a building the grid placed reads its footprint plan, and its join is '
      'the one no graph slot names', () {
    final city = town();
    final spec = kUtilCatalog.firstWhere((s) => s.cellCount == 1);
    final half = city.grid ~/ 2;
    final anchor = (half + 1) * city.grid + (half + 1);
    city.utils[anchor] = spec;
    final g = city.roadGraph;
    final lg = LaneGraphBuilder.build(g);
    final fp = city.parcelForCell(anchor, spec);
    final id = CitySim.siteIdOfCell(anchor);
    final plans = _Drafted(
        g, [SyntheticSites.footprintDraft(g, polygon: fp.polygon, siteId: id)]);
    final planned = BuildingTable()..sync(city, lg, plans);
    final kerb = BuildingTable()..sync(city, lg);
    final sl = SlotPool.slotOf(planned.handleOfSite(id)!);
    expect(planned.accCount[sl], 2, reason: 'one join, served both ways');
    final base = BuildingTable.accRow0(sl);
    for (var i = 0; i < 2; i++) {
      expect(planned.accJoin[base + i], kJoinRefNone,
          reason: 'a footprint has no graph handle');
      expect(planned.accBits[base + i] & kAccCut, kAccCut);
      // The plan copied the placer's own slot 0, so the rows land exactly
      // where today's footprint access does.
      expect(planned.accEdge[base + i], kerb.accEdge[base + i]);
      expect(planned.accT[base + i], closeTo(kerb.accT[base + i], 1e-3));
      expect(planned.accLane[base + i], kerb.accLane[base + i]);
    }
  });

  test('reachability is per role, and an out-join off the network is no way '
      'out', () {
    final city = town();
    // A road two kilometres off, joined to nothing: a plan resolved before
    // an edit stranded its side street looks like this.
    final lone = city.commitRoad(
        [const Vec2(2000, 0), const Vec2(2300, 0)], RoadClass.street,
        regenerateLots: false)!;
    final g = city.roadGraph;
    final lg = LaneGraphBuilder.build(g);
    var lonePiece = -1;
    for (var p = 0; p < g.pieceCount && lonePiece < 0; p++) {
      if (g.roads[g.pieceRoad[p]].id == lone) lonePiece = p;
    }
    expect(lonePiece, greaterThanOrEqualTo(0));
    expect(lg.edgeInMainScc[g.pieceFwdEdge[lonePiece]], 0);

    const site = 'lot-r0x1-l9';
    BuildingTable resolved(SiteJoinRole role, {bool strandedOut = false}) {
      final d = SyntheticSites.draftAt(g, site, SyntheticTemplate.kerbside,
          siteId: site);
      d.joins[0].role = role;
      if (strandedOut) {
        d.joins.add(DraftJoin(
          slot: 1,
          ref: kJoinRefNone,
          piece: lonePiece,
          roadS: (g.pieceS0[lonePiece] + g.pieceS1[lonePiece]) / 2,
          right: true,
          dirs: RoadGraph.forwardBit | RoadGraph.backwardBit,
          role: SiteJoinRole.outOnly,
          kind: SiteJoinKind.kerbside,
        ));
      }
      return BuildingTable()..sync(city, lg, _Drafted(g, [d]));
    }

    final both = resolved(SiteJoinRole.both);
    var sl = SlotPool.slotOf(both.handleOfSite(site)!);
    expect(both.served[sl], 1);
    expect(both.accessFlags[sl] & kAccessIsolated, 0);
    expect(both.reachable(sl), isTrue);

    // In-capable only: a car can be driven there and never driven away.
    final inOnly = resolved(SiteJoinRole.inOnly);
    sl = SlotPool.slotOf(inOnly.handleOfSite(site)!);
    expect(inOnly.accCount[sl], 2, reason: 'the rows are there either way');
    expect(inOnly.accessFlags[sl] & kAccessIsolated, kAccessIsolated);
    expect(inOnly.reachable(sl), isFalse);

    // Both roles, but the only way out is a road nothing can reach: still
    // no site a trip may use (§3.10, per role).
    final stranded = resolved(SiteJoinRole.inOnly, strandedOut: true);
    sl = SlotPool.slotOf(stranded.handleOfSite(site)!);
    expect(stranded.accCount[sl], 4);
    final base = BuildingTable.accRow0(sl);
    expect(stranded.accBits[base] & kAccIn, kAccIn);
    expect(stranded.accBits[base + 2] & kAccOut, kAccOut);
    expect(lg.edgeInMainScc[stranded.accEdge[base + 2]], 0);
    expect(stranded.accessFlags[sl] & kAccessIsolated, kAccessIsolated);
    expect(stranded.reachable(sl), isFalse);
    // It is still an origin and a goal: the rule says the site is no use to
    // a trip, not that its joins vanished.
    final ends = PathEnds();
    expect(stranded.addOrigins(stranded.handleOfSite(site)!, ends), isTrue);
  });

  test('a plan that is not current, one that is missing, and one whose join '
      'serves nothing all read kerbside at slot 0', () {
    final (city, g, lg) = built();
    const site = 'lot-r0x1-l7';
    final kerb = BuildingTable()..sync(city, lg);

    final plans = FixturePlanSource(g, const {site: SyntheticTemplate.strip});
    final planned = BuildingTable()..sync(city, lg, plans);
    expect(rowsOf(planned, site), isNot(rowsOf(kerb, site)),
        reason: 'a strip cuts its kerb, so its rows differ from a stop at it');

    // Queued for a check: new arrivals read the kerb, not the old joins.
    plans.markStale(site);
    final stale = BuildingTable()..sync(city, lg, plans);
    expect(rowsOf(stale, site), rowsOf(kerb, site));

    // A building the source has no plan for keeps today's access, and so
    // does every other building in the table.
    plans.markStale(site, stale: false);
    for (final other in ['lot-r0x1-l4', 'lot-m3']) {
      expect(rowsOf(planned, other), rowsOf(kerb, other), reason: other);
    }

    // A plan whose only join serves no direction of travel resolves no rows
    // at all, so the site falls back as well.
    final d =
        SyntheticSites.draftAt(g, site, SyntheticTemplate.strip, siteId: site);
    d.joins[0].dirs = 0;
    final dirless = BuildingTable()..sync(city, lg, _Drafted(g, [d]));
    expect(rowsOf(dirless, site), rowsOf(kerb, site));
  });

  test('the colony\'s own book resolves on the starter kit', () {
    final city = starterKit();
    final g = city.roadGraph;
    final lg = LaneGraphBuilder.build(g);
    final book = BookPlanSource(city.siteAccess);
    final b = BuildingTable()..sync(city, lg, book);
    final kerb = BuildingTable()..sync(city, lg);
    var planned = 0, kerbside = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      final id = b.siteId[sl];
      final plan = book.isCurrentFor(id, g) ? book.planOf(id) : null;
      final implied = plan == null ? const <int>[] : impliedJoins(lg, plan);
      if (implied.isEmpty) {
        expect(rowsOf(b, id), rowsOf(kerb, id), reason: id);
        kerbside++;
        continue;
      }
      planned++;
      final base = BuildingTable.accRow0(sl);
      expect(b.accCount[sl], implied.length, reason: id);
      for (var i = 0; i < implied.length; i++) {
        expect(b.accJoin[base + i], implied[i], reason: '$id row $i');
        expect(b.accEdge[base + i], greaterThanOrEqualTo(0), reason: id);
      }
      expect(b.hasAccess(b.handleOf(sl)), isTrue, reason: id);
    }
    expect(planned, greaterThan(0), reason: 'the founding drains the book');
    expect(planned + kerbside, b.liveCount);
  });
}

/// The access row of the building in [sl] on [edge].
int _rowOn(BuildingTable b, int sl, int edge) {
  final base = BuildingTable.accRow0(sl);
  for (var i = 0; i < b.accCount[sl]; i++) {
    if (b.accEdge[base + i] == edge) return base + i;
  }
  throw StateError('no access row on edge $edge');
}

/// Hand-made drafts as a [SitePlanSource]: what [FixturePlanSource] cannot
/// say — a footprint site, a join that serves no direction, a join on a road
/// the network stranded. Plans are emitted through the road side's own
/// builder, unvalidated: these are the states a graph edit leaves behind, not
/// plans a generator would publish.
class _Drafted implements SitePlanSource {
  _Drafted(this.graph, List<DraftSite> drafts)
      : _chunks = List<SiteAccessChunk>.unmodifiable(
            [SyntheticSites.chunkOf(graph, drafts, validate: false)]);

  final RoadGraph graph;
  final List<SiteAccessChunk> _chunks;

  @override
  int get sitesRev => 1;

  @override
  List<SiteAccessChunk> get chunks => _chunks;

  @override
  SiteAccessPlan? planOf(String siteId) {
    final k = _chunks[0].siteOf(siteId);
    return k < 0 ? null : _chunks[0].plan(k);
  }

  @override
  int slotOf(String siteId) => _chunks[0].siteOf(siteId);

  @override
  bool isCurrentFor(String siteId, RoadGraph g) =>
      _chunks[0].siteOf(siteId) >= 0 &&
      g.structureStamp == graph.structureStamp;
}
