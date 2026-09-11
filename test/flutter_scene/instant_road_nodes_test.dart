// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart'
    show kMileM;
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_bucketing.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/instant_road_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// A road the player edits is drawn the frame it changes — not seconds
/// later, when its tile lands — and only until that tile shows it.
void main() {
  const radius = 1737.4e3;
  final anchor = Vector3(radius, 0, 0);
  final basis = ColonyTangentBasis.at(anchor);
  const tileM = 2 * kMileM;

  Vector3 at(double e, double n) {
    final v = basis.up +
        basis.east * math.tan(e / radius) +
        basis.north * math.tan(n / radius);
    return v.normalized * radius;
  }

  RoadSnapshot road(
    List<(double, double)> pts, {
    RoadClass cls = RoadClass.street,
    List<double> lifts = const [],
    String? id,
  }) {
    final flat = Float64List(pts.length * 3);
    for (var i = 0; i < pts.length; i++) {
      final p = at(pts[i].$1, pts[i].$2);
      flat[3 * i] = p.x;
      flat[3 * i + 1] = p.y;
      flat[3 * i + 2] = p.z;
    }
    return RoadSnapshot(
      colonyId: 'c',
      body: 'moon',
      points: flat,
      halfWidthM: cls.halfWidth,
      roadClassIndex: cls.index,
      lifts: lifts,
      id: id,
    );
  }

  Iterable<CityTileBucket> cut(List<RoadSnapshot> roads) =>
      CityTileBucketer.bucket(
              WorldSnapshot(tick: 0, vessels: const {}, roads: roads),
              anchors: {'moon': anchor},
              tileM: tileM)
          .tiles
          .values;

  String tileOf(double e, double n) {
    final (ie, iN) = basis.cellOf(at(e, n), tileM);
    return 'moon/$ie/$iN';
  }

  final a = road([(1000, 1600), (1600, 1600), (2200, 1600)], id: 'a');
  final b = road([(7000, 1600), (7600, 1600), (8200, 1600)], id: 'b');
  final c = road([(1000, 7600), (1600, 7600), (2200, 7600)], id: 'c');
  final tileB = tileOf(7600, 1600);

  group('the tracker', () {
    test('a small colony\'s first cut is drawn at once', () {
      final t = InstantRoadTracker()..noteCut(cut([a, b, c]));
      expect(t.pendingCount, 3);
      expect(t.bodies, {'moon'});
    });

    test('a cut that changed nothing adds nothing', () {
      final t = InstantRoadTracker()..noteCut(cut([a, b, c]));
      expect(t.retire((_) => true), isTrue);
      expect(t.pendingCount, 0);
      // A fresh frame of the same content, as the flight view captures.
      t.noteCut(cut([
        road([(1000, 1600), (1600, 1600), (2200, 1600)], id: 'a'),
        road([(7000, 1600), (7600, 1600), (8200, 1600)], id: 'b'),
        road([(1000, 7600), (1600, 7600), (2200, 7600)], id: 'c'),
      ]));
      expect(t.pendingCount, 0);
    });

    test('an upgraded road alone is drawn, until its own tile shows it', () {
      final t = InstantRoadTracker()..noteCut(cut([a, b, c]));
      t.retire((_) => true);
      final upgraded = road([(7000, 1600), (7600, 1600), (8200, 1600)],
          cls: RoadClass.avenue, id: 'b');
      t.noteCut(cut([a, upgraded, c]));
      final pending = t.pendingOn('moon').toList();
      expect(pending, hasLength(1));
      expect(pending.single.road.roadClassIndex, RoadClass.avenue.index);
      expect(pending.single.tileKey, tileB);
      // Other tiles landing retire nothing.
      expect(t.retire((k) => k != tileB), isFalse);
      expect(t.pendingCount, 1);
      expect(t.retire((k) => k == tileB), isTrue);
      expect(t.pendingCount, 0);
    });

    test('a road re-split into new pieces is drawn as its pieces', () {
      final t = InstantRoadTracker()..noteCut(cut([a, b, c]));
      t.retire((_) => true);
      // The same geometry under a new id: the layout split it.
      final piece = road([(1000, 1600), (1600, 1600), (2200, 1600)],
          id: 'ax1');
      t.noteCut(cut([piece, b, c]));
      expect(t.pendingOn('moon').single.road.id, 'ax1');
    });

    test('a pending road changed again, or removed, leaves the set', () {
      final t = InstantRoadTracker()..noteCut(cut([a, b, c]));
      t.retire((_) => true);
      final avenue = road([(7000, 1600), (7600, 1600), (8200, 1600)],
          cls: RoadClass.avenue, id: 'b');
      t.noteCut(cut([a, avenue, c]));
      expect(t.pendingCount, 1);
      final boulevard = road([(7000, 1600), (7600, 1600), (8200, 1600)],
          cls: RoadClass.boulevard, id: 'b');
      t.noteCut(cut([a, boulevard, c]));
      expect(t.pendingOn('moon').single.road.roadClassIndex,
          RoadClass.boulevard.index);
      t.noteCut(cut([a, c]));
      expect(t.pendingCount, 0);
    });

    test('a cut past the edit budget is left to the tiles', () {
      final saved = InstantRoadTracker.maxEditedPerCut;
      addTearDown(() => InstantRoadTracker.maxEditedPerCut = saved);
      InstantRoadTracker.maxEditedPerCut = 2;
      final t = InstantRoadTracker()..noteCut(cut([a, b, c]));
      expect(t.pendingCount, 0);
    });

    test('the revision moves only when a body\'s set does', () {
      final t = InstantRoadTracker();
      final r0 = t.revisionOf('moon');
      t.noteCut(cut([a]));
      final r1 = t.revisionOf('moon');
      expect(r1, isNot(r0));
      t.noteCut(cut([a]));
      expect(t.revisionOf('moon'), r1);
      t.retire((_) => false);
      expect(t.revisionOf('moon'), r1);
      t.retire((_) => true);
      expect(t.revisionOf('moon'), isNot(r1));
    });

    test('a reset makes the next cut a first', () {
      final t = InstantRoadTracker()..noteCut(cut([a, b]));
      t.retire((_) => true);
      t.reset();
      t.noteCut(cut([a, b]));
      expect(t.pendingCount, 2);
    });
  });

  group('the mesher', () {
    final pts = [for (var i = 0; i < 8; i++) (1000.0 + i * 20, 1600.0)];

    InstantRoadGeometry draw(RoadSnapshot r) {
      final g = InstantRoadGeometry();
      InstantRoadMesher.emit(g, r, anchor);
      return g;
    }

    double lowest(MeshBuilder m) {
      final mesh = m.build();
      var low = double.infinity;
      for (var i = 0; i < mesh.vertexCount; i++) {
        final p = Vector3(mesh.positions[3 * i], mesh.positions[3 * i + 1],
                mesh.positions[3 * i + 2]) *
            (1 / kRenderScale);
        low = math.min(low, (p + anchor).length - radius);
      }
      return low;
    }

    test('a street on the ground: its carriageway, a little over the tile',
        () {
      final g = draw(road(pts));
      expect(g.roads, 1);
      expect(g.road.triangleCount, greaterThan(0));
      expect(g.solid.triangleCount, 0);
      expect(lowest(g.road),
          closeTo(RoadMesher.ribbonLiftM + InstantRoadMesher.overTileM, 0.01));
    });

    test('a raised road stands on piers, at its deck', () {
      final g = draw(road(pts, lifts: List.filled(8, 12.0)));
      expect(g.solid.triangleCount, greaterThan(0));
      expect(lowest(g.road), greaterThan(12));
    });

    test('a road in a tunnel draws nothing; half in, its open half', () {
      final buried = InstantRoadGeometry();
      expect(
          InstantRoadMesher.emit(
              buried, road(pts, lifts: List.filled(8, -12.0)), anchor),
          isFalse);
      expect(buried.road.triangleCount, 0);
      final whole = draw(road(pts)).road.triangleCount;
      final half = draw(road(pts,
              lifts: [for (var i = 0; i < 8; i++) i < 4 ? 0.0 : -12.0]))
          .road
          .triangleCount;
      expect(half, greaterThan(0));
      expect(half, lessThan(whole));
    });

    test('gravel and alleys on their own materials; structures left out', () {
      final gravel = draw(road(pts, cls: RoadClass.path));
      expect(gravel.dirt.triangleCount, greaterThan(0));
      expect(gravel.road.triangleCount, 0);
      final alley = draw(road(pts, cls: RoadClass.alley));
      expect(alley.alley.triangleCount, greaterThan(0));
      for (final cls in [
        RoadClass.elevated,
        RoadClass.transit,
        RoadClass.rail,
      ]) {
        final g = InstantRoadGeometry();
        expect(InstantRoadMesher.emit(g, road(pts, cls: cls), anchor), isFalse,
            reason: '$cls');
        expect(g.roads, 0);
      }
    });
  });

  group('lift profiles and tunnel runs', () {
    test('each station reads its own lift; between them, the straight line',
        () {
      final pts = [
        Vector3.zero,
        const Vector3(10, 0, 0),
        const Vector3(30, 0, 0),
      ];
      final p = RoadLiftProfile(pts, const [0, 6, 2]);
      expect(p.at(0), 0);
      expect(p.at(10), 6);
      expect(p.at(30), 2);
      expect(p.at(5), closeTo(3, 1e-12));
      expect(p.at(20), closeTo(4, 1e-12));
      expect(p.at(-4), 0);
      expect(p.at(99), 2);
    });

    test('runs split by segment and share their boundary points', () {
      List<LiftRun> runs(List<double> lifts) =>
          tunnelRuns(lifts.length, (i) => lifts[i]);
      expect(runs(const [0, 0, 0]), [(from: 0, to: 2, tunnel: false)]);
      expect(runs(const [0, 0, -12, -12, -12, 0]), [
        (from: 0, to: 1, tunnel: false),
        (from: 1, to: 5, tunnel: true),
      ]);
      expect(runs(const [0, 0, -4, -12, 0, 0]), [
        (from: 0, to: 2, tunnel: false),
        (from: 2, to: 4, tunnel: true),
        (from: 4, to: 5, tunnel: false),
      ]);
      expect(runs(const [0]), isEmpty);
    });
  });
}
