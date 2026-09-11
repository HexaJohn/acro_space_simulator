// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/road_snapper.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/road_tool_scene.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the road tool asks the renderer to draw: the ghost on its deck, the
/// guidelines, the markers, the tunnels below ground, the info views — all
/// written into [RoadOverlayState], laid on the ground the scene is given.
void main() {
  final o = RoadOverlayState.instance;
  setUp(o.clear);
  tearDown(o.clear);

  CitySim colony({double funds = 1e6}) => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'scene',
      )..funds = funds;

  /// A flat world: a colony-local point P at height H is body-fixed
  /// (P.e, P.n, 1000 + H), over [ground].
  RoadToolScene scene({double Function(Vec2)? ground}) => RoadToolScene()
    ..bindCustom(
      bodyId: 'earth',
      toBodyFixed: (p, h) => Vector3(p.e, p.n, 1000 + h),
      height: ground ?? (_) => 0,
    );

  CityEditController roadTool() => CityEditController()
    ..set(CityEditTool.roadSpline)
    ..snap = RoadSnapOptions.off;

  test('the ghost is the stretch the next click builds, lifted onto its deck',
      () {
    final city = colony();
    final s = scene();
    final c = roadTool()..stepElevation(1);
    c.clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(0, 200));
    final rev = o.revision;
    s.showRoadTool(city, c);
    expect(o.revision, greaterThan(rev), reason: 'the renderer is told');
    expect(o.bodyId, 'earth');
    expect(o.ghostBF.first.distanceTo(Vector3(0, 0, 1000)), lessThan(1e-6));
    expect(o.ghostBF.last.distanceTo(Vector3(0, 200, 1000)), lessThan(1e-6),
        reason: 'draped on the ground');
    expect(o.ghostBF.length, greaterThan(40), reason: 'a point every 4 m');
    expect(o.ghostLiftsM, hasLength(o.ghostBF.length));
    for (final l in o.ghostLiftsM) {
      expect(l, closeTo(12, 1e-6), reason: 'the deck, 12 m over the drape');
    }
    expect(o.ghostClassIndex, RoadClass.street.index);
    expect(o.ghostState, RoadGhostState.ok);
    expect(o.ghostOneWay, isFalse);
    final ring =
        o.markers.where((m) => m.kind == OverlayMarkerKind.ring).single;
    expect(ring.atBF.z, closeTo(1012, 1e-6), reason: 'the anchor, at 12 m');
  });

  test('a stretch that cannot be built is drawn refused', () {
    final city = colony(funds: 0);
    final s = scene();
    final c = roadTool()..clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(0, 200));
    s.showRoadTool(city, c);
    expect(o.ghostState, RoadGhostState.refused);
    expect(o.ghostLiftsM, isEmpty, reason: 'a road on the ground has no deck');
  });

  test('a one-way type draws its direction of travel', () {
    final city = colony();
    final s = scene();
    final c = roadTool()..pickRoadType(RoadType.byId('one-way')!);
    c.clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(0, 200));
    s.showRoadTool(city, c);
    expect(o.ghostOneWay, isTrue);
    expect(o.ghostClassIndex, RoadClass.streetOneWay.index);
  });

  test('guidelines are dashed lines draped on the ground', () {
    final city = colony();
    final s = scene(ground: (p) => p.n * 0.1);
    final c = roadTool()
      ..snap = const RoadSnapOptions(
          roads: false, angles: true, zoningGrid: false, guidelines: false);
    c.clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(3, 100));
    s.showRoadTool(city, c);
    final guide = o.lines.single;
    expect(guide.dashed, isTrue);
    expect(guide.pointsBF.length, greaterThan(2),
        reason: 'densified, so it follows the ground rather than a chord');
    for (final p in guide.pointsBF) {
      expect(p.z, closeTo(1000 + p.y * 0.1, 1e-6));
    }
  });

  test('below ground every tunnel already built shows; above it none do', () {
    final city = colony();
    final s = scene();
    final c = roadTool()..stepElevation(-1);
    c.clickAt(city, const Vec2(100, 0));
    c.clickAt(city, const Vec2(100, 300));
    expect(city.layout.roadById(c.lastRoadId!)!.deck!.tunnels, isNotEmpty);

    c.endChain();
    c.clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(0, 100));
    s.showRoadTool(city, c);
    expect(o.showUnderground, isTrue);
    expect(o.lines.where((l) => l.argb == RoadToolScene.tunnelArgb),
        isNotEmpty);
    for (final l in o.ghostLiftsM) {
      expect(l, closeTo(-12, 1e-6), reason: 'the ghost runs 12 m under');
    }

    c.stepElevation(1);
    c.previewTo(city, const Vec2(0, 100));
    s.showRoadTool(city, c);
    expect(o.showUnderground, isFalse);
    expect(o.lines, isEmpty);
  });

  test('Upgrade draws the road under the cursor as the type it would become',
      () {
    final city = colony();
    city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street);
    final s = scene();
    final c = roadTool()
      ..setMode(RoadToolMode.upgrade)
      ..pickRoadType(RoadType.byId('four-lane')!);
    c.upgradeHover(city, const Vec2(3, 100));
    s.showUpgrade(city, c);
    expect(o.ghostClassIndex, RoadClass.avenue.index);
    expect(o.ghostState, RoadGhostState.selected);
    expect(o.ghostBF.first.distanceTo(Vector3(0, 0, 1000)), lessThan(1e-6));
    expect(o.ghostBF.last.distanceTo(Vector3(0, 200, 1000)), lessThan(1e-6));

    c.upgradeHover(city, const Vec2(500, 500));
    s.showUpgrade(city, c);
    expect(o.ghostBF, isEmpty, reason: 'no road under the cursor');
  });

  test('Junctions: a marker on the junction and a stop sign on each leg that '
      'stops', () {
    final city = colony();
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..setTrafficView(TrafficInfoView.junctions);
    s.showTraffic(city, c);
    expect(o.markers.where((m) => m.kind == OverlayMarkerKind.noLights),
        hasLength(1));
    final stops =
        o.markers.where((m) => m.kind == OverlayMarkerKind.stop).toList();
    expect(stops, hasLength(4));
    for (final m in stops) {
      expect(Vec2(m.atBF.x, m.atBF.y).distanceTo(const Vec2(0, 0)),
          closeTo(JunctionMarks.stopOutM(1), 0.5),
          reason: 'out along its leg');
    }

    c.toggleJunctionAt(city, const Vec2(0, 0));
    s.showTraffic(city, c);
    expect(o.markers.where((m) => m.kind == OverlayMarkerKind.lights),
        hasLength(1));
    expect(o.markers.where((m) => m.kind == OverlayMarkerKind.stop), isEmpty);
  });

  test('Routes: the picked road is highlighted, and its trips counted', () {
    final city = colony();
    final id =
        city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..selectRoad(id);
    s.showTraffic(city, c);
    expect(o.lines.first.argb, RoadToolScene.highlightArgb);
    expect(c.routeCount, 0, reason: 'nobody lives here yet');
  });

  test('Adjust: the road picked is outlined with a circle at each end; a drag '
      'draws it re-laid', () {
    final city = colony();
    final id =
        city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..setTrafficView(TrafficInfoView.adjust)
      ..selectRoad(id);
    s.showTraffic(city, c);
    expect(o.lines, hasLength(1));
    expect(o.markers.where((m) => m.kind == OverlayMarkerKind.ring),
        hasLength(2));

    expect(s.handleAt(city, id, const Vec2(3, 197), 10),
        (roadId: id, atStart: false));
    expect(s.handleAt(city, id, const Vec2(0, 100), 10), isNull);
    s.drag = (roadId: id, atStart: false);
    s.dragTo = const Vec2(50, 250);
    c.previewMoveEnd(city, atStart: false, to: const Vec2(50, 250));
    s.showTraffic(city, c);
    expect(o.ghostBF.last.distanceTo(Vector3(50, 250, 1000)), lessThan(1e-6));
    expect(o.ghostState, RoadGhostState.selected);
  });

  test('Adjust: the dragged road is drawn as letting go lays it — on its '
      'deck, its end on the street it is dropped beside', () {
    final city = colony();
    final id = city
        .buildRoad(RoadBuildRequest(
          controls: const [Vec2(0, 0), Vec2(0, 200)],
          type: RoadType.byId('two-lane')!,
          startElevationM: 12,
          endElevationM: 12,
        ))
        .roadId!;
    city.commitRoad(const [Vec2(-200, 400), Vec2(200, 400)], RoadClass.street);
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..setTrafficView(TrafficInfoView.adjust)
      ..selectRoad(id);
    s.drag = (roadId: id, atStart: false);
    s.dragTo = const Vec2(50, 250);
    c.previewMoveEnd(city, atStart: false, to: const Vec2(50, 250));
    s.showTraffic(city, c);
    expect(o.ghostLiftsM, hasLength(o.ghostBF.length),
        reason: 'on its deck, not flat on the ground');
    expect(o.ghostLiftsM.first, closeTo(12, 1e-6));
    expect(o.ghostLiftsM.last, closeTo(12, 1e-6));

    // Let go 9 m short of the street: it lands on it, and comes down to it.
    s.dragTo = const Vec2(0, 391);
    c.previewMoveEnd(city, atStart: false, to: const Vec2(0, 391));
    s.showTraffic(city, c);
    expect(o.ghostBF.last.distanceTo(Vector3(0, 400, 1000)), lessThan(1e-6));
    expect(o.ghostLiftsM.last, closeTo(0, 1e-6));
    final rings =
        o.markers.where((m) => m.kind == OverlayMarkerKind.ring).toList();
    expect(rings, hasLength(2));
    expect(rings.first.atBF.z, closeTo(1012, 1e-6),
        reason: 'the end left alone, on its deck');
    expect(rings.last.atBF.z, closeTo(1000, 1e-6),
        reason: 'the end moved, down at the street');
  });

  test("Adjust: a reversed one-way road's ghost runs the way its traffic "
      'does, on its deck', () {
    final city = colony();
    // Down from 12 m to the ground at (0, 200); then turned round, so its
    // traffic climbs from (0, 200) to (0, 0).
    final id = city
        .buildRoad(RoadBuildRequest(
          controls: const [Vec2(0, 0), Vec2(0, 200)],
          type: RoadType.byId('one-way')!,
          startElevationM: 12,
        ))
        .roadId!;
    expect(city.reverseRoad(id), isTrue);
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..setTrafficView(TrafficInfoView.adjust)
      ..selectRoad(id);
    s.drag = (roadId: id, atStart: false);
    s.dragTo = const Vec2(0, 260);
    c.previewMoveEnd(city, atStart: false, to: const Vec2(0, 260));
    s.showTraffic(city, c);
    expect(o.ghostOneWay, isTrue);
    expect(o.ghostBF.first.distanceTo(Vector3(0, 260, 1000)), lessThan(1e-6),
        reason: 'traffic starts at the moved end, its last control');
    expect(o.ghostBF.last.distanceTo(Vector3(0, 0, 1000)), lessThan(1e-6));
    expect(o.ghostLiftsM, hasLength(o.ghostBF.length));
    expect(o.ghostLiftsM.first, closeTo(0, 1e-6),
        reason: 'the moved end, on the ground');
    expect(o.ghostLiftsM.last, closeTo(12, 1e-6),
        reason: 'the end left alone, on its deck');
  });

  test('the info views publish only what changed: a hover over them costs '
      'the renderer nothing', () {
    final city = colony();
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
    final s = scene();
    final c = CityEditController()..set(CityEditTool.traffic);
    final picked = city.layout.roads.first.id;
    for (final v in TrafficInfoView.values) {
      c.setTrafficView(v);
      c.selectRoad(picked);
      s.hover = const Vec2(5, 5);
      s.showTraffic(city, c);
      final rev = o.revision;
      for (var i = 1; i <= 10; i++) {
        s.hover = Vec2(5.0 + i, 5);
        s.showTraffic(city, c);
      }
      expect(o.revision, rev, reason: '${v.name}: only the mouse moved');
    }
    // A real change is still drawn: lights at the crossroads.
    c.setTrafficView(TrafficInfoView.junctions);
    s.showTraffic(city, c);
    final rev = o.revision;
    c.toggleJunctionAt(city, const Vec2(0, 0));
    s.showTraffic(city, c);
    expect(o.revision, greaterThan(rev));
    expect(o.markers.where((m) => m.kind == OverlayMarkerKind.lights),
        hasLength(1));
  });

  test('Routes: a road picked again reads its routes again', () {
    final city = colony();
    final id =
        city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..selectRoad(id);
    s.showTraffic(city, c);
    expect(c.routeCount, 0);
    c.selectRoad(null);
    s.showTraffic(city, c);
    expect(c.routeCount, isNull);
    c.selectRoad(id);
    s.showTraffic(city, c);
    expect(c.routeCount, 0,
        reason: 'drawn from the cache, and counted with it — not "0 routes" '
            'by accident of a null');
  });

  test('Routes: a new pass of the traffic draws the routes again', () {
    final city = colony();
    final id =
        city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..selectRoad(id);
    s.showTraffic(city, c);
    final drawn = o.lines;
    final rev = o.revision;
    s.showTraffic(city, c);
    expect(o.revision, rev, reason: 'the same pass: nothing to draw again');
    final passes = city.trafficModel.passes;
    for (var i = 0; i < 5000 && city.trafficModel.passes == passes; i++) {
      city.roadTraffic.advance(1);
    }
    expect(city.trafficModel.passes, greaterThan(passes),
        reason: 'the traffic ran a pass');
    s.showTraffic(city, c);
    expect(identical(o.lines, drawn), isFalse,
        reason: 'the routes were asked of the new pass');
    expect(o.revision, greaterThan(rev));
  });

  test("Junctions: from a district zoom the stop signs stand clear of the "
      "junction's disc", () {
    final city = colony();
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    city.commitRoad(const [Vec2(0, -200), Vec2(0, 200)], RoadClass.street);
    final s = scene();
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..setTrafficView(TrafficInfoView.junctions);
    s.showTraffic(city, c, pxM: 3);
    final disc =
        o.markers.singleWhere((m) => m.kind == OverlayMarkerKind.noLights);
    expect(disc.radiusM, closeTo(JunctionMarks.ringRadiusM(3), 1e-9));
    final stops =
        o.markers.where((m) => m.kind == OverlayMarkerKind.stop).toList();
    expect(stops, hasLength(4));
    for (final m in stops) {
      final d = Vec2(m.atBF.x, m.atBF.y).distanceTo(const Vec2(0, 0));
      expect(d, closeTo(JunctionMarks.stopOutM(3), 1e-3));
      expect(d - m.radiusM, greaterThanOrEqualTo(disc.radiusM - 1e-9),
          reason: 'off the disc a click on would switch the lights');
    }
  });

  test('a drawing laid on ground the raster had not filled is laid again, '
      'once, when it has', () {
    final city = colony();
    final id =
        city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
    // A raster that fills [budget] cells a refresh and answers the ground
    // before the grading (0) for the rest; the graded ground is 3 m down.
    final warm = <(int, int)>{};
    var budget = 0;
    (int, int) cellOf(Vec2 p) => ((p.e / 8).floor(), (p.n / 8).floor());
    double height(Vec2 p) {
      final k = cellOf(p);
      if (warm.contains(k)) return -3;
      if (budget > 0) {
        budget--;
        warm.add(k);
        return -3;
      }
      return 0;
    }

    final s = RoadToolScene()
      ..bindCustom(
        bodyId: 'earth',
        toBodyFixed: (p, h) => Vector3(p.e, p.n, 1000 + h),
        height: height,
        warmAt: (p) => warm.contains(cellOf(p)),
      );
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..selectRoad(id);
    budget = 4;
    s.showTraffic(city, c);
    expect(s.warming, isTrue);
    expect(o.lines.single.pointsBF.any((p) => (p.z - 1000).abs() < 1e-9),
        isTrue,
        reason: 'laid partly on the ground before the grading');
    final rev = o.revision;
    var refreshes = 0;
    while (s.warming && refreshes++ < 100) {
      budget = 4;
      s.showTraffic(city, c);
      if (s.warming) {
        expect(o.revision, rev, reason: 'nothing re-published while it warms');
      }
    }
    expect(s.warming, isFalse);
    expect(o.revision, rev + 1, reason: 'laid again, once');
    for (final p in o.lines.single.pointsBF) {
      expect(p.z, closeTo(997, 1e-9), reason: 'on the graded ground');
    }
  });

  test('a drawing kept is laid again when the ground under it changes', () {
    final city = colony();
    final id =
        city.commitRoad(const [Vec2(0, 0), Vec2(0, 200)], RoadClass.street)!;
    var ground = 0.0;
    final s = RoadToolScene();
    void bind(Object key) => s.bindCustom(
          bodyId: 'earth',
          toBodyFixed: (p, h) => Vector3(p.e, p.n, 1000 + h),
          height: (_) => ground,
          groundKey: key,
        );
    final c = CityEditController()
      ..set(CityEditTool.traffic)
      ..selectRoad(id);
    bind(1);
    s.showTraffic(city, c);
    expect(o.lines.single.pointsBF.first.z, closeTo(1000, 1e-9));
    // A brush lands: the edits' version moves, and the drawing follows.
    ground = -2;
    bind(2);
    s.showTraffic(city, c);
    expect(o.lines.single.pointsBF.first.z, closeTo(998, 1e-9));
  });

  test("the join marker stands where the end joins: up on a viaduct's deck",
      () {
    final city = colony();
    city.buildRoad(RoadBuildRequest(
      controls: const [Vec2(-200, 300), Vec2(200, 300)],
      type: RoadType.byId('two-lane')!,
      startElevationM: 12,
      endElevationM: 12,
    ));
    final s = scene();
    final c = roadTool()
      ..snap = const RoadSnapOptions(
          roads: true, angles: false, zoningGrid: false, guidelines: false);
    c.clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(2, 301));
    s.showRoadTool(city, c);
    final dot = o.markers.singleWhere((m) => m.argb == RoadToolScene.joinArgb);
    expect(dot.atBF.z, closeTo(1012, 1e-6));
  });

  test('another tool, and everything is dropped', () {
    final city = colony();
    final s = scene();
    final c = roadTool()..clickAt(city, const Vec2(0, 0));
    c.previewTo(city, const Vec2(0, 100));
    s.showRoadTool(city, c);
    expect(o.ghostBF, isNotEmpty);
    expect(s.toolChanged(CityEditTool.roadSpline), isTrue);
    expect(s.toolChanged(CityEditTool.roadSpline), isFalse);
    s.clear();
    expect(o.ghostBF, isEmpty);
    expect(o.markers, isEmpty);
  });

  test('the hover is redrawn at most once an interval', () {
    final s = scene();
    expect(s.refreshDue(), isTrue);
    s.markRefreshed();
    expect(s.refreshDue(), isFalse);
  });
}
