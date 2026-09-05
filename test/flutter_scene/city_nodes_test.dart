// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
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
}
