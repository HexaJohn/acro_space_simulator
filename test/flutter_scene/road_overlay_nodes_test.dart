// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart'
    show CityMaterialKind;
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's overlay is drawn from [RoadOverlayState] on the UI
/// thread: rebuilt only when the state's revision moves, and drawn as the
/// real road — not a coloured strip — wherever the road would stand.
void main() {
  const radius = 1737.4e3;
  final anchor = Vector3(radius, 0, 0);
  final s = RoadOverlayState.instance;

  tearDown(() {
    s.clear();
    s.ghostClassIndex = 0;
    s.ghostHalfWidthM = 4;
    s.bodyId = '';
  });

  /// [count] points [stepM] apart along east from the anchor, on the
  /// surface.
  List<Vector3> eastward(int count, {double stepM = 10}) => [
        for (var i = 0; i < count; i++)
          Vector3(radius, -i * stepM, 0).normalized * radius,
      ];

  /// Height over the surface of vertex [i] of scene-unit [positions]
  /// relative to [anchor].
  double heightOf(List<double> positions, int i) {
    final p = Vector3(positions[3 * i], positions[3 * i + 1],
            positions[3 * i + 2]) *
        (1 / kRenderScale);
    return (p + anchor).length - radius;
  }

  group('the gate', () {
    test('rebuilds on a new revision, never on a frame that changed nothing',
        () {
      final gate = RoadOverlayGate();
      expect(gate.wants(s.revision, 'moon', anchor), isTrue);
      for (var frame = 0; frame < 60; frame++) {
        expect(gate.wants(s.revision, 'moon', anchor), isFalse);
      }
      s.changed();
      expect(gate.wants(s.revision, 'moon', anchor), isTrue);
      expect(gate.wants(s.revision, 'moon', anchor), isFalse);
      expect(gate.builds, 2);
    });

    test('another body, another anchor, or a dropped node rebuilds', () {
      final gate = RoadOverlayGate();
      gate.wants(3, 'moon', anchor);
      expect(gate.wants(3, 'mars', anchor), isTrue);
      expect(gate.wants(3, 'mars', anchor + const Vector3(0, 1, 0)), isTrue);
      gate.reset();
      expect(gate.wants(3, 'mars', anchor + const Vector3(0, 1, 0)), isTrue);
      expect(gate.builds, 4);
    });
  });

  group('the ghost', () {
    test('is the class\'s own carriageway on the road material', () {
      final pts = eastward(12);
      s
        ..bodyId = 'moon'
        ..ghostBF = pts
        ..ghostClassIndex = RoadClass.avenue.index
        ..ghostHalfWidthM = RoadClass.avenue.halfWidth;
      final g = RoadOverlayMesher.build(s, anchor);
      // The very carriageway the tiles lay for an avenue, lanes and all.
      final ref = MeshBuilder();
      RoadMesher.carriageway(ref, [for (final p in pts) p - anchor], anchor,
          RoadClass.avenue,
          halfWidthM: RoadClass.avenue.halfWidth,
          liftM: RoadMesher.ribbonLiftM + RoadOverlayMesher.ghostLiftM,
          solid: MeshBuilder());
      expect(g.trianglesOn(CityMaterialKind.road), ref.triangleCount);
      expect(g.trianglesOn(CityMaterialKind.road), greaterThan(0));
      expect(g.translucent.isEmpty, isTrue);
      expect(g.trianglesOn(CityMaterialKind.facade), 0,
          reason: 'on the ground: no piers');
    });

    test('stands on its deck, with piers under it', () {
      s
        ..ghostBF = eastward(12)
        ..ghostLiftsM = List.filled(12, 12.0)
        ..ghostClassIndex = RoadClass.street.index
        ..ghostHalfWidthM = RoadClass.street.halfWidth;
      final g = RoadOverlayMesher.build(s, anchor);
      expect(g.trianglesOn(CityMaterialKind.facade), greaterThan(0));
      final road = g.opaque[CityMaterialKind.road]!.build();
      var highest = 0.0;
      for (var i = 0; i < road.vertexCount; i++) {
        highest = math.max(highest, heightOf(road.positions, i));
      }
      expect(highest, greaterThan(12));
      expect(highest, lessThan(13));
    });

    test('refused: the same shape in a translucent red, nothing opaque', () {
      s
        ..ghostBF = eastward(12)
        ..ghostClassIndex = RoadClass.avenue.index
        ..ghostHalfWidthM = RoadClass.avenue.halfWidth
        ..ghostState = RoadGhostState.refused;
      final g = RoadOverlayMesher.build(s, anchor);
      expect(g.opaque.values.every((m) => m.triangleCount == 0), isTrue);
      final ref = MeshBuilder();
      RoadMesher.carriageway(ref, [for (final p in eastward(12)) p - anchor],
          anchor, RoadClass.avenue,
          halfWidthM: RoadClass.avenue.halfWidth,
          liftM: RoadMesher.ribbonLiftM + RoadOverlayMesher.ghostLiftM,
          solid: MeshBuilder());
      expect(g.translucent.triangleCount, ref.triangleCount);
      final c = g.translucent.colorAt(0);
      expect(c[0], greaterThan(c[1] * 3), reason: 'red');
      expect(c[3], closeTo(0xA6 / 255, 1e-6), reason: 'translucent');
    });

    test('a tunnel stretch is a band on the surface, not a road', () {
      s
        ..ghostBF = eastward(12)
        ..ghostLiftsM = List.filled(12, -12.0);
      final g = RoadOverlayMesher.build(s, anchor);
      expect(g.opaque.values.every((m) => m.triangleCount == 0), isTrue);
      expect(g.translucent.triangleCount, 2 * 11);
      final positions = g.translucent.positions;
      for (var i = 0; i < g.translucent.vertexCount; i++) {
        expect(heightOf(positions, i),
            closeTo(RoadOverlayMesher.tunnelLiftM, 0.05));
      }
    });

    test('half in a tunnel: road to the portal, band beyond', () {
      s.ghostBF = eastward(12);
      s.ghostLiftsM = [for (var i = 0; i < 12; i++) i < 6 ? 0.0 : -12.0];
      final g = RoadOverlayMesher.build(s, anchor);
      expect(g.trianglesOn(CityMaterialKind.road), greaterThan(0));
      expect(g.translucent.triangleCount, greaterThan(0));
    });

    test('one way: an arrow every spacing, pointing along the drawing', () {
      final pts = eastward(12);
      s
        ..ghostBF = pts
        ..ghostOneWay = true;
      final g = RoadOverlayMesher.build(s, anchor);
      // 110 m of road, arrows from 12 m every 24 m: 12, 36, 60, 84, 108.
      expect(g.translucent.triangleCount, 5);
      // The tip leads: further along the drawing than the arrow's base.
      final p = g.translucent.positions;
      final tip = Vector3(p[0], p[1], p[2]);
      final left = Vector3(p[3], p[4], p[5]);
      final along = (pts[1] - pts[0]).normalized;
      expect((tip - left).dot(along), greaterThan(0));
    });

    test('selected: a highlight over the road', () {
      s
        ..ghostBF = eastward(12)
        ..ghostState = RoadGhostState.selected;
      final g = RoadOverlayMesher.build(s, anchor);
      expect(g.trianglesOn(CityMaterialKind.road), greaterThan(0));
      expect(g.translucent.triangleCount, 2 * 11);
    });
  });

  group('lines and markers', () {
    test('a solid line is one strip; a dashed one covers 60% of it', () {
      final pts = eastward(6, stepM: 20); // 100 m
      s.lines = [OverlayLine(pointsBF: pts, argb: 0xFF00FF00)];
      expect(RoadOverlayMesher.build(s, anchor).translucent.triangleCount,
          2 * 5);
      s.lines = [OverlayLine(pointsBF: pts, argb: 0xFF00FF00, dashed: true)];
      final dashed = RoadOverlayMesher.build(s, anchor).translucent;
      // Each dash is its own quad: four vertices, p0 left and right, then
      // p1 right and left.
      final pos = dashed.positions;
      var covered = 0.0;
      for (var q = 0; q < dashed.vertexCount; q += 4) {
        final a = Vector3(pos[3 * q], pos[3 * q + 1], pos[3 * q + 2]);
        final b = Vector3(
            pos[3 * (q + 3)], pos[3 * (q + 3) + 1], pos[3 * (q + 3) + 2]);
        covered += (b - a).length / kRenderScale;
      }
      expect(covered, closeTo(60, 0.1));
    });

    test('per-point lifts raise a line with the deck it describes', () {
      s.lines = [
        OverlayLine(
            pointsBF: eastward(4),
            argb: 0xFFFFFFFF,
            liftsM: const [12, 12, 12, 12]),
      ];
      final t = RoadOverlayMesher.build(s, anchor).translucent;
      for (var i = 0; i < t.vertexCount; i++) {
        expect(heightOf(t.positions, i), closeTo(12.5, 0.05));
      }
    });

    test('every marker kind draws, each its own shape', () {
      final triangles = <OverlayMarkerKind, int>{};
      for (final kind in OverlayMarkerKind.values) {
        s.markers = [
          OverlayMarker(atBF: anchor, argb: 0xFF2196F3, kind: kind),
        ];
        triangles[kind] =
            RoadOverlayMesher.build(s, anchor).translucent.triangleCount;
      }
      expect(triangles[OverlayMarkerKind.dot], 24);
      expect(triangles[OverlayMarkerKind.ring], 48);
      expect(triangles[OverlayMarkerKind.lights], 48 + 3 * 12);
      expect(triangles[OverlayMarkerKind.noLights], 48 + 2);
      expect(triangles[OverlayMarkerKind.stop], 8 + 16);
    });

    test('the anchor is the first thing drawn, or none', () {
      expect(RoadOverlayMesher.anchorOf(s), isNull);
      s.markers = [OverlayMarker(atBF: anchor, argb: 0xFFFFFFFF)];
      expect(RoadOverlayMesher.anchorOf(s), anchor);
      final pts = eastward(3);
      s.ghostBF = pts;
      expect(RoadOverlayMesher.anchorOf(s), pts.first);
    });
  });
}
