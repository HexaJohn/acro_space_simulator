// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:isolate';
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
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
  final patches = <CityPatchSnapshot>[
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
  ];
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
}
