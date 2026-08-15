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
}
