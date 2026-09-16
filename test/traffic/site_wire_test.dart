// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A14 `site_wire_test` (docs/plans/site-access.md §7.9): the sites on the
/// traffic wire.
///
/// Four things, and they are the whole contract between the two sessions:
///
/// 1. **One object, held.** A colony's `CityTrafficFrame.sites` is the very
///    `CitySiteFrame` the snapshot carries — not a copy — and the parked-car
///    columns beside it keep their identity until a car moves, so a steady
///    frame is a handful of identity compares and no work at all.
/// 2. **The heights agree.** A site's kerb node stands on the road's own
///    drape, within a centimetre of where the traffic geometry puts the
///    ribbon a car drives in on: leaving a lot must not step up or down.
/// 3. **The indices are enough.** A published lot row is `(lotSite,
///    lotStall)` — a BOOK SLOT and a stall index — and a reader that looks
///    those up in the site frame lands on the pose the wire published,
///    within a centimetre.
/// 4. **A revision mismatch holds.** A stall index means something only
///    against the plan it was taken from, so a capture whose site revision
///    and site frame disagree republishes the cars it had rather than
///    placing them on another revision's stalls.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/city_traffic_frame.dart';
import 'package:acro_space_simulator/application/snapshot/traffic_capture.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import '../application/site_town_fixture.dart';

void main() {
  late CitySim city;

  /// The colony's traffic frame in a fresh capture, with the snapshot it
  /// came from.
  (WorldSnapshot, CityTrafficFrame) capture() {
    final snap = captureSiteTown(city);
    final f = snap.cityTraffic.singleWhere((f) => f.colonyId == city.id);
    return (snap, f);
  }

  setUpAll(() {
    city = siteTown();
    // The colony's OWN agents, because the capture reads those: the lane
    // graph, the building access rows and the site rows all come up in the
    // first few advances.
    city.agents.enabled = true;
    for (var i = 0; i < 8; i++) {
      city.agents.advance(0.5);
    }
  });

  test('the colony has site rows to publish', () {
    final sites = city.agents.sites;
    expect(sites, isNotNull);
    expect(sites!.highWater, greaterThan(0));
    expect(sites.syncedSitesRev, city.siteAccess.sitesRev);
    // E36 stage 1: the sites whose parking the agents run, by book slot.
    final managed = city.agents.agentManaged;
    var runs = 0;
    for (var i = 0; i < managed.length; i++) {
      if (managed[i] != 0) runs++;
    }
    expect(runs, greaterThan(0),
        reason: 'the road side skips baking lot cars on these');
  });

  test('a steady frame holds the site frame and the parked columns', () {
    final (snap, f) = capture();
    expect(snap.sites, hasLength(1));
    expect(identical(f.sites, snap.sites.single), isTrue,
        reason: 'shared by reference, never copied (§13.1)');
    expect(f.agents.sitesRev, city.agents.sites!.syncedSitesRev);
    expect(f.agentManagedRev, city.agents.agentManagedRev);
    expect(identical(f.agentManaged, city.agents.agentManaged), isTrue);

    final (_, g) = capture();
    expect(identical(g.sites, f.sites), isTrue,
        reason: 'nothing moved, so the site frame is the one it was');
    expect(identical(g.parked, f.parked), isTrue,
        reason: 'no car came or went, so the parked columns are too');
  });

  test('a kerb node stands on the road drape the cars drive in on, ±1 cm',
      () {
    final (snap, f) = capture();
    final sf = f.sites!;
    final up = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);
    final graph = city.roadGraph;
    final byId = <String, RoadSnapshot>{
      for (final r in snap.roads)
        if (r.id != null && r.colonyId == city.id) r.id!: r,
    };
    var checked = 0;
    var worst = 0.0;
    for (final g in sf.chunks) {
      for (var k = 0; k < g.siteCount; k++) {
        final plan = g.plan.plan(k);
        if (plan.graphStamp != graph.structureStamp) continue;
        final ptBase = g.plan.ptStart(k);
        for (var j = 0; j < plan.joinCount; j++) {
          final node = plan.joinKerbNode(j);
          final r = plan.joinRoadNo(j);
          if (node < 0 || r < 0 || r >= graph.roadCount) continue;
          final road = graph.roads[r];
          final snapshot = byId[road.id];
          if (snapshot == null) continue;
          final pt = plan.nodePt(node);
          // The height the site frame published for that node, the offset
          // the plan asked for taken back off: it is the GROUND there.
          final wire = sf.datumRadiusM + g.ptUp(ptBase + pt) - plan.ptDz(pt);
          // The height the traffic geometry reads at the same place: the
          // road snapshot's own points, which is what a lane is sliced from.
          final onRoad = _radiusAt(snapshot, up,
              plan.joinRoadS(j) / graph.roadRecs[r].lengthM, road.reversed);
          if (onRoad == null) continue;
          final d = (wire - onRoad).abs();
          if (d > worst) worst = d;
          checked++;
        }
      }
    }
    expect(checked, greaterThan(10), reason: 'the scan must have found joins');
    // ignore: avoid_print
    print('A14 kerb heights: $checked joins, worst '
        '${(worst * 1000).toStringAsFixed(2)} mm');
    expect(worst, lessThanOrEqualTo(0.01));
  });

  test('a lot row is a book slot and a stall, and lands on the stall pose',
      () {
    final sites = city.agents.sites!;
    final cars = city.agents.parkedCars!;
    // A live site with stalls, and a car standing on its first one.
    var row = -1;
    for (var r = 0; r < sites.highWater && row < 0; r++) {
      if (!sites.isRowLive(r) || sites.stallCount[r] <= 0) continue;
      row = r;
    }
    expect(row, greaterThanOrEqualTo(0), reason: 'a site with a stall');
    final plan = sites.plan[row]!;
    final car = cars.parkLot(
        building: sites.building[row],
        row: row,
        stall: 0,
        stallKey: plan.stallKey(0),
        ownerKind: CarOwnerKind.homePool,
        owner: sites.building[row],
        kind: 0,
        variant: 3);
    addTearDown(() => cars.remove(car));

    final (_, f) = capture();
    final parked = f.parked;
    final sf = f.sites!;
    expect(parked.sitesRev, sf.sitesRev);
    expect(parked.parkedRev, cars.parkedRev);
    expect(parked.lotCount, 1);
    expect(parked.lotSite[0], sites.bookSlot[row],
        reason: 'the BOOK SLOT is the wire ordinal (§0 Q4)');
    expect(parked.lotStall[0], 0);
    expect(parked.lotKind[0], 0);
    expect(parked.lotVariant[0], 3);

    // The indices alone put the car where the wire says it is: this is what
    // a consumer that never saw the agents does.
    final at = sf.locate(parked.lotSite[0]);
    expect(at, isNotNull);
    final (geom, k) = at!;
    final onPlan = geom.plan.plan(k);
    final stall = parked.lotStall[0];
    final want = sf.localToBodyFixed(onPlan.stallE(stall),
        onPlan.stallN(stall), geom.stallUp(geom.plan.stallStart(k) + stall));
    final got = sf.localToBodyFixed(
        parked.lotE[0], parked.lotN[0], parked.lotUp[0]);
    final d = (want - got).length;
    // ignore: avoid_print
    print('A14 lot pose: ${(d * 1000).toStringAsFixed(3)} mm from the stall');
    expect(d, lessThanOrEqualTo(0.01));
    expect(parked.lotDirE[0], closeTo(onPlan.stallDirE(stall), 1e-6));
    expect(parked.lotDirN[0], closeTo(onPlan.stallDirN(stall), 1e-6));

    // A second capture republishes nothing: the car did not move.
    final (_, g) = capture();
    expect(identical(g.parked, parked), isTrue);
  });

  test('a sitesRev mismatch holds the lot cars one publish', () {
    final sites = city.agents.sites!;
    final cars = city.agents.parkedCars!;
    final (snap, before) = capture();
    final sf = before.sites!;
    expect(before.parked.lotCount, 0, reason: 'nothing parked yet');

    // A car parks — and the capture runs against a site frame of ANOTHER
    // revision, as it does in the frame between a re-plan and the agents'
    // next sync.
    var row = -1;
    for (var r = 0; r < sites.highWater && row < 0; r++) {
      if (!sites.isRowLive(r) || sites.stallCount[r] <= 0) continue;
      row = r;
    }
    final plan = sites.plan[row]!;
    final car = cars.parkLot(
        building: sites.building[row],
        row: row,
        stall: 0,
        stallKey: plan.stallKey(0),
        ownerKind: CarOwnerKind.homePool,
        owner: sites.building[row],
        kind: 0,
        variant: 1);
    addTearDown(() => cars.remove(car));

    final stale = CitySiteFrame(
      colonyId: sf.colonyId,
      bodyId: sf.bodyId,
      sitesRev: sf.sitesRev + 1,
      geometryStamp: sf.geometryStamp,
      datumRadiusM: sf.datumRadiusM,
      up: sf.up,
      east: sf.east,
      north: sf.north,
      chunks: sf.chunks,
    );
    final held = TrafficCapture.frameFor(city, sf.bodyId, snap.roads,
        sites: stale);
    expect(identical(held.parked, before.parked), isTrue,
        reason: 'the columns it had, held one publish — not the new car on a '
            'stall index of a plan it has not seen');
    expect(held.parked.lotCount, 0);
    expect(held.parked.sitesRev, sf.sitesRev,
        reason: 'and they still say which revision they are of, so a '
            'renderer holding them knows not to redraw');

    // The very next publish, against the frame's own revision, has it.
    final (_, after) = capture();
    expect(after.parked.lotCount, 1);
    expect(after.parked.sitesRev, sf.sitesRev);
  });
}

/// The body radius of [snap] at [fraction] of its road's index length, along
/// the colony's [up]; null when the snapshot has no line. [reversed] roads
/// are published last control to first, so the fraction counts from the
/// other end — the capture's own `_Road.snapArc`.
double? _radiusAt(
    RoadSnapshot snap, Vector3 up, double fraction, bool reversed) {
  final p = snap.points;
  final n = p.length ~/ 3;
  if (n < 2) return null;
  final arc = Float64List(n);
  for (var i = 1; i < n; i++) {
    final dx = p[3 * i] - p[3 * i - 3];
    final dy = p[3 * i + 1] - p[3 * i - 2];
    final dz = p[3 * i + 2] - p[3 * i - 1];
    arc[i] = arc[i - 1] + math.sqrt(dx * dx + dy * dy + dz * dz);
  }
  final total = arc[n - 1];
  if (total <= 0) return null;
  var f = fraction;
  if (reversed) f = 1 - f;
  final x = f.clamp(0.0, 1.0) * total;
  var lo = 0, hi = n - 2;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (arc[mid] <= x) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  final span = arc[lo + 1] - arc[lo];
  final u = span > 0 ? (x - arc[lo]) / span : 0.0;
  double at(int i) =>
      p[3 * i] * up.x + p[3 * i + 1] * up.y + p[3 * i + 2] * up.z;
  return at(lo) + (at(lo + 1) - at(lo)) * u;
}
