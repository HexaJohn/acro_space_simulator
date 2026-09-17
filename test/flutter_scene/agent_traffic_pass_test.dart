// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The agents' pose pass (docs/plans/agent-traffic.md §13.3–13.8, §17.1
/// `agent_traffic_pass_test`).
///
/// A car sits on its lane's paint, to the right of its travel, on the deck
/// of a raised road and nowhere in a tunnel; it crosses from a lane onto a
/// connector and off it without a jump; its basis is never mirrored. The
/// nearest are drawn first, a draw's instance count stands still while the
/// vehicles in it come and go, and the render clock runs through the frames
/// that carry no tick, stops when the host pauses and snaps after a hitch.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/city_traffic_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/agent_traffic_pass.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_traffic.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/vehicle_meshes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../traffic/traffic_fixture.dart';

/// One hand-placed vehicle.
typedef Car = ({int elem, double s, double v, double a, int next, int flags});

void main() {
  final system = SampleWorld.realSystem();
  final earthRadius =
      system.all.firstWhere((b) => b.id.value == 'earth').radius;

  CityTrafficFrame captured(CitySim city) => WorldSnapshot.capture(
        0,
        InMemoryVesselRepository(const []),
        system: system,
        cities: InMemoryCityRepository([city]),
      ).cityTraffic.single;

  CitySim live(CitySim city) {
    city.agents.enabled = true;
    city.agents.advance(0.5);
    return city;
  }

  /// A frame of [cars], all private cars of [variant], stamped [timeUs].
  AgentFrame frameOf(List<Car> cars, int graphRev,
      {int timeUs = 0, int variant = 0}) {
    final n = cars.length;
    return AgentFrame.fromColumns(
      count: n,
      timeUs: timeUs.toDouble(),
      graphRev: graphRev,
      handle: Int32List.fromList([for (var i = 0; i < n; i++) i + 1]),
      elem: Int32List.fromList([for (final c in cars) c.elem]),
      next: Int32List.fromList([for (final c in cars) c.next]),
      s: Float32List.fromList([for (final c in cars) c.s]),
      v: Float32List.fromList([for (final c in cars) c.v]),
      a: Float32List.fromList([for (final c in cars) c.a]),
      lat: Float32List(n),
      kind: Uint8List(n)..fillRange(0, n, AgentKind.car.index),
      variant: Uint8List(n)..fillRange(0, n, variant),
      flags: Uint8List.fromList([for (final c in cars) c.flags]),
    );
  }

  Car parked(int elem, double s) =>
      (elem: elem, s: s, v: 0, a: 0, next: -1, flags: 0);

  double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  List<double> unit(Vector3 v) {
    final l = v.length;
    return [v.x / l, v.y / l, v.z / l];
  }

  /// An instance matrix's translation is single precision.
  double f32(double x) => (Float32List(1)..[0] = x)[0];

  group('poses', () {
    late CitySim city;
    late CityTrafficFrame f;
    late LaneGraph lg;
    late Vector3 anchor;
    late AgentPoseTables t;
    late List<double> east, north, up;

    setUpAll(() {
      city = foundFlat(id: 'pass', roads: const [
        FixtureRoad([Vec2(-300, 0), Vec2(300, 0)], roadClass: RoadClass.avenue),
        FixtureRoad([Vec2(0, -300), Vec2(0, 300)]),
        FixtureRoad([Vec2(-300, -150), Vec2(0, -230), Vec2(300, -150)]),
      ]);
      // Where the ground is, to put a deck above it and a tunnel under it.
      final ground =
          captured(live(foundFlat(id: 'probe', roads: const [
            FixtureRoad([Vec2(-300, 0), Vec2(300, 0)]),
          ]))).geometry.pts;
      final groundM =
          math.sqrt(ground[0] * ground[0] + ground[1] * ground[1] + ground[2] * ground[2]) -
              earthRadius;
      city.layout.addRoad(RoadSpline(
          id: 'deck',
          roadClass: RoadClass.street,
          controls: const [Vec2(-300, 600), Vec2(300, 600)],
          deck: RoadDeck(startM: groundM + 12, endM: groundM + 12)));
      city.layout.addRoad(RoadSpline(
          id: 'tunnel',
          roadClass: RoadClass.street,
          controls: const [Vec2(-300, 900), Vec2(300, 900)],
          deck: RoadDeck(startM: groundM - 30, endM: groundM - 30)));
      live(city);
      f = captured(city);
      lg = city.agents.laneGraph!;
      final r = math.sqrt(f.geometry.pts[0] * f.geometry.pts[0] +
          f.geometry.pts[1] * f.geometry.pts[1] +
          f.geometry.pts[2] * f.geometry.pts[2]);
      anchor = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r);
      east = unit(city.localToBodyFixed(const Vec2(1, 0), bodyRadiusM: r) - anchor);
      north = unit(city.localToBodyFixed(const Vec2(0, 1), bodyRadiusM: r) - anchor);
      up = unit(anchor);
      t = AgentPoseTables(f.geometry, anchor);
    });

    List<double> at(AgentPose p) => [p.px, p.py, p.pz];

    /// The pose's place in the colony's own (east, north) metres.
    (double, double) local(AgentPose p) => (dot(at(p), east), dot(at(p), north));

    bool roadIs(int e, bool Function(RoadSpline) test) =>
        test(lg.graph.roads[lg.edgeRoad[e]]);

    double gap(AgentPose a, AgentPose b) => math.sqrt(
        math.pow(a.px - b.px, 2) + math.pow(a.py - b.py, 2) + math.pow(a.pz - b.pz, 2));

    test('a car sits on its lane\'s paint, to the right of its travel', () {
      final layout = RoadClass.avenue.lanes!;
      // The mesher draws lane centres at the layout's offsets, scaled to the
      // road's drawn width (road_mesher.dart, `carriageway`).
      final scale = RoadClass.avenue.halfWidth / layout.halfWidthM;
      final nLanes = layout.lanesEachWay;
      var checked = 0;
      final pose = AgentPose(), start = AgentPose(), end = AgentPose();
      for (var e = 0; e < lg.edgeCount; e++) {
        if (!roadIs(e, (r) => r.roadClass == RoadClass.avenue)) continue;
        for (var k = 0; k < lg.edgeLaneCount[e]; k++) {
          final l = lg.laneOf(e, k);
          final len = f.geometry.laneLen[l];
          expect(t.poseAt(l, len / 2, 0, pose), isTrue);
          expect(t.poseAt(l, 0, 0, start), isTrue);
          expect(t.poseAt(l, len, 0, end), isTrue);
          final eastbound = local(end).$1 > local(start).$1;
          final paint = layout.laneOffsets[nLanes - 1 - k] * scale;
          // Right-hand traffic: right of eastbound is south.
          expect(local(pose).$2, closeTo(eastbound ? -paint : paint, 0.02),
              reason: 'edge $e lane $k');
          expect(dot([pose.fx, pose.fy, pose.fz], east) * (eastbound ? 1 : -1),
              greaterThan(0.999));
          // Draped, unbridged: the ribbon's own lift and nothing more.
          expect(pose.lift, closeTo(RoadMesher.ribbonLiftM, 1e-6));
          checked++;
        }
      }
      expect(checked, 8, reason: 'two avenue pieces, two lanes each way');
    });

    test('on a curve a car keeps its lane\'s offset, on the right', () {
      final roads = {
        for (final r in WorldSnapshot.capture(0, InMemoryVesselRepository(const []),
                system: system, cities: InMemoryCityRepository([city]))
            .roads)
          r.id: r,
      };
      final pose = AgentPose();
      var checked = 0;
      for (var e = 0; e < lg.edgeCount; e++) {
        final road = lg.graph.roads[lg.edgeRoad[e]];
        // The curve's pieces: the only roads that run east–west down there.
        if (!road.controls.any((c) => c.n < -160) ||
            (road.controls.first.e - road.controls.last.e).abs() < 100) {
          continue;
        }
        final rs = roads[road.id]!;
        final line = [
          for (var i = 0; i < rs.points.length ~/ 3; i++)
            (
              dot([rs.points[3 * i] - anchor.x, rs.points[3 * i + 1] - anchor.y,
                  rs.points[3 * i + 2] - anchor.z], east),
              dot([rs.points[3 * i] - anchor.x, rs.points[3 * i + 1] - anchor.y,
                  rs.points[3 * i + 2] - anchor.z], north),
            ),
        ];
        final l = lg.laneOf(e, 0);
        final want = lg.laneOff[l];
        for (var s = 5.0; s < f.geometry.laneLen[l] - 5; s += 10) {
          expect(t.poseAt(l, s, 0, pose), isTrue);
          final (x, y) = local(pose);
          // Nearest point of the drape's line, and the side it is on.
          var best = double.infinity, cross = 0.0;
          for (var i = 1; i < line.length; i++) {
            final (ax, ay) = line[i - 1];
            final (bx, by) = line[i];
            final dx = bx - ax, dy = by - ay;
            final u = (((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy))
                .clamp(0.0, 1.0);
            final px = ax + dx * u, py = ay + dy * u;
            final d = math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
            if (d < best) {
              best = d;
              final fx = dot([pose.fx, pose.fy, pose.fz], east);
              final fy = dot([pose.fx, pose.fy, pose.fz], north);
              cross = fx * (y - py) - fy * (x - px);
            }
          }
          expect(best, closeTo(want, 0.1), reason: 'edge $e at $s');
          // Negative cross in east-north is to the right.
          expect(cross, lessThan(0), reason: 'edge $e at $s');
          checked++;
        }
      }
      expect(checked, greaterThan(40));
    });

    test('a car crosses onto a connector and off it without a jump', () {
      final a = AgentPose(), b = AgentPose();
      final g = f.geometry;
      var checked = 0;
      for (var c = 0; c < g.connectorCount; c++) {
        final from = g.conFromLane[c], to = g.conToLane[c];
        final elem = g.laneCount + c;
        if (!t.poseAt(from, g.laneLen[from], 0, a)) continue;
        expect(t.poseAt(elem, 0, 0, b), isTrue);
        expect(gap(a, b), lessThan(1e-6), reason: 'into connector $c');
        expect(b.lift, closeTo(a.lift, 1e-9));
        expect(t.poseAt(elem, g.conLen[c], 0, a), isTrue);
        expect(t.poseAt(to, 0, 0, b), isTrue);
        expect(gap(a, b), lessThan(1e-6), reason: 'off connector $c');
        checked++;
      }
      expect(checked, greaterThan(20));
    });

    test('no basis is ever mirrored', () {
      final p = AgentPose();
      final m = vm.Matrix4.zero();
      var checked = 0;
      for (var elem = 0; elem < f.geometry.elementCount; elem++) {
        final len = t.lengthOf(elem);
        for (final s in [-2.0, 0.0, len / 3, len, len + 2]) {
          if (!t.poseAt(elem, s, 0, p)) continue;
          final side = [p.sx, p.sy, p.sz];
          final fwd = [p.fx, p.fy, p.fz];
          final u = [p.ux, p.uy, p.uz];
          for (final v in [side, fwd, u]) {
            expect(dot(v, v), closeTo(1, 1e-9));
          }
          expect(dot(side, fwd).abs(), lessThan(1e-9));
          expect(dot(side, u).abs(), lessThan(1e-9));
          expect(dot(fwd, u).abs(), lessThan(1e-9));
          // side · (forward × up) = +1: a rotation, never a reflection.
          final det = side[0] * (fwd[1] * u[2] - fwd[2] * u[1]) -
              side[1] * (fwd[0] * u[2] - fwd[2] * u[0]) +
              side[2] * (fwd[0] * u[1] - fwd[1] * u[0]);
          expect(det, closeTo(1, 1e-9));
          TrafficRoad.writePose(m, p.px, p.py, p.pz, p.sx, p.sy, p.sz, p.fx,
              p.fy, p.fz, p.ux, p.uy, p.uz);
          expect(m.getRotation().determinant(), closeTo(1, 1e-5));
          // Up stays near the body's radial: a road is never steep.
          expect(dot(u, up), greaterThan(0.99));
          checked++;
        }
      }
      expect(checked, greaterThan(100));
    });

    test('a raised road carries a car on its deck; a tunnel hides it', () {
      final g = f.geometry;
      final p = AgentPose();
      var deck = 0, tunnel = 0;
      for (var e = 0; e < lg.edgeCount; e++) {
        final id = lg.graph.roads[lg.edgeRoad[e]].id;
        if (id != 'deck' && id != 'tunnel') continue;
        final l = lg.laneOf(e, 0);
        if (id == 'tunnel') {
          for (var s = 0.0; s <= g.laneLen[l]; s += 25) {
            expect(t.poseAt(l, s, 0, p), isFalse);
          }
          tunnel++;
          continue;
        }
        // At a point of the capture's own: the ribbon's lift plus the deck,
        // the numbers that raise the ribbon.
        final a = g.edgePtStart[e];
        final k = a + 3;
        final s = g.cum[k] * g.edgeSimLen[e] / g.cum[g.edgePtStart[e + 1] - 1] -
            g.laneS0[l];
        expect(t.poseAt(l, s, 0, p), isTrue);
        expect(p.lift, closeTo(RoadMesher.ribbonLiftM + g.lift[k], 1e-4));
        expect(g.lift[k], greaterThan(5), reason: 'on its deck, clear of the ground');
        deck++;
      }
      expect(deck, 2);
      expect(tunnel, 2);

      // A frame with a car in the tunnel draws nothing, and says so.
      final tunnelLane = [
        for (var e = 0; e < lg.edgeCount; e++)
          if (lg.graph.roads[lg.edgeRoad[e]].id == 'tunnel') lg.laneOf(e, 0),
      ].first;
      final pass = AgentTrafficPass();
      final placed = pass.place(
          CityTrafficFrame(
              colonyId: city.id,
              bodyId: 'earth',
              agents: frameOf([parked(tunnelLane, 50)], g.graphRev),
              geometry: g,
              net: f.net),
          anchor,
          anchor,
          wallNowS: 0);
      expect(placed, 0);
      expect(pass.hidden, 1);
    });

    test('a turning place in a tunnel hides its cars too: a connector '
        'joining two lanes underground is never drawn on the ground above '
        'them', () {
      final g = f.geometry;
      final nL = g.laneCount;
      final p = AgentPose();
      bool inTunnel(int lane) =>
          lg.graph.roads[lg.edgeRoad[g.laneEdge[lane]]].id == 'tunnel';
      final under = [
        for (var c = 0; c < g.connectorCount; c++)
          if (inTunnel(g.conFromLane[c]) && inTunnel(g.conToLane[c])) c,
      ];
      expect(under, isNotEmpty, reason: 'the tunnel\'s ends turn cars round');
      for (final c in under) {
        final len = g.conLen[c].toDouble();
        for (final s in [0.0, len / 2, len]) {
          expect(t.poseAt(nL + c, s, 0, p), isFalse,
              reason: 'connector $c at $s m');
        }
      }
      final c = under.first;
      final pass = AgentTrafficPass();
      final placed = pass.place(
          CityTrafficFrame(
              colonyId: city.id,
              bodyId: 'earth',
              agents: frameOf([parked(nL + c, g.conLen[c] / 2)], g.graphRev),
              geometry: g,
              net: f.net),
          anchor,
          anchor,
          wallNowS: 0);
      expect(placed, 0);
      expect(pass.hidden, 1);
    });

    test('a road laid shows every car at once: a frame is published on the '
        'new graph before any sub-step runs, and most host ticks run none', () {
      final town0 = live(town());
      town0.agents.advance(60);
      final r0 = captured(town0).geometry;
      final r = math.sqrt(r0.pts[0] * r0.pts[0] +
          r0.pts[1] * r0.pts[1] +
          r0.pts[2] * r0.pts[2]);
      final at = town0.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r);
      final pass = AgentTrafficPass();
      expect(pass.place(captured(town0), at, at, wallNowS: 0), greaterThan(0));

      final rev = town0.agents.graphRev;
      commit(town0, const FixtureRoad([Vec2(-300, 150), Vec2(300, 150)]));
      // One world tick at 1×: 0.02 s, a tenth of a sub-step.
      town0.agents.advance(0.02);
      final after = captured(town0);
      expect(after.geometry.graphRev, rev + 1);
      expect(after.agents.graphRev, rev + 1);
      expect(pass.place(after, at, at, wallNowS: 0.02), greaterThan(0));
    });

    test('a vehicle rolls on into its next element, never past a stop', () {
      final g = f.geometry;
      final pass = AgentTrafficPass();
      // A lane, a connector off it, and the lane it reaches.
      final l = lg.laneOf(
          [for (var e = 0; e < lg.edgeCount; e++)
            if (roadIs(e, (r) => r.roadClass == RoadClass.avenue)) e].first,
          0);
      final c = lg.laneConStart[l];
      final con = g.laneCount + c;
      final to = g.conToLane[c];
      final len = g.laneLen[l];
      double along(double s, double v, double a, double tau,
              {int next = -1, bool stopping = false}) =>
          pass.advanceAlong(t, l, next, s, v, a, tau, stopping: stopping);

      expect(along(10, 10, 0, 0.1), closeTo(11, 1e-9));
      // Braking to a stand inside the interval: it stops, it never reverses.
      expect(along(10, 1, -5, 0.3), closeTo(10.1, 1e-9));
      // Back in time, before a car at rest pulled away: where it stood.
      expect(along(10, 0, 2, -0.1), 10);
      expect(along(0.2, 5, 0, -0.1), 0, reason: 'never below 0');
      // Past the lane's end into the connector, with the remainder.
      expect(along(len - 0.5, 10, 0, 0.1, next: con), closeTo(0.5, 1e-4));
      expect(pass.lastElement, con);
      // Past the connector too, into the lane it reaches.
      expect(along(len - 0.1, 10, 0, 0.2 + g.conLen[c] / 10, next: con),
          closeTo(1.9, 1e-3));
      expect(pass.lastElement, to);
      // Never past a line it was refused at, nor the end of its route.
      expect(along(len - 0.5, 10, 0, 0.1, next: con, stopping: true), len);
      expect(pass.lastElement, l);
      expect(along(len - 0.5, 10, 0, 0.1), len);
    });

    test('the nearest are drawn first, in slot order, up to the cap', () {
      final grid = foundFlat(id: 'rings', roads: const [
        FixtureRoad([Vec2(0, -300), Vec2(0, 4000)]),
        FixtureRoad([Vec2(-100, 0), Vec2(100, 0)]),
        FixtureRoad([Vec2(-100, 1000), Vec2(100, 1000)]),
        FixtureRoad([Vec2(-100, 2000), Vec2(100, 2000)]),
        FixtureRoad([Vec2(-100, 3000), Vec2(100, 3000)]),
      ]);
      live(grid);
      final gf = captured(grid);
      expect(gf.geometry.complete, isTrue, reason: 'every piece, 4 km out too');
      final glg = grid.agents.laneGraph!;
      final r = math.sqrt(gf.geometry.pts[0] * gf.geometry.pts[0] +
          gf.geometry.pts[1] * gf.geometry.pts[1] +
          gf.geometry.pts[2] * gf.geometry.pts[2]);
      final anchorBF = grid.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r);
      final focus = grid.localToBodyFixed(const Vec2(0, -300), bodyRadiusM: r);
      final tables = AgentPoseTables(gf.geometry, anchorBF);
      // The northbound lane of the long street's piece starting at [y].
      int laneFrom(double y) {
        for (var e = 0; e < glg.edgeCount; e++) {
          final road = glg.graph.roads[glg.edgeRoad[e]];
          if (road.controls.first.e != 0 || road.controls.last.e != 0) continue;
          final from = glg.graph.nodes[glg.edgeFrom[e]].at;
          final to = glg.graph.nodes[glg.edgeTo[e]].at;
          if ((from.n - y).abs() < 1 && to.n > from.n) return glg.laneOf(e, 0);
        }
        throw StateError('no piece from $y');
      }

      final a = laneFrom(-300), b = laneFrom(0), c = laneFrom(1000);
      final d = laneFrom(2000), e = laneFrom(3000);
      // Rings by distance: a and b within 500 m, c within 1,500, d and e
      // beyond — in scrambled slot order.
      final lanes = [d, a, c, e, b, c, a];
      final cars = [
        for (var i = 0; i < lanes.length; i++) parked(lanes[i], 20.0 + i),
      ];
      final frame = CityTrafficFrame(
          colonyId: grid.id,
          bodyId: 'earth',
          agents: frameOf(cars, gf.geometry.graphRev),
          geometry: gf.geometry,
          net: gf.net);

      Set<(double, double, double)> drawn(AgentTrafficPass pass) => {
            for (final batch in pass.batches)
              if (batch != null)
                for (var i = 0; i < batch.live; i++)
                  (
                    batch.poses.matrices[i].storage[12],
                    batch.poses.matrices[i].storage[13],
                    batch.poses.matrices[i].storage[14],
                  ),
          };
      (double, double, double) centreOf(int row) {
        final p = AgentPose();
        expect(tables.poseAt(cars[row].elem,
                cars[row].s - VehicleKind.coupe.lengthM / 2, 0, p),
            isTrue);
        return (
          f32(lengthToScene(p.px)),
          f32(lengthToScene(p.py)),
          f32(lengthToScene(p.pz)),
        );
      }

      addTearDown(() {
        AgentTrafficPass.renderCap = 1500;
        AgentTrafficPass.rangeM = 3500;
      });
      AgentTrafficPass.renderCap = 4;
      final pass = AgentTrafficPass();
      expect(pass.place(frame, anchorBF, focus, wallNowS: 0), 4);
      expect(pass.inRange, 7);
      // Ring 0 in slot order — rows 1, 4, 6 — then ring 1's first, row 2.
      expect(drawn(pass), {for (final row in [1, 4, 6, 2]) centreOf(row)});

      AgentTrafficPass.renderCap = 100;
      AgentTrafficPass.rangeM = 3000;
      final wider = AgentTrafficPass();
      expect(wider.place(frame, anchorBF, focus, wallNowS: 0), 6);
      expect(drawn(wider),
          {for (final row in [0, 1, 2, 4, 5, 6]) centreOf(row)},
          reason: 'row 3 is beyond the range');
    });

    test('a draw\'s instance count stands still within a bucket of 64', () {
      final g = f.geometry;
      final l = lg.laneOf(
          [for (var e = 0; e < lg.edgeCount; e++)
            if (roadIs(e, (r) => r.roadClass == RoadClass.avenue)) e].first,
          0);
      final pass = AgentTrafficPass();
      AgentDrawBatch batchAfter(int n, int step) {
        final cars = [
          for (var i = 0; i < n; i++) parked(l, (i * 2.0) % g.laneLen[l] + 3),
        ];
        pass.place(
            CityTrafficFrame(
                colonyId: city.id,
                bodyId: 'earth',
                agents: frameOf(cars, g.graphRev, timeUs: step * 200000),
                geometry: g,
                net: f.net),
            anchor,
            anchor,
            wallNowS: step * 0.2);
        return pass.batchOf(VehicleKind.coupe, true);
      }

      var step = 0;
      for (final (n, want) in [(10, 64), (50, 64), (63, 64), (64, 64),
        (65, 128), (10, 128), (127, 128)]) {
        final batch = batchAfter(n, step++);
        expect(batch.live, n);
        expect(batch.poses.count, want, reason: '$n vehicles');
        expect(batch.highWater, want);
        for (var i = n; i < batch.poses.count; i++) {
          expect(batch.poses.matrices[i].storage.every((x) => x == 0), isTrue);
        }
      }
      pass.resetHighWater();
      expect(batchAfter(10, step++).poses.count, 64);
    });

    test('a frame of another graph revision is not drawn', () {
      final g = f.geometry;
      final pass = AgentTrafficPass();
      final placed = pass.place(
          CityTrafficFrame(
              colonyId: city.id,
              bodyId: 'earth',
              agents: frameOf([parked(0, 10)], g.graphRev + 1),
              geometry: g,
              net: f.net),
          anchor,
          anchor,
          wallNowS: 0);
      expect(placed, 0);
    });
  });

  group('the render clock', () {
    AgentFrame sampleAt(int timeUs) => AgentFrame.fromColumns(
          count: 0,
          timeUs: timeUs.toDouble(),
          graphRev: 1,
          handle: Int32List(0),
          elem: Int32List(0),
          next: Int32List(0),
          s: Float32List(0),
          v: Float32List(0),
          a: Float32List(0),
          lat: Float32List(0),
          kind: Uint8List(0),
          variant: Uint8List(0),
          flags: Uint8List(0),
        );

    test('runs through the frames that carry no tick, pauses, and snaps', () {
      final clock = AgentRenderClock();
      // 60 Hz frames against the world's 20 ms ticks, and a sub-step's
      // sample every ten ticks.
      var wall = 0.0, acc = 0.0, ticks = 0, sampleUs = 0, tickless = 0;
      var sample = sampleAt(0);
      clock.advance(sample, wall);
      var last = clock.renderT;
      for (var frame = 0; frame < 600; frame++) {
        wall += 1 / 60;
        acc += 1 / 60;
        var ran = 0;
        while (acc >= 0.02 - 1e-12) {
          acc -= 0.02;
          ran++;
          if (++ticks % 10 == 0) sample = sampleAt(sampleUs += 200000);
        }
        if (ran == 0) tickless++;
        clock.advance(sample, wall);
        expect(clock.renderT, greaterThan(last), reason: 'frame $frame');
        expect((clock.renderT - sample.timeUs / 1e6).abs(),
            lessThanOrEqualTo(AgentRenderClock.h + 1e-9));
        last = clock.renderT;
      }
      expect(tickless, greaterThan(50));
      expect(clock.rate, closeTo(1, 0.1));

      // The host pauses: no ticks, and the vehicles stand exactly still.
      final frozen = clock.renderT;
      for (var frame = 0; frame < 60; frame++) {
        wall += 1 / 60;
        clock.advance(sample, wall, warp: 0);
        expect(clock.renderT, frozen);
      }

      // A hitch: a second of wall time and no sample. The clock does not
      // run away from the sample; it snaps to it.
      wall += 1.0;
      clock.advance(sample, wall);
      expect(clock.renderT, sample.timeUs / 1e6);
      expect(clock.tau, 0);
    });

    test('at a warp the rate follows the samples', () {
      final clock = AgentRenderClock();
      var wall = 0.0, sampleUs = 0;
      // Four sub-steps a frame: the frame hold's most.
      for (var frame = 0; frame < 300; frame++) {
        wall += 1 / 60;
        sampleUs += 4 * 200000;
        clock.advance(sampleAt(sampleUs), wall);
      }
      expect(clock.rate, closeTo(48, 2));
    });
  });

  group('a steady scene leaves the shared instance buffer alone', () {
    // §13.8. Every instanced draw in the process emplaces its matrices into
    // ONE host buffer (flutter_scene's `instance_packing.dart`), and the
    // engine repacks an item whenever its mesh version moves — so the
    // renderer must not write matrices back that nothing moved. Two rules
    // here: a draw's instance count stands still (the bucket of 64), and a
    // batch's revision moves only when a pose did.
    late CityTrafficFrame steady;
    late Vector3 at;

    setUpAll(() {
      final grown = live(town());
      grown.agents.advance(60);
      steady = captured(grown);
      final p = steady.geometry.pts;
      final r = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
      at = grown.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r);
    });

    List<int> countsOf(AgentTrafficPass pass) =>
        [for (final b in pass.batches) b?.poses.count ?? -1];
    int revSum(AgentTrafficPass pass) =>
        pass.batches.fold(0, (n, b) => n + (b?.rev ?? 0));

    test('a frame that moved nothing places nothing anew', () {
      final pass = AgentTrafficPass();
      final placed = pass.place(steady, at, at, wallNowS: 0);
      expect(placed, greaterThan(0));
      final counts = countsOf(pass);
      final revs = revSum(pass);

      // The same sample at the same wall time: the clock did not run.
      expect(pass.place(steady, at, at, wallNowS: 0), placed);
      expect(revSum(pass), revs, reason: 'nothing to repack');
      expect(countsOf(pass), counts);

      // The host paused (E26): wall time runs on, the clock stands still,
      // and a paused colony costs the buffer nothing at all.
      for (var i = 1; i <= 30; i++) {
        expect(pass.place(steady, at, at, wallNowS: i / 60, warp: 0), placed);
      }
      expect(revSum(pass), revs, reason: 'a paused host repacks nothing');
      expect(countsOf(pass), counts);
    });

    test('the counts stand still while the clock runs, and the repacks stop '
        'when it does', () {
      final pass = AgentTrafficPass();
      pass.place(steady, at, at, wallNowS: 0);
      final counts = countsOf(pass);
      var wall = 0.0, was = revSum(pass);
      final moved = <bool>[];
      for (var i = 0; i < 40; i++) {
        wall += 1 / 60;
        pass.place(steady, at, at, wallNowS: wall);
        expect(countsOf(pass), counts, reason: 'frame $i');
        final now = revSum(pass);
        moved.add(now != was);
        was = now;
      }
      expect(moved.first, isTrue, reason: 'the clock ran: the cars moved');
      // With no new sample the clock runs one sub-step past it and waits
      // there (§13.4) — and a clock that stands still repacks nothing.
      expect(moved.last, isFalse);
      expect(moved.where((m) => m).length, lessThan(20),
          reason: 'it waits out the rest of the frames');
    });

    test('the site cars keep their counts, and the parked ones are written '
        'only when a car comes or goes', () {
      // Hand-built columns: what the capture hands the renderer (§13.1,
      // §13.2, site-access.md §7.4) — a new pose set every capture, and a
      // parked set whose identity moves only with the parked revision.
      final sites = CitySiteFrame(
          colonyId: 'c',
          bodyId: 'earth',
          sitesRev: 7,
          geometryStamp: 0,
          datumRadiusM: 6.371e6,
          up: const Vector3(0, 0, 1),
          east: const Vector3(1, 0, 0),
          north: const Vector3(0, 1, 0),
          chunks: const []);
      final anchor = const Vector3(0, 0, 6.371e6);
      final agents = frameOf(
          [for (var i = 0; i < 8; i++) parked(0, 10)], steady.geometry.graphRev);

      SitePoseColumns inside(int cars, double shift) => SitePoseColumns(
            count: cars,
            sitesRev: 7,
            sealed: false,
            row: Int32List.fromList([for (var i = 0; i < cars; i++) i]),
            e: Float32List.fromList(
                [for (var i = 0; i < cars; i++) 10.0 * i + shift]),
            n: Float32List(cars),
            up: Float32List(cars),
            dirE: Float32List(cars)..fillRange(0, cars, 1),
            dirN: Float32List(cars),
          );
      ParkedColumns onStalls(int cars) => ParkedColumns(
            parkedRev: cars,
            sitesRev: 7,
            lotCount: cars,
            lotSite: Int32List(cars),
            lotStall: Int32List(cars),
            lotKind: Uint8List(cars)..fillRange(0, cars, AgentKind.car.index),
            lotVariant: Uint8List(cars),
            lotE: Float32List.fromList([for (var i = 0; i < cars; i++) 4.0 * i]),
            lotN: Float32List(cars),
            lotUp: Float32List(cars),
            lotDirE: Float32List(cars)..fillRange(0, cars, 1),
            lotDirN: Float32List(cars),
          );
      CityTrafficFrame frameOfCars(SitePoseColumns p, ParkedColumns k) =>
          CityTrafficFrame(
              colonyId: 'c',
              bodyId: 'earth',
              agents: agents,
              geometry: steady.geometry,
              net: steady.net,
              sites: sites,
              sitePoses: p,
              parked: k);

      final site = SiteCarPass();
      final near = VehicleKind.coupe.index * 2;
      final p0 = inside(5, 0), k0 = onStalls(3);
      expect(site.place(frameOfCars(p0, k0), anchor, anchor), 5);
      expect(site.vehicles.live[near], 5);
      expect(site.parked.live[near], 3);
      for (final b in [site.vehicles, site.parked]) {
        expect(b.poses[near]!.count, 64, reason: 'bucketed, like the road\'s');
        for (var i = b.live[near]; i < 64; i++) {
          expect(b.poses[near]!.matrices[i].storage.every((x) => x == 0), isTrue,
              reason: 'the padding is zero scale');
        }
      }
      final vRev = site.vehicles.rev, pRev = site.parked.rev;

      // The same columns again — the capture published nothing new: neither
      // half is written.
      expect(site.place(frameOfCars(p0, k0), anchor, anchor), 5);
      expect(site.vehicles.rev, vRev);
      expect(site.parked.rev, pRev);

      // The cars inside the sites moved and one more drove in; the parked
      // ones did not move, and are not written for it.
      final p1 = inside(6, 3);
      expect(site.place(frameOfCars(p1, k0), anchor, anchor), 6);
      expect(site.vehicles.rev, vRev + 1);
      expect(site.vehicles.live[near], 6);
      expect(site.vehicles.poses[near]!.count, 64, reason: 'the count stands still');
      expect(site.parked.rev, pRev, reason: 'not one parked matrix rewritten');

      // A car parked: the parked half is written, once, and its count does
      // not move for it either.
      expect(site.place(frameOfCars(p1, onStalls(4)), anchor, anchor), 6);
      expect(site.parked.rev, pRev + 1);
      expect(site.parked.live[near], 4);
      expect(site.parked.poses[near]!.count, 64);
      expect(site.vehicles.rev, vRev + 1, reason: 'the same poses: not written');
    });
  });

  test('every agent kind maps to a model, or to none', () {
    VehicleKind? kindOf(AgentKind k, [int variant = 0, bool sealed = false]) =>
        agentVehicleKind(k.index, variant, sealed: sealed);
    expect(kindOf(AgentKind.car, 0), VehicleKind.coupe);
    expect(kindOf(AgentKind.car, 1), VehicleKind.sedan);
    expect(kindOf(AgentKind.car, 2), VehicleKind.coupe);
    expect(kindOf(AgentKind.truck), VehicleKind.truck);
    expect(kindOf(AgentKind.semi), VehicleKind.semi);
    expect(kindOf(AgentKind.bus), VehicleKind.truck);
    expect(kindOf(AgentKind.ambulance), VehicleKind.sedan);
    for (final k in [AgentKind.train, AgentKind.lTrain, AgentKind.freightTrain]) {
      expect(kindOf(k), isNull);
    }
    for (final k in AgentKind.values) {
      if (kindOf(k) == null) continue;
      expect(kindOf(k, 1, true), VehicleKind.rover, reason: '$k when sealed');
    }
    expect(agentVehicleKind(AgentKind.values.length, 0), isNull);
  });

  group('beside the cosmetic traffic', () {
    final source = File('lib/infrastructure/flutter_scene/city/city_nodes.dart')
        .readAsStringSync();
    final part = File('lib/infrastructure/flutter_scene/city/agent_nodes.dart')
        .readAsStringSync();

    test('an agent frame zeroes the cosmetic road cars, before begin', () {
      // The cap is captured by `begin` (each sink's `_reset`), so it must be
      // set before it or it changes nothing — the trap the order pins.
      final body = source.substring(source.indexOf('void _syncTraffic('));
      final cap = body.indexOf(
          '..maxVehicles = snap.cityTraffic.isEmpty ? _maxVehicles : 0');
      final begin = body.indexOf('..begin(_structureSig)');
      expect(cap, greaterThan(0));
      expect(begin, greaterThan(cap));

      // And the trap itself, on the cosmetic pass as it is: a body's sink
      // made on an earlier frame takes the cap `begin` finds.
      const r = 1.7374e6;
      final roads = [
        RoadSnapshot(
          colonyId: 'c',
          body: 'moon',
          points: [for (var i = 0; i < 6; i++) ...[i * 100.0, 0.0, r]],
          halfWidthM: RoadClass.street.halfWidth,
          roadClassIndex: RoadClass.street.index,
        ),
      ];
      int placedWith(void Function(CityTraffic) frame) {
        final pass = CityTraffic()..begin('s');
        pass.visitTile('t', 'k', 'moon', roads, const Vector3(0, 0, r));
        pass.place('moon', 0, const Vector3(0, 0, r), const {});
        pass.end();
        frame(pass);
        pass.visitTile('t', 'k', 'moon', roads, const Vector3(0, 0, r));
        return pass.place('moon', 0, const Vector3(0, 0, r), const {}).placed;
      }

      expect(placedWith((p) => p..maxVehicles = 0..begin('s')), 0);
      expect(placedWith((p) => p.begin('s')), greaterThan(0));
      expect(placedWith((p) => p..begin('s')..maxVehicles = 0), greaterThan(0),
          reason: 'set after begin, the cap is not the frame\'s');
    });

    test('agents draw after the cosmetic pass, whatever its toggle', () {
      final update = source.substring(source.indexOf('  void update('));
      final traffic = update.indexOf('_syncTraffic(snap, origin, moved, focusWorld);');
      final agents = update.indexOf('_syncAgents(snap, origin, moved, focusWorld);');
      final overlay = update.indexOf('_syncRoadOverlay(snap, origin, moved);');
      final extras = update.indexOf('_syncAgentExtras(snap, origin, moved);');
      expect(traffic, greaterThan(0));
      expect(agents, greaterThan(traffic));
      expect(extras, greaterThan(overlay));
      // The cosmetic toggle returns early inside `_syncTraffic`; the agents'
      // pass is not in there, and never reads it.
      final syncTraffic = source.substring(source.indexOf('void _syncTraffic('),
          source.indexOf('static void _setInstances('));
      expect(syncTraffic.contains('_syncAgents'), isFalse);
      expect(part.contains('CityNodes.traffic'), isFalse);
      expect(RegExp(r'\btraffic\b(?!\.)').hasMatch(part.replaceAll(
              RegExp(r'//.*'), '')),
          isFalse);
    });
  });
}
