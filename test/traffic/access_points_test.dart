// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// Where a building meets the road (docs/plans/agent-traffic.md §3.10): the
/// road graph's own lot access, read, plus the side of the road the building
/// is on — which is what decides the lane a trip arrives in.
void main() {
  LaneGraph lanesOf(CityLayout layout) =>
      LaneGraphBuilder.build(RoadGraph.of(layout));

  /// A road east from (0, 0) to (400, 0), its lots cut, and its id.
  (CityLayout, String) along(RoadClass cls) {
    final layout = CityLayout();
    final id = layout
        .commitRoad(controls: const [Vec2(0, 0), Vec2(400, 0)], roadClass: cls)
        .roadId;
    return (layout, id);
  }

  /// The lot on [roadId] nearest (200, ±20), north or south of the road.
  Parcel lotBeside(CityLayout layout, String roadId, {required bool north}) {
    final lots = layout.autoParcels
        .where((l) => l.roadId == roadId && (l.centroid.n > 0) == north)
        .toList()
      ..sort((a, b) => a.centroid
          .distanceTo(Vec2(200, north ? 20 : -20))
          .compareTo(b.centroid.distanceTo(Vec2(200, north ? 20 : -20))));
    return lots.first;
  }

  test('access is the road graph\'s own: piece, arc and directions', () {
    final city = town();
    final g = city.roadGraph;
    final lg = LaneGraphBuilder.build(g);
    var resolved = 0;
    for (var i = 0; i < g.lotCount; i++) {
      final a = AccessPoints.ofLotIndex(lg, i);
      if (g.lotPiece[i] < 0) {
        expect(a, isNull, reason: g.lotIds[i]);
        continue;
      }
      resolved++;
      final k = g.lotJoinStart[i];
      expect(a!.piece, g.lotPiece[i]);
      expect(a.roadS, g.lotS[i]);
      expect(a.dirs, g.lotDirs[i]);
      expect(a.joinRef, k, reason: 'slot 0 IS the lot\'s access (C1)');
      expect(a.rightOfForward, g.joinRight[k] == 1,
          reason: 'the side is read, never re-derived from the centroid');
      expect(a.canIn && a.canOut, isTrue, reason: 'a graph slot is both');
      final p = g.lotPiece[i];
      expect(a.fwdEdge,
          g.lotDirs[i] & RoadGraph.forwardBit != 0 ? g.pieceFwdEdge[p] : -1);
      expect(a.bwdEdge,
          g.lotDirs[i] & RoadGraph.backwardBit != 0 ? g.pieceBwdEdge[p] : -1);
      expect(AccessPoints.ofLot(lg, g.lotIds[i])!.piece, p);
    }
    expect(resolved, greaterThan(20));
  });

  test('the side comes from where the lot lies, and on a four-lane road it '
      'is the side the graph lets it be reached from', () {
    final (layout, id) = along(RoadClass.avenue);
    final lg = lanesOf(layout);
    var north = 0, south = 0;
    for (final lot in layout.autoParcels.where((l) => l.roadId == id)) {
      final a = AccessPoints.ofLot(lg, lot.id)!;
      // Drawn east: the south kerb is on the right.
      expect(a.rightOfForward, lot.centroid.n < 0, reason: lot.id);
      // Two lanes each way: the graph serves a lot from its own side only.
      expect(a.dirs,
          a.rightOfForward ? RoadGraph.forwardBit : RoadGraph.backwardBit);
      if (lot.centroid.n > 0) {
        north++;
      } else {
        south++;
      }
    }
    expect(north, greaterThan(0));
    expect(south, greaterThan(0));
  });

  test('a street lot across the road is reached by turning in from the '
      'inner lane; an avenue lot only from its own side', () {
    final (street, sid) = along(RoadClass.street);
    final slg = lanesOf(street);
    final far = AccessPoints.ofLot(slg, lotBeside(street, sid, north: true).id)!;
    // North of an eastbound street: its left. Both ways serve it.
    expect(far.fwdEdge, isNot(-1));
    expect(far.bwdEdge, isNot(-1));
    expect(far.rightOfTravel(slg, far.fwdEdge), isFalse);
    expect(far.destLane(slg, far.fwdEdge), 0,
        reason: 'one lane: the inner lane is the kerb lane');
    expect(far.rightOfTravel(slg, far.bwdEdge), isTrue);

    final (avenue, aid) = along(RoadClass.avenue);
    final alg = lanesOf(avenue);
    final north = AccessPoints.ofLot(alg, lotBeside(avenue, aid, north: true).id)!;
    expect(north.fwdEdge, -1, reason: 'no left turn across four lanes');
    expect(north.bwdEdge, isNot(-1));
    expect(north.destLane(alg, north.bwdEdge), 0, reason: 'its own kerb');
    expect(north.isolated(alg), isFalse);
  });

  test('on a one-way road both kerbs are served, the left from the inner '
      'lane', () {
    final (layout, id) = along(RoadClass.streetOneWay);
    final lg = lanesOf(layout);
    final left = AccessPoints.ofLot(lg, lotBeside(layout, id, north: true).id)!;
    final right = AccessPoints.ofLot(lg, lotBeside(layout, id, north: false).id)!;
    for (final a in [left, right]) {
      expect(a.fwdEdge, isNot(-1));
      expect(a.bwdEdge, -1);
    }
    expect(left.destLane(lg, left.fwdEdge), 1);
    expect(right.destLane(lg, right.fwdEdge), 0);
  });

  test('a hand-drawn lot 89 m off the kerb is served; 91 m off, not', () {
    Parcel? site(double offKerbM) {
      final layout = CityLayout();
      layout.commitRoad(
          controls: const [Vec2(0, 0), Vec2(600, 0)], regenerateLots: false);
      final y = RoadClass.street.halfWidth + offKerbM;
      final lot = layout.addManualParcel([
        Vec2(200, -y),
        Vec2(200, -y - 200),
        Vec2(400, -y - 200),
        Vec2(400, -y),
      ].reversed.toList());
      if (lot == null) return null;
      final lg = lanesOf(layout);
      return AccessPoints.ofLot(lg, lot.id) == null ? null : lot;
    }

    expect(site(89), isNotNull);
    expect(site(91), isNull);
  });

  test('the starter spaceport is reached from the crossroads', () {
    final city = starterKit();
    final lg = LaneGraphBuilder.build(city.roadGraph);
    // The pad is the hand-drawn lot north-east of the crossroads.
    final pad = city.layout.manualParcels
        .firstWhere((p) => p.centroid.e > 0 && p.centroid.n > 0);
    final a = AccessPoints.ofLot(lg, pad.id);
    expect(a, isNotNull);
    expect(a!.isolated(lg), isFalse);
    final edge = a.fwdEdge >= 0 ? a.fwdEdge : a.bwdEdge;
    final s = a.sOn(lg, edge);
    expect(s, inInclusiveRange(lg.edgeLaneS0[edge], lg.edgeLaneS1[edge]));
  });

  test('a building off the plat hangs where the graph\'s attach puts it', () {
    final city = starterKit();
    final g = city.roadGraph;
    final lg = LaneGraphBuilder.build(g);
    final spec =
        kZoneSpecs[CitySim.zoneKindOf(ParcelUse.residential)!]![Density.low]!;
    final half = city.grid ~/ 2;
    final fp = city.parcelForCell((half + 1) + (half + 1) * city.grid, spec);
    final a = AccessPoints.ofFootprint(lg, fp.polygon, centroid: fp.centroid)!;
    final hit = g.attachFootprint(fp.polygon, centroid: fp.centroid)!;
    expect(a.piece, hit.piece);
    expect(a.roadS, hit.sM);
    expect(a.dirs, hit.dirs);
    // Its side is the placer's own, as a lot's is: a footprint has no graph
    // handle, so it is the one join traffic cannot name (kJoinRefNone).
    final slot = g.attachFootprintJoins(fp.polygon, centroid: fp.centroid).first;
    expect(a.rightOfForward, slot.right);
    expect(a.joinRef, kJoinRefNone);
  });

  test('a lot on a road cut off from the rest is isolated', () {
    final layout = CityLayout();
    layout.commitRoad(
        controls: const [Vec2(0, -200), Vec2(0, 200)], regenerateLots: false);
    layout.commitRoad(
        controls: const [Vec2(-200, 0), Vec2(200, 0)], regenerateLots: false);
    // Two kilometres off, joined to nothing.
    final lone = layout
        .commitRoad(controls: const [Vec2(2000, 0), Vec2(2300, 0)])
        .roadId;
    final lg = lanesOf(layout);
    final lot = layout.autoParcels.firstWhere((l) => l.roadId == lone);
    expect(AccessPoints.ofLot(lg, lot.id)!.isolated(lg), isTrue);
    final home = layout.autoParcels.firstWhere((l) => l.roadId != lone);
    expect(AccessPoints.ofLot(lg, home.id)!.isolated(lg), isFalse);
  });
}
