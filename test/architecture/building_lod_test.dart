// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Detail tiers that are actually worth switching between.
void main() {
  final gen =
      const BuildingGenerator().withStyle(ArchitectureStyle.masonryStreet);
  Parcel lot(double w, double d) => Parcel(
        id: 'l',
        polygon: [
          Vec2(-w / 2, 0),
          Vec2(w / 2, 0),
          Vec2(w / 2, d),
          Vec2(-w / 2, d)
        ],
        frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      );

  int tris(CityBuildingSpec spec, BuildingDetail d) =>
      gen.generate(spec, lot(24, 42), detail: d, seed: 3).model.triangleCount;

  group('a tier has to earn its place', () {
    // The regression this guards: `exterior` used to drop only the interior
    // slabs, which nobody can see and which cost almost nothing. A tower was
    // 2,846 triangles at full and 2,418 at exterior — a 15% saving on the tier
    // that is supposed to carry most of a city. Everything expensive on a
    // masonry facade is the ARTICULATION, and it was surviving into a tier
    // meant to be cheap.
    for (final (label, spec) in [
      ('tower', kZoneSpecs['commercial']![Density.high]!),
      ('apartments', kZoneSpecs['residential']![Density.medium]!),
      ('house', kZoneSpecs['residential']![Density.low]!),
    ]) {
      test('$label: each tier is meaningfully cheaper than the last', () {
        final full = tris(spec, BuildingDetail.full);
        final ext = tris(spec, BuildingDetail.exterior);
        final block = tris(spec, BuildingDetail.block);

        expect(ext, lessThan(full * 0.8),
            reason: 'exterior saves only ${(100 - ext / full * 100).round()}% '
                '— not worth a second batch');
        // 0.3, not 0.25: the block tier now carries per-storey window bands
        // (two triangles per face per storey) so distant towers light their
        // windows at night. That is a deliberate spend, and it is bounded —
        // the silhouette plus its bands must still be a fraction of the
        // exterior shell.
        expect(block, lessThan(ext * 0.3),
            reason: 'the far tier must be a silhouette, not a building');
        expect(block, greaterThan(0), reason: 'something must still be drawn');
      });
    }

    test('the near tier keeps the ornament the whole kit exists for', () {
      // The other half of the invariant: cheapening `exterior` must not have
      // cheapened `full` with it, or the street loses its awnings and fire
      // escapes at every distance.
      final spec = kZoneSpecs['commercial']![Density.medium]!;
      expect(tris(spec, BuildingDetail.full),
          greaterThan(tris(spec, BuildingDetail.exterior)));
    });
  });

  group('which tier a building gets', () {
    test('is its OWN distance, not the colony\'s nearest', () {
      // Chosen once for a whole colony, from whichever building happened to be
      // nearest, standing in a city built every tower in it at full detail —
      // including the ones two kilometres away covering four pixels.
      expect(CityNodes.tierForDistance(10), BuildingDetail.full);
      expect(CityNodes.tierForDistance(CityNodes.interiorRangeM + 1),
          BuildingDetail.exterior);
      expect(CityNodes.tierForDistance(CityNodes.blockRangeM + 1),
          BuildingDetail.block);
    });

    test('the ranges are ordered, so every tier is reachable', () {
      expect(CityNodes.interiorRangeM, lessThan(CityNodes.blockRangeM));
    });

    test('per-building LOD is on, and the visualiser is off, by default', () {
      expect(CityNodes.perBuildingLod, isTrue);
      expect(CityNodes.lodDebug, isFalse,
          reason: 'a debug view must never be what ships');
    });
  });

  group('the camera has to be in the building\'s own frame', () {
    // The bug this exists for: a building's px/py/pz are BODY-FIXED metres, a
    // few thousand from the planet's centre, while the camera is in world
    // space — about 1.5e11 m from the origin for anything orbiting the Sun.
    // Subtracting one from the other is not a distance, it is the radius of
    // the orbit, so every building in every colony resolved to the coarsest
    // tier the moment per-building LOD was switched on.
    final bodyWorld = Vector3(1.47e11, 3.2e10, 0);
    final spin = Quaternion.axisAngle(Vector3.unitZ, 1.1);

    // Ranges PINNED, not read from the shipped defaults. What these check is
    // the frame conversion — that a camera 60 m from a building measures
    // 60 m and not the radius of the planet's orbit. Written against the
    // live values they were hostage to a tuning change: dropping the shipped
    // interior range to 50 m made "standing next to it" the exterior tier,
    // and both failed for a reason that had nothing to do with frames.
    late double savedInterior, savedBlock;
    setUp(() {
      savedInterior = CityNodes.interiorRangeM;
      savedBlock = CityNodes.blockRangeM;
      CityNodes.interiorRangeM = 600;
      CityNodes.blockRangeM = 3500;
    });
    tearDown(() {
      CityNodes.interiorRangeM = savedInterior;
      CityNodes.blockRangeM = savedBlock;
    });

    BuildingSnapshot at(Vector3 bf) => BuildingSnapshot(
          id: 'b',
          type: 'c-high',
          colonyId: 'c',
          body: 'earth',
          px: bf.x,
          py: bf.y,
          pz: bf.z,
          qw: 1,
          qx: 0,
          qy: 0,
          qz: 0,
          lat: 0,
          lon: 0,
          siteWidthM: 20,
          siteDepthM: 20,
          siteKindIndex: 0,
          colorArgb: 0,
        );

    test('a camera standing next to a building reads as NEXT TO it', () {
      final standing = Vector3(6.371e6, 0, 0);
      final cameraWorld = bodyWorld + spin.rotate(standing + Vector3(60, 0, 0));
      final focusBF = CityNodes.focusInBodyFrame(cameraWorld, bodyWorld, spin);

      expect((focusBF - standing).length, closeTo(60, 1e-3),
          reason: 'the frame conversion is wrong: got ${focusBF - standing}');
      expect(CityNodes.detailFor(at(standing), focusBF, BuildingDetail.block),
          BuildingDetail.full);
    });

    test('and one across the city reads as across the city', () {
      final standing = Vector3(6.371e6, 0, 0);
      final cameraWorld = bodyWorld + spin.rotate(standing);
      final focusBF = CityNodes.focusInBodyFrame(cameraWorld, bodyWorld, spin);

      final near = at(standing + Vector3(0, 100, 0));
      final mid = at(standing + Vector3(0, CityNodes.interiorRangeM + 200, 0));
      final far = at(standing + Vector3(0, CityNodes.blockRangeM + 500, 0));
      expect(CityNodes.detailFor(near, focusBF, BuildingDetail.block),
          BuildingDetail.full);
      expect(CityNodes.detailFor(mid, focusBF, BuildingDetail.block),
          BuildingDetail.exterior);
      expect(CityNodes.detailFor(far, focusBF, BuildingDetail.full),
          BuildingDetail.block);
    });

    test('turning it off falls back to the colony tier, whatever the frame',
        () {
      addTearDown(() => CityNodes.perBuildingLod = true);
      CityNodes.perBuildingLod = false;
      expect(
          CityNodes.detailFor(
              at(Vector3(6.371e6, 0, 0)), Vector3.zero, BuildingDetail.exterior),
          BuildingDetail.exterior);
    });
  });
}

// NOT TESTED HERE: that toggling the visualiser invalidates the uploaded mesh
// cache. That was the bug behind "amber never shows".
//
// `_uploaded` is keyed by `BuildingArchetype`, which carries the detail tier
// but says nothing about whether an entry is a real building or a debug box.
// The rebuild key does carry `lodDebug`, so the toggle rebuilds — but the
// rebuild fills its batches with `putIfAbsent`, which returns whatever was
// already cached. Only archetypes never meshed before the toggle got a box,
// and the studio frames a colony at the exterior tier, so those were exactly
// the ones already cached as real buildings. Red and green appeared on the
// way in and out because those archetypes were new; the middle tier stayed
// real geometry. `lodCounts` reported the tiers correctly the whole time,
// which is what makes it worth writing down: the tiers were never wrong, the
// PICTURE was stale.
//
// Not reachable from a unit test — `CityNodes` needs an `fs.Scene`, and that
// throws without the Impeller GPU backend. Guarded by review: anything cached
// under an archetype key has to be invalidated when a flag outside that key
// changes what gets built.
