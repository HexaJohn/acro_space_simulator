// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/universe/terrain_heights.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// R0's renderer twin (docs/plans/site-access.md §5.1).
///
/// Whatever the snapshot's quaternion says, what counts is where the DRAWN
/// door lands: the massing the tile library builds the mesh from, placed by
/// the exact model transform the tiles instance it with. The door must end
/// up on the street side of the building, nearer the lot's frontage
/// midpoint than the building's own centre is. If this passes without the
/// orientation fix, something downstream already compensates for the flip
/// and the fix must not land (the §5.1 stop rule).
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  const style = ArchitectureStyle.masonryStreet;
  final libraries = CityBuildingLibraries()..sync(style.id, 6, 4);

  /// Body-fixed metres of colony-local (east, north) on the tangent plane,
  /// at the radius the buildings were placed at.
  Vector3 bodyFixed(CitySim city, Vec2 p) => const SurfacePlacement()
      .place(
        radius: city.body.radius,
        lat: city.cityLat * math.pi / 180.0,
        lon: city.cityLon * math.pi / 180.0,
        east: p.e,
        north: p.n,
      )
      .position;

  /// The drawn door of [b], body-fixed metres.
  Vector3 drawnDoor(BuildingSnapshot b) {
    final anchor = Vector3(b.px, b.py, b.pz);
    final built = libraries.forTier(BuildingDetail.full).get(
        CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, style),
        seed: b.id.hashCode, detail: BuildingDetail.full);
    final (ex, ey) = built.massing.entrance;
    final m = CityTileMesher.instanceTransform(anchor, b);
    final s = m.transform3(vm.Vector3(ex, ey, 0));
    return anchor +
        Vector3(s.x / kRenderScale, s.y / kRenderScale, s.z / kRenderScale);
  }

  void expectDoorToStreet(
      CitySim city, Parcel parcel, BuildingSnapshot b, String label) {
    final mid = parcel.frontageMidpoint;
    expect(mid, isNotNull, reason: '$label has a frontage');
    final street = bodyFixed(city, mid!);
    final centre = Vector3(b.px, b.py, b.pz);
    final door = drawnDoor(b);
    final doorGap = (door - street).length;
    final centreGap = (centre - street).length;
    expect(doorGap, lessThan(centreGap),
        reason: '$label: the drawn door is ${doorGap.toStringAsFixed(1)} m '
            'from the frontage midpoint, the building centre '
            '${centreGap.toStringAsFixed(1)} m — the front faces away');
  }

  test('starter kit: every site\'s drawn door is on its street side', () {
    final city = CityStarterKit.found(
      bodies: bodies,
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
    );
    final built = city.parcelBuiltLots().toList();
    expect(built.length, 5);
    for (final (parcel, spec) in built) {
      final b = BuildingSnapshot.ofParcel(city, parcel, spec, city.body,
          siteRadiusM: city.body.radius);
      expectDoorToStreet(city, parcel, b, '${spec.type} ${parcel.id}');
    }
  });

  test('starter kit: a grid cell\'s drawn door is on its stored frontage', () {
    final city = CityStarterKit.found(
      bodies: bodies,
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
    );
    final spec =
        kZoneSpecs[CitySim.zoneKindOf(ParcelUse.commercial)!]![Density.low]!;
    final half = city.grid ~/ 2;
    final cell = (half + 3) + (half + 3) * city.grid;
    final parcel = city.parcelForCell(cell, spec);
    final b = BuildingSnapshot.ofCityCell(city, cell, spec, city.body,
        const SurfacePlacement(), TerrainHeights());
    expectDoorToStreet(city, parcel, b, 'cell $cell ${spec.type}');
  });

  test('a generated block: the drawn doors face the streets', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 2, buildFraction: 1.0),
        bodies: bodies);
    final built = city.parcelBuiltLots().toList();
    expect(built, isNotEmpty);
    // A spread of lots, not the whole town: each one generates a full mesh.
    final step = math.max(1, built.length ~/ 24);
    var checked = 0;
    for (var i = 0; i < built.length; i += step) {
      final (parcel, spec) = built[i];
      // A frontage-less generator lot has no street to face yet: its turn
      // to the effective frontage is R4's (§3.1).
      if (parcel.frontageMidpoint == null) continue;
      checked++;
      final b = BuildingSnapshot.ofParcel(city, parcel, spec, city.body,
          siteRadiusM: city.body.radius);
      expectDoorToStreet(city, parcel, b, '${spec.type} ${parcel.id}');
    }
    expect(checked, greaterThan(10));
  });
}
