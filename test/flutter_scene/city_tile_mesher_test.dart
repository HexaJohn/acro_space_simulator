// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_scheduler.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/mesh_merge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tile meshing is a pure function of its request: the same tile
/// meshes to the same bytes and the same archetype keys wherever it runs,
/// which is what lets it run on a worker at all — and what the UI thread,
/// meshing the instanced archetypes itself, relies on.
void main() {
  const r = 1.7374e6;
  const body = 'moon';
  // A flat little town on the pole: local +Z is radial up at (0, 0, r),
  // so an identity orientation is the surface basis.
  const anchor = Vector3(0, 0, r);

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

  RoadSnapshot road(RoadClass cls, List<(double, double)> xy,
          {bool sealed = false}) =>
      RoadSnapshot(
        colonyId: 'c',
        body: body,
        points: [for (final (x, y) in xy) ...[x, y, r]],
        halfWidthM: cls.width / 2,
        roadClassIndex: cls.index,
        sealed: sealed,
      );

  List<(double, double)> line(double y, double x0, double x1, int n) => [
        for (var i = 0; i < n; i++) (x0 + (x1 - x0) * i / (n - 1), y),
      ];

  final buildings = <BuildingSnapshot>[
    for (var i = 0; i < 6; i++)
      bldg('r$i', 'r-med', -120 + i * 40.0, 60, w: 18 + (i % 3) * 6),
    for (var i = 0; i < 4; i++)
      bldg('c$i', 'c-high', -90 + i * 60.0, -80, w: 40, d: 36,
          corner: i == 0),
    bldg('i0', 'i-low', 200, 200, w: 60, d: 40),
  ];
  final roads = <RoadSnapshot>[
    road(RoadClass.street, line(0, -200, 200, 9)),
    road(RoadClass.street, [(-200, 0), (-200, 150)]),
    road(RoadClass.street, [(200, 0), (200, 150)]),
    // A dead end: the cul-de-sac pass.
    road(RoadClass.street, [(0, 0), (0, -150)]),
  ];
  final patches = CityPatchColumns.of([
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
  ]);
  // The three crossings and the dead end, as the UI thread cuts them.
  CityTileEnd end(double x, double y, double nx, double ny) => CityTileEnd(
      Vector3(x, y, r), Vector3(nx, ny, r), RoadClass.street.width / 2,
      RoadClass.street, RoadClass.street.paved, false);
  final ends = <CityTileEnd>[
    end(-200, 0, -150, 0),
    end(-200, 0, -200, 40),
    end(200, 0, 150, 0),
    end(200, 0, 200, 40),
    end(0, 0, -50, 0),
    end(0, 0, 50, 0),
    end(0, 0, 0, -50),
  ];
  // Two ends meet at each cross street, one at the dead end.
  final roadEnds = <(double, int)?>[
    (RoadClass.street.width / 2, 2), (RoadClass.street.width / 2, 2),
    (RoadClass.street.width / 2, 2), null,
    (RoadClass.street.width / 2, 2), null,
    (RoadClass.street.width / 2, 3), null,
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

  // The members packed the way `CityNodes` packs them, once; and packed a
  // second time through a round trip, the way a worker sees them, for the
  // test that the two mesh the same.
  final columns = CityTileColumns.fromSnapshots(
    buildings: buildings,
    roads: roads,
    patches: patches,
    ends: ends,
    roadEnds: roadEnds,
    transitEnds: const [],
  );

  CityTileRequest request(CityTier tier,
          {Vector3 focus = const Vector3(0, 0, r + 40),
          bool canDetail = true,
          CityMeshKnobs k = knobs,
          CityTileColumns? members}) =>
      CityTileRequest(
        tileKey: '$body/0/0',
        key: 'k-${tier.name}',
        tier: tier,
        canDetail: canDetail && tier == CityTier.near,
        anchorBF: anchor,
        columns: members ?? columns,
        focusBF: focus,
        colonyTier: BuildingDetail.full,
        epoch: 1234.5,
        knobs: k,
      );

  /// Every stream of every group consistent with itself: as many normals
  /// and texture coordinates as positions, every index a vertex.
  void expectWellFormed(CityTileResult result) {
    for (final g in result.groups) {
      expect(g.positions.length % 3, 0);
      expect(g.normals.length, g.positions.length);
      expect(g.texCoords.length, g.vertexCount * 2);
      expect(g.indices.length % 3, 0);
      expect(g.indices.isNotEmpty, isTrue, reason: 'empty ${g.material}');
      for (final i in g.indices) {
        expect(i, lessThan(g.vertexCount));
      }
    }
    for (final i in result.instances) {
      expect(i.transforms.length % 16, 0);
      expect(i.count, greaterThan(0));
    }
    expect(result.treePits.length % 4, 0);
    expect(result.shrubPits.length % 4, 0);
  }

  Map<(CityMaterialKind, bool), CityMeshGroup> byMaterial(
          CityTileResult result) =>
      {for (final g in result.groups) (g.material, g.castsShadow): g};

  group('a synthetic tile at each tier', () {
    final libraries = CityBuildingLibraries();

    test('far: ribbons, ground, and the skyline baked, nothing instanced',
        () {
      final result = CityTileMesher.mesh(request(CityTier.far), libraries);
      expectWellFormed(result);
      final m = byMaterial(result);
      expect(m.containsKey((CityMaterialKind.road, false)), isTrue);
      expect(m.containsKey((CityMaterialKind.ground, false)), isTrue);
      // Every building is a block silhouette in the facade sink; none is
      // an instance, and nothing casts at this tier.
      expect(m.containsKey((CityMaterialKind.facade, false)), isTrue);
      expect(result.instances, isEmpty);
      expect(result.skylineTris, greaterThan(0));
      expect(result.lodCounts[BuildingDetail.block], buildings.length);
      expect(result.groups.every((g) => !g.castsShadow), isTrue);
      // The silhouettes are massing boxes, and the count is honest: the
      // facade group at far is the skyline and nothing else.
      expect(result.skylineTris,
          m[(CityMaterialKind.facade, false)]!.triangleCount);
      expect(m.containsKey((CityMaterialKind.glazing, false)), isFalse);
      // No furniture at far: no pavement, no lamps, no planting.
      expect(m.containsKey((CityMaterialKind.sidewalk, false)), isFalse);
      expect(result.treePits, isEmpty);
    });

    test('mid: lanes painted, junction plates, still silhouettes', () {
      final far = CityTileMesher.mesh(request(CityTier.far), libraries);
      final mid = CityTileMesher.mesh(request(CityTier.mid), libraries);
      expectWellFormed(mid);
      // The plates and the cul-de-sac are triangles the far tier lacks.
      expect(byMaterial(mid)[(CityMaterialKind.road, false)]!.triangleCount,
          greaterThan(
              byMaterial(far)[(CityMaterialKind.road, false)]!.triangleCount));
      expect(mid.instances, isEmpty);
      expect(mid.lodCounts[BuildingDetail.block], buildings.length);
    });

    test('near: the street dressed, buildings instanced by archetype', () {
      final near = CityTileMesher.mesh(request(CityTier.near), libraries);
      expectWellFormed(near);
      final m = byMaterial(near);
      // Pavements, lamps (facade + glazing), curbs: the near tier's own.
      expect(m.containsKey((CityMaterialKind.sidewalk, false)), isTrue);
      expect(m.containsKey((CityMaterialKind.facade, true)), isTrue);
      expect(m.containsKey((CityMaterialKind.glazing, false)), isTrue);
      // Facades cast at near; flat materials do not.
      expect(m[(CityMaterialKind.road, false)], isNotNull);
      expect(m.containsKey((CityMaterialKind.road, true)), isFalse);
      // With the camera forty metres over the crossing every building is
      // within block range: all instanced, none in the skyline.
      expect(near.skylineTris, 0);
      expect(near.lodCounts[BuildingDetail.block] ?? 0, 0);
      final instanced =
          near.instances.fold(0, (n, g) => n + g.count);
      expect(instanced, buildings.length);
      // Fewer archetypes than buildings: the bucketing shares meshes.
      expect(near.instances.length, lessThan(buildings.length));
      expect(near.treePits.length, greaterThan(0));
    });

    test('near from afar: everything a block, nothing to instance', () {
      final near = CityTileMesher.mesh(
          request(CityTier.near, focus: const Vector3(5000, 0, r + 40),
              canDetail: false),
          libraries);
      expect(near.instances, isEmpty);
      expect(near.lodCounts[BuildingDetail.block], buildings.length);
      expect(near.skylineTris, greaterThan(0));
    });
  });

  group('the block tier is massing boxes at every tier; mid and near keep the glazing',
      () {
    // The fixture's buildings all carry a site, and a sited building's
    // coarse model is its volumes as plain shapes with no glazing. Three
    // parcel-fitted ones (no site on the wire) take the other block path —
    // one box and a window band per storey — so the tile has glazing to
    // lose at far and keep at mid and near.
    final mixed = <BuildingSnapshot>[
      ...buildings,
      bldg('p0', 'r-med', 0, 120, w: 0, d: 0),
      bldg('p1', 'c-high', 0, 160, w: 0, d: 0),
      bldg('p2', 'i-low', 0, 200, w: 0, d: 0),
    ];
    final mixedColumns = CityTileColumns.fromSnapshots(
      buildings: mixed,
      roads: roads,
      patches: patches,
      ends: ends,
      roadEnds: roadEnds,
      transitEnds: const [],
    );

    /// The block-tier skyline as the mid and near tiers bake it: every
    /// building's massing boxes, and the coarse model's glazing, through
    /// its instance transform, in tile order.
    (PropMesh, PropMesh) blockSkyline(CityBuildingLibraries libraries) {
      libraries.syncKnobs(knobs);
      final lib = libraries.forTier(BuildingDetail.block);
      final boxes = MergedMeshSink(), glazing = MergedMeshSink();
      for (final b in mixed) {
        final built = lib.get(CityTileMesher.specOf(b),
            CityTileMesher.parcelOf(b, knobs.style),
            seed: b.id.hashCode, detail: BuildingDetail.block);
        final m = CityTileMesher.instanceTransform(anchor, b);
        boxes.append(CityTileMesher.massingBoxes(built.massing), m);
        glazing.append(built.model.foliage, m);
      }
      return (boxes.build(), glazing.build());
    }

    /// The per-building bound on a skyline mesh at the block tier: a
    /// dozen triangles a volume, four volumes at most, against the two
    /// hundred the coarse model spent per building.
    const trisPerBlockBuilding = 60;

    void expectSameMesh(CityMeshGroup g, PropMesh mesh) {
      expect(g.positions, mesh.positions);
      expect(g.normals, mesh.normals);
      expect(g.texCoords, mesh.texCoords);
      expect(g.indices, mesh.indices);
    }

    test('far: a box per volume, on the facade, no glazing, 40 tris a building',
        () {
      final libraries = CityBuildingLibraries();
      final far = CityTileMesher.mesh(
          request(CityTier.far, members: mixedColumns), libraries);
      expectWellFormed(far);
      final m = byMaterial(far);
      expect(m.containsKey((CityMaterialKind.glazing, false)), isFalse,
          reason: 'a window band is sub-pixel from where a tile is far');
      final facade = m[(CityMaterialKind.facade, false)]!;
      expect(facade.triangleCount, lessThanOrEqualTo(40 * mixed.length));
      expect(far.skylineTris, facade.triangleCount);
      expect(far.lodCounts[BuildingDetail.block], mixed.length);
      // Exactly the massing boxes, twelve triangles a volume, placed by the
      // same transform the coarse model takes.
      final lib = libraries.forTier(BuildingDetail.block);
      final expected = MergedMeshSink();
      var volumes = 0;
      for (final b in mixed) {
        final built = lib.get(CityTileMesher.specOf(b),
            CityTileMesher.parcelOf(b, knobs.style),
            seed: b.id.hashCode, detail: BuildingDetail.block);
        volumes += built.massing.volumes.length;
        expected.append(CityTileMesher.massingBoxes(built.massing),
            CityTileMesher.instanceTransform(anchor, b));
      }
      expect(facade.triangleCount, 12 * volumes);
      expectSameMesh(facade, expected.build());
      // Well under the byte cap: one group, one draw, for the whole tile.
      expect(far.groups.where((g) => g.material == CityMaterialKind.facade),
          hasLength(1));
    });

    test('mid: the same boxes as far, and the coarse glazing kept', () {
      final mid = CityTileMesher.mesh(
          request(CityTier.mid, members: mixedColumns),
          CityBuildingLibraries());
      final far = CityTileMesher.mesh(
          request(CityTier.far, members: mixedColumns),
          CityBuildingLibraries());
      final m = byMaterial(mid);
      final facade = m[(CityMaterialKind.facade, false)]!;
      final glazing = m[(CityMaterialKind.glazing, false)];
      expect(glazing, isNotNull);
      expect(glazing!.triangleCount, greaterThan(0));
      // The facade is the far tile's, byte for byte: boxes, and no
      // more triangles a building than four volumes make.
      final farFacade = byMaterial(far)[(CityMaterialKind.facade, false)]!;
      expect(facade.positions, farFacade.positions);
      expect(facade.normals, farFacade.normals);
      expect(facade.texCoords, farFacade.texCoords);
      expect(facade.indices, farFacade.indices);
      expect(facade.triangleCount,
          lessThanOrEqualTo(trisPerBlockBuilding * mixed.length));
      // And the glazing is the coarse model's, so the night windows stay.
      final (boxes, foliage) = blockSkyline(CityBuildingLibraries());
      expectSameMesh(facade, boxes);
      expectSameMesh(glazing, foliage);
      expect(mid.skylineTris, boxes.triangleCount + foliage.triangleCount);
      // The sited buildings' coarse model has no window bands, so their
      // skyline is the boxes alone; the parcel-fitted three carry a band a
      // storey, and a tower's band is more triangles than its boxes (see
      // the test below) — which is why the bound is on the facade, and
      // the glazing is only asked to be what the coarse model made.
      final lib = (CityBuildingLibraries()..syncKnobs(knobs))
          .forTier(BuildingDetail.block);
      for (final b in mixed.take(buildings.length)) {
        final built = lib.get(
            CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, knobs.style),
            seed: b.id.hashCode, detail: BuildingDetail.block);
        expect(built.model.foliage.triangleCount, 0, reason: b.id);
      }
    });

    test('the coarse glazing is a window band a storey, heavy on a tower',
        () {
      // Measured, not capped: what the mid and near skylines spend on
      // glazing per parcel-fitted building, for the record the slice that
      // boxed the block tier was asked to keep. A c-high tower's band is
      // 280 triangles, five times its boxes; the cap on a building's
      // facade says nothing about it.
      final lib = (CityBuildingLibraries()..syncKnobs(knobs))
          .forTier(BuildingDetail.block);
      final glazing = <String, int>{};
      for (final b in mixed.skip(buildings.length)) {
        final built = lib.get(
            CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, knobs.style),
            seed: b.id.hashCode, detail: BuildingDetail.block);
        glazing[b.type] = built.model.foliage.triangleCount;
        expect(12 * built.massing.volumes.length,
            lessThanOrEqualTo(trisPerBlockBuilding));
      }
      expect(glazing, {'r-med': 88, 'c-high': 280, 'i-low': 8});
    });

    test('near from afar: boxes and the glazing, like mid', () {
      // A near tile whose buildings are all beyond block range bakes the
      // same skyline the mid tier does.
      final near = CityTileMesher.mesh(
          request(CityTier.near,
              focus: const Vector3(5000, 0, r + 40),
              canDetail: false,
              members: mixedColumns),
          CityBuildingLibraries());
      expect(near.instances, isEmpty);
      final m = byMaterial(near);
      final (boxes, foliage) = blockSkyline(CityBuildingLibraries());
      // The skyline is appended before the street's builders: the facade
      // group begins with it.
      final facade = m[(CityMaterialKind.facade, true)]!;
      expect(facade.triangleCount, greaterThanOrEqualTo(boxes.triangleCount));
      expect(boxes.triangleCount,
          lessThanOrEqualTo(trisPerBlockBuilding * mixed.length));
      expect(facade.positions.sublist(0, boxes.positions.length),
          boxes.positions);
      expect(facade.indices.sublist(0, boxes.indices.length), boxes.indices);
      final glazing = m[(CityMaterialKind.glazing, false)]!;
      expect(glazing.positions.sublist(0, foliage.positions.length),
          foliage.positions);
      expect(glazing.indices.sublist(0, foliage.indices.length),
          foliage.indices);
    });

    test('the boxes are cached per coarse archetype, dropped on rebuild',
        () {
      final libraries = CityBuildingLibraries()..syncKnobs(knobs);
      final b = mixed.first;
      final built = libraries.forTier(BuildingDetail.block).get(
          CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, knobs.style),
          seed: b.id.hashCode, detail: BuildingDetail.block);
      final boxes = libraries.massingBoxesOf(built);
      expect(identical(libraries.massingBoxesOf(built), boxes), isTrue);
      expect(boxes.triangleCount, 12 * built.massing.volumes.length);
      // Other knobs: a new coarse library, and the boxes keyed by the old
      // one's objects go with it.
      expect(libraries.sync(knobs.styleId, knobs.bucketM * 2, knobs.variants),
          isTrue);
      expect(identical(libraries.massingBoxesOf(built), boxes), isFalse);
    });
  });

  group('the exterior and full tiers are what they were', () {
    // The block tier's change of model must not reach the tiers that
    // instance: a digest of the near tile — its groups, the street's
    // furniture, and its instance keys and transforms — pinned from before
    // the block tier was boxed at every tier. `Object.hash` is salted per
    // run, so the archetype goes in as its fields.
    //
    // The fixture's one junction is a street T of the generator's roads,
    // so the road tool's junction plan leaves it on the class-only warrant
    // with whole-width bars (see `RoadMesher.byClass`): these digests are
    // also the guard that a town the tool never touched keeps its
    // junctions to the byte.
    int fnv(int h, int v) => ((h ^ (v & 0xFFFFFFFF)) * 0x01000193) & 0xFFFFFFFF;
    int digest(CityTileResult res) {
      var h = 0x811C9DC5;
      void words(TypedData d) {
        for (final v in d.buffer.asUint32List(d.offsetInBytes, d.lengthInBytes ~/ 4)) {
          h = fnv(h, v);
        }
      }

      for (final g in res.groups) {
        h = fnv(h, g.material.index);
        h = fnv(h, g.castsShadow ? 1 : 0);
        words(g.positions);
        words(g.normals);
        words(g.texCoords);
        words(g.indices);
      }
      for (final i in res.instances) {
        final a = i.archetype;
        for (final c in '${a.type}|${a.widthBucket}|${a.depthBucket}|'
                '${a.detail.index}|${a.variant}|${a.styleId}|${a.corner}'
            .codeUnits) {
          h = fnv(h, c);
        }
        words(i.transforms);
      }
      return h;
    }

    test('exterior: every building instanced, the tile to the byte', () {
      final near = CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries());
      expect(near.lodCounts, {BuildingDetail.exterior: buildings.length});
      expect(near.groups, hasLength(5));
      expect(near.instances, hasLength(9));
      expect(digest(near), 0x8b0c9fe1);
    });

    test('with the detail layer off the tile is the same to the byte', () {
      // The layer's switch is a request field; off, nothing of the
      // layer's reaches the tile (see `CityTileRequest.detailLayer`).
      final r = request(CityTier.near);
      final off = CityTileMesher.mesh(
          CityTileRequest(
            tileKey: r.tileKey,
            key: r.key,
            tier: r.tier,
            canDetail: r.canDetail,
            anchorBF: r.anchorBF,
            columns: r.columns,
            focusBF: r.focusBF,
            colonyTier: r.colonyTier,
            epoch: r.epoch,
            knobs: r.knobs,
            detailLayer: false,
          ),
          CityBuildingLibraries());
      expect(digest(off), 0x8b0c9fe1);
      expect(off.archetypeMeshes, isEmpty);
    });

    test('full: the camera in the street, the tile to the byte', () {
      // One of this tile's groups is over a megabyte: at the cap of the
      // day the digest was taken it arrived in two chunks, at today's cap
      // of two it is one. Pinned at the old cap, so the digest is of the
      // geometry and not of where it was cut; then at the default, the
      // same triangles per material in one group fewer.
      CityTileResult mesh() => CityTileMesher.mesh(
          request(CityTier.near, focus: const Vector3(0, 60, r + 5)),
          CityBuildingLibraries());
      final was = CityTileMesher.maxGroupBytes;
      CityTileMesher.maxGroupBytes = 1024 * 1024;
      final CityTileResult cut;
      try {
        cut = mesh();
      } finally {
        CityTileMesher.maxGroupBytes = was;
      }
      expect(cut.lodCounts, {BuildingDetail.full: 3, BuildingDetail.exterior: 8});
      expect(cut.groups, hasLength(7));
      expect(cut.instances, hasLength(11));
      expect(digest(cut), 0xe7497c94);

      final whole = mesh();
      expect(whole.groups, hasLength(6));
      expect(whole.instances.map((g) => g.archetype).toList(),
          cut.instances.map((g) => g.archetype).toList());
      for (var i = 0; i < cut.instances.length; i++) {
        expect(whole.instances[i].transforms, cut.instances[i].transforms);
      }
      int tris(CityTileResult res, (CityMaterialKind, bool) key) => res.groups
          .where((g) => (g.material, g.castsShadow) == key)
          .fold(0, (n, g) => n + g.triangleCount);
      for (final key in byMaterial(cut).keys) {
        expect(tris(whole, key), tris(cut, key), reason: '$key');
      }
    });

    test('mid and far: the tile to the byte', () {
      expect(digest(CityTileMesher.mesh(request(CityTier.mid), CityBuildingLibraries())),
          0xffd81c34);
      expect(digest(CityTileMesher.mesh(request(CityTier.far), CityBuildingLibraries())),
          0xb51e60e0);
    });

    test('site access on the wire leaves every tier to the byte with the '
        'knob OFF (docs/plans/site-access.md §9 R3, §9 R4)', () {
      // Every building served with a gate, every road with kerb cuts: the
      // wire fields R3 adds, carried by the columns. With the knob OFF
      // nothing draws them, at any tier — R3's statement, and the one R4
      // keeps. With it ON, R4 draws the plan: track B's massing reads the
      // envelope at every tier, and track A's kerb cuts lay the dropped
      // kerbs on the near tier's kerbside (the fixture carries no
      // `CitySiteFrame`, so the site mesher itself draws nothing here).
      // Every tier therefore moves, and each is pinned below.

      final served = CityTileColumns.fromSnapshots(
        buildings: [
          for (final (i, b) in buildings.indexed)
            BuildingSnapshot(
              id: b.id,
              type: b.type,
              colonyId: b.colonyId,
              body: b.body,
              px: b.px,
              py: b.py,
              pz: b.pz,
              qw: b.qw,
              qx: b.qx,
              qy: b.qy,
              qz: b.qz,
              lat: b.lat,
              lon: b.lon,
              siteWidthM: b.siteWidthM,
              siteDepthM: b.siteDepthM,
              siteKindIndex: b.siteKindIndex,
              colorArgb: b.colorArgb,
              corner: b.corner,
              siteSlot: 1024 + i,
              gateXM: i * 1.5,
              gateWM: 8,
            ),
        ],
        roads: [
          for (final x in roads)
            RoadSnapshot(
              colonyId: x.colonyId,
              body: x.body,
              points: x.points,
              halfWidthM: x.halfWidthM,
              roadClassIndex: x.roadClassIndex,
              sealed: x.sealed,
              kerbCuts: const [1, 20, 4, 1, 1, 0, 20, 4, -1, 2, 0, 60, 3.5, -1, 0],
            ),
        ],
        patches: patches,
        ends: ends,
        roadEnds: roadEnds,
        transitEnds: const [],
      );
      expect(served.toSnapshots().buildings.first.siteSlot, 1024);
      const on = CityMeshKnobs(
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
        siteAccess: true,
      );
      expect(knobs.keyTerms.contains('siteAccess'), isFalse);
      expect(on.keyTerms, '${knobs.keyTerms}|siteAccess');
      int at(CityMeshKnobs k, CityTier tier) => digest(CityTileMesher.mesh(
          request(tier, members: served, k: k), CityBuildingLibraries()));
      expect(at(knobs, CityTier.near), 0x8b0c9fe1, reason: knobs.keyTerms);
      expect(at(knobs, CityTier.mid), 0xffd81c34, reason: knobs.keyTerms);
      expect(at(knobs, CityTier.far), 0xb51e60e0, reason: knobs.keyTerms);
      // R4, the knob on: the served buildings are drawn from their plans —
      // no car park of their own, front-aligned on the envelope, the gate
      // lane cut open — and the near tier's kerbside lays the dropped kerbs
      // and stands the masked kerb cars down. So every tier moves; the off
      // values above never move.
      for (final tier in CityTier.values) {
        expect(at(on, tier), isNot(at(knobs, tier)), reason: tier.name);
      }
      expect(at(on, CityTier.near), 0x6a1f715e, reason: on.keyTerms);
      expect(at(on, CityTier.mid), 0xcf757f38, reason: on.keyTerms);
      expect(at(on, CityTier.far), 0xbf7c5994, reason: on.keyTerms);
    });

    test('a join road with NO PAVEMENT lays no dropped kerb: an alley draws '
        'the same tile with its cut and without it (§3.8, R8) — a '
        'CHARACTERIZATION pin of behaviour on dev', () {
      // CHARACTERIZATION PIN, not coverage of a change: no line of R8 touches
      // the mesher's kerb-cut path, and this case passes unchanged on dev. It is
      // here because R8 is the first slice to put a cut on a road without a
      // pavement, and the assumption it rests on had never been written down.
      //
      // §3.8's row: "kerb = carriageway edge; no kerb-cut mesh; throat still
      // ≥ 7 m". An R8 alley join's cut is REAL on the wire — the agents' kerb
      // masks and a lamp's shift-out read the same table (§5.5, A12) — but
      // nothing on a road without a pavement draws it: the dropped kerb is
      // laid by the sidewalk, and `walked` is `paved && cls.hasPavement &&
      // !road.sealed`. The verge, the lamps, the props and the kerb cars are
      // gated on the same class bit. The SAME cut on a street moves the tile,
      // which is what says this case is not vacuous. That the entry EXISTS on
      // the alley and nowhere else is `alley_car_park_test`'s half of this
      // (over `KerbCuts.canonicalOf` on a real F2a plan); this half is what
      // the entry then draws.
      expect(RoadClass.alley.hasPavement, isFalse);
      expect(RoadClass.street.hasPavement, isTrue);
      // One canonical entry in the drawn frame: side 1, arc 100 (mid-road),
      // an F2a cut half (a 6 m throat and the 1 m flare), σ +1 on the
      // right-hand kerb of a two-way road, `KerbCuts.kindDropped`.
      const cut = <double>[1, 100, 4, 1, 0];
      RoadSnapshot withCuts(RoadSnapshot x) => RoadSnapshot(
            colonyId: x.colonyId,
            body: x.body,
            points: x.points,
            halfWidthM: x.halfWidthM,
            roadClassIndex: x.roadClassIndex,
            sealed: x.sealed,
            kerbCuts: cut,
          );
      CityTileColumns only(RoadSnapshot x) => CityTileColumns.fromSnapshots(
            buildings: const [],
            roads: [x],
            patches: CityPatchColumns.of(const []),
            ends: const <CityTileEnd>[],
            roadEnds: const [null, null],
            transitEnds: const [],
          );
      const siteAccessOn = CityMeshKnobs(
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
        siteAccess: true,
      );
      CityTileResult meshOf(RoadSnapshot x) => CityTileMesher.mesh(
          request(CityTier.near, members: only(x), k: siteAccessOn),
          CityBuildingLibraries());
      final alley = road(RoadClass.alley, line(0, -100, 100, 11));
      final street = road(RoadClass.street, line(0, -100, 100, 11));
      // The alley IS drawn — a carriageway of its own — so "identical" below
      // is two real tiles and not two empty ones.
      expect(
          meshOf(alley).groups.fold<int>(0, (n, g) => n + g.triangleCount),
          greaterThan(0));
      expect(digest(meshOf(withCuts(alley))), digest(meshOf(alley)));
      expect(digest(meshOf(withCuts(street))), isNot(digest(meshOf(street))));
    });

    test('through one scratch, job after job, every tier to the byte', () {
      // The ground and lot builders live in the scratch beside the road
      // builders, and the road pass fills one point list for every road:
      // a tile meshed into buffers another tile grew must be the tile a
      // fresh set makes, at every tier, in whatever order the tiles come.
      final scratch = CityMeshScratch();
      final libraries = CityBuildingLibraries();
      int at(CityTier tier) => digest(
          CityTileMesher.mesh(request(tier), libraries, scratch: scratch)
              .detached());
      expect(at(CityTier.near), 0x8b0c9fe1);
      expect(at(CityTier.far), 0xb51e60e0);
      expect(at(CityTier.mid), 0xffd81c34);
      expect(at(CityTier.near), 0x8b0c9fe1);
      expect(at(CityTier.far), 0xb51e60e0);
    });
  });

  group('massingBoxes', () {
    const style = ArchitectureStyle.utilitarian;

    BuildingMassing massing(List<MassBox> volumes, {int material = 3}) =>
        BuildingMassing(
          volumes: volumes,
          storeyM: 3.5,
          floorArea: 100,
          entrance: (0, 0),
          style: style,
          material: material,
        );

    /// The extent of [mesh] along each axis.
    (Vector3, Vector3) bounds(PropMesh mesh) {
      var lo = Vector3(double.infinity, double.infinity, double.infinity);
      var hi = lo * -1;
      for (var i = 0; i < mesh.vertexCount; i++) {
        final p = Vector3(mesh.positions[i * 3], mesh.positions[i * 3 + 1],
            mesh.positions[i * 3 + 2]);
        lo = Vector3(math.min(lo.x, p.x), math.min(lo.y, p.y),
            math.min(lo.z, p.z));
        hi = Vector3(math.max(hi.x, p.x), math.max(hi.y, p.y),
            math.max(hi.z, p.z));
      }
      return (lo, hi);
    }

    test('one box per volume, in metres, standing where the volume does', () {
      final mesh = CityTileMesher.massingBoxes(massing(const [
        MassBox(x: 0, y: 5, z: 0, width: 30, depth: 20, height: 12, floors: 3),
        MassBox(x: 2, y: 5, z: 12, width: 16, depth: 10, height: 40, floors: 10),
      ]));
      expect(mesh.triangleCount, 24);
      expect(mesh.vertexCount, 48);
      final (lo, hi) = bounds(mesh);
      // Metres, not scene units: the instance transform scales.
      expect(lo.x, closeTo(-15, 1e-6));
      expect(hi.x, closeTo(15, 1e-6));
      expect(lo.y, closeTo(-5, 1e-6));
      expect(hi.y, closeTo(15, 1e-6));
      expect(lo.z, closeTo(0, 1e-6));
      expect(hi.z, closeTo(52, 1e-6));
    });

    test('every vertex samples the middle of the volume\'s facade band', () {
      final mesh = CityTileMesher.massingBoxes(massing(const [
        MassBox(x: 0, y: 0, z: 0, width: 10, depth: 10, height: 10),
        MassBox(
            x: 0, y: 0, z: 10, width: 4, depth: 4, height: 3, material: 7),
      ], material: 3));
      final (a0, a1) = BuildingGenerator.bandUV(3);
      final (b0, b1) = BuildingGenerator.bandUV(7);
      for (var i = 0; i < mesh.vertexCount; i++) {
        final u = mesh.texCoords[i * 2], v = mesh.texCoords[i * 2 + 1];
        // The first box's 24 vertices, then the plant room's.
        expect(u, closeTo(i < 24 ? (a0 + a1) / 2 : (b0 + b1) / 2, 1e-6));
        expect(v, 0.5);
      }
    });

    test('a plate runs its width across its bearing; a box along its yaw',
        () {
      // A heliostat facing +X (yaw 0) is a plate whose width runs along +Y
      // — the way the massing rules fit one to its parcel — where a yawed
      // box (a vehicle) runs its width along the bearing itself.
      final plate = CityTileMesher.massingBoxes(massing(const [
        MassBox(
            x: 0, y: 0, z: 0, width: 12, depth: 1, height: 2,
            shape: MassShape.mirror, yaw: 0),
      ]));
      final (plo, phi) = bounds(plate);
      expect(phi.y - plo.y, closeTo(12, 1e-6));
      expect(phi.x - plo.x, closeTo(1, 1e-6));
      final truck = CityTileMesher.massingBoxes(massing(const [
        MassBox(
            x: 0, y: 0, z: 0, width: 12, depth: 3, height: 3,
            shape: MassShape.vehicle, yaw: math.pi / 2),
      ]));
      final (tlo, thi) = bounds(truck);
      expect(thi.y - tlo.y, closeTo(12, 1e-6));
      expect(thi.x - tlo.x, closeTo(3, 1e-6));
    });

    test('no volumes: the footprint by the height, never nothing', () {
      final mesh = CityTileMesher.massingBoxes(massing(const []));
      expect(mesh.triangleCount, 12);
      final (lo, hi) = bounds(mesh);
      expect(hi.z - lo.z, closeTo(1, 1e-6));
    });
  });

  test('the archetype keys are the ones the UI thread computes', () {
    // The worker groups instances by a key it computes; the UI thread
    // looks the mesh up by a key IT computes from the group's
    // representative, through the library. They must be the same key or
    // every instanced group misses the cache and a mesh is generated
    // per group under a key nothing will ask for again.
    final workerSide = CityBuildingLibraries();
    final uiSide = CityBuildingLibraries()..syncKnobs(knobs);
    final near = CityTileMesher.mesh(request(CityTier.near), workerSide);
    expect(near.instances, isNotEmpty);
    final seen = <BuildingArchetype>{};
    for (final g in near.instances) {
      final lib = uiSide.forTier(g.archetype.detail);
      expect(
          CityTileMesher.archetypeOf(g.representative, g.archetype.detail,
              knobs,
              bucketM: lib.bucketM, variants: lib.variants),
          g.archetype);
      // The library generates under the same key: one mesh per group.
      final before = lib.meshCount;
      lib.get(CityTileMesher.specOf(g.representative),
          CityTileMesher.parcelOf(g.representative, knobs.style),
          seed: g.representative.id.hashCode, detail: g.archetype.detail);
      expect(lib.meshCount, before + (seen.add(g.archetype) ? 1 : 0));
    }
    expect(uiSide.meshCount, near.instances.length);
  });

  test('meshing is deterministic to the byte', () {
    final a = CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries());
    final b = CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries());
    expect(a.groups.length, b.groups.length);
    for (var i = 0; i < a.groups.length; i++) {
      expect(a.groups[i].material, b.groups[i].material);
      expect(a.groups[i].positions, b.groups[i].positions);
      expect(a.groups[i].normals, b.groups[i].normals);
      expect(a.groups[i].texCoords, b.groups[i].texCoords);
      expect(a.groups[i].indices, b.groups[i].indices);
    }
    expect(a.instances.map((g) => g.archetype).toList(),
        b.instances.map((g) => g.archetype).toList());
    for (var i = 0; i < a.instances.length; i++) {
      expect(a.instances[i].transforms, b.instances[i].transforms);
    }
    expect(a.treePits, b.treePits);
    expect(a.shrubPits, b.shrubPits);
  });

  test('the columns mesh to the bytes the snapshots do', () {
    // The UI thread packs the tile's snapshots into columns; the worker
    // rebuilds snapshots from them. Whatever the rebuilt roads are made of
    // (a Float64List view where the frame had a growable list), the
    // emitters must produce the same geometry, the same archetype keys and
    // the same road seeds — or a tile meshed on a worker would differ from
    // the one the UI thread would have made.
    final rebuilt = columns.toSnapshots();
    expect(rebuilt.roads.length, roads.length);
    for (var i = 0; i < roads.length; i++) {
      expect(CityTileMesher.roadSeed(rebuilt.roads[i]),
          CityTileMesher.roadSeed(roads[i]));
    }
    final again = CityTileColumns.fromSnapshots(
      buildings: rebuilt.buildings,
      roads: rebuilt.roads,
      patches: rebuilt.patches,
      ends: rebuilt.ends,
      roadEnds: rebuilt.roadEnds,
      transitEnds: rebuilt.transitEnds,
    );
    for (final tier in CityTier.values) {
      final a = CityTileMesher.mesh(request(tier), CityBuildingLibraries());
      final b = CityTileMesher.mesh(
          request(tier, members: again), CityBuildingLibraries());
      expect(b.groups.length, a.groups.length, reason: tier.name);
      for (var i = 0; i < a.groups.length; i++) {
        expect(b.groups[i].material, a.groups[i].material);
        expect(b.groups[i].castsShadow, a.groups[i].castsShadow);
        expect(b.groups[i].positions, a.groups[i].positions);
        expect(b.groups[i].normals, a.groups[i].normals);
        expect(b.groups[i].texCoords, a.groups[i].texCoords);
        expect(b.groups[i].indices, a.groups[i].indices);
      }
      expect(b.instances.map((g) => g.archetype).toList(),
          a.instances.map((g) => g.archetype).toList());
      for (var i = 0; i < a.instances.length; i++) {
        expect(b.instances[i].transforms, a.instances[i].transforms);
        expect(b.instances[i].representative.id,
            a.instances[i].representative.id);
      }
      expect(b.treePits, a.treePits);
      expect(b.shrubPits, a.shrubPits);
      expect(b.lodCounts, a.lodCounts);
      expect(b.skylineTris, a.skylineTris);
    }
  });

  test('a transit line takes a terminal only at an end nothing else meets',
      () {
    // The terminal test counts the body's transit ends within 8 m of the
    // end, off the column (see `CityTileColumns.transitEndsNear`): the
    // end's own entry and nothing else means free, and a free end takes
    // a terminal — so the more ends are met, the less of the viaduct's
    // solid there is.
    final line = road(RoadClass.transit, [(-100, 300), (100, 300)]);
    CityTileColumns withEnds(List<Vector3> transit) =>
        CityTileColumns.fromSnapshots(
          buildings: const [],
          roads: [line],
          patches: CityPatchColumns.empty,
          ends: const [],
          roadEnds: const [null, null],
          transitEnds: transit,
        );
    int solidTris(CityTileColumns c) => CityTileMesher.mesh(
            request(CityTier.near, members: c), CityBuildingLibraries())
        .groups
        .where((g) => g.material == CityMaterialKind.facade)
        .fold(0, (n, g) => n + g.triangleCount);
    final own = [const Vector3(-100, 300, r), const Vector3(100, 300, r)];
    final both = solidTris(withEnds(own));
    final east = solidTris(withEnds([...own, const Vector3(103, 302, r)]));
    final none = solidTris(withEnds([
      ...own,
      const Vector3(103, 302, r),
      const Vector3(-104, 297, r),
    ]));
    expect(both, greaterThan(east));
    expect(east, greaterThan(none));
    // Nothing listed at all: nothing meets either end.
    expect(solidTris(withEnds(const [])), both);
    // Nine metres off is out of reach.
    expect(solidTris(withEnds([...own, const Vector3(109, 300, r)])), both);
  });

  test('the road seed does not depend on the isolate', () async {
    // `Object.hash` is salted per isolate; the furniture seed must not be,
    // or two workers would dress the same street differently.
    final here = [for (final r in roads) CityTileMesher.roadSeed(r)];
    final there = await Isolate.run(
        () => [for (final r in roads) CityTileMesher.roadSeed(r)]);
    expect(there, here);
  });

  test('pack and unpack round-trip through a TransferableTypedData', () {
    final result = CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries());
    final (layout, blob) = result.pack();
    // Every span eight-byte aligned, so the views over the blob are legal
    // for every element size up to a double.
    for (final s in layout.groups) {
      for (final at in [s[2], s[4], s[6], s[8]]) {
        expect(at % 8, 0);
      }
    }
    expect(layout.treeSpan[0] % 8, 0);
    expect(layout.shrubSpan[0] % 8, 0);
    final back = CityTileResult.unpack(
        layout, TransferableTypedData.fromList([blob]).materialize());
    expect(back.tileKey, result.tileKey);
    expect(back.key, result.key);
    expect(back.tier, result.tier);
    expect(back.groups.length, result.groups.length);
    for (var i = 0; i < result.groups.length; i++) {
      final a = result.groups[i], b = back.groups[i];
      expect(b.material, a.material);
      expect(b.castsShadow, a.castsShadow);
      expect(b.positions, a.positions);
      expect(b.normals, a.normals);
      expect(b.texCoords, a.texCoords);
      expect(b.indices, a.indices);
      expect(b.bytes, a.bytes);
    }
    expect(back.instances.length, result.instances.length);
    for (var i = 0; i < result.instances.length; i++) {
      expect(back.instances[i].archetype, result.instances[i].archetype);
      expect(back.instances[i].representative.id,
          result.instances[i].representative.id);
      expect(back.instances[i].transforms, result.instances[i].transforms);
    }
    expect(back.treePits, result.treePits);
    expect(back.shrubPits, result.shrubPits);
    expect(back.lodCounts, result.lodCounts);
    expect(back.skylineTris, result.skylineTris);
    // The views are over the blob, not copies of it.
    expect(back.groups.first.positions.buffer.lengthInBytes, blob.length);
  });

  test('an empty tile packs and unpacks', () {
    final empty = CityTileResult(
      tileKey: 't',
      key: 'k',
      tier: CityTier.far,
      groups: const [],
      instances: const [],
      treePits: Float64List(0),
      shrubPits: Float64List(0),
      lodCounts: const {},
      skylineTris: 0,
    );
    final (layout, blob) = empty.pack();
    final back = CityTileResult.unpack(layout, blob.buffer);
    expect(back.groups, isEmpty);
    expect(back.instances, isEmpty);
    expect(back.treePits, isEmpty);
  });

  test('the steps run in the planned order under a step-at-a-time driver',
      () {
    // The inline scheduler runs a job a step at a time; the result must
    // be the one the whole run gives.
    final whole = CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries());
    final job = CityTileMeshJob(request(CityTier.near), CityBuildingLibraries());
    final kinds = <CityMeshStepKind>[];
    while (!job.done) {
      kinds.add(job.step());
    }
    expect(kinds.first, CityMeshStepKind.roads);
    expect(kinds.last, CityMeshStepKind.pack);
    expect(kinds.contains(CityMeshStepKind.merge), isTrue);
    final stepped = job.result;
    expect(stepped.groups.length, whole.groups.length);
    for (var i = 0; i < whole.groups.length; i++) {
      expect(stepped.groups[i].positions, whole.groups[i].positions);
      expect(stepped.groups[i].indices, whole.groups[i].indices);
    }
  });

  group('a merged mesh over the cap is cut into chunks', () {
    /// [n] quads in a row, each its four vertices then its two triangles,
    /// the way every builder emits: 4 * 48 + 6 * 4 = 216 bytes a quad.
    PropMesh quads(int n) {
      final m = MeshBuilder();
      for (var i = 0; i < n; i++) {
        final x = i * 2.0;
        final a = m.vertex(Vector3(x, 0, 0), Vector3.unitZ, 0, 0);
        final b = m.vertex(Vector3(x + 1, 0, 0), Vector3.unitZ, 1, 0);
        final c = m.vertex(Vector3(x + 1, 1, 0), Vector3.unitZ, 1, 1);
        final d = m.vertex(Vector3(x, 1, 0), Vector3.unitZ, 0, 1);
        m.quad(a, b, c, d);
      }
      return m.build();
    }

    /// Every triangle of [mesh] as its three vertices' positions, in order.
    List<List<double>> triangles(PropMesh mesh, [Uint32List? indices]) {
      final idx = indices ?? mesh.indices;
      return [
        for (var t = 0; t + 2 < idx.length; t += 3)
          [
            for (final i in [idx[t], idx[t + 1], idx[t + 2]])
              ...mesh.positions.sublist(i * 3, i * 3 + 3),
          ],
      ];
    }

    test('the engine size counts the colour stream', () {
      final g = CityTileMesher.chunk(quads(10),
          material: CityMaterialKind.facade, castsShadow: true);
      expect(g, hasLength(1));
      expect(CityTileMesher.bytesPerVertex, 48,
          reason: 'position 12 + normal 12 + uv 8 + colour 16');
      expect(g.single.bytes, 40 * 48 + 60 * 4);
    });

    test('under the cap: one group, the mesh itself, untouched', () {
      final mesh = quads(10);
      final before = Uint32List.fromList(mesh.indices);
      final g = CityTileMesher.chunk(mesh,
          material: CityMaterialKind.road, castsShadow: false, maxBytes: 4096);
      expect(g, hasLength(1));
      expect(g.single.material, CityMaterialKind.road);
      expect(g.single.castsShadow, isFalse);
      expect(g.single.vertexCount, 40);
      expect(g.single.indices, before);
      // A view, not a copy: a write through the mesh shows in the group.
      mesh.positions[0] = 42;
      expect(g.single.positions[0], 42);
    });

    test('over the cap: chunks under it, re-based, the same triangles', () {
      final mesh = quads(100);
      final original = triangles(mesh);
      const cap = 2000; // nine quads
      final chunks = CityTileMesher.chunk(mesh,
          material: CityMaterialKind.facade, castsShadow: true, maxBytes: cap);
      expect(chunks.length, greaterThan(5));
      final seen = <List<double>>[];
      for (final c in chunks) {
        expect(c.material, CityMaterialKind.facade);
        expect(c.castsShadow, isTrue);
        expect(c.bytes, lessThanOrEqualTo(cap));
        expect(c.indices.length % 3, 0, reason: 'no triangle straddles');
        expect(c.indices.isNotEmpty, isTrue);
        expect(c.normals.length, c.positions.length);
        expect(c.texCoords.length, c.vertexCount * 2);
        for (final i in c.indices) {
          expect(i, lessThan(c.vertexCount), reason: 're-based to the chunk');
        }
        expect(c.indices.contains(0), isTrue,
            reason: 'the range starts at a vertex the chunk uses');
        seen.addAll(triangles(
            PropMesh(
                positions: c.positions,
                normals: c.normals,
                texCoords: c.texCoords,
                indices: c.indices),
            c.indices));
      }
      // The union, in order, is the mesh: every triangle once.
      expect(seen, original);
      // And the chunks are views: their vertex bytes are the mesh's.
      expect(chunks.fold(0, (n, c) => n + c.vertexCount),
          greaterThanOrEqualTo(mesh.vertexCount));
      mesh.positions[mesh.positions.length - 1] = 42;
      expect(chunks.last.positions.last, 42);
    });

    test('an empty mesh makes no chunk', () {
      expect(
          CityTileMesher.chunk(PropMesh.empty,
              material: CityMaterialKind.ground, castsShadow: false),
          isEmpty);
    });

    test('a near tile arrives in groups no bigger than the cap', () {
      final near = CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries());
      expectWellFormed(near);
      for (final g in near.groups) {
        expect(g.bytes, lessThanOrEqualTo(CityTileMesher.maxGroupBytes));
      }
      // Forced small, the same tile is the same triangles in more groups.
      final was = CityTileMesher.maxGroupBytes;
      CityTileMesher.maxGroupBytes = 64 * 1024;
      try {
        final cut = CityTileMesher.mesh(
            request(CityTier.near), CityBuildingLibraries());
        expectWellFormed(cut);
        expect(cut.groups.length, greaterThan(near.groups.length));
        for (final g in cut.groups) {
          expect(g.bytes, lessThanOrEqualTo(64 * 1024));
        }
        int tris(CityTileResult r) =>
            r.groups.fold(0, (n, g) => n + g.triangleCount);
        expect(tris(cut), tris(near));
        // Per material and shadow answer too.
        for (final key in byMaterial(near).keys) {
          expect(
              cut.groups
                  .where((g) => (g.material, g.castsShadow) == key)
                  .fold(0, (n, g) => n + g.triangleCount),
              byMaterial(near)[key]!.triangleCount);
        }
      } finally {
        CityTileMesher.maxGroupBytes = was;
      }
    });
  });

  group('the merge sinks are reused across jobs', () {
    void expectSameGroups(CityTileResult a, CityTileResult b) {
      expect(b.groups.length, a.groups.length);
      for (var i = 0; i < a.groups.length; i++) {
        expect(b.groups[i].material, a.groups[i].material);
        expect(b.groups[i].positions, a.groups[i].positions);
        expect(b.groups[i].normals, a.groups[i].normals);
        expect(b.groups[i].texCoords, a.groups[i].texCoords);
        expect(b.groups[i].indices, a.groups[i].indices);
      }
    }

    test('a smaller job after a larger one: same bytes, no growth', () {
      final scratch = CityMeshScratch();
      final libraries = CityBuildingLibraries();
      final big = CityTileMesher.mesh(request(CityTier.near), libraries,
              scratch: scratch)
          .detached();
      expect(big.groups, isNotEmpty);
      final grown = scratch.vertexCapacity;
      expect(grown, greaterThan(0));

      final small = CityTileMesher.mesh(request(CityTier.far), libraries,
          scratch: scratch);
      expect(scratch.vertexCapacity, grown,
          reason: 'the far tile fits what the near one grew');
      expectSameGroups(
          CityTileMesher.mesh(request(CityTier.far), CityBuildingLibraries()),
          small);

      // And the near tile again, from the same sinks.
      final again = CityTileMesher.mesh(request(CityTier.near), libraries,
          scratch: scratch);
      expect(scratch.vertexCapacity, grown);
      expectSameGroups(big, again);
    });

    test('the road builders are reused across jobs: same bytes, no growth',
        () {
      // The road pass's builders live in the scratch too, reset per job:
      // the near tile grows them, the far tile and the near tile again fill
      // the same buffers, and every result matches a fresh build. The
      // budgets (props, curb cars) and the pit lists must come back per
      // tile as well, or the second near tile would be a poorer street.
      final scratch = CityMeshScratch();
      final libraries = CityBuildingLibraries();
      final big = CityTileMesher.mesh(request(CityTier.near), libraries,
              scratch: scratch)
          .detached();
      final grown = scratch.roadVertexCapacity;
      expect(grown, greaterThan(0));
      // The ground sheet and the lot furniture build into the scratch as
      // well; the near tile grows those too and nothing after it does.
      final grownTile = scratch.tileVertexCapacity;
      expect(grownTile, greaterThan(0));
      final fresh = CityTileMesher.mesh(
          request(CityTier.near), CityBuildingLibraries());
      expectSameGroups(fresh, big);
      expect(big.treePits, fresh.treePits);
      expect(big.shrubPits, fresh.shrubPits);

      final small = CityTileMesher.mesh(request(CityTier.far), libraries,
          scratch: scratch);
      expect(scratch.roadVertexCapacity, grown);
      expect(scratch.tileVertexCapacity, grownTile);
      expectSameGroups(
          CityTileMesher.mesh(request(CityTier.far), CityBuildingLibraries()),
          small);

      final again = CityTileMesher.mesh(request(CityTier.near), libraries,
          scratch: scratch);
      expect(scratch.roadVertexCapacity, grown);
      expect(scratch.tileVertexCapacity, grownTile);
      expectSameGroups(big, again);
      expect(again.treePits, big.treePits);
      expect(again.shrubPits, big.shrubPits);
    });

    test('the inline scheduler hands out results that alias nothing', () async {
      final scheduler = SyncCityTileScheduler();
      final first = scheduler.mesh(request(CityTier.near));
      final second = scheduler.mesh(request(CityTier.far));
      scheduler.pumpAll();
      final a = await first, b = await second;
      // The far tile was built into the sinks the near one's result was
      // views over; the result the caller holds is a copy, and still the
      // near tile.
      expectSameGroups(
          CityTileMesher.mesh(request(CityTier.near), CityBuildingLibraries()),
          a);
      expectSameGroups(
          CityTileMesher.mesh(request(CityTier.far), CityBuildingLibraries()),
          b);
      scheduler.dispose();
    });
  });
}
