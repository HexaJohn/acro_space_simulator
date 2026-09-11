// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_elevation.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_traffic.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/rail_vehicles.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_deck.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's roads as the tiles draw them: raised onto decks and
/// carried on structures whose piers keep out of the roads beneath, sunk
/// into tunnels behind portals, dressed with grass and trees, one-way with
/// arrows, meeting at junctions only where they meet at the same level and
/// controlled by the leg-aware warrant where the tool had a hand in them —
/// and every road and junction the generator lays drawn exactly as it
/// always was.
///
/// The tile tests hand the mesher its members directly (see
/// [CityTileMeshJob]'s `members`): a road's deck, dressing and end flags
/// reach a worker through the tile columns, which are the wire's half of
/// the road tool and pinned by their own round-trip test.
void main() {
  const r = 1.7374e6;
  const body = 'moon';
  // A flat little town on the pole: local +Z is radial up at (0, 0, r).
  const anchor = Vector3(0, 0, r);

  RoadSnapshot road(RoadClass cls, List<(double, double)> xy,
          {bool sealed = false,
          bool walls = false,
          bool collector = false,
          List<double> bridges = const [],
          double? hw0,
          double? hw1,
          int decoration = 0,
          List<double> lifts = const []}) =>
      RoadSnapshot(
        colonyId: 'c',
        body: body,
        points: [for (final (x, y) in xy) ...[x, y, r]],
        halfWidthM: cls.width / 2,
        roadClassIndex: cls.index,
        sealed: sealed,
        soundWalls: walls,
        collector: collector,
        bridges: bridges,
        startHalfWidthM: hw0,
        endHalfWidthM: hw1,
        decoration: decoration,
        lifts: lifts,
      );

  List<(double, double)> line(double y, double x0, double x1, int n) => [
        for (var i = 0; i < n; i++) (x0 + (x1 - x0) * i / (n - 1), y),
      ];

  const knobs = CityMeshKnobs(
    styleId: 'masonry-street',
    bucketM: 6,
    variants: 4,
    perBuildingLod: true,
    blockRangeM: 300,
    interiorRangeM: 50,
    lodDebug: false,
    onStreetParking: true,
    sealedWorld: false,
    maxParkedCars: 400,
  );

  int fnv(int h, int v) => ((h ^ (v & 0xFFFFFFFF)) * 0x01000193) & 0xFFFFFFFF;
  int words(int h, TypedData d, [int? count]) {
    final all = d.buffer.asUint32List(d.offsetInBytes, d.lengthInBytes ~/ 4);
    final n = count ?? all.length;
    for (var i = 0; i < n; i++) {
      h = fnv(h, all[i]);
    }
    return h;
  }

  /// Every group's streams, then the pits: what a tile hands the upload.
  int digest(CityTileResult res) {
    var h = 0x811C9DC5;
    for (final g in res.groups) {
      h = fnv(h, g.material.index);
      h = fnv(h, g.castsShadow ? 1 : 0);
      h = words(h, g.positions);
      h = words(h, g.normals);
      h = words(h, g.texCoords);
      h = words(h, g.indices);
    }
    h = words(h, res.treePits);
    return words(h, res.shrubPits);
  }

  CityTileRequest request(CityTileColumns c, CityTier tier,
          {bool canDetail = false, CityMeshKnobs k = knobs}) =>
      CityTileRequest(
        tileKey: '$body/0/0',
        key: 'k-${tier.name}',
        tier: tier,
        canDetail: canDetail,
        anchorBF: anchor,
        columns: c,
        focusBF: const Vector3(0, 0, r + 40),
        colonyTier: BuildingDetail.full,
        epoch: 1234.5,
        knobs: k,
      );

  /// A tile meshed from its packed columns, the way a worker meshes it.
  CityTileResult mesh(CityTileColumns c, CityTier tier,
          {bool canDetail = false}) =>
      CityTileMesher.mesh(
          request(c, tier, canDetail: canDetail), CityBuildingLibraries());

  final noColumns = CityTileColumns.fromSnapshots(
    buildings: const [],
    roads: const [],
    patches: CityPatchColumns.empty,
    ends: const [],
    roadEnds: const [],
    transitEnds: const [],
  );

  /// A tile meshed from [roads] (and junction [ends] and [junctions]) as
  /// they are, every field of the road tool's included.
  CityTileResult meshWith(List<RoadSnapshot> roads, CityTier tier,
          {List<(double, int)?>? roadEnds,
          List<CityTileEnd> ends = const [],
          List<CityTileJunction> junctions = const [],
          List<CityTileCorridor> corridors = const [],
          CityMeshKnobs k = knobs}) =>
      CityTileMeshJob(request(noColumns, tier, k: k), CityBuildingLibraries(),
              members: CityTileMembers(
                buildings: const [],
                roads: roads,
                patches: CityPatchColumns.empty,
                ends: ends,
                roadEnds: roadEnds ?? [for (final _ in roads) ...[null, null]],
                transitEnds: const [],
                junctions: junctions,
                corridors: corridors,
              ))
          .runAll();

  CityTileColumns roadsOnly(List<RoadSnapshot> roads,
          {List<(double, int)?>? roadEnds}) =>
      CityTileColumns.fromSnapshots(
        buildings: const [],
        roads: roads,
        patches: CityPatchColumns.empty,
        ends: const [],
        roadEnds: roadEnds ?? [for (final _ in roads) ...[null, null]],
        transitEnds: const [],
      );

  /// Positions of every vertex of [kind]'s groups, anchor-relative metres.
  List<Vector3> verts(CityTileResult res, CityMaterialKind kind) => [
        for (final g in res.groups)
          if (g.material == kind)
            for (var i = 0; i < g.vertexCount; i++)
              Vector3(g.positions[i * 3], g.positions[i * 3 + 1],
                      g.positions[i * 3 + 2]) *
                  (1 / kRenderScale),
      ];

  int tris(CityTileResult res, CityMaterialKind kind) => res.groups
      .where((g) => g.material == kind)
      .fold(0, (n, g) => n + g.triangleCount);

  group('a road on the ground meshes as it always did', () {
    // Digests taken on the tree before the road tool's meshing landed:
    // every class the generator lays, bridges, walls, tapers, collectors
    // and a sealed street, with no junction ends — the mesher fixture's
    // own digests (`city_tile_mesher_test`) hold a junction of the
    // generator's streets to the byte as well.
    final zoo = <RoadSnapshot>[
      road(RoadClass.street, line(0, -200, 200, 9)),
      road(RoadClass.avenue, line(100, -300, 300, 13), bridges: [100, 300]),
      road(RoadClass.highway, line(200, -300, 300, 11), walls: true),
      road(RoadClass.trunk, line(300, -300, 300, 7), hw0: 12, hw1: 9),
      road(RoadClass.expressway8, line(400, -300, 300, 7)),
      road(RoadClass.alley, line(500, -100, 100, 3)),
      road(RoadClass.path, line(550, -100, 100, 3)),
      road(RoadClass.elevated, line(600, -300, 300, 7)),
      road(RoadClass.transit, line(700, -300, 300, 7)),
      road(RoadClass.rail, line(800, -300, 300, 7)),
      road(RoadClass.street, line(900, -200, 200, 5), sealed: true),
      road(RoadClass.street, line(-100, -200, 200, 5), collector: true),
      road(RoadClass.boulevard, line(-200, -300, 300, 9)),
    ];
    final zooEnds = <(double, int)?>[
      (4.0, 3), null,
      for (var i = 1; i < zoo.length; i++) ...[null, null],
    ];

    test('every class, every tier, to the byte', () {
      final c = roadsOnly(zoo, roadEnds: zooEnds);
      expect(digest(mesh(c, CityTier.near)), 0xfaae5bd2);
      expect(digest(mesh(c, CityTier.mid)), 0xa687274b);
      expect(digest(mesh(c, CityTier.far)), 0xb8c5ea2d);
      // And handed in as members rather than columns: the same tile.
      for (final tier in CityTier.values) {
        expect(digest(meshWith(zoo, tier, roadEnds: zooEnds)),
            digest(mesh(c, tier)),
            reason: tier.name);
      }
    });

    test('the mesher fixture, its junctions aside, to the byte', () {
      BuildingSnapshot bldg(String id, String type, double x, double y,
              {double w = 24, double d = 24, bool corner = false}) =>
          BuildingSnapshot(
            id: id,
            type: type,
            colonyId: 'c',
            body: body,
            px: x,
            py: y,
            pz: r,
            qw: 1,
            qx: 0,
            qy: 0,
            qz: 0,
            lat: 0,
            lon: 0,
            siteWidthM: w,
            siteDepthM: d,
            siteKindIndex: 0,
            colorArgb: 0xFF808080,
            corner: corner,
          );
      final columns = CityTileColumns.fromSnapshots(
        buildings: [
          for (var i = 0; i < 6; i++)
            bldg('r$i', 'r-med', -120 + i * 40.0, 60, w: 18 + (i % 3) * 6),
          for (var i = 0; i < 4; i++)
            bldg('c$i', 'c-high', -90 + i * 60.0, -80,
                w: 40, d: 36, corner: i == 0),
          bldg('i0', 'i-low', 200, 200, w: 60, d: 40),
        ],
        roads: [
          road(RoadClass.street, line(0, -200, 200, 9)),
          road(RoadClass.street, [(-200, 0), (-200, 150)]),
          road(RoadClass.street, [(200, 0), (200, 150)]),
          road(RoadClass.street, [(0, 0), (0, -150)]),
        ],
        patches: CityPatchColumns.of([
          const CityPatchSnapshot(
            colonyId: 'c',
            body: body,
            px: 0,
            py: 60,
            pz: r,
            qw: 1,
            qx: 0,
            qy: 0,
            qz: 0,
            sizeM: 300,
            kind: CityPatchSnapshot.kindResidential,
            depthM: 60,
          ),
        ]),
        ends: const [],
        roadEnds: [
          (RoadClass.street.width / 2, 2), (RoadClass.street.width / 2, 2),
          (RoadClass.street.width / 2, 2), null,
          (RoadClass.street.width / 2, 2), null,
          (RoadClass.street.width / 2, 3), null,
        ],
        transitEnds: const [],
      );
      int at(CityTier tier) =>
          digest(mesh(columns, tier, canDetail: tier == CityTier.near));
      expect(at(CityTier.near), 0x5e473abb);
      expect(at(CityTier.mid), 0x09731332);
      expect(at(CityTier.far), 0x07d559a4);
    });

    test('a ramp is what it was, and then its arrows', () {
      // A ramp is one way: the only road the generator lays that gains
      // anything. Its bytes are what they were, with the arrows after.
      final ramp = roadsOnly([road(RoadClass.ramp, line(0, -200, 200, 11))]);
      expect(digest(mesh(ramp, CityTier.far)), 0x0610818f,
          reason: 'no paint at far, so no arrows');
      for (final tier in [CityTier.mid, CityTier.near]) {
        final res = mesh(ramp, tier);
        final g =
            res.groups.singleWhere((g) => g.material == CityMaterialKind.road);
        var h = 0x811C9DC5;
        h = fnv(h, g.material.index);
        h = fnv(h, g.castsShadow ? 1 : 0);
        h = words(h, g.positions, 110 * 3);
        h = words(h, g.normals, 110 * 3);
        h = words(h, g.texCoords, 110 * 2);
        h = words(h, g.indices, 300);
        h = words(h, res.treePits);
        h = words(h, res.shrubPits);
        expect(h, 0xe4af1e87, reason: tier.name);
        // One lane, 400 m: eight arrows, a shaft and a head each.
        expect(g.indices.length - 300, 8 * 3 * 3, reason: tier.name);
      }
    });
  });

  group('lifts', () {
    // On the equator of a 6371 km world: local up is +x, the road runs +z.
    final eq = Vector3(6371000, 0, 0);
    List<Vector3> along(double lengthM, int samples) => [
          for (var i = 0; i < samples; i++)
            Vector3(0, 0, lengthM * i / (samples - 1)),
        ];

    test('the deck rides the lift, exactly at every point', () {
      final pts = along(200, 21);
      final lifts = [for (var i = 0; i < 21; i++) 3.0 + i * 0.5];
      final m = MeshBuilder();
      RoadMesher.carriageway(m, pts, eq, RoadClass.street,
          liftAt: RoadDeckMesher.liftAt(pts, lifts), paint: false);
      final mesh = m.build();
      // The ribbon is one strip, two vertices a station.
      expect(mesh.vertexCount, 42);
      for (var i = 0; i < 21; i++) {
        for (final v in [2 * i, 2 * i + 1]) {
          expect(mesh.positions[v * 3] / kRenderScale,
              closeTo(RoadMesher.ribbonLiftM + lifts[i], 1e-6));
        }
      }
      // And between the points, linear.
      final at = RoadDeckMesher.liftAt(pts, lifts);
      expect(at(15), closeTo(3.75, 1e-9));
      expect(at(-5), 3.0);
      expect(at(500), lifts.last);
      // A plan's bridge composes with it, measured from the ROAD's start.
      final both = RoadDeckMesher.liftAt(pts, lifts,
          bridges: const [(0, 1000)], s0: 400);
      expect(both(100), closeTo(8.0 + RoadMesher.bridgeHeightM, 1e-9));
    });

    test('a lifted street in a tile: the carriageway on its deck', () {
      final res = meshWith([
        road(RoadClass.street, line(0, -200, 200, 21),
            lifts: List.filled(21, 8.0)),
      ], CityTier.mid);
      final deck = verts(res, CityMaterialKind.road);
      expect(deck, isNotEmpty);
      for (final p in deck) {
        // Ribbon, paint: the deck plus a few centimetres. No turning
        // circle at either end — a raised end is an abutment.
        expect(p.z, inInclusiveRange(8.0, 8.3));
      }
      // Its structure is on the facade: girders, parapets, piers down to a
      // metre under the drape.
      final concrete = verts(res, CityMaterialKind.facade);
      expect(concrete, isNotEmpty);
      expect(concrete.map((p) => p.z).reduce(math.min), closeTo(-1.0, 0.01));
      // The same road flat: nothing on the facade at all.
      expect(
          tris(meshWith([road(RoadClass.street, line(0, -200, 200, 21))],
              CityTier.mid), CityMaterialKind.facade),
          0);
    });

    test('a raised span keeps its lamps on the deck and nothing on the '
        'ground beneath', () {
      // At grade for 100 m each end, up on a 10 m structure between.
      final xy = line(0, -300, 300, 31);
      final lifts = [
        for (final (x, _) in xy)
          x.abs() >= 200 ? 0.0 : (x.abs() <= 150 ? 10.0 : (200 - x.abs()) / 5)
      ];
      final res = meshWith([road(RoadClass.street, xy, lifts: lifts)],
          CityTier.near);
      // No pavement under the structure (clear of 2.5 m inside 187.5 m).
      for (final p in verts(res, CityMaterialKind.sidewalk)) {
        expect(p.x.abs(), greaterThan(187.4), reason: '$p');
      }
      // No tree and no car there either.
      for (var i = 0; i < res.treePits.length; i += 4) {
        expect(res.treePits[i].abs(), greaterThan(187.4));
      }
      // Lamps up on the deck: glass heads over the structure, nine metres
      // above ten.
      final heads = verts(res, CityMaterialKind.glazing)
          .where((p) => p.x.abs() < 150)
          .toList();
      expect(heads, isNotEmpty);
      for (final p in heads) {
        expect(p.z, greaterThan(18.0));
      }
    });

    test('piers and girders only where the deck stands clear', () {
      final pts = along(300, 31);
      // Flat for 100 m, up a ramp to 10 m by 160 m, then held.
      double liftFor(double s) =>
          s <= 100 ? 0.0 : (s >= 160 ? 10.0 : (s - 100) / 60 * 10);
      final lifts = [for (final p in pts) liftFor(p.z)];
      final solid = MeshBuilder();
      RoadDeckMesher.structure(
          solid, pts, eq, 4, RoadDeckMesher.liftAt(pts, lifts));
      final mesh = solid.build();
      expect(mesh.triangleCount, greaterThan(0));
      // Clear of 2.5 m from 115 m on; the first segment carried is the one
      // whose middle is clear (120-130 m), so nothing stands before 120 m.
      for (var v = 0; v < mesh.vertexCount; v++) {
        expect(mesh.positions[v * 3 + 2] / kRenderScale, greaterThan(118.0));
      }
      // At grade throughout: nothing at all.
      final flat = MeshBuilder();
      RoadDeckMesher.structure(flat, pts, eq, 4,
          RoadDeckMesher.liftAt(pts, List.filled(31, 2.4)));
      expect(flat.triangleCount, 0);
    });

    test('a bridge spans further on deeper girders', () {
      final pts = along(300, 31);
      int boxes(double lift) {
        final m = MeshBuilder();
        RoadDeckMesher.structure(
            m, pts, eq, 4, RoadDeckMesher.liftAt(pts, List.filled(31, lift)));
        return m.triangleCount ~/ 12;
      }

      // Thirty segments, a girder and a parapet each side: 120 boxes; the
      // piers are the rest — at 0, 40, 80 ... 280 on a viaduct (eight), at
      // 0, 70, 140, 210, 280 on a bridge (five).
      expect(boxes(10), 120 + 8);
      expect(boxes(20), 120 + 5);
      bool reaches(double lift, double depth) {
        final m = MeshBuilder();
        RoadDeckMesher.structure(
            m, pts, eq, 4, RoadDeckMesher.liftAt(pts, List.filled(31, lift)));
        final mesh = m.build();
        final soffit = RoadMesher.ribbonLiftM + lift - depth;
        for (var v = 0; v < mesh.vertexCount; v++) {
          if ((mesh.positions[v * 3] / kRenderScale - soffit).abs() < 1e-3) {
            return true;
          }
        }
        return false;
      }

      expect(reaches(10, RoadDeckMesher.girderDepthM), isTrue);
      expect(reaches(20, RoadDeckMesher.bridgeGirderDepthM), isTrue);
      expect(reaches(20, RoadDeckMesher.girderDepthM), isFalse);
    });
  });

  group('tunnels', () {
    test('the runs above ground end at the mouths', () {
      final pts = [for (var i = 0; i < 7; i++) Vector3(0, 0, i * 10.0)];
      final runs = RoadDeckMesher.runs(pts, const [0, 0, -8, -8, -8, 0, 0]);
      expect(runs, hasLength(2));
      final a = runs.first, b = runs.last;
      expect(a.fromStart, isTrue);
      expect(a.toEnd, isFalse);
      expect(a.pts, hasLength(3));
      // Down to the cover depth 5/8 of the way to the first point inside.
      expect(a.pts.last.z, closeTo(16.25, 1e-9));
      expect(a.lifts!.last, -RoadElevation.tunnelCoverM);
      expect(b.fromStart, isFalse);
      expect(b.toEnd, isTrue);
      expect(b.pts.first.z, closeTo(43.75, 1e-9));
      expect(b.s0, closeTo(43.75, 1e-9));
      expect(b.lifts!.first, -RoadElevation.tunnelCoverM);
      // Wholly underground: nothing; never under: one run, as it was.
      expect(RoadDeckMesher.runs(pts, List.filled(7, -9.0)), isEmpty);
      final whole = RoadDeckMesher.runs(pts, List.filled(7, -4.0));
      expect(whole.single.pts, pts);
      expect(whole.single.fromStart && whole.single.toEnd, isTrue);
    });

    test('a portal: wing walls from the deck, a lintel, a headwall above '
        'the ground', () {
      // At the pole the mouth's up is +Z; the road runs +X into the hill.
      final m = MeshBuilder();
      RoadDeckMesher.portal(
          m, Vector3.zero, const Vector3(1, 0, 0), anchor, 4);
      final mesh = m.build();
      // Two wing walls, the lintel and the headwall: four boxes.
      expect(mesh.triangleCount, 4 * 12);
      final zs = [
        for (var v = 0; v < mesh.vertexCount; v++)
          mesh.positions[v * 3 + 2] / kRenderScale
      ];
      final xs = [
        for (var v = 0; v < mesh.vertexCount; v++)
          mesh.positions[v * 3] / kRenderScale
      ];
      expect(zs.reduce(math.min), closeTo(-RoadElevation.tunnelCoverM, 1e-3));
      expect(zs.reduce(math.max), greaterThan(1.0));
      // The wing walls run back out of the mouth along the cutting.
      expect(xs.reduce(math.min), closeTo(-RoadDeckMesher.wingWallM, 1e-3));
    });

    // A street down into a tunnel under the middle of the town and out
    // again: at grade beyond 100 m out, 10 m down within 60 m, the mouths
    // (5 m down) at +-80 m.
    List<double> dip(List<(double, double)> xy) => [
          for (final (x, _) in xy)
            x.abs() >= 100
                ? 0.0
                : x.abs() <= 60
                    ? -10.0
                    : -10 + (x.abs() - 60) / 40 * 10,
        ];

    test('nothing is drawn in the tunnel, and a portal stands at each mouth',
        () {
      final xy = line(0, -200, 200, 21);
      final res = meshWith([road(RoadClass.street, xy, lifts: dip(xy))],
          CityTier.near);
      final asphalt = verts(res, CityMaterialKind.road);
      expect(asphalt, isNotEmpty);
      for (final p in asphalt) {
        expect(p.x.abs(), greaterThan(79.9), reason: 'in the tunnel: $p');
      }
      // The cutting's deck goes down with the lift: at the mouths the road
      // is the cover depth below the drape, and at grade 100 m out.
      expect(
          asphalt.any((p) =>
              (p.x.abs() - 80).abs() < 0.5 &&
              (p.z - (RoadMesher.ribbonLiftM - 5)).abs() < 0.05),
          isTrue);
      expect(
          asphalt.any((p) =>
              (p.x.abs() - 100).abs() < 0.5 &&
              (p.z - RoadMesher.ribbonLiftM).abs() < 0.05),
          isTrue);
      // A headwall at each mouth, standing proud of the ground and wider
      // than anything on the pavement.
      final concrete = verts(res, CityMaterialKind.facade);
      for (final side in const [-1.0, 1.0]) {
        expect(
            concrete.any((p) =>
                (p.x * side - 79.5).abs() < 0.6 &&
                p.y.abs() > 7.5 &&
                p.z > 1.5),
            isTrue,
            reason: 'a headwall at ${side * 80}');
      }
      // No sidewalk, tree or car in the tunnel either.
      for (final p in verts(res, CityMaterialKind.sidewalk)) {
        expect(p.x.abs(), greaterThan(79.9));
      }
      for (var i = 0; i < res.treePits.length; i += 4) {
        expect(res.treePits[i].abs(), greaterThan(79.9));
      }
    });

    test('an end in its tunnel takes no turning circle', () {
      int roadTris(List<double> lifts, [CityTier tier = CityTier.mid]) => tris(
          meshWith([road(RoadClass.street, line(0, 0, 200, 11), lifts: lifts)],
              tier),
          CityMaterialKind.road);
      final plain = roadTris(const []);
      // Half a metre up is still at grade: the same triangles, turning
      // circles and all.
      expect(roadTris(List.filled(11, 0.5)), plain);
      // The last 60 m underground: the carriageway there and the circle at
      // that end go; the circle at the start stays.
      final sunk = roadTris([
        for (var i = 0; i < 11; i++) i < 7 ? 0.5 : -9.0,
      ]);
      // Ribbon and centre line over six segments and the mouth's part
      // segment (28), and one circle (12).
      expect(sunk, 28 + 12);
      expect(plain, 40 + 2 * 12);
    });

    test('a node in a tunnel is no junction', () {
      RoadEnd end(Vector3 towards, double lift) =>
          RoadEnd(Vector3.zero, towards, 4, RoadClass.street, liftM: lift);
      final n = Vector3(0, 0, 1), e = Vector3(0, 1, 0);
      expect(
          RoadMesher.junctionsFromEnds(
              [end(n, -9), end(n * -1, -9), end(e, -9)]),
          isEmpty);
      expect(
          RoadMesher.junctionsFromEnds(
                  [end(n, -3), end(n * -1, -3), end(e, -3)])
              .single
              .liftM,
          -3);
    });
  });

  group('junctions', () {
    // At the pole, so the node's tangent frame is the town's own: east +X,
    // north +Y.
    RoadEnd end(double dx, double dy, RoadClass cls,
            {bool isStart = false, double lift = 0}) =>
        RoadEnd(Vector3.zero, Vector3(dx, dy, 0), cls.halfWidth, cls,
            isStart: isStart, liftM: lift);

    test('ends meet only at one level', () {
      final js = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.street),
        end(-10, 0, RoadClass.street),
        end(0, 10, RoadClass.street),
        // An overpass twelve metres up over the same point.
        end(10, 1, RoadClass.avenue, lift: 12),
        end(-10, 1, RoadClass.avenue, lift: 12),
        end(0, -10, RoadClass.avenue, lift: 12),
      ], anchorBF: anchor);
      expect(js, hasLength(2));
      expect(js.map((j) => j.liftM), [0, 12]);
      expect(
          js.first.legs.map((l) => l.roadClass).toSet(), {RoadClass.street});
      expect(
          js.last.legs.map((l) => l.roadClass).toSet(), {RoadClass.avenue});
      // A metre apart is one level; a three-metre step is not.
      expect(
          RoadMesher.junctionsFromEnds([
            end(10, 0, RoadClass.street),
            end(-10, 0, RoadClass.street, lift: 1.0),
            end(0, 10, RoadClass.street, lift: 1.4),
          ]).single.legs,
          hasLength(3));
      expect(
          RoadMesher.junctionsFromEnds([
            end(10, 0, RoadClass.street),
            end(-10, 0, RoadClass.street),
            end(0, 10, RoadClass.street, lift: 3),
          ]),
          isEmpty);
    });

    test('an outgoing one-way leg has no bar, no mast and no signal', () {
      List<RoadJunction> at({required bool leaving}) =>
          RoadMesher.junctionsFromEnds([
            end(10, 0, RoadClass.boulevard),
            end(-10, 0, RoadClass.boulevard),
            end(0, 10, RoadClass.street),
            end(0, -10, RoadClass.streetOneWay, isStart: leaving),
          ], anchorBF: anchor);
      final out = at(leaving: true).single;
      expect(out.control, JunctionControl.signals);
      expect(out.legs.last.outgoing, isTrue);
      expect(out.controls(3), isFalse);
      expect([for (var i = 0; i < 3; i++) out.controls(i)],
          everyElement(isTrue));
      int count(RoadJunction j, int which) {
        final m = [MeshBuilder(), MeshBuilder(), MeshBuilder()];
        RoadMesher.junctions(m[0], m[1], m[2], [j], anchor, 0);
        return m[which].triangleCount;
      }

      // Road: the plate, a bar on each of the three inbound legs, zebras
      // (five stripes) on all four. Masts and heads: one a leg that
      // arrives.
      expect(count(out, 0), 8 + 3 * 2 + 4 * 5 * 2);
      expect(count(out, 1), 3 * 8);
      expect(count(out, 2), 3 * 2);
      // The one-way arriving instead: a fourth inbound leg.
      final into = at(leaving: false).single;
      expect(into.control, JunctionControl.signals);
      expect(count(into, 0), 8 + 4 * 2 + 4 * 5 * 2);
      expect(count(into, 1), 4 * 8);
      expect(count(into, 2), 4 * 2);
    });

    test('the bar on a two-way leg spans the inbound half; a one-way '
        'arriving is barred across', () {
      final j = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.street),
        end(-10, 0, RoadClass.street),
        end(0, 10, RoadClass.streetOneWay),
      ], anchorBF: anchor).single;
      expect(j.control, JunctionControl.stop);
      final m = MeshBuilder();
      RoadMesher.junctions(m, MeshBuilder(), MeshBuilder(), [j], anchor, 0);
      final mesh = m.build();
      // The octagonal plate (nine vertices), then a bar (four) a leg.
      expect(mesh.vertexCount, 9 + 3 * 4);
      final up = anchor.normalized;
      for (var k = 0; k < 3; k++) {
        final leg = j.legs[k];
        final side = leg.dir.cross(up).normalized;
        final lateral = [
          for (var v = 9 + 4 * k; v < 13 + 4 * k; v++)
            Vector3(mesh.positions[v * 3], mesh.positions[v * 3 + 1],
                        mesh.positions[v * 3 + 2])
                    .dot(side) /
                kRenderScale,
        ];
        final hw = leg.halfWidthM * 0.92;
        // Traffic keeps right: the traffic leaving is on the leg's +side,
        // the traffic arriving on its -side, and the bar is across that —
        // across the whole of a one-way road coming in.
        expect(lateral.reduce(math.min), closeTo(-hw, 1e-5));
        expect(lateral.reduce(math.max), closeTo(leg.oneWay ? hw : 0, 1e-5));
      }
    });

    test('the plan agrees with the old warrant where the town has always '
        'had it', () {
      // Streets crossing: an all-way stop, every leg stopping.
      final stop = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.street),
        end(-10, 0, RoadClass.street),
        end(0, 10, RoadClass.street),
        end(0, -10, RoadClass.street),
      ]).single;
      expect(stop.control, JunctionControl.stop);
      expect(stop.stopLegs, {0, 1, 2, 3});
      // Avenues crossing: signals, no stop legs.
      final lights = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.avenue),
        end(-10, 0, RoadClass.avenue),
        end(0, 10, RoadClass.avenue),
        end(0, -10, RoadClass.avenue),
      ]).single;
      expect(lights.control, JunctionControl.signals);
      expect(lights.stopLegs, isNull);
    });

    test('an override picks the stop legs and the lights', () {
      List<RoadEnd> crossing(RoadClass cls) => [
            end(10, 0, cls),
            end(-10, 0, cls),
            end(0, 10, cls),
            end(0, -10, cls),
          ];
      // Stop the north-south road only: points 12 m out along it.
      final ns = RoadMesher.junctionsFromEnds(crossing(RoadClass.street),
          anchorBF: anchor,
          overrides: const [
            RoadOverride(Vector3(1, 1, 0), stopPoints: [
              Vector3(0, 12, 0),
              Vector3(0, -12, 0),
            ]),
          ]).single;
      expect(ns.control, JunctionControl.stop);
      expect(ns.stopLegs, {2, 3});
      final m = [MeshBuilder(), MeshBuilder(), MeshBuilder()];
      RoadMesher.junctions(m[0], m[1], m[2], [ns], anchor, 0);
      // The plate and two bars; two signs (a post of four quads and a
      // plate each).
      expect(m[0].triangleCount, 8 + 2 * 2);
      expect(m[1].triangleCount, 2 * (8 + 2));
      // Lights forced on at the street crossing; off at the avenues'.
      expect(
          RoadMesher.junctionsFromEnds(crossing(RoadClass.street),
              anchorBF: anchor,
              overrides: const [
                RoadOverride(Vector3.zero, lights: true)
              ]).single.control,
          JunctionControl.signals);
      final off = RoadMesher.junctionsFromEnds(crossing(RoadClass.avenue),
          anchorBF: anchor,
          overrides: const [RoadOverride(Vector3.zero, lights: false)]).single;
      expect(off.control, JunctionControl.stop);
      expect(off.stopLegs, {0, 1, 2, 3});
      // Seven metres off is some other junction's.
      expect(
          RoadMesher.junctionsFromEnds(crossing(RoadClass.street),
              anchorBF: anchor,
              overrides: const [
                RoadOverride(Vector3(7, 0, 0), lights: true)
              ]).single.control,
          JunctionControl.stop);
    });

    test('a tile carries its end flags and its overrides to the plan', () {
      // The crossing as a tile holds it: body-fixed ends, flags and all,
      // and the player's overrides, through the whole mesher at near.
      CityTileEnd tileEnd(double dx, double dy, RoadClass cls,
              {bool isStart = false, double lift = 0}) =>
          CityTileEnd(anchor, anchor + Vector3(dx, dy, 0), cls.halfWidth, cls,
              true, false,
              isStart: isStart, liftM: lift);
      final ends = [
        tileEnd(10, 0, RoadClass.boulevard),
        tileEnd(-10, 0, RoadClass.boulevard),
        tileEnd(0, 10, RoadClass.street),
        tileEnd(0, -10, RoadClass.streetOneWay, isStart: true),
      ];
      int heads(List<CityTileJunction> junctions, [List<CityTileEnd>? e]) =>
          tris(meshWith(const [], CityTier.near,
                  ends: e ?? ends, junctions: junctions),
              CityMaterialKind.glazing);
      // Signals, and a head on each of the three legs that arrive.
      expect(heads(const []), 3 * 2);
      // The player turns them off: a stop, no heads.
      expect(heads([CityTileJunction(anchor, 0, const [])]), 0);
      // Streets only: a stop by the warrant; the player puts lights in.
      final streets = [
        tileEnd(10, 0, RoadClass.street),
        tileEnd(-10, 0, RoadClass.street),
        tileEnd(0, 10, RoadClass.street),
      ];
      expect(heads(const [], streets), 0);
      expect(heads([CityTileJunction(anchor, 1, const [])], streets), 3 * 2);
      // An override left to the warrant changes nothing.
      expect(heads([CityTileJunction(anchor, -1, const [])], streets), 0);
      // The stop legs by their points: the east-west road stops, the
      // north leg runs through — two signs on posts, not three.
      final poles = tris(
          meshWith(const [], CityTier.near, ends: streets, junctions: [
            CityTileJunction(anchor, -1, [
              anchor.x + 12, anchor.y, anchor.z, //
              anchor.x - 12, anchor.y, anchor.z,
            ]),
          ]),
          CityMaterialKind.facade);
      expect(poles, 2 * (8 + 2));
      // And a node down in a tunnel: nothing at all.
      final sunk = meshWith(const [], CityTier.near, ends: [
        for (final e in streets)
          CityTileEnd(e.at, e.next, e.halfWidthM, e.roadClass, true, false,
              liftM: -9),
      ]);
      expect(sunk.groups, isEmpty);
    });

    test("the generator's junctions keep the class warrant, whichever way "
        'their streets were drawn', () {
      // An avenue ENDING on two streets has always been a stop. Read by
      // the leg-aware warrant it would take lights unless both streets
      // happened to start at it — and the generator draws its streets
      // either way.
      for (final (a, b) in const [
        (false, false),
        (true, false),
        (false, true),
        (true, true)
      ]) {
        final j = RoadMesher.junctionsFromEnds([
          end(10, 0, RoadClass.avenue),
          end(-10, 0, RoadClass.street, isStart: a),
          end(0, 10, RoadClass.street, isStart: b),
        ], anchorBF: anchor).single;
        expect(j.control, JunctionControl.stop, reason: '$a $b');
        expect(j.stopLegs, {0, 1, 2}, reason: '$a $b');
        expect(j.wholeBars, isTrue);
      }
      // An avenue running past a street's end: signals, whether the
      // street was drawn from the avenue or to it.
      for (final away in [false, true]) {
        final t = RoadMesher.junctionsFromEnds([
          end(10, 0, RoadClass.avenue),
          end(-10, 0, RoadClass.avenue, isStart: true),
          end(0, 10, RoadClass.street, isStart: away),
        ], anchorBF: anchor).single;
        expect(t.control, JunctionControl.signals, reason: 'away: $away');
      }
      // A ramp leaving an avenue keeps the terminal's signals, and — one
      // way, leaving — no mast.
      final onRamp = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.avenue),
        end(-10, 0, RoadClass.avenue),
        end(0, 10, RoadClass.ramp, isStart: true),
      ], anchorBF: anchor).single;
      expect(onRamp.control, JunctionControl.signals);
      expect(onRamp.controls(2), isFalse);
      // Any of the generator's classes, drawn any way round: the class
      // warrant exactly, every leg that arrives stopping at a stop.
      final generated = [
        for (final c in RoadClass.values)
          if (!RoadMesher.toolOnly(c)) c
      ];
      final rng = math.Random(3);
      for (var n = 0; n < 400; n++) {
        final k = 3 + rng.nextInt(3);
        final classes = [
          for (var i = 0; i < k; i++) generated[rng.nextInt(generated.length)]
        ];
        final js = RoadMesher.junctionsFromEnds([
          for (var i = 0; i < k; i++)
            end(math.cos(i * 2 * math.pi / k) * 10,
                math.sin(i * 2 * math.pi / k) * 10, classes[i],
                isStart: rng.nextBool()),
        ], anchorBF: anchor);
        final want = junctionControlFor(classes);
        if (want == JunctionControl.none) {
          expect(js, isEmpty, reason: '$classes');
          continue;
        }
        final j = js.single;
        expect(j.control, want, reason: '$classes');
        expect(j.wholeBars, isTrue, reason: '$classes');
        if (want == JunctionControl.stop) {
          expect(j.stopLegs, {
            for (var i = 0; i < k; i++)
              if (j.legs[i].inbound) i
          });
        }
      }
    });

    test("the tool's classes and its decks take the leg-aware plan", () {
      // That avenue T raised onto a deck with its street drawn away from
      // it: the tool drew the street, so which way counts — no lights, and
      // the street gives way to the avenue. Drawn to it: lights.
      List<RoadJunction> raisedT({required bool away}) =>
          RoadMesher.junctionsFromEnds([
            end(10, 0, RoadClass.avenue, lift: 6),
            end(-10, 0, RoadClass.avenue, lift: 6),
            end(0, 10, RoadClass.street, isStart: away, lift: 6),
          ], anchorBF: anchor);
      final away = raisedT(away: true).single;
      expect(away.control, JunctionControl.stop);
      expect(away.stopLegs, {2});
      expect(away.wholeBars, isFalse);
      expect(raisedT(away: false).single.control, JunctionControl.signals);
      // On the ground, a leg of a class only the tool lays does the same:
      // a one-way street arriving at an avenue's end makes it a four-lane
      // crossing with lights; leaving it, with the other street drawn
      // away, a stop where the street gives way.
      final arriving = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.avenue),
        end(-10, 0, RoadClass.street),
        end(0, 10, RoadClass.streetOneWay),
      ], anchorBF: anchor).single;
      expect(arriving.control, JunctionControl.signals);
      expect(arriving.wholeBars, isFalse);
      final leaving = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.avenue),
        end(-10, 0, RoadClass.street, isStart: true),
        end(0, 10, RoadClass.streetOneWay, isStart: true),
      ], anchorBF: anchor).single;
      expect(leaving.control, JunctionControl.stop);
      expect(leaving.stopLegs, {1});
    });

    test('an override applies over the warrant the legs chose', () {
      // The generator's avenue T, its street drawn away: signals by class.
      final t = [
        end(10, 0, RoadClass.avenue),
        end(-10, 0, RoadClass.avenue),
        end(0, 10, RoadClass.street, isStart: true),
      ];
      RoadJunction at(RoadOverride o) =>
          RoadMesher.junctionsFromEnds(t, anchorBF: anchor, overrides: [o])
              .single;
      // Naming stop legs does not swap it onto the leg-aware warrant, which
      // would have made it a stop.
      final named =
          at(const RoadOverride(Vector3.zero, stopPoints: [Vector3(0, 12, 0)]));
      expect(named.control, JunctionControl.signals);
      expect(named.wholeBars, isTrue);
      // Lights off: a stop, every leg that arrives stopping — or only the
      // ones the player names.
      final off = at(const RoadOverride(Vector3.zero, lights: false));
      expect(off.control, JunctionControl.stop);
      expect(off.stopLegs, {0, 1, 2});
      expect(
          at(const RoadOverride(Vector3.zero,
                  lights: false, stopPoints: [Vector3(0, 12, 0)]))
              .stopLegs,
          {2});
    });

    test("stop points are read from the override's own point", () {
      // The override lies 5.5 m east of the node, inside the match, its
      // stop points 12 m north and south of it; the north leg runs three
      // degrees west of north. Seen from the node the north point is 24.6
      // degrees east of north — past the 25 degree match with the leg's
      // lean the other way.
      const lean = 3 * math.pi / 180;
      final j = RoadMesher.junctionsFromEnds([
        end(-10 * math.sin(lean), 10 * math.cos(lean), RoadClass.street),
        end(0, -10, RoadClass.street),
        end(10, 0, RoadClass.street),
        end(-10, 0, RoadClass.street),
      ], anchorBF: anchor, overrides: const [
        RoadOverride(Vector3(5.5, 0, 0),
            stopPoints: [Vector3(5.5, 12, 0), Vector3(5.5, -12, 0)]),
      ]).single;
      expect(j.control, JunctionControl.stop);
      expect(j.stopLegs, {0, 1});
    });

    test('an override that stops no leg draws no bar and no sign', () {
      List<RoadEnd> crossing(RoadClass cls) => [
            end(10, 0, cls),
            end(-10, 0, cls),
            end(0, 10, cls),
            end(0, -10, cls),
          ];
      // The player took every stop sign away: the domain's empty stop
      // headings, not "leave them to the warrant".
      for (final cls in [RoadClass.street, RoadClass.streetOneWay]) {
        final none = RoadMesher.junctionsFromEnds(crossing(cls),
            anchorBF: anchor,
            overrides: const [
              RoadOverride(Vector3.zero, stopPoints: [])
            ]).single;
        expect(none.control, JunctionControl.stop, reason: cls.name);
        expect(none.stopLegs, isEmpty, reason: cls.name);
        final m = [MeshBuilder(), MeshBuilder(), MeshBuilder()];
        RoadMesher.junctions(m[0], m[1], m[2], [none], anchor, 0);
        expect(m[0].triangleCount, 8, reason: 'the plate alone');
        expect(m[1].triangleCount, 0, reason: 'no sign');
      }
      // Stop points unsaid leave the warrant's stop legs: every leg.
      expect(
          RoadMesher.junctionsFromEnds(crossing(RoadClass.street),
              anchorBF: anchor,
              overrides: const [RoadOverride(Vector3.zero)]).single.stopLegs,
          {0, 1, 2, 3});
      // A tile's override can say it chose the stop legs only by carrying
      // points, so one with none still leaves them to the warrant: three
      // signs on posts at the street T.
      CityTileEnd tileEnd(double dx, double dy) => CityTileEnd(
          anchor,
          anchor + Vector3(dx, dy, 0),
          RoadClass.street.halfWidth,
          RoadClass.street,
          true,
          false);
      final poles = tris(
          meshWith(const [], CityTier.near, ends: [
            tileEnd(10, 0),
            tileEnd(-10, 0),
            tileEnd(0, 10),
          ], junctions: [
            CityTileJunction(anchor, -1, const [])
          ]),
          CityMaterialKind.facade);
      expect(poles, 3 * (8 + 2));
    });

    test("a junction of the generator's roads bars each leg right across",
        () {
      final j = RoadMesher.junctionsFromEnds([
        end(10, 0, RoadClass.street),
        end(-10, 0, RoadClass.street),
        end(0, 10, RoadClass.street),
      ], anchorBF: anchor).single;
      expect(j.wholeBars, isTrue);
      final m = MeshBuilder();
      RoadMesher.junctions(m, MeshBuilder(), MeshBuilder(), [j], anchor, 0);
      final mesh = m.build();
      expect(mesh.vertexCount, 9 + 3 * 4);
      final up = anchor.normalized;
      for (var k = 0; k < 3; k++) {
        final side = j.legs[k].dir.cross(up).normalized;
        final lateral = [
          for (var v = 9 + 4 * k; v < 13 + 4 * k; v++)
            Vector3(mesh.positions[v * 3], mesh.positions[v * 3 + 1],
                        mesh.positions[v * 3 + 2])
                    .dot(side) /
                kRenderScale,
        ];
        final hw = j.legs[k].halfWidthM * 0.92;
        expect(lateral.reduce(math.min), closeTo(-hw, 1e-5));
        expect(lateral.reduce(math.max), closeTo(hw, 1e-5));
      }
    });
  });

  group('piers keep out of the roads beneath', () {
    // On the equator of a 6371 km world: local up is +x, the deck runs +z
    // from 0 to 300 m, a point every 10 m.
    final eq = Vector3(6371000, 0, 0);
    final pts = [for (var i = 0; i < 31; i++) Vector3(0, 0, i * 10.0)];
    // An avenue across it at 40 m, on the ground: body-fixed points.
    const avenueHw = 8.0;
    List<double> across(double z) => [
          for (final y in const [-100.0, 0.0, 100.0]) ...[eq.x, y, z],
        ];
    RoadCorridors corridors(List<double> pointsBF) =>
        RoadCorridors(eq)..add(1, pointsBF, avenueHw);
    PierBlocked blockedBy(RoadCorridors c) =>
        (foot, along, up, a, b) => c.blocks(foot, along, up, a, b, except: 0);

    /// The z of every vertex a pier stands on — a metre under the drape.
    List<double> feet(MeshBuilder m) {
      final mesh = m.build();
      return [
        for (var v = 0; v < mesh.vertexCount; v++)
          if (mesh.positions[v * 3] / kRenderScale < -0.5)
            mesh.positions[v * 3 + 2] / kRenderScale,
      ];
    }

    test('the distance from a pier to a road, in plan', () {
      // Across the pier's axis between its ends: touching.
      expect(RoadCorridors.axisDistance(0, -5, 0, 5, 3), 0);
      // Parallel to it, off to one side.
      expect(RoadCorridors.axisDistance(-10, 4, 10, 4, 3), closeTo(4, 1e-12));
      // Along its line: overlapping, and past its end.
      expect(RoadCorridors.axisDistance(-1, 0, 20, 0, 3), 0);
      expect(RoadCorridors.axisDistance(5, 0, 20, 0, 3), closeTo(2, 1e-12));
      // Crossing the line beyond the axis's end: to that end.
      expect(RoadCorridors.axisDistance(6, -1, 6, 1, 3), closeTo(3, 1e-12));
    });

    test('a structure moves its pier out of the avenue it crosses', () {
      final liftAt = RoadDeckMesher.liftAt(pts, List.filled(31, 10.0));
      final open = MeshBuilder();
      RoadDeckMesher.structure(open, pts, eq, 4, liftAt);
      // Left to itself a pier lands at 40 m, in the avenue's lanes.
      expect(feet(open).any((z) => (z - 40).abs() < avenueHw), isTrue);
      final kept = MeshBuilder();
      RoadDeckMesher.structure(kept, pts, eq, 4, liftAt,
          blocked: blockedBy(corridors(across(40))));
      final z = feet(kept);
      for (final f in z) {
        expect((f - 40).abs(), greaterThanOrEqualTo(avenueHw + 1.5),
            reason: 'a pier foot at $f m');
      }
      // Moved to the first point clear — 60 m — and the spans go on from
      // there: as many piers as before.
      expect(z.any((f) => (f - 60).abs() <= 1.2), isTrue);
      expect(kept.triangleCount, open.triangleCount);
      // Nothing else in the tile: the same structure to the byte.
      final alone = MeshBuilder();
      RoadDeckMesher.structure(alone, pts, eq, 4, liftAt,
          blocked: blockedBy(RoadCorridors(eq)));
      expect(alone.build().positions, open.build().positions);
    });

    test('a road the length of the deck beneath it still gets its piers', () {
      // No point along the deck is clear, so each pier stands a span past
      // where it fell due rather than never: 40, 120, 200 and 280 m.
      final under = [
        for (final z in const [-50.0, 150.0, 350.0]) ...[eq.x, 0.0, z],
      ];
      final m = MeshBuilder();
      RoadDeckMesher.structure(m, pts, eq, 4,
          RoadDeckMesher.liftAt(pts, List.filled(31, 10.0)),
          blocked: blockedBy(corridors(under)));
      expect(m.triangleCount ~/ 12, 120 + 4);
    });

    test("a generated bridge's piers keep out too", () {
      double lift(double s) => 12.0;
      final open = MeshBuilder();
      RoadMesher.piers(open, pts, eq, 6, lift);
      expect(feet(open).any((z) => (z - 40).abs() < avenueHw), isTrue);
      final kept = MeshBuilder();
      RoadMesher.piers(kept, pts, eq, 6, lift,
          blocked: blockedBy(corridors(across(40))));
      for (final f in feet(kept)) {
        expect((f - 40).abs(), greaterThanOrEqualTo(avenueHw + 1.5));
      }
      expect(kept.triangleCount, open.triangleCount);
    });

    test('in a tile: a raised street over an avenue', () {
      final res = meshWith([
        road(RoadClass.street, line(0, -200, 200, 21),
            lifts: List.filled(21, 8.0)),
        road(RoadClass.avenue, [(40, -100), (40, 0), (40, 100)]),
      ], CityTier.mid);
      final piers = [
        for (final p in verts(res, CityMaterialKind.facade))
          if (p.z < -0.5) p
      ];
      expect(piers, isNotEmpty);
      for (final p in piers) {
        expect((p.x - 40).abs(), greaterThanOrEqualTo(8.0 + 1.5),
            reason: 'a pier foot at $p');
      }
    });

    test("in a tile: a raised street over the next tile's avenue", () {
      // The avenue belongs to the tile its middle lies in, next door, and
      // reaches this one only as a corridor (see `CityTileBucketer`).
      final deck = road(RoadClass.street, line(0, -200, 200, 21),
          lifts: List.filled(21, 8.0));
      final avenue = road(RoadClass.avenue, [(40, -100), (40, 0), (40, 100)]);
      List<Vector3> piersOf(CityTileResult res) => [
            for (final p in verts(res, CityMaterialKind.facade))
              if (p.z < -0.5) p
          ];
      // Without it, a pier stands in its lanes.
      expect(
          piersOf(meshWith([deck], CityTier.mid))
              .any((p) => (p.x - 40).abs() < 8.0),
          isTrue);
      final piers = piersOf(meshWith([deck], CityTier.mid, corridors: [
        CityTileCorridor(avenue.points, avenue.halfWidthM),
      ]));
      expect(piers, isNotEmpty);
      for (final p in piers) {
        expect((p.x - 40).abs(), greaterThanOrEqualTo(8.0 + 1.5),
            reason: 'a pier foot at $p');
      }
    });
  });

  group('a junction up on a deck', () {
    final hw = RoadClass.street.width / 2;
    const up = 12.0;
    // Three streets raised 12 m, meeting at the origin: west and east the
    // through road, north the stem of the T.
    RoadSnapshot leg(List<(double, double)> xy) =>
        road(RoadClass.street, xy, lifts: List.filled(xy.length, up));
    final west = leg(line(0, 0, -200, 11));
    final east = leg(line(0, 0, 200, 11));
    final north = leg([for (var i = 0; i < 11; i++) (0.0, i * 20.0)]);

    /// Concrete standing above the deck: the parapets. The girders' tops
    /// are the deck's, and the piers stand under it.
    List<Vector3> aboveDeck(CityTileResult res) => [
          for (final p in verts(res, CityMaterialKind.facade))
            if (p.z > up + RoadMesher.ribbonLiftM + 0.2) p
        ];

    test("its parapets stand clear of the other legs' lanes", () {
      final res = meshWith([west, east, north], CityTier.mid, roadEnds: [
        for (var i = 0; i < 3; i++) ...[(hw, 3), null],
      ]);
      final walls = aboveDeck(res);
      expect(walls, isNotEmpty);
      for (final p in walls) {
        final inThrough = p.y.abs() < hw - 0.01;
        final inStem = p.x.abs() < hw - 0.01 && p.y > 0;
        expect(inThrough || inStem, isFalse, reason: 'a parapet at $p');
      }
      // Held back at the plate, and running on past it down every leg.
      expect(walls.any((p) => p.x < -20), isTrue);
      expect(walls.any((p) => p.x > 20), isTrue);
      expect(walls.any((p) => p.y > 20), isTrue);
    });

    test('a deck going on through a joint keeps its parapets', () {
      // Two ends meeting are one road going on: nothing to stop short of.
      final res = meshWith([west, east], CityTier.mid,
          roadEnds: [(hw, 2), null, (hw, 2), null]);
      expect(aboveDeck(res).any((p) => p.x.abs() < 1), isTrue);
    });

    /// The junction pass's entry for [leg]'s first end, the one at the
    /// origin, as the cut hands it to the tile the end lies in.
    CityTileEnd endOf(RoadSnapshot leg) => CityTileEnd(
        Vector3(leg.points[0], leg.points[1], leg.points[2]),
        Vector3(leg.points[3], leg.points[4], leg.points[5]),
        hw, RoadClass.street, true, false,
        isStart: true, liftM: up);

    test("an L's parapets stand clear of the other leg's lanes", () {
      // Two raised streets joined end to end at a corner — the second
      // snapped onto the first's free end. Only two ends meet and no plate
      // is drawn, but each leg's inside parapet ran on across the other's
      // lanes. The other end is found among the tile's roads, among its
      // junction ends, and — the other leg the next tile's — there alone.
      final cases = <(String, List<RoadSnapshot>, List<CityTileEnd>)>[
        ('both legs in the tile', [east, north], const []),
        ('and their ends', [east, north], [endOf(east), endOf(north)]),
        ('north the next tile\'s', [east], [endOf(east), endOf(north)]),
        ('east the next tile\'s', [north], [endOf(east), endOf(north)]),
      ];
      for (final (label, roads, ends) in cases) {
        final walls = aboveDeck(meshWith(roads, CityTier.mid,
            roadEnds: [for (final _ in roads) ...[(hw, 2), null]],
            ends: ends));
        expect(walls, isNotEmpty, reason: label);
        for (final p in walls) {
          final inEast = p.y.abs() < hw - 0.01 && p.x > 0;
          final inNorth = p.x.abs() < hw - 0.01 && p.y > 0;
          expect(inEast || inNorth, isFalse, reason: '$label: a parapet at $p');
        }
        // Held back at the corner, and running on past it down both legs.
        if (roads.contains(east)) {
          expect(walls.any((p) => p.x > 20), isTrue, reason: label);
        }
        if (roads.contains(north)) {
          expect(walls.any((p) => p.y > 20), isTrue, reason: label);
        }
      }
    });

    test('a deck bending gently through a joint keeps its parapets', () {
      // Ten degrees off straight on is still one road going on.
      final a = 10 * math.pi / 180;
      final on = leg([
        for (var i = 0; i < 11; i++)
          (i * 20.0 * math.cos(a), i * 20.0 * math.sin(a)),
      ]);
      for (final ends in [
        const <CityTileEnd>[],
        [endOf(west), endOf(on)],
      ]) {
        final res = meshWith([west, on], CityTier.mid,
            roadEnds: [(hw, 2), null, (hw, 2), null], ends: ends);
        expect(aboveDeck(res).any((p) => p.x.abs() < 1), isTrue);
      }
    });
  });

  group('one-way arrows', () {
    final eq = Vector3(6371000, 0, 0);
    final pts = [for (var i = 0; i < 21; i++) Vector3(0, 0, i * 10.0)];

    int arrowTris(RoadClass cls, {bool paint = true}) {
      final a = MeshBuilder(), b = MeshBuilder();
      RoadMesher.carriageway(a, pts, eq, cls, paint: paint);
      RoadMesher.carriageway(b, pts, eq, cls, paint: paint, arrows: true);
      return b.triangleCount - a.triangleCount;
    }

    test('an arrow a lane, about every fifty metres, on one-way roads only',
        () {
      // 200 m: four arrows a lane, three triangles each.
      expect(arrowTris(RoadClass.streetOneWay), 2 * 4 * 3);
      expect(arrowTris(RoadClass.motorway), 3 * 4 * 3);
      expect(arrowTris(RoadClass.ramp), 1 * 4 * 3);
      expect(arrowTris(RoadClass.street), 0);
      expect(arrowTris(RoadClass.avenue), 0);
      expect(arrowTris(RoadClass.streetOneWay, paint: false), 0);
    });

    test('they point first point to last, the way the traffic runs', () {
      final m = MeshBuilder();
      RoadMesher.carriageway(m, pts, eq, RoadClass.ramp, arrows: true);
      final mesh = m.build();
      // The last three vertices are the last arrow's head: base left,
      // base right, tip.
      final n = mesh.vertexCount;
      double z(int v) => mesh.positions[v * 3 + 2] / kRenderScale;
      expect(z(n - 1), greaterThan(z(n - 2)));
      expect(z(n - 1), greaterThan(z(n - 3)));
      expect(z(n - 1), closeTo(175 + 2.2, 1e-4));
    });

    test('in the tile, on a one-way street and not on a two-way one', () {
      final c = roadsOnly([road(RoadClass.streetOneWay, line(0, -200, 200, 21))]);
      final mid = tris(mesh(c, CityTier.mid), CityMaterialKind.road);
      final far = tris(mesh(c, CityTier.far), CityMaterialKind.road);
      // 400 m: the lane line (a strip of twenty quads) over the ribbon, and
      // eight arrows in each of two lanes.
      expect(mid - far, 20 * 2 + 2 * 8 * 3);
      final two = roadsOnly([road(RoadClass.street, line(0, -200, 200, 21))]);
      // A two-way street: the centre line and the two turning circles.
      expect(
          tris(mesh(two, CityTier.mid), CityMaterialKind.road) -
              tris(mesh(two, CityTier.far), CityMaterialKind.road),
          20 * 2 + 2 * 12);
    });
  });

  group('decorations', () {
    final xy = line(0, -200, 200, 21);
    bool grass(CityTileResult res) => res.groups
            .where((g) => g.material == CityMaterialKind.ground)
            .any((g) {
          for (var i = 0; i < g.vertexCount; i++) {
            if ((g.texCoords[i * 2] - CityTileMesher.grassU).abs() < 1e-6) {
              return true;
            }
          }
          return false;
        });

    test('a decorated street has grass verges; trees plant pits in them', () {
      final plain = meshWith([road(RoadClass.street, xy)], CityTier.near);
      final grassed = meshWith([
        road(RoadClass.street, xy, decoration: RoadDecoration.grass.index)
      ], CityTier.near);
      final treed = meshWith([
        road(RoadClass.street, xy, decoration: RoadDecoration.trees.index)
      ], CityTier.near);
      expect(grass(plain), isFalse);
      expect(grass(grassed), isTrue);
      expect(grass(treed), isTrue);
      // The verge lies between the kerb and the walk, a shade above it.
      for (final p in verts(grassed, CityMaterialKind.ground)) {
        expect(p.y.abs(),
            inInclusiveRange(4.11, 4.0 + 0.12 + CityTileMesher.vergeWidthM + 0.01));
        expect(p.z, greaterThan(CityTileMesher.walkTopLiftM));
      }
      // The trees stand in the middle of the verges, both sides, besides
      // whatever the pavement's own furniture planted.
      final mid = 4.0 + 0.12 + CityTileMesher.vergeWidthM / 2;
      final inVerge = [
        for (var i = 0; i < treed.treePits.length; i += 4)
          if ((treed.treePits[i + 1].abs() - mid).abs() < 1e-4) i
      ];
      expect(inVerge.length, greaterThanOrEqualTo(2 * 30));
      expect(treed.treePits.length, greaterThan(grassed.treePits.length));
      // Deterministic: the same street, the same trees.
      final again = meshWith([
        road(RoadClass.street, xy, decoration: RoadDecoration.trees.index)
      ], CityTier.near);
      expect(again.treePits, treed.treePits);
    });

    test('a decorated avenue grasses its planted median; trees line it', () {
      final grassed = meshWith([
        road(RoadClass.avenue, xy, decoration: RoadDecoration.grass.index)
      ], CityTier.mid);
      expect(grass(grassed), isTrue);
      for (final p in verts(grassed, CityMaterialKind.ground)) {
        expect(p.y.abs(), lessThan(1.0));
      }
      expect(grassed.treePits, isEmpty, reason: 'no pits at mid');
      final treed = meshWith([
        road(RoadClass.avenue, xy, decoration: RoadDecoration.trees.index)
      ], CityTier.near);
      final median = [
        for (var i = 0; i < treed.treePits.length; i += 4)
          if (treed.treePits[i + 1].abs() < 1e-4) i
      ];
      // Every 14 m down 400 m, clear of the ends.
      expect(median.length, greaterThanOrEqualTo(25));
      // An undecorated avenue has no median to plant, and a grassed one on
      // an airless world grows nothing.
      expect(grass(meshWith([road(RoadClass.avenue, xy)], CityTier.mid)),
          isFalse);
      expect(
          grass(meshWith([
            road(RoadClass.avenue, xy,
                decoration: RoadDecoration.trees.index, sealed: true)
          ], CityTier.near)),
          isFalse);
    });

    test('decoration takes the kerb, except on a four-lane road', () {
      expect(CityTileMesher.curbParks(RoadClass.street, RoadDecoration.none),
          isTrue);
      expect(CityTileMesher.curbParks(RoadClass.street, RoadDecoration.grass),
          isFalse);
      expect(
          CityTileMesher.curbParks(
              RoadClass.streetOneWay, RoadDecoration.trees),
          isFalse);
      expect(CityTileMesher.curbParks(RoadClass.avenue, RoadDecoration.trees),
          isTrue);
      expect(
          CityTileMesher.curbParks(RoadClass.boulevard, RoadDecoration.grass),
          isFalse);
      expect(CityTileMesher.curbParks(RoadClass.motorway, RoadDecoration.none),
          isFalse);
      // In the tile: the parking knob changes a plain street and a
      // decorated avenue, and not a decorated street.
      const noParking = CityMeshKnobs(
        styleId: 'masonry-street',
        bucketM: 6,
        variants: 4,
        perBuildingLod: true,
        blockRangeM: 300,
        interiorRangeM: 50,
        lodDebug: false,
        onStreetParking: false,
        sealedWorld: false,
        maxParkedCars: 400,
      );
      bool parks(RoadClass cls, RoadDecoration d) {
        final roads = [road(cls, xy, decoration: d.index)];
        return digest(meshWith(roads, CityTier.near)) !=
            digest(meshWith(roads, CityTier.near, k: noParking));
      }

      expect(parks(RoadClass.street, RoadDecoration.none), isTrue);
      expect(parks(RoadClass.street, RoadDecoration.grass), isFalse);
      expect(parks(RoadClass.avenue, RoadDecoration.trees), isTrue);
    });
  });

  group('traffic', () {
    const focus = Vector3(0, 0, r + 500);
    List<Vector3> cars(RoadSnapshot road) {
      final traffic = CityTraffic();
      traffic.begin('sig');
      traffic.visitTile('$body/0/0/0', 'k', body, [road], anchor);
      final sink = traffic.place(body, 321.0, focus, const {});
      traffic.end();
      final scene = lengthToScene(1.0);
      return [
        for (final b in sink.byKind.values)
          for (var i = 0; i < b.count; i++)
            Vector3(b.matrices[i].storage[12], b.matrices[i].storage[13],
                    b.matrices[i].storage[14]) *
                (1 / scene),
      ];
    }

    final xy = line(0, -400, 400, 41);

    test('vehicles ride the deck', () {
      final on = cars(road(RoadClass.avenue, xy, lifts: List.filled(41, 10)));
      expect(on, isNotEmpty);
      for (final p in on) {
        expect(p.z, closeTo(10, 0.1));
      }
    });

    test('and none is drawn in a tunnel', () {
      final lifts = [
        for (final (x, _) in xy)
          x.abs() >= 100
              ? 0.0
              : (x.abs() <= 60 ? -10.0 : -10 + (x.abs() - 60) / 4)
      ];
      final all = cars(road(RoadClass.avenue, xy));
      final some = cars(road(RoadClass.avenue, xy, lifts: lifts));
      expect(some.length, lessThan(all.length));
      for (final p in some) {
        expect(p.x.abs(), greaterThan(79.9), reason: '$p');
      }
    });

    test('the lanes are the dressed ones', () {
      final tile = TrafficTile.build('k', body, anchor, [
        road(RoadClass.avenue, xy, decoration: RoadDecoration.trees.index),
      ], density: 1);
      final dressed =
          RoadClass.avenue.lanesFor(RoadDecoration.trees)!.laneOffsets;
      expect(tile.roads.single.laneOffsetsM, dressed);
      expect(dressed, isNot(RoadClass.avenue.lanes!.laneOffsets));
    });

    // The railway's trains, which ran the drape whatever the track did: a
    // passenger working and a freight on a 1.2 km line, split in two at a
    // crossing with the second piece reversed, so the lifts are chained.
    final railXy = line(0, -600, 600, 61);
    List<RoadSnapshot> railway([List<double> lifts = const []]) {
      final a = railXy.sublist(0, 31), b = railXy.sublist(30).reversed;
      final la = lifts.isEmpty ? const <double>[] : lifts.sublist(0, 31);
      final lb = lifts.isEmpty
          ? const <double>[]
          : lifts.sublist(30).reversed.toList();
      return [
        road(RoadClass.rail, a, lifts: la),
        road(RoadClass.rail, b.toList(), lifts: lb),
      ];
    }

    List<Vector3> trainCars(List<RoadSnapshot> roads, double epoch) {
      final traffic = CityTraffic();
      traffic.begin('sig');
      traffic.visitTile('$body/0/0/0', 'k', body, roads, anchor);
      final sink = traffic.place(body, epoch, focus, const {});
      traffic.end();
      final scene = lengthToScene(1.0);
      return [
        for (final b in sink.railCars.values)
          for (var i = 0; i < b.count; i++)
            Vector3(b.matrices[i].storage[12], b.matrices[i].storage[13],
                    b.matrices[i].storage[14]) *
                (1 / scene),
      ];
    }

    const epochs = [0.0, 20.0, 45.0, 321.0];

    test('trains ride a raised railway on its deck', () {
      for (final epoch in epochs) {
        final on = trainCars(railway(List.filled(61, 12)), epoch);
        expect(on, isNotEmpty, reason: '@$epoch');
        for (final p in on) {
          expect(p.z, closeTo(12 + RailVehicleMeshes.railHeadM, 0.05),
              reason: '$p @$epoch');
        }
      }
    });

    test('and none runs over the hill its tunnel goes through', () {
      // Wholly underground: the track is dropped, and so is every train.
      for (final epoch in epochs) {
        expect(trainCars(railway(), epoch), isNotEmpty, reason: '@$epoch');
        expect(trainCars(railway(List.filled(61, -20)), epoch), isEmpty,
            reason: '@$epoch');
      }
      // Under the middle: 20 m down within 400 m of it, out by 500, so the
      // mouths — where the deck is at the cover depth — stand at 475 m.
      final lifts = [
        for (final (x, _) in railXy)
          x.abs() >= 500
              ? 0.0
              : (x.abs() <= 400 ? -20.0 : -20 + (x.abs() - 400) / 5)
      ];
      var seen = 0;
      for (var epoch = 0.0; epoch < 120; epoch += 5) {
        for (final p in trainCars(railway(lifts), epoch)) {
          seen++;
          expect(p.x.abs(), greaterThan(474.9), reason: '$p @$epoch');
          expect(p.z, greaterThan(-RoadElevation.tunnelCoverM), reason: '$p');
        }
      }
      expect(seen, greaterThan(0));
    });

    test('a railway on the ground runs exactly where it always ran', () {
      for (final epoch in epochs) {
        final ground = trainCars(railway(), epoch);
        expect(ground, isNotEmpty);
        for (final p in ground) {
          expect(p.z, closeTo(RailVehicleMeshes.railHeadM, 0.05), reason: '$p');
        }
        // A deck that never leaves the drape is the same train, to the bit.
        final level = trainCars(railway(List.filled(61, 0)), epoch);
        expect(level.length, ground.length);
        for (var i = 0; i < ground.length; i++) {
          expect(level[i].x, ground[i].x);
          expect(level[i].y, ground[i].y);
          expect(level[i].z, ground[i].z);
        }
      }
    });
  });
}
