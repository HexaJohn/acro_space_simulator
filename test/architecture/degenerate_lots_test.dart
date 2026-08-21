// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every spec, on every plot size, in every kit — without throwing.
///
/// This exists because of a crash that no amount of looking at a normal city
/// would have found. A quarry's processing shed is sized as a FRACTION of its
/// plot, so on a small plot it comes out 0.72 m across; the masonry kit's
/// facade pass then tried to fit a 1.1 m brick pier into it, and the clamp
/// keeping that pier inside its own corner inverted its limits and threw.
///
/// The geometry pass runs for every archetype the colony builds, every frame
/// the colony's shape changes, so one unbuildable combination took down the
/// whole city's rendering — and reported itself only as
/// `Invalid argument(s): 0.29168808452431244` against the widget that happened
/// to wrap the scene.
///
/// A sweep is the right shape of test for this: the failure was not in any
/// particular building, it was in an ASSUMPTION (that a wall is wider than a
/// pier) that most inputs happen to satisfy.
void main() {
  final specs = <CityBuildingSpec>[
    for (final zone in kZoneSpecs.values) ...zone.values,
    ...kUtilCatalog,
  ];

  Parcel lot(double w, double d, {bool corner = false}) => Parcel(
        id: 'lot-${w}x$d',
        polygon: [
          Vec2(-w / 2, 0),
          Vec2(w / 2, 0),
          Vec2(w / 2, d),
          Vec2(-w / 2, d),
        ],
        frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
        sideStreet: corner ? (Vec2(w / 2, 0), Vec2(w / 2, d)) : null,
      );

  for (final style in ArchitectureStyle.kits) {
    test('${style.id}: no plot size can break the generator', () {
      final gen = const BuildingGenerator().withStyle(style);
      // Weighted toward the small end rather than swept uniformly. Every
      // failure of this kind lives down there — a plot that small is nonsense
      // and the generator still may not throw on it, because the archetype
      // library quantises real lots into buckets and a spec's own declared
      // site can cap one below anything the plat would ever cut. A uniform
      // sweep spent most of two minutes re-proving that 40x60 works.
      const sizes = [2.0, 3.0, 4.0, 5.0, 7.0, 10.0, 16.0, 30.0, 66.0];
      for (final spec in specs) {
        for (final w in sizes) {
          for (final d in sizes) {
            for (final corner in [false, true]) {
              final built = gen.generate(spec, lot(w, d, corner: corner),
                  seed: (w + d).round());
              for (final p in built.model.solid.positions) {
                expect(p.isFinite, isTrue,
                    reason: '${spec.type} on ${w}x$d produced $p');
              }
            }
          }
        }
      }
    });
  }

  test('a wall narrower than a pier is left solid, not articulated', () {
    // The invariant behind the fix, stated directly: below the threshold the
    // wall gets no openings and no piers rather than a pier that cannot fit.
    final gen =
        const BuildingGenerator().withStyle(ArchitectureStyle.masonryStreet);
    // A pit spec with NO staff and NO visitors, so it draws no car park.
    // Measured against a real one, the glazing channel also carries the car
    // park's lamp heads — and a lamp head is a box, so four of its six faces
    // have horizontal normals too. Filtering the output could not separate
    // them; controlling the input can.
    const pit = CityBuildingSpec(
      type: 'test-pit',
      label: 'Test Pit',
      colorArgb: 0,
      group: 'ind',
      siteKind: SiteKind.pit,
    );

    expect(gen.generate(pit, lot(4, 4)).massing.parking, isNull,
        reason: 'this spec must draw no car park, or it measures the lamps');
    expect(gen.generate(pit, lot(4, 4)).model.foliage.triangleCount, 0,
        reason: 'a sub-metre shed was given windows');
    expect(gen.generate(pit, lot(60, 60)).model.foliage.triangleCount,
        greaterThan(0),
        reason: 'the guard is swallowing ordinary buildings too');
  });

  test('every detail tier survives a degenerate plot', () {
    for (final detail in BuildingDetail.values) {
      for (final style in ArchitectureStyle.kits) {
        final gen = const BuildingGenerator().withStyle(style);
        for (final spec in specs) {
          gen.generate(spec, lot(2, 2), detail: detail);
        }
      }
    }
  });
}
