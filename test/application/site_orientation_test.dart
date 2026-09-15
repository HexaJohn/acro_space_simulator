// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_frame.dart';
import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/universe/terrain_heights.dart';
import 'package:flutter_test/flutter_test.dart';

/// R0: every parcel building faces its street (docs/plans/site-access.md
/// §5.1, the legacy heading rule of §3.1).
///
/// The generator's street face is local −Y (the front wall, bays and awnings
/// are all gated on it, and the massing's entrance sits at y = −depth/2), so
/// the snapshot's orientation must carry local −Y onto `Parcel.facing`, the
/// direction from the lot's centroid to its street. And it must be a turn,
/// not a mirror: where the site frame agrees with `Parcel.facing`, local +X
/// is the frame's `u`.
void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();

  /// Body-fixed to colony-local (east, north, up). `place` builds one tangent
  /// basis at the colony origin for every offset, so one conjugate serves
  /// every building in the colony.
  Quaternion colonyBasis(CitySim city) => const SurfacePlacement()
      .place(
        radius: city.body.radius,
        lat: city.cityLat * math.pi / 180.0,
        lon: city.cityLon * math.pi / 180.0,
      )
      .orientation;

  ({Vec2 front, Vec2 right, double upZ}) axesOf(
      CitySim city, BuildingSnapshot b) {
    final q = Quaternion(b.qw, b.qx, b.qy, b.qz);
    final toLocal = colonyBasis(city).conjugate;
    final front = toLocal.rotate(q.rotate(const Vector3(0, -1, 0)));
    final right = toLocal.rotate(q.rotate(Vector3.unitX));
    final up = toLocal.rotate(q.rotate(Vector3.unitZ));
    return (
      front: Vec2(front.x, front.y),
      right: Vec2(right.x, right.y),
      upZ: up.z,
    );
  }

  /// Checks one placed building against its lot, and returns whether the
  /// site frame agreed with `Parcel.facing` (so the handedness was checked).
  bool expectFacesStreet(
      CitySim city, Parcel parcel, BuildingSnapshot b, String label) {
    final a = axesOf(city, b);
    expect(a.upZ, closeTo(1, 1e-9), reason: '$label stands upright');
    expect(a.front.dot(parcel.facing), greaterThan(0.99),
        reason: '$label: local −Y must face the street '
            '(front ${a.front}, facing ${parcel.facing})');
    final frame = SiteFrame.of(
        parcel.polygon, parcel.frontage, city.layout.roadIndex);
    if (frame == null || frame.usedEffectiveFrontage) return false;
    // `Parcel.facing` runs centroid → frontage midpoint, so on a skewed lot
    // it leans off the frontage normal by the skew; "equal" within 0.5°.
    if (parcel.facing.dot(frame.v * -1) < 0.99996) return false;
    expect(a.right.dot(frame.u), greaterThan(0.99),
        reason: '$label: local +X must run along u (a turn, not a mirror)');
    return true;
  }

  group('the starter kit', () {
    late CitySim city;
    setUpAll(() {
      city = CityStarterKit.found(
        bodies: bodies,
        config: const CityConfig(bodyId: 'earth', gridSize: 20),
      );
    });

    test('pump, backwards pad, farm, solar field and warehouse lot', () {
      final built = city.parcelBuiltLots().toList();
      final types = {for (final (_, s) in built) s.type};
      expect(types, containsAll(['spaceport', 'solar', 'warehouse']));
      expect(built.length, 5, reason: 'four manual sites and the depot');
      var framed = 0;
      for (final (parcel, spec) in built) {
        final b = BuildingSnapshot.ofParcel(city, parcel, spec, city.body,
            siteRadiusM: city.body.radius);
        if (expectFacesStreet(city, parcel, b, '${spec.type} ${parcel.id}')) {
          framed++;
        }
      }
      // Every starter lot stores a frontage the frame uses as is.
      expect(framed, 5);
    });

    test('grid cells face their stored (north) frontage', () {
      const placement = SurfacePlacement();
      final heights = TerrainHeights();
      final specs = <CityBuildingSpec>[
        kZoneSpecs[CitySim.zoneKindOf(ParcelUse.residential)!]![Density.low]!,
        kUtilCatalog.firstWhere((s) => s.type == 'warehouse'),
      ];
      final half = city.grid ~/ 2;
      for (final spec in specs) {
        for (final cell in [
          (half + 3) + (half + 3) * city.grid,
          (half - 4) + (half + 2) * city.grid,
        ]) {
          final parcel = city.parcelForCell(cell, spec);
          final b = BuildingSnapshot.ofCityCell(
              city, cell, spec, city.body, placement, heights);
          final a = axesOf(city, b);
          expect(a.upZ, closeTo(1, 1e-9));
          expect(a.front.dot(parcel.facing), greaterThan(0.99),
              reason: 'cell $cell ${spec.type}: front ${a.front}, '
                  'facing ${parcel.facing}');
        }
      }
    });
  });

  test('a generated block: every built lot faces its street', () {
    final city = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 2, buildFraction: 1.0),
        bodies: bodies);
    final built = city.parcelBuiltLots().toList();
    expect(built, isNotEmpty);
    var framed = 0;
    for (final (parcel, spec) in built) {
      final b = BuildingSnapshot.ofParcel(city, parcel, spec, city.body,
          siteRadiusM: city.body.radius);
      if (expectFacesStreet(city, parcel, b, '${spec.type} ${parcel.id}')) {
        framed++;
      }
    }
    // Frontage-less generator lots (installations, megas) are checked
    // against `Parcel.facing` only; their turn is R4's (§3.1).
    final fronted = built.where((e) => e.$1.frontage != null).length;
    expect(framed, greaterThan(fronted ~/ 2));
  });
}
