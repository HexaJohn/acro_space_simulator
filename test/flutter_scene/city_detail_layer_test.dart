// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:isolate';
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_detail_layer.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

/// The detail layer: the eye keyed by its cell, the buildings round it
/// gathered and meshed as one job, the archetypes the UI thread lacks
/// generated on the worker — and the base tiles under it reading nothing
/// off the camera.
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

  // Within the interior range, within the block range, and beyond it.
  final near = <BuildingSnapshot>[
    bldg('h0', 'r-low', 20, 30, w: 12, d: 14),
    bldg('h1', 'r-med', -30, 20, w: 18),
    bldg('s0', 'c-med', 0, -40, w: 30, d: 24, corner: true),
  ];
  final mid = <BuildingSnapshot>[
    bldg('m0', 'r-med', 120, 0),
    bldg('m1', 'c-high', -100, 150, w: 40, d: 36),
    bldg('m2', 'i-low', 200, -180, w: 60, d: 40),
  ];
  final far = <BuildingSnapshot>[
    bldg('f0', 'r-med', 340, 0),
    bldg('f1', 'r-med', 900, 900),
  ];
  final all = [...near, ...mid, ...far];
  const eye = Vector3(0, 0, r + 2);

  CityTileColumns columnsOf(List<BuildingSnapshot> buildings) =>
      CityTileColumns.fromSnapshots(
        buildings: buildings,
        roads: const [],
        patches: CityPatchColumns.empty,
        ends: const [],
        roadEnds: const [],
        transitEnds: const [],
      );

  CityTileRequest tile(CityTier tier,
          {required bool detailLayer,
          Vector3 focus = eye,
          bool canDetail = true,
          List<BuildingSnapshot>? buildings}) =>
      CityTileRequest(
        tileKey: '$body/0/0',
        key: 'k',
        tier: tier,
        canDetail: canDetail,
        anchorBF: anchor,
        columns: columnsOf(buildings ?? all),
        focusBF: focus,
        colonyTier: BuildingDetail.full,
        epoch: 1.0,
        knobs: knobs,
        detailLayer: detailLayer,
      );

  void expectSameGroups(CityTileResult a, CityTileResult b) {
    expect(a.groups.length, b.groups.length);
    for (var i = 0; i < a.groups.length; i++) {
      expect(a.groups[i].material, b.groups[i].material);
      expect(a.groups[i].castsShadow, b.groups[i].castsShadow);
      expect(a.groups[i].positions, b.groups[i].positions);
      expect(a.groups[i].normals, b.groups[i].normals);
      expect(a.groups[i].texCoords, b.groups[i].texCoords);
      expect(a.groups[i].indices, b.groups[i].indices);
    }
  }

  group('the eye is keyed by its cell', () {
    test('two eyes in one cell key the same; across the edge they differ',
        () {
      final c = CityDetailLayer.cellM;
      final a = CityDetailLayer.cellOf(Vector3(10, 10, r + 2));
      final b = CityDetailLayer.cellOf(Vector3(20, -10, r + 5));
      expect(a, b);
      // Rounded to the nearest cell, as the tiles' camera term was.
      expect(a.$1, 0);
      expect(a.$3, (r / c).round());
      final over = CityDetailLayer.cellOf(Vector3(c * 0.5 + 1, 10, r + 2));
      expect(over.$1, 1);
      expect(over, isNot(a));
      // The cell is a knob.
      expect(CityDetailLayer.cellOf(Vector3(100, 0, 0), cellM: 32).$1, 3);
    });

    test('the key moves only with the cell and the inputs the meshing reads',
        () {
      String key(
              {(int, int, int) cell = (0, 0, 27147),
              String sig = 's',
              int inv = 0,
              BuildingDetail colonyTier = BuildingDetail.full,
              bool lots = true,
              CityMeshKnobs k = knobs}) =>
          CityDetailLayer.keyFor(
              bodyId: body,
              cell: cell,
              structureSig: sig,
              invalidation: inv,
              colonyTier: colonyTier,
              lotFeatures: lots,
              knobs: k);
      final base = key();
      expect(key(), base);
      expect(key(cell: (1, 0, 27147)), isNot(base));
      expect(key(sig: 't'), isNot(base));
      expect(key(inv: 1), isNot(base));
      expect(key(colonyTier: BuildingDetail.block), isNot(base));
      expect(key(lots: false), isNot(base));
      expect(
          key(
              k: const CityMeshKnobs(
            styleId: 'masonry-street',
            bucketM: 6,
            variants: 4,
            perBuildingLod: true,
            blockRangeM: 250,
            interiorRangeM: 50,
            lodDebug: false,
            onStreetParking: true,
            sealedWorld: false,
            maxParkedCars: 400,
          )),
          isNot(base));
    });

    test('the cell centre is what the set is anchored on', () {
      final cell = CityDetailLayer.cellOf(eye);
      final centre = CityDetailLayer.cellCentre(cell);
      expect((centre - eye).length, lessThan(CityDetailLayer.cellM));
    });
  });

  group('the gather', () {
    test('takes the buildings within range of the centre, in order', () {
      // Three tiles' worth of candidates, as the ring round the eye's
      // tile hands them over.
      final candidates = [...far, ...near, ...mid];
      final centre = CityDetailLayer.cellCentre(CityDetailLayer.cellOf(eye));
      final radius = CityDetailLayer.gatherRadiusM(knobs.blockRangeM);
      expect(radius, knobs.blockRangeM + CityDetailLayer.cellM);
      final got = CityDetailLayer.gather(candidates, centre, radius);
      // f0 at 340 m is inside the margin — the eye could be a cell
      // nearer — and f1 is not.
      expect(got.map((b) => b.id).toList(),
          ['f0', 'h0', 'h1', 's0', 'm0', 'm1', 'm2']);
    });

    test('the known keys are the ones the buildings will key to', () {
      final cache = <BuildingArchetype>{};
      expect(
          CityDetailLayer.knownArchetypes(
              all, eye, BuildingDetail.full, knobs, cache.contains),
          isEmpty);
      // What the worker keys the near buildings to.
      final result = CityTileMesher.mesh(
          CityDetailLayer.requestFor(
            key: 'k',
            bodyId: body,
            anchorBF: anchor,
            buildings: all,
            focusBF: eye,
            colonyTier: BuildingDetail.full,
            lotFeatures: true,
            epoch: 1.0,
            knobs: knobs,
            known: const [],
          ),
          CityBuildingLibraries());
      cache.addAll(result.instances.map((g) => g.archetype));
      final known = CityDetailLayer.knownArchetypes(
          all, eye, BuildingDetail.full, knobs, cache.contains);
      expect(known.toSet(), cache);
      // A key the cache holds for a building out of range is not sent.
      expect(known.length, result.instances.length);
    });
  });

  group('a detail job', () {
    CityTileRequest detail(
            {List<BuildingArchetype> known = const [],
            bool lots = true,
            List<BuildingSnapshot>? buildings}) =>
        CityDetailLayer.requestFor(
          key: 'k',
          bodyId: body,
          anchorBF: anchor,
          buildings: buildings ?? all,
          focusBF: eye,
          colonyTier: BuildingDetail.full,
          lotFeatures: lots,
          epoch: 1.0,
          knobs: knobs,
          known: known,
        );

    test('meshes the buildings in range at their own tier, none at block',
        () {
      final result = CityTileMesher.mesh(detail(), CityBuildingLibraries());
      expect(result.tileKey, 'detail/$body');
      expect(result.lodCounts, {
        BuildingDetail.full: near.length,
        BuildingDetail.exterior: mid.length,
      });
      var instanced = 0;
      for (final g in result.instances) {
        instanced += g.count;
        expect(g.archetype.detail, isNot(BuildingDetail.block));
      }
      expect(instanced, near.length + mid.length);
      // No skyline, no roads, no planting: the base tiles' business.
      expect(result.skylineTris, 0);
      expect(result.treePits, isEmpty);
      expect(result.shrubPits, isEmpty);
      // The furniture, merged as a near tile's is: fences and signs on
      // the facade, casting.
      final facade = result.groups
          .where((g) => g.material == CityMaterialKind.facade)
          .toList();
      expect(facade, isNotEmpty);
      expect(facade.every((g) => g.castsShadow), isTrue);
      expect(result.groups.any((g) => g.material == CityMaterialKind.ground),
          isFalse);
    });

    test('the result carries the meshes of the archetypes the UI lacks',
        () {
      final cold = CityTileMesher.mesh(detail(), CityBuildingLibraries());
      final keys = cold.instances.map((g) => g.archetype).toList();
      expect(keys.toSet(), hasLength(keys.length));
      // Nothing known: every archetype comes back with its mesh, none
      // of them empty.
      expect(cold.archetypeMeshes.map((a) => a.archetype).toSet(),
          keys.toSet());
      for (final a in cold.archetypeMeshes) {
        expect(a.solid.isEmpty, isFalse);
        expect(a.lod, isFalse);
        expect(a.bytes, greaterThan(0));
      }
      // Two known: the rest come back, the instances unchanged.
      final known = keys.take(2).toList();
      final warm = CityTileMesher.mesh(
          detail(known: known), CityBuildingLibraries());
      expect(warm.archetypeMeshes.map((a) => a.archetype).toSet(),
          keys.skip(2).toSet());
      expect(warm.instances.map((g) => g.archetype).toList(), keys);
      for (var i = 0; i < keys.length; i++) {
        expect(warm.instances[i].transforms, cold.instances[i].transforms);
      }
      // Every archetype known: none generated.
      final hot =
          CityTileMesher.mesh(detail(known: keys), CityBuildingLibraries());
      expect(hot.archetypeMeshes, isEmpty);
    });

    test('a generated mesh is the one the UI library would have made', () {
      final result = CityTileMesher.mesh(detail(), CityBuildingLibraries());
      final ui = CityBuildingLibraries()..syncKnobs(knobs);
      for (final g in result.instances) {
        final a = result.archetypeMeshes
            .singleWhere((a) => a.archetype == g.archetype);
        final b = g.representative;
        final built = ui.forTier(g.archetype.detail).get(
            CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, knobs.style),
            seed: b.id.hashCode, detail: g.archetype.detail);
        expect(a.solid.positions, built.model.solid.positions);
        expect(a.solid.indices, built.model.solid.indices);
        expect(a.glazing.positions, built.model.foliage.positions);
      }
    });

    test('no furniture when the lot features are off', () {
      final result =
          CityTileMesher.mesh(detail(lots: false), CityBuildingLibraries());
      expect(result.groups, isEmpty);
      expect(result.instances, isNotEmpty);
    });

    test('under the LOD visualiser the meshes are boxes in the tier colour',
        () {
      final result = CityTileMesher.mesh(
          CityDetailLayer.requestFor(
            key: 'k',
            bodyId: body,
            anchorBF: anchor,
            buildings: all,
            focusBF: eye,
            colonyTier: BuildingDetail.full,
            lotFeatures: false,
            epoch: 1.0,
            knobs: const CityMeshKnobs(
              styleId: 'masonry-street',
              bucketM: 6,
              variants: 4,
              perBuildingLod: true,
              blockRangeM: 300,
              interiorRangeM: 50,
              lodDebug: true,
              onStreetParking: true,
              sealedWorld: false,
              maxParkedCars: 400,
            ),
            known: const [],
          ),
          CityBuildingLibraries());
      expect(result.archetypeMeshes, isNotEmpty);
      for (final a in result.archetypeMeshes) {
        expect(a.lod, isTrue);
        expect(a.solid.triangleCount, 12);
        expect(a.glazing.isEmpty, isTrue);
        final u = a.solid.texCoords[0];
        expect(u, closeTo(CityTileMesher.lodSwatchU(a.archetype.detail), 1e-6));
      }
    });

    test('packs and unpacks with its archetype meshes, through a transfer',
        () {
      final result = CityTileMesher.mesh(detail(), CityBuildingLibraries());
      final (layout, blob) = result.pack();
      expect(layout.archetypeMeshKeys.length, result.archetypeMeshes.length);
      for (final s in layout.archetypeMeshSpans) {
        expect(s, hasLength(17));
        for (var i = 0; i < 16; i += 2) {
          expect(s[i] % 8, 0);
        }
      }
      final back = CityTileResult.unpack(
          layout, TransferableTypedData.fromList([blob]).materialize());
      expect(back.archetypeMeshes.length, result.archetypeMeshes.length);
      for (var i = 0; i < result.archetypeMeshes.length; i++) {
        final a = result.archetypeMeshes[i], b = back.archetypeMeshes[i];
        expect(b.archetype, a.archetype);
        expect(b.lod, a.lod);
        expect(b.solid.positions, a.solid.positions);
        expect(b.solid.normals, a.solid.normals);
        expect(b.solid.texCoords, a.solid.texCoords);
        expect(b.solid.indices, a.solid.indices);
        expect(b.glazing.positions, a.glazing.positions);
        expect(b.glazing.indices, a.glazing.indices);
        expect(b.bytes, a.bytes);
      }
      expect(back.instances.length, result.instances.length);
      expect(back.groups.length, result.groups.length);
      // A tile's result still packs with none.
      final tileResult = CityTileMesher.mesh(
          tile(CityTier.near, detailLayer: true), CityBuildingLibraries());
      final (tl, tb) = tileResult.pack();
      expect(tl.archetypeMeshKeys, isEmpty);
      expect(CityTileResult.unpack(tl, tb.buffer).archetypeMeshes, isEmpty);
    });

    test('the steps run in the planned order, a step at a time', () {
      final whole = CityTileMesher.mesh(detail(), CityBuildingLibraries());
      final job = CityTileMeshJob(detail(), CityBuildingLibraries());
      final kinds = <CityMeshStepKind>[];
      while (!job.done) {
        kinds.add(job.step());
      }
      expect(kinds.first, CityMeshStepKind.buildings);
      expect(kinds.last, CityMeshStepKind.pack);
      // The archetypes are planned once the groups are known, and run
      // before the furniture and the merge.
      final archetypes = kinds.indexOf(CityMeshStepKind.archetypes);
      expect(archetypes, greaterThan(kinds.lastIndexOf(CityMeshStepKind.buildings)));
      expect(kinds.lastIndexOf(CityMeshStepKind.archetypes),
          lessThan(kinds.indexOf(CityMeshStepKind.lots)));
      expect(kinds.contains(CityMeshStepKind.roads), isFalse);
      expect(kinds.contains(CityMeshStepKind.patches), isFalse);
      final stepped = job.result;
      expect(stepped.archetypeMeshes.length, whole.archetypeMeshes.length);
      expectSameGroups(stepped, whole);
    });
  });

  group('a base tile under the layer', () {
    test('near: every building a block, no instances, no furniture', () {
      final on = CityTileMesher.mesh(
          tile(CityTier.near, detailLayer: true), CityBuildingLibraries());
      expect(on.instances, isEmpty);
      expect(on.lodCounts, {BuildingDetail.block: all.length});
      // The facade and glazing groups are the skyline alone: no fence,
      // sign or car joined them, whatever the caller's canDetail said.
      var tris = 0;
      for (final g in on.groups) {
        if (g.material == CityMaterialKind.facade ||
            g.material == CityMaterialKind.glazing) {
          tris += g.triangleCount;
        }
      }
      expect(tris, on.skylineTris);
      expect(on.groups.any((g) => g.material == CityMaterialKind.road),
          isFalse);
      // Off, the same tile with the same canDetail carries the furniture
      // and instances the near buildings.
      final off = CityTileMesher.mesh(
          tile(CityTier.near, detailLayer: false), CityBuildingLibraries());
      expect(off.instances, isNotEmpty);
      var offTris = 0;
      for (final g in off.groups) {
        if (g.material == CityMaterialKind.facade ||
            g.material == CityMaterialKind.glazing) {
          offTris += g.triangleCount;
        }
      }
      expect(offTris, greaterThan(off.skylineTris));
    });

    test('near: the boxes are inset by nearBoxInset about the building', () {
      // One building at the anchor with the surface basis: every skyline
      // vertex is then the box's own coordinates, and the inset is a
      // plain scale of each.
      final one = [bldg('x', 'c-high', 0, 0, w: 40, d: 36)];
      // The reference: the same tile with the layer off and the eye far
      // enough that the building is a block — the box at full size.
      final plain = CityTileMesher.mesh(
          tile(CityTier.near,
              detailLayer: false,
              focus: const Vector3(5000, 0, r),
              canDetail: false,
              buildings: one),
          CityBuildingLibraries());
      final inset = CityTileMesher.mesh(
          tile(CityTier.near, detailLayer: true, buildings: one),
          CityBuildingLibraries());
      expect(inset.groups.length, plain.groups.length);
      final s = CityTileMesher.nearBoxInset;
      expect(s, 0.97);
      for (var i = 0; i < plain.groups.length; i++) {
        final a = plain.groups[i], b = inset.groups[i];
        expect(b.material, a.material);
        expect(b.indices, a.indices);
        expect(b.normals, a.normals);
        expect(b.positions.length, a.positions.length);
        for (var k = 0; k < a.positions.length; k++) {
          expect(b.positions[k], closeTo(a.positions[k] * s, 1e-4),
              reason: '${a.material} vertex ${k ~/ 3}');
        }
      }
      // At an inset of one the tile is the plain tile to the byte.
      final was = CityTileMesher.nearBoxInset;
      CityTileMesher.nearBoxInset = 1.0;
      try {
        final none = CityTileMesher.mesh(
            tile(CityTier.near, detailLayer: true, buildings: one),
            CityBuildingLibraries());
        expectSameGroups(none, plain);
      } finally {
        CityTileMesher.nearBoxInset = was;
      }
    });

    test('mid and far: the tile it was, to the byte', () {
      // Beyond the near tier nothing can detail, and the caller says so
      // (see `CityNodes.tileCanDetail`); the layer changes nothing there.
      for (final tier in [CityTier.mid, CityTier.far]) {
        final on = CityTileMesher.mesh(
            tile(tier, detailLayer: true, canDetail: false),
            CityBuildingLibraries());
        final off = CityTileMesher.mesh(
            tile(tier, detailLayer: false, canDetail: false),
            CityBuildingLibraries());
        expectSameGroups(on, off);
        expect(on.instances, isEmpty);
        expect(on.lodCounts, off.lodCounts);
      }
    });

    test('the layer off is the tile as it was, to the byte', () {
      // The switch's default is off at the request: a request that does
      // not name it meshes as one that names it off.
      final unnamed = CityTileMesher.mesh(
          CityTileRequest(
            tileKey: '$body/0/0',
            key: 'k',
            tier: CityTier.near,
            canDetail: true,
            anchorBF: anchor,
            columns: columnsOf(all),
            focusBF: eye,
            colonyTier: BuildingDetail.full,
            epoch: 1.0,
            knobs: knobs,
          ),
          CityBuildingLibraries());
      final off = CityTileMesher.mesh(
          tile(CityTier.near, detailLayer: false), CityBuildingLibraries());
      expectSameGroups(unnamed, off);
      expect(off.instances.map((g) => g.archetype).toList(),
          unnamed.instances.map((g) => g.archetype).toList());
      for (var i = 0; i < off.instances.length; i++) {
        expect(off.instances[i].transforms, unnamed.instances[i].transforms);
      }
      expect(unnamed.archetypeMeshes, isEmpty);
    });
  });

  test('the request goes over an isolate and back with its known keys',
      () async {
    final request = CityDetailLayer.requestFor(
      key: 'k',
      bodyId: body,
      anchorBF: anchor,
      buildings: all,
      focusBF: eye,
      colonyTier: BuildingDetail.full,
      lotFeatures: true,
      epoch: 1.0,
      knobs: knobs,
      known: const [
        BuildingArchetype(
            type: 'r-low',
            widthBucket: 2,
            depthBucket: 3,
            detail: BuildingDetail.full,
            variant: 1,
            styleId: 'masonry-street'),
      ],
    );
    final back = await Isolate.run(() => request);
    expect(back.isDetail, isTrue);
    expect(back.detailLayer, isTrue);
    expect(back.detail!.knownArchetypes, request.detail!.knownArchetypes);
    expect(back.columns.buildingCount, all.length);
    final there = await Isolate.run(() {
      final (layout, blob) =
          CityTileMesher.mesh(request, CityBuildingLibraries()).pack();
      return (layout, TransferableTypedData.fromList([blob]));
    });
    final result = CityTileResult.unpack(there.$1, there.$2.materialize());
    expect(result.instances, isNotEmpty);
    expect(result.archetypeMeshes, isNotEmpty);
    // The one known key was a guess; the worker generated what it met.
    expect(result.archetypeMeshes.length, result.instances.length);
  });

  test('the columns pack a building-only set', () {
    final c = columnsOf(near);
    expect(c.buildingCount, near.length);
    expect(c.roadCount, 0);
    expect(c.patchCount, 0);
    expect(c.endCount, 0);
    final m = c.toSnapshots();
    expect(m.buildings.map((b) => b.id).toList(), near.map((b) => b.id).toList());
    expect(m.roads, isEmpty);
    expect(Float64List(0), isEmpty);
  });
}
