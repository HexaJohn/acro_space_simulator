// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart'
    show kMileM;
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_catalog.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/mesh_merge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The renderer builds a colony from the FRAME alone — it has no access to the
/// authoritative CitySim, and a networked client never will.
void main() {
  BuildingSnapshot bldg({
    String id = 'b1',
    String type = 'r-med',
    double w = 24,
    double d = 24,
    int kind = 0,
    Vector3? pos,
  }) {
    final p = pos ?? Vector3(600000, 0, 0);
    return BuildingSnapshot(
      id: id,
      type: type,
      colonyId: 'c',
      body: 'moon',
      px: p.x,
      py: p.y,
      pz: p.z,
      // Surface basis: local +Z radial-up at (1,0,0) means a quarter turn.
      qw: 0.7071067811865476,
      qx: 0,
      qy: 0.7071067811865476,
      qz: 0,
      lat: 0,
      lon: 0,
      siteWidthM: w,
      siteDepthM: d,
      siteKindIndex: kind,
      colorArgb: 0xFF808080,
    );
  }

  test('site data survives the wire', () {
    final b = bldg(w: 3000, d: 3000, kind: SiteKind.pit.index);
    final back = BuildingSnapshot.fromJson(b.toJson());
    expect(back.siteWidthM, 3000);
    expect(back.siteDepthM, 3000);
    expect(back.siteKindIndex, SiteKind.pit.index);
    expect(back.colorArgb, 0xFF808080);
  });

  test('an old frame without site fields still renders as a cell building', () {
    // Forward compatibility: a publisher that predates these fields must not
    // produce zero-sized buildings on a newer client.
    final legacy = BuildingSnapshot.fromJson({
      'id': 'x',
      'type': 'r-low',
      'colony': 'c',
      'body': 'moon',
      'p': [600000, 0, 0],
      'q': [1, 0, 0, 0],
      'lat': 0.0,
      'lon': 0.0,
    });
    expect(legacy.siteWidthM, greaterThan(0));
    expect(CityNodes.parcelOf(legacy).area, greaterThan(0));
  });

  test('the reconstructed spec drives real massing', () {
    final quarry = bldg(w: 3000, d: 3000, kind: SiteKind.pit.index);
    final spec = CityNodes.specOf(quarry);
    expect(spec.siteKind, SiteKind.pit);
    expect(spec.siteMetres().width, 3000);

    // A pit builds plant on the rim, not a shed over the hole.
    final built = const BuildingGenerator()
        .generate(spec, CityNodes.parcelOf(quarry), detail: BuildingDetail.exterior);
    expect(built.model.solid.triangleCount, greaterThan(0));
    expect(built.massing.footprint.width, lessThan(3000));
  });

  test('instances are placed relative to the colony anchor, standing up', () {
    final anchor = Vector3(600000, 0, 0);
    // 100 m north of the anchor, on the same body-fixed radius.
    final b = bldg(pos: Vector3(600000, 0, 100));
    final m = CityNodes.instanceTransform(anchor, b);

    final t = m.getTranslation();
    // Offset carries only the 100 m, scaled into render units.
    expect(t.x, closeTo(0, 1e-6));
    expect(t.y, closeTo(0, 1e-6));
    expect(t.z.abs(), greaterThan(0));

    // The rotation is the building's own surface basis — its local +Z (the
    // axis buildings are authored along) must come out radial, or every
    // building in the colony lies on its side.
    // getRotation() carries the render scale baked in by compose(), so compare
    // the DIRECTION, not the magnitude.
    final up = (m.getRotation() * vm.Vector3(0, 0, 1))..normalize();
    expect(up.x.abs(), closeTo(1.0, 1e-6));
  });

  test('a tile outside the view steps down one tier, never out', () {
    // View culling must coarsen, not remove: a turn refines from a coarser
    // city, never from a hole where a block used to be.
    expect(CityNodes.viewTier(CityTier.near, inView: true), CityTier.near);
    expect(CityNodes.viewTier(CityTier.far, inView: true), CityTier.far);
    expect(CityNodes.viewTier(CityTier.near, inView: false), CityTier.mid);
    expect(CityNodes.viewTier(CityTier.mid, inView: false), CityTier.far);
    expect(CityNodes.viewTier(CityTier.far, inView: false), CityTier.far);
  });

  test('a distant colony drops to block silhouettes', () {
    // The tiers exist and are ordered; the node family picks between them by
    // range, and a block must be cheaper than a full building.
    final spec = CityNodes.specOf(bldg());
    final parcel = CityNodes.parcelOf(bldg());
    const gen = BuildingGenerator();
    final full = gen.generate(spec, parcel).model.solid.triangleCount;
    final block =
        gen.generate(spec, parcel, detail: BuildingDetail.block).model.solid
            .triangleCount;
    expect(block, lessThan(full));
  });

  group('a tile tracks the camera only where a building can take detail', () {
    // At orbit altitude every building resolves to its block silhouette,
    // so a near tile's build does not depend on where the camera is — and
    // must not carry it in its key, or every drag re-keys every near tile
    // into a build that lands nothing.
    final block = CityNodes.blockRangeM;

    test('not outside the near tier', () {
      for (final tier in [CityTier.mid, CityTier.far]) {
        expect(
            CityNodes.tileCanDetail(tier, 0,
                colonyTier: BuildingDetail.full, perBuildingLod: true),
            isFalse);
      }
    });

    test('per-building LOD: only a tile within the block range', () {
      expect(
          CityNodes.tileCanDetail(CityTier.near, block - 1,
              colonyTier: BuildingDetail.block, perBuildingLod: true),
          isTrue);
      // Exactly at the range a building is still exterior tier, and the
      // tile's distance is a lower bound on every building's.
      expect(
          CityNodes.tileCanDetail(CityTier.near, block,
              colonyTier: BuildingDetail.block, perBuildingLod: true),
          isTrue);
      expect(
          CityNodes.tileCanDetail(CityTier.near, block + 1,
              colonyTier: BuildingDetail.full, perBuildingLod: true),
          isFalse);
    });

    test('one tier for the colony: the colony tier answers', () {
      // The distance is irrelevant here — and the colony tier is already
      // part of the build key, so the camera never needs to be.
      expect(
          CityNodes.tileCanDetail(CityTier.near, block * 10,
              colonyTier: BuildingDetail.exterior, perBuildingLod: false),
          isTrue);
      expect(
          CityNodes.tileCanDetail(CityTier.near, 0,
              colonyTier: BuildingDetail.block, perBuildingLod: false),
          isFalse);
    });
  });

  group('tier hysteresis', () {
    final nearM = CityNodes.nearRangeM;
    final midM = CityNodes.midRangeM;
    final h = CityNodes.tierHysteresis;

    test('a tile with no history takes the plain ranges', () {
      expect(CityNodes.tierAtDistance(nearM - 1), CityTier.near);
      expect(CityNodes.tierAtDistance(nearM), CityTier.mid);
      expect(CityNodes.tierAtDistance(midM - 1), CityTier.mid);
      expect(CityNodes.tierAtDistance(midM), CityTier.far);
    });

    test('a near tile leaves near only past the widened range', () {
      // A tier flip is a tile rebuilt: a camera settling on the boundary
      // must not flip it back and forth.
      expect(CityNodes.tierAtDistance(nearM + 1, previous: CityTier.near),
          CityTier.near);
      expect(
          CityNodes.tierAtDistance(nearM * h - 1, previous: CityTier.near),
          CityTier.near);
      expect(CityNodes.tierAtDistance(nearM * h, previous: CityTier.near),
          CityTier.mid);
    });

    test('a mid tile leaves mid only past the widened range', () {
      expect(CityNodes.tierAtDistance(midM + 1, previous: CityTier.mid),
          CityTier.mid);
      expect(CityNodes.tierAtDistance(midM * h, previous: CityTier.mid),
          CityTier.far);
      // Coming back in is at the plain range, not the widened one.
      expect(CityNodes.tierAtDistance(nearM + 1, previous: CityTier.mid),
          CityTier.mid);
      expect(CityNodes.tierAtDistance(nearM - 1, previous: CityTier.mid),
          CityTier.near);
    });

    test('a far tile enters at the plain ranges', () {
      expect(CityNodes.tierAtDistance(midM + 1, previous: CityTier.far),
          CityTier.far);
      expect(CityNodes.tierAtDistance(midM - 1, previous: CityTier.far),
          CityTier.mid);
      expect(CityNodes.tierAtDistance(nearM - 1, previous: CityTier.far),
          CityTier.near);
    });

    test('a near tile thrown past mid lands where its distance says', () {
      // Leaving near lands in mid; leaving mid needs mid's own widened
      // edge; beyond that the tile is far whatever it was.
      expect(CityNodes.tierAtDistance(midM + 1, previous: CityTier.near),
          CityTier.mid);
      expect(CityNodes.tierAtDistance(midM * h + 1, previous: CityTier.near),
          CityTier.far);
    });
  });

  group('tiles are cells of the tangent grid, not of a cube', () {
    // A colony sits on a curved surface. Keyed on body-fixed cubes, its
    // footprint drifted across the grid's slabs and a third of the tiles
    // were slivers; keyed on arc across the tangent plane at the root's
    // anchor, one footprint is one tile whatever its height.
    const radius = 1737.4e3; // the Moon
    final anchor = Vector3(radius, 0, 0);
    final basis = ColonyTangentBasis.at(anchor);
    final tileM = 2 * kMileM;

    /// A point [arcM] of surface east of the anchor, on the surface.
    Vector3 alongEast(double arcM) {
      final a = arcM / radius;
      return (basis.up * math.cos(a) + basis.east * math.sin(a)) * radius;
    }

    test('the frame is orthonormal and up is through the anchor', () {
      expect(basis.radiusM, closeTo(radius, 1e-6));
      expect(basis.up.dot(basis.east), closeTo(0, 1e-12));
      expect(basis.up.dot(basis.north), closeTo(0, 1e-12));
      expect(basis.east.dot(basis.north), closeTo(0, 1e-12));
      expect(basis.east.length, closeTo(1, 1e-12));
      expect(basis.north.length, closeTo(1, 1e-12));
    });

    test('a rooftop and the street below it land in one tile', () {
      // The same footprint a kilometre east, on the ground and 300 m up.
      final ground = alongEast(1000);
      final roof = ground.normalized * (radius + 300);
      expect(basis.cellOf(ground, tileM), basis.cellOf(roof, tileM));
      expect(basis.cellOf(ground, tileM), (0, 0));
      // And the far side of the same cell, a valley 200 m down.
      final valley = alongEast(tileM - 50).normalized * (radius - 200);
      expect(basis.cellOf(valley, tileM), (0, 0));
    });

    test('two miles of arc apart is the next tile over, exactly', () {
      // Points just short of and just past one cell of ARC east of the
      // anchor: the cell holds two miles of ground, no more.
      expect(basis.cellOf(alongEast(tileM - 1), tileM).$1, 0);
      expect(basis.cellOf(alongEast(tileM + 1), tileM).$1, 1);
      // Forty kilometres out — a whole colony's width — the count of
      // cells crossed is the arc's, not the foreshortened chord's.
      const far = 40000.0;
      expect(basis.cellOf(alongEast(far), tileM).$1, (far / tileM).floor());
      expect(basis.arcOf(alongEast(far)).$1, closeTo(far, 1e-3));
      // And the same to the north, and negative the other way.
      final a = tileM * 1.5 / radius;
      final north =
          (basis.up * math.cos(a) + basis.north * math.sin(a)) * radius;
      expect(basis.cellOf(north, tileM), (0, 1));
      expect(basis.cellOf(alongEast(-1), tileM).$1, -1);
    });

    test('a cell centre is on the surface, in the middle of its cell', () {
      final c = basis.cellCentre(3, -2, tileM);
      expect(c.length, closeTo(radius, 1e-6));
      final (e, n) = basis.arcOf(c);
      // Within a metre off the axes, as the doc promises — it is an anchor.
      expect(e, closeTo(3.5 * tileM, 1.0));
      expect(n, closeTo(-1.5 * tileM, 1.0));
      expect(basis.cellOf(c, tileM), (3, -2));
    });
  });

  group('the upload merges by material', () {
    /// A strip of [n] unit quads.
    MeshBuilder strip(int n) {
      final m = MeshBuilder();
      for (var i = 0; i < n; i++) {
        final a = m.vertex(Vector3(i.toDouble(), 0, 0), Vector3.unitZ, 0, 0);
        final b = m.vertex(Vector3(i + 1.0, 0, 0), Vector3.unitZ, 1, 0);
        final c = m.vertex(Vector3(i + 1.0, 1, 0), Vector3.unitZ, 1, 1);
        final d = m.vertex(Vector3(i.toDouble(), 1, 0), Vector3.unitZ, 0, 1);
        m.quad(a, b, c, d);
      }
      return m;
    }

    test('several facade builders become one facade geometry', () {
      // Seven distinct materials, two dozen builders: a tile's draw count
      // is the materials', not the builders'.
      final props = strip(2), lamps = strip(3), curbs = strip(1);
      final glow = strip(1);
      final ribbon = strip(4), apron = strip(1), deck = strip(1);
      final groups = CityNodes.uploadGroups([
        (props, CityMaterialKind.facade, false),
        (lamps, CityMaterialKind.facade, false),
        (curbs, CityMaterialKind.facade, false),
        (glow, CityMaterialKind.glazing, false),
        (ribbon, CityMaterialKind.road, false),
        (apron, CityMaterialKind.road, false),
        (deck, CityMaterialKind.road, true),
      ], CityTier.near);
      expect(groups[(CityMaterialKind.facade, true)], [props, lamps, curbs]);
      expect(groups[(CityMaterialKind.glazing, false)], [glow]);
      // Flat ribbons and aprons receive; the elevated deck casts, so it is
      // the one extra draw.
      expect(groups[(CityMaterialKind.road, false)], [ribbon, apron]);
      expect(groups[(CityMaterialKind.road, true)], [deck]);
      // Every material has its plain group even with nothing in it — the
      // skyline sinks ride on the facade and glazing ones.
      expect(groups.containsKey((CityMaterialKind.ground, false)), isTrue);
      expect(groups.length, CityMaterialKind.values.length + 1);

      final facade =
          CityNodes.mergeBuilders(groups[(CityMaterialKind.facade, true)]!);
      expect(facade.vertexCount, (2 + 3 + 1) * 4);
      expect(facade.triangleCount, (2 + 3 + 1) * 2);
    });

    test('the merge appends into the skyline sink and skips empties', () {
      final skyline = MergedMeshSink();
      skyline.appendMesh(strip(5).build());
      final out = CityNodes.mergeBuilders([strip(2), MeshBuilder(), strip(1)],
          into: skyline);
      expect(identical(out, skyline), isTrue);
      expect(out.vertexCount, (5 + 2 + 1) * 4);
      // The appended strip's triangles index its own vertices.
      final mesh = out.build();
      for (var i = 5 * 6; i < 7 * 6; i++) {
        expect(mesh.indices[i], inInclusiveRange(20, 27));
      }
    });

    test('a far tile casts nothing, so the deck joins the plain road', () {
      final deck = strip(1);
      final groups = CityNodes.uploadGroups(
          [(deck, CityMaterialKind.road, true)], CityTier.far);
      expect(groups[(CityMaterialKind.road, false)], [deck]);
      expect(groups.length, CityMaterialKind.values.length);
    });
  });

  group('planting shows by distance, with hysteresis', () {
    final shrub = CityNodes.floraShrubRangeM;
    final tree = CityNodes.floraTreeRangeM;
    final h = CityNodes.floraHysteresis;

    test('a shrub is under a pixel past a few hundred metres', () {
      expect(CityNodes.floraVisibleAt(PropKind.shrub, shrub - 1, shown: false),
          isTrue);
      expect(CityNodes.floraVisibleAt(PropKind.shrub, shrub, shown: false),
          isFalse);
    });

    test('a tree carries further', () {
      expect(
          CityNodes.floraVisibleAt(PropKind.broadleafTree, tree - 1,
              shown: false),
          isTrue);
      expect(
          CityNodes.floraVisibleAt(PropKind.broadleafTree, tree, shown: false),
          isFalse);
      // Well past the shrub range, where a shrub would be gone.
      expect(
          CityNodes.floraVisibleAt(PropKind.broadleafTree, shrub * 2,
              shown: false),
          isTrue);
    });

    test('shown planting stays shown until the widened range', () {
      // A tile's trees blinking on a camera at rest on the edge is worse
      // than a few frames of sub-pixel trees.
      expect(CityNodes.floraVisibleAt(PropKind.shrub, shrub + 1, shown: true),
          isTrue);
      expect(
          CityNodes.floraVisibleAt(PropKind.shrub, shrub * h - 1, shown: true),
          isTrue);
      expect(CityNodes.floraVisibleAt(PropKind.shrub, shrub * h, shown: true),
          isFalse);
      expect(
          CityNodes.floraVisibleAt(PropKind.broadleafTree, tree * h - 1,
              shown: true),
          isTrue);
      expect(
          CityNodes.floraVisibleAt(PropKind.broadleafTree, tree * h,
              shown: true),
          isFalse);
    });
  });

  group('what casts a shadow', () {
    test('on a near tile: solids cast, glazing and flat ground do not', () {
      expect(CityNodes.castsShadowFor(CityTier.near, CityMaterialKind.facade),
          isTrue);
      expect(CityNodes.castsShadowFor(CityTier.near, CityMaterialKind.glazing),
          isFalse);
      for (final flat in [
        CityMaterialKind.ground,
        CityMaterialKind.road,
        CityMaterialKind.dirt,
        CityMaterialKind.alley,
        CityMaterialKind.sidewalk,
      ]) {
        expect(CityNodes.castsShadowFor(CityTier.near, flat), isFalse,
            reason: '$flat lies on the ground: a receiver');
        // Unless it stands off the ground — an overpass deck.
        expect(CityNodes.castsShadowFor(CityTier.near, flat, elevated: true),
            isTrue);
      }
    });

    test('mid and far tiles cast nothing at all', () {
      for (final tier in [CityTier.mid, CityTier.far]) {
        for (final kind in CityMaterialKind.values) {
          expect(CityNodes.castsShadowFor(tier, kind), isFalse);
          expect(
              CityNodes.castsShadowFor(tier, kind, elevated: true), isFalse);
        }
        expect(
            CityNodes.floraCastsShadow(tier, PropKind.broadleafTree), isFalse);
      }
    });

    test('trees cast on a near tile, shrubs never', () {
      expect(CityNodes.floraCastsShadow(CityTier.near, PropKind.broadleafTree),
          isTrue);
      expect(
          CityNodes.floraCastsShadow(CityTier.near, PropKind.shrub), isFalse);
    });
  });
}
