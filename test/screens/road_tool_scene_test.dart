// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
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
          closeTo(RoadToolScene.stopOutM, 0.5),
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
    s.showTraffic(city, c);
    expect(o.ghostBF.last.distanceTo(Vector3(50, 250, 1000)), lessThan(1e-6));
    expect(o.ghostState, RoadGhostState.selected);
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
