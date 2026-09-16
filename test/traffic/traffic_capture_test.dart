// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The agents on the wire (docs/plans/agent-traffic.md §13.1–13.3, §17.1
/// `traffic_capture_test`).
///
/// Every edge's polyline is the capture's own road points, sliced — byte
/// for byte, in travel order, a reversed road's from the flipped copy the
/// capture sent — with its heights from the same snapshots and nothing asked
/// of the ground. The geometry is built once per graph and drapes and
/// handed out by reference, frame after frame; the vehicles' columns are the
/// agents' own, never copied.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/city_traffic_frame.dart';
import 'package:acro_space_simulator/application/snapshot/traffic_capture.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_manoeuvre.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

void main() {
  final system = SampleWorld.realSystem();

  WorldSnapshot capture(CitySim city) => WorldSnapshot.capture(
        0,
        InMemoryVesselRepository(const []),
        system: system,
        cities: InMemoryCityRepository([city]),
      );

  /// [city] with its agents on and one tick run: the lane graph built and a
  /// frame published.
  CitySim live(CitySim city) {
    city.agents.enabled = true;
    city.agents.advance(0.5);
    return city;
  }

  double f32(double x) => (Float32List(1)..[0] = x)[0];

  List<double> pointOf(List<double> p, int i) => [p[3 * i], p[3 * i + 1], p[3 * i + 2]];

  double dist(List<double> a, List<double> b) {
    final dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double norm(List<double> a) => math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);

  /// The snapshot's own arc along its points.
  List<double> arcOf(RoadSnapshot r) {
    final n = r.points.length ~/ 3;
    final arc = <double>[0];
    for (var i = 1; i < n; i++) {
      arc.add(arc.last + dist(pointOf(r.points, i - 1), pointOf(r.points, i)));
    }
    return arc;
  }

  /// A colony with one of everything the slicing has a rule for: two-way
  /// roads crossing (both directions of travel), a reversed one-way street
  /// (flipped on the wire), a curve, a street ending beside the avenue that
  /// the graph attaches part way along it (a piece cut where the capture
  /// sampled nothing), a raised road, a bridged one and a tapered one.
  CitySim mixed() {
    final city = foundFlat(id: 'capture', roads: const [
      FixtureRoad([Vec2(-300, 0), Vec2(300, 0)], roadClass: RoadClass.avenue),
      FixtureRoad([Vec2(0, -300), Vec2(0, 300)]),
      FixtureRoad([Vec2(-300, 150), Vec2(300, 150)],
          roadClass: RoadClass.streetOneWay, reversed: true),
      FixtureRoad([Vec2(-300, -150), Vec2(0, -220), Vec2(300, -150)]),
    ]);
    city.layout.addRoad(RoadSpline(
        id: 'spur',
        roadClass: RoadClass.street,
        controls: const [Vec2(150, 14), Vec2(150, 110)]));
    city.layout.addRoad(RoadSpline(
        id: 'deck',
        roadClass: RoadClass.street,
        controls: const [Vec2(-300, 600), Vec2(300, 600)],
        deck: const RoadDeck(startM: 50, endM: 62)));
    city.layout.addRoad(RoadSpline(
        id: 'bridged',
        roadClass: RoadClass.street,
        controls: const [Vec2(-300, 900), Vec2(300, 900)],
        bridges: const [(100, 400)]));
    city.layout.addRoad(RoadSpline(
        id: 'taper',
        roadClass: RoadClass.avenue,
        controls: const [Vec2(-300, 1200), Vec2(300, 1200)],
        startHalfWidthM: 5));
    return city;
  }

  Map<String, RoadSnapshot> byId(WorldSnapshot snap) =>
      {for (final r in snap.roads) r.id!: r};

  /// Edge [e]'s points.
  List<List<double>> slice(TrafficGeometry g, int e) => [
        for (var k = g.edgePtStart[e]; k < g.edgePtStart[e + 1]; k++)
          pointOf(g.pts, k),
      ];

  group('geometry', () {
    late CitySim city;
    late WorldSnapshot snap;
    late TrafficGeometry g;
    late LaneGraph lg;

    setUpAll(() {
      city = live(mixed());
      snap = capture(city);
      g = snap.cityTraffic.single.geometry;
      lg = city.agents.laneGraph!;
    });

    test('every edge is the slice of its road\'s own points, in travel order',
        () {
      expect(g.complete, isTrue);
      expect(g.graphRev, city.agents.graphRev);
      expect(g.edgeCount, lg.edgeCount);
      final roads = byId(snap);
      var whole = 0, partial = 0, against = 0, flipped = 0;
      for (var e = 0; e < lg.edgeCount; e++) {
        final r = lg.edgeRoad[e];
        final road = lg.graph.roads[r];
        final rs = roads[road.id]!;
        final got = slice(g, e);
        expect(got.length, greaterThanOrEqualTo(2), reason: 'edge $e');
        final n = rs.points.length ~/ 3;
        // Travel runs with the snapshot's points unless the edge runs
        // against its road's own: a backward edge of a two-way road. A
        // reversed one-way road's only edge runs against the road and WITH
        // its snapshot, which the capture flipped.
        final withSnap = (lg.edgeForward[e] == 1) != road.reversed;
        final recLen = lg.graph.roadRecs[r].lengthM;
        final wholeRoad =
            lg.edgeS0[e].abs() < 1e-9 && (lg.edgeS1[e] - recLen).abs() < 1e-6;
        if (wholeRoad) {
          // Byte for byte: the capture's own points, every one.
          expect(got, [
            for (var i = 0; i < n; i++) pointOf(rs.points, withSnap ? i : n - 1 - i),
          ], reason: 'edge $e of ${road.id}');
          whole++;
          if (!withSnap) against++;
          if (road.reversed) flipped++;
        } else {
          partial++;
          // Where the edge's arc range falls on the snapshot, by the same
          // fraction of the road, and the snapshot's points strictly inside.
          final arc = arcOf(rs);
          double onSnap(double s) {
            var f = s / recLen;
            if (road.reversed) f = 1 - f;
            return f.clamp(0.0, 1.0) * arc.last;
          }

          final x0 = onSnap(lg.roadArc(e, 0));
          final x1 = onSnap(lg.roadArc(e, lg.edgeLen[e]));
          final inside = [
            for (var j = 0; j < n; j++)
              if (math.min(x0, x1) + 1e-6 < arc[x0 <= x1 ? j : n - 1 - j] &&
                  arc[x0 <= x1 ? j : n - 1 - j] < math.max(x0, x1) - 1e-6)
                x0 <= x1 ? j : n - 1 - j,
          ];
          expect(got.sublist(1, got.length - 1),
              [for (final i in inside) pointOf(rs.points, i)],
              reason: 'edge $e of ${road.id}');
          // Its ends on the snapshot's line, where the range falls.
          for (final (end, x) in [(got.first, x0), (got.last, x1)]) {
            var i = 0;
            while (i < n - 2 && arc[i + 1] < x) {
              i++;
            }
            final u = (x - arc[i]) / (arc[i + 1] - arc[i]);
            final a = pointOf(rs.points, i), b = pointOf(rs.points, i + 1);
            final want = [for (var c = 0; c < 3; c++) a[c] + (b[c] - a[c]) * u];
            expect(dist(end, want), lessThan(1e-6), reason: 'edge $e end');
          }
        }
        // Every slice runs from the node it leaves to the node it reaches.
        for (final (end, node) in [
          (got.first, lg.edgeFrom[e]),
          (got.last, lg.edgeTo[e]),
        ]) {
          final at = city.localToBodyFixed(lg.graph.nodes[node].at,
              bodyRadiusM: norm(end));
          expect(dist(end, [at.x, at.y, at.z]),
              lessThan(RoadGraph.nodeMatchPlanM + RoadGraph.maxHalfWidth),
              reason: 'edge $e, node $node');
        }
        // Arc along the slice, from 0.
        final a = g.edgePtStart[e];
        expect(g.cum[a], 0);
        for (var k = a + 1; k < g.edgePtStart[e + 1]; k++) {
          expect(g.cum[k], greaterThanOrEqualTo(g.cum[k - 1]));
        }
        expect(g.edgeSimLen[e], f32(lg.edgeLen[e]));
      }
      expect(whole, greaterThan(4));
      expect(partial, greaterThan(0), reason: 'the spur attaches part way');
      expect(against, greaterThan(0));
      expect(flipped, greaterThan(0));
    });

    test('a raised road\'s lift is its snapshot\'s; a draped road\'s is its '
        'class and its bridges', () {
      final roads = byId(snap);
      var deck = 0, bridged = 0;
      for (var e = 0; e < lg.edgeCount; e++) {
        final road = lg.graph.roads[lg.edgeRoad[e]];
        final rs = roads[road.id]!;
        final a = g.edgePtStart[e], b = g.edgePtStart[e + 1];
        final n = rs.points.length ~/ 3;
        final withSnap = (lg.edgeForward[e] == 1) != road.reversed;
        int at(int k) => withSnap ? k - a : n - 1 - (k - a);
        if (road.id == 'deck') {
          expect(rs.lifts, hasLength(n));
          for (var k = a; k < b; k++) {
            expect(g.lift[k], f32(rs.lifts[at(k)]), reason: 'point $k');
          }
          expect(g.lift[a], greaterThan(40));
          deck++;
        } else if (road.id == 'bridged') {
          final arc = arcOf(rs);
          final ranges = [(rs.bridges[0], rs.bridges[1])];
          for (var k = a; k < b; k++) {
            final i = at(k);
            expect(g.lift[k],
                f32(RoadClass.street.deckHeightM +
                    SprawlPlan.bridgeLiftAt(arc[i], ranges)),
                reason: 'point $k');
          }
          bridged++;
        } else if (rs.lifts.isEmpty) {
          for (var k = a; k < b; k++) {
            expect(g.lift[k], f32(road.roadClass.deckHeightM));
          }
        }
      }
      expect(deck, 2, reason: 'both ways along the raised street');
      expect(bridged, 2);
    });

    test('the lanes\' room narrows over a taper exactly as the ribbon does',
        () {
      expect(TrafficCapture.taperM, RoadMesher.taperM);
      final layout = RoadClass.avenue.lanes!;
      final hw = RoadClass.avenue.halfWidth;
      final scale = hw / layout.halfWidthM;
      final shoulder = layout.shoulderM * scale;
      final rs = byId(snap)['taper']!;
      final arc = arcOf(rs);
      for (var e = 0; e < lg.edgeCount; e++) {
        if (lg.graph.roads[lg.edgeRoad[e]].id != 'taper') continue;
        final a = g.edgePtStart[e];
        final n = arc.length;
        final fwd = lg.edgeForward[e] == 1;
        for (var k = a; k < g.edgePtStart[e + 1]; k++) {
          final i = fwd ? k - a : n - 1 - (k - a);
          final want = arc[i] < RoadMesher.taperM
              ? 5 + (hw - 5) * (arc[i] / RoadMesher.taperM)
              : hw;
          expect(g.room[k], closeTo(want - shoulder, 1e-4), reason: 'point $k');
        }
        expect(g.edgeOffScale[e], f32(scale));
      }
    });

    test('lanes keep the graph\'s own offsets; connectors lie on the drape of '
        'the lanes they join', () {
      expect(identical(g.laneOff, lg.laneOff), isTrue);
      expect(identical(g.laneEdge, lg.laneEdge), isTrue);
      for (var l = 0; l < lg.laneCount; l++) {
        final e = lg.laneEdge[l];
        expect(g.laneS0[l], lg.edgeLaneS0[e]);
        expect(g.laneLen[l], f32(lg.edgeLaneS1[e] - lg.edgeLaneS0[e]));
      }
      // The colony's up: a point is put down at a radius along it, on the
      // tangent plane (`SurfacePlacement.place`), so that radius is the
      // point's height along it — not quite the point's length.
      final up0 = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);
      double height(List<double> p) => p[0] * up0.x + p[1] * up0.y + p[2] * up0.z;
      const k = TrafficGeometry.conPoints;
      expect(g.connectorCount, lg.connectorCount);
      for (var c = 0; c < lg.connectorCount; c++) {
        for (var i = 0; i < k; i++) {
          final p = pointOf(g.conPts, k * c + i);
          // The domain's own path, (east, north), on the drape.
          final want = city.localToBodyFixed(
              Vec2(lg.conPts[2 * k * c + 2 * i], lg.conPts[2 * k * c + 2 * i + 1]),
              bodyRadiusM: height(p));
          expect(dist(p, [want.x, want.y, want.z]), lessThan(1e-6));
        }
        expect(g.conPlate[c],
            lg.controls.stopBack[lg.conNode[c]] > 0 ? 1 : 0);
      }
      // The colony is laid out on a tangent plane, so its east and north
      // are one pair of axes everywhere.
      final origin = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);
      final eastAxis =
          city.localToBodyFixed(const Vec2(1, 0), bodyRadiusM: 1) - origin;
      final northAxis =
          city.localToBodyFixed(const Vec2(0, 1), bodyRadiusM: 1) - origin;
      for (var n = 0; n < lg.nodeCount; n++) {
        final p = pointOf(g.nodePts, n);
        final e = pointOf(g.nodeEast, n), no = pointOf(g.nodeNorth, n);
        expect(dist(e, [eastAxis.x, eastAxis.y, eastAxis.z]), lessThan(1e-6));
        expect(dist(no, [northAxis.x, northAxis.y, northAxis.z]),
            lessThan(1e-6));
        final want = city.localToBodyFixed(lg.graph.nodes[n].at,
            bodyRadiusM: height(p));
        expect(dist(p, [want.x, want.y, want.z]), lessThan(1e-6));
      }
    });

    test('nothing is asked of the ground: every height is the snapshots\' own',
        () {
      final ground = Map.of(city.groundCache);
      final cells = Map.of(city.cellGroundRadius);
      // Every snapshot three metres higher. A capture that draped anything
      // itself would leave the geometry where the ground is.
      final raised = [
        for (final r in snap.roads)
          RoadSnapshot(
            colonyId: r.colonyId,
            body: r.body,
            points: Float64List.fromList([
              for (var i = 0; i < r.points.length ~/ 3; i++)
                for (var c = 0; c < 3; c++)
                  r.points[3 * i + c] *
                      (1 + 3 / norm(pointOf(r.points, i))),
            ]),
            halfWidthM: r.halfWidthM,
            roadClassIndex: r.roadClassIndex,
            sealed: r.sealed,
            bridges: r.bridges,
            startHalfWidthM: r.startHalfWidthM,
            endHalfWidthM: r.endHalfWidthM,
            id: r.id,
            decoration: r.decoration,
            lifts: r.lifts,
          ),
      ];
      final up = TrafficCapture.geometryOf(city, lg, raised);
      expect(up.complete, isTrue);
      expect(city.groundCache, ground);
      expect(city.cellGroundRadius, cells);
      for (var k = 0; k < g.pointCount; k++) {
        expect(norm(pointOf(up.pts, k)) - norm(pointOf(g.pts, k)),
            closeTo(3, 1e-6));
      }
    });

    test('a road the graph has not caught up with is left out, not guessed',
        () {
      final roads = byId(snap);
      // One road gone from the capture, and one flipped the other way: a
      // removal and a reversal the agents have not advanced past yet.
      final flippedId = lg.graph.roads[lg.edgeRoad[0]].id;
      final edited = [
        for (final r in snap.roads)
          if (r.id == 'bridged')
            null
          else if (r.id == flippedId)
            RoadSnapshot(
              colonyId: r.colonyId,
              body: r.body,
              points: Float64List.fromList([
                for (var i = r.points.length ~/ 3 - 1; i >= 0; i--)
                  ...pointOf(r.points, i),
              ]),
              halfWidthM: r.halfWidthM,
              roadClassIndex: r.roadClassIndex,
              id: r.id,
            )
          else
            r,
      ].whereType<RoadSnapshot>().toList();
      final partial = TrafficCapture.geometryOf(city, lg, edited);
      expect(partial.complete, isFalse);
      for (var e = 0; e < lg.edgeCount; e++) {
        final id = lg.graph.roads[lg.edgeRoad[e]].id;
        final points = partial.edgePtStart[e + 1] - partial.edgePtStart[e];
        if (id == 'bridged' || id == flippedId) {
          expect(points, 0, reason: 'edge $e of $id');
        } else {
          expect(slice(partial, e), slice(g, e), reason: 'edge $e of $id');
        }
      }
      expect(roads, isNotEmpty);
    });
  });

  group('frames', () {
    test('built once per graph and drapes, handed out by reference', () {
      final city = live(signalised());
      final first = capture(city).cityTraffic.single;
      final again = capture(city).cityTraffic.single;
      expect(identical(again.geometry, first.geometry), isTrue);
      expect(identical(again.net, first.net), isTrue);
      expect(identical(again.agents, city.agents.frame), isTrue);
      expect(first.colonyId, city.id);
      expect(first.bodyId, 'earth');

      // A sub-step: a new frame, over new columns; the geometry stands.
      city.agents.advance(0.2);
      final next = capture(city).cityTraffic.single;
      expect(identical(next.agents, first.agents), isFalse);
      expect(next.agents.timeUs, first.agents.timeUs + 200000);
      expect(identical(next.geometry, first.geometry), isTrue);

      // A junction override re-times the light: the same lanes, so the
      // same geometry, but the heads' plans are new.
      final before = city.agents.laneGraph!;
      city.setJunctionOverride(
          const JunctionOverride(at: Vec2(0, 0), lights: false));
      city.agents.advance(0.2);
      final after = city.agents.laneGraph!;
      expect(identical(after, before), isFalse);
      expect(after.sharesStructureWith(before), isTrue);
      final refreshed = capture(city).cityTraffic.single;
      expect(identical(refreshed.geometry, first.geometry), isTrue);
      expect(identical(refreshed.net, first.net), isFalse);
      expect(refreshed.net.headCount, 0, reason: 'the light is switched off');

      // The shaper settled something: every drape is worked out again, and
      // on ground that did not move they come back as they were, so the
      // geometry stands.
      city.shapedTerrain.add('traffic-capture-test');
      final reshaped = capture(city).cityTraffic.single;
      expect(identical(reshaped.geometry, first.geometry), isTrue);

      // One road's drape worked out a metre higher (a brush laid under it):
      // new geometry, that road's points a metre further up.
      final lg = city.agents.laneGraph!;
      final id = lg.graph.roads.first.id;
      final held = city.drapeCache[id]!;
      city.drapeCache[id] = (
        road: held.road,
        pts: held.pts,
        dirs: held.dirs,
        radii: Float64List.fromList([for (final r in held.radii) r + 1]),
      );
      final raised = capture(city).cityTraffic.single;
      expect(identical(raised.geometry, first.geometry), isFalse);
      final up = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);
      double height(TrafficGeometry g, int k) =>
          g.pts[3 * k] * up.x + g.pts[3 * k + 1] * up.y + g.pts[3 * k + 2] * up.z;
      var moved = 0;
      for (var e = 0; e < lg.roadEdgeCount; e++) {
        if (lg.edgeRoad[e] != 0) continue;
        final a = first.geometry.edgePtStart[e];
        final b = first.geometry.edgePtStart[e + 1];
        expect(raised.geometry.edgePtStart[e + 1] - raised.geometry.edgePtStart[e],
            b - a);
        for (var k = 0; k < b - a; k++) {
          final k1 = raised.geometry.edgePtStart[e] + k;
          expect(height(raised.geometry, k1) - height(first.geometry, a + k),
              closeTo(1, 1e-6),
              reason: 'edge $e, point $k');
          moved++;
        }
      }
      expect(moved, greaterThan(0));

      // A road laid: a new graph, a new revision, new geometry.
      final rev = city.agents.graphRev;
      commit(city, const FixtureRoad([Vec2(-300, 120), Vec2(300, 120)]));
      city.agents.advance(0.2);
      final rebuilt = capture(city).cityTraffic.single;
      expect(city.agents.graphRev, rev + 1);
      expect(rebuilt.geometry.graphRev, rev + 1);
      expect(identical(rebuilt.geometry, raised.geometry), isFalse);
      expect(rebuilt.agents.graphRev, rev + 1);
    });

    test('a frame the renderer holds is not written for two publishes', () {
      final city = town();
      live(city);
      // Some traffic to publish.
      city.agents.advance(60);
      final held = capture(city).cityTraffic.single.agents;
      final s = Float32List.fromList(held.s);
      final elem = Int32List.fromList(held.elem);
      for (var k = 0; k < 2; k++) {
        city.agents.advance(0.2);
        capture(city);
        expect(held.s, s);
        expect(held.elem, elem);
      }
      expect(held.count, greaterThan(0));
    });

    test('without agents a frame carries no traffic, and the wire never does',
        () {
      final city = mixed();
      expect(capture(city).cityTraffic, isEmpty);

      // On, but no graph built yet: the empty geometry and frame.
      city.agents.enabled = true;
      final bare = capture(city).cityTraffic.single;
      expect(identical(bare.geometry, TrafficGeometry.empty), isTrue);
      expect(identical(bare.net, TrafficNetColumns.empty), isTrue);
      expect(bare.agents.count, 0);

      city.agents.advance(0.5);
      final snap = capture(city);
      expect(snap.cityTraffic, hasLength(1));
      final later = snap.copyWithEpoch(snap.epoch + 60);
      expect(identical(later.cityTraffic, snap.cityTraffic), isTrue);
      final json = snap.toJson();
      expect(jsonEncode(json), isNot(contains('graphRev')));
      final back = WorldSnapshot.fromJson(
          jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(back.cityTraffic, isEmpty);
    });
  });

  group('network columns', () {
    test('a head on every signalised leg, timed by the plan the arbiter reads',
        () {
      final city = live(signalised());
      final lg = city.agents.laneGraph!;
      final net = capture(city).cityTraffic.single.net;
      expect(net.headCount, 4);
      expect(net.graphRev, city.agents.graphRev);
      expect(net.plans, hasLength(1));
      final plan = net.plans.single;
      final node = lg.graph.nodes[plan.node];
      final phases = <RoadClass, Set<int>>{};
      for (var h = 0; h < net.headCount; h++) {
        expect(net.headNode[h], node.id);
        final leg = node.legs[net.headLeg[h]];
        expect(leg.inbound, isTrue);
        final e = net.headDirE[h], n = net.headDirN[h];
        expect(e * e + n * n, closeTo(1, 1e-6));
        expect(math.cos(math.atan2(e, n) - leg.heading), closeTo(1, 1e-6));
        expect(net.headHalfWidth[h], f32(leg.roadClass.halfWidth));
        expect(net.headR[h],
            f32(junctionHalfWidthOf(node) * kPlateRadiusPerHalfWidth));
        expect(net.headPhase[h], plan.legPhase[net.headLeg[h]]);
        (phases[leg.roadClass] ??= {}).add(net.headPhase[h]);
        for (var t = 0; t < 64000000; t += 250000) {
          expect(net.stateOf(h, t), plan.stateAt(net.headPhase[h], t));
        }
      }
      // Opposite legs share a phase: the avenue one, the street the other.
      expect(phases[RoadClass.avenue], hasLength(1));
      expect(phases[RoadClass.street], hasLength(1));
      expect(phases[RoadClass.avenue], isNot(phases[RoadClass.street]));
    });
  });

  group('the sites on the wire (T4a, site-access.md §7.4-7.5)', () {
    // A forced trip and nothing else on the road, so the one car inside the
    // lot is the one the test asked for.
    setUp(() => AgentTuning.commuteRatePerResident = 0);
    tearDown(AgentTuning.reset);

    test('a car inside a site is placed off the plan, and parks where it '
        'was last drawn', () {
      final city = starterKit(agentTraffic: true);
      final a = city.agents;
      final trip = a.forceTrip('lot-m2', 'lot-m3');
      expect(trip, isNot(SlotPool.none), reason: 'both sites are built');
      final cols = a.siteVehicles!;
      final table = a.vehicles!;

      // 1. Drive it in. The gate hands it over to the site lanes, and from
      // there it is on no road element at all.
      var slot = -1;
      for (var i = 0; i < 900 && slot < 0; i++) {
        a.advance(kStepS);
        slot = _phaseSlot(a, SitePhase.inbound);
      }
      expect(slot, greaterThanOrEqualTo(0),
          reason: 'the car drove into the pump lot');

      final f1 = capture(city).cityTraffic.single;
      expect(f1.sites, isNotNull);
      final row = cols.row[slot];
      expect(f1.agents.elem[slot], -1, reason: 'a site is no road element');
      expect(f1.agents.siteOrd[slot], a.sites!.bookSlot[row]);
      expect(f1.agents.siteLane[slot], cols.lane[slot]);
      expect(f1.agents.sitesRev, a.sites!.syncedSitesRev);
      expect(f1.sitePoses.sitesRev, f1.sites!.sitesRev);
      var k = -1;
      for (var i = 0; i < f1.sitePoses.count; i++) {
        if (f1.sitePoses.row[i] == slot) k = i;
      }
      expect(k, greaterThanOrEqualTo(0), reason: 'the capture placed it');
      // On the very curve the simulation drives, at its own arc: the pose is
      // the car's CENTRE at `s`, which is where a stall manoeuvre's `u = 0`
      // begins, so the two never disagree by half a car.
      final want = Float64List(4);
      SiteManoeuvre.lanePose(a.sites!.plan[row]!, cols.lane[slot],
          table.s[slot].toDouble(), want, 0);
      expect(f1.sitePoses.e[k], closeTo(want[0], 0.01));
      expect(f1.sitePoses.n[k], closeTo(want[1], 0.01));
      expect(f1.sitePoses.dirE[k], closeTo(want[2], 1e-6));
      expect(f1.sitePoses.dirN[k], closeTo(want[3], 1e-6));

      // 2. It turns into its stall. The last pose drawn while it was still
      // a vehicle is where the parked car has to appear.
      var lastE = double.nan, lastN = double.nan, lastUp = double.nan;
      for (var i = 0; i < 900 && a.parkedCars!.lotCars == 0; i++) {
        a.advance(kStepS);
        final s = _phaseSlot(a, SitePhase.stallIn);
        if (s < 0 || cols.manU[s] < 0.9) continue;
        final f = capture(city).cityTraffic.single;
        for (var j = 0; j < f.sitePoses.count; j++) {
          if (f.sitePoses.row[j] != s) continue;
          lastE = f.sitePoses.e[j];
          lastN = f.sitePoses.n[j];
          lastUp = f.sitePoses.up[j];
        }
      }
      expect(a.parkedCars!.lotCars, 1, reason: 'it parked');
      expect(lastE, isNot(isNaN), reason: 'and it was drawn on its way in');

      final f2 = capture(city).cityTraffic.single;
      expect(f2.parked.lotCount, 1);
      expect(f2.parked.lotSite[0], a.sites!.bookSlot[row]);
      final de = f2.parked.lotE[0] - lastE, dn = f2.parked.lotN[0] - lastN;
      final du = f2.parked.lotUp[0] - lastUp;
      final moved = math.sqrt(de * de + dn * dn + du * du);
      // One sub-step of the manoeuvre is the most it can have moved between
      // the last sample and the stall it lands on, and the failure this
      // guards against — the wrong stall, or the aisle — is metres away.
      expect(moved, lessThan(kStallManoeuvreMps * kStepS + 0.05),
          reason: 'the vehicle row went and the parked car took its place, '
              'in the same spot: ${moved.toStringAsFixed(3)} m apart');
      // ignore: avoid_print
      print('site wire: the parked car appeared '
          '${(moved * 1000).round()} mm from where the vehicle was drawn');
      expect(f2.sitePoses.count, 0, reason: 'nothing is inside the lot now');

      // 3. And a steady frame republishes nothing and asks the ground
      // nothing, the site half included.
      final q0 = WorldSnapshot.groundQueries;
      final f3 = capture(city).cityTraffic.single;
      expect(WorldSnapshot.groundQueries - q0, 0);
      expect(identical(f3.parked, f2.parked), isTrue);
      expect(identical(f3.sites, f2.sites), isTrue);
    });
  });
}

/// The slot of [a]'s one vehicle in [phase], or −1: the site business is
/// read off the columns rather than the trip, because a car that has been
/// handed to a site is no longer the trip's to name.
int _phaseSlot(CityAgents a, SitePhase phase) {
  final t = a.vehicles;
  final cols = a.siteVehicles;
  if (t == null || cols == null) return -1;
  for (var s = 0; s < t.highWater; s++) {
    if (t.isSlotLive(s) && cols.phase[s] == phase.index) return s;
  }
  return -1;
}
