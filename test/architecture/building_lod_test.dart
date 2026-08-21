// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
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
        expect(block, lessThan(ext * 0.25),
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
}
