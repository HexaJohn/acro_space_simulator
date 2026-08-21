// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The style kit, checked on the things that actually make a street read as a
/// street rather than on triangle counts.
void main() {
  Parcel lot({double w = 22, double d = 30}) => Parcel(
        id: 'lot',
        polygon: [
          Vec2(-w / 2, 0),
          Vec2(w / 2, 0),
          Vec2(w / 2, d),
          Vec2(-w / 2, d),
        ],
        frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      );

  final shop = kZoneSpecs['commercial']![Density.medium]!;

  BuildingMassing massed(ArchitectureStyle style, {Parcel? on, int seed = 3}) =>
      BuildingMassingRules(style: style).massFor(shop, on ?? lot(), seed: seed);

  group('siting — the half of this that matters most', () {
    test('a street wall stands on its frontage; the office park does not', () {
      final wall = massed(ArchitectureStyle.masonryStreet);
      final park = massed(ArchitectureStyle.utilitarian);
      final ext = lot().buildableExtent;
      final curb = -ext.depth / 2;

      // Front face of the building, in lot-local metres.
      double front(BuildingMassing m) => m.volumes
          .where((v) => v.floors > 0)
          .map((v) => v.y - v.depth / 2)
          .reduce((a, b) => a < b ? a : b);

      expect(front(wall) - curb, lessThan(2.0),
          reason: 'a street wall meets the pavement');
      expect(front(park) - curb, greaterThan(6.0),
          reason: 'the setback style keeps its distance, as it always did');
    });

    test('a street wall fills its frontage, so neighbours meet', () {
      final wall = massed(ArchitectureStyle.masonryStreet);
      final park = massed(ArchitectureStyle.utilitarian);
      final ext = lot().buildableExtent;
      expect(wall.footprint.width, closeTo(ext.width, 0.01),
          reason: 'edge to edge is what a party wall IS');
      expect(park.footprint.width, lessThan(ext.width * 0.85));
    });

    test('the car park moves behind the building, not in front of it', () {
      final wall = massed(ArchitectureStyle.masonryStreet);
      final park = massed(ArchitectureStyle.utilitarian);
      // Both must actually have one, or this proves nothing.
      expect(wall.parking, isNotNull);
      expect(park.parking, isNotNull);
      final wallFront =
          wall.volumes.map((v) => v.y - v.depth / 2).reduce((a, b) => a < b ? a : b);
      final parkFront =
          park.volumes.map((v) => v.y - v.depth / 2).reduce((a, b) => a < b ? a : b);
      expect(wall.parking!.y, greaterThan(wallFront),
          reason: 'behind the building, off the alley');
      expect(park.parking!.y, lessThan(parkFront),
          reason: 'out front, which is exactly the strip-mall look');
    });

    test('a taller ground storey lifts the first floor, not the whole stack',
        () {
      final m = massed(ArchitectureStyle.masonryStreet);
      expect(m.groundStoreyM, greaterThan(m.storeyM));
      expect(m.floorBase(0), 0);
      expect(m.floorBase(1), closeTo(m.groundStoreyM, 1e-9));
      expect(m.floorBase(2), closeTo(m.groundStoreyM + m.storeyM, 1e-9));
    });
  });

  group('geometry', () {
    // Winding is measured against the RIBBON pass, which ships and renders
    // right way out. Asserting an absolute convention here would just record
    // whichever way I happened to write it; asserting agreement with working
    // geometry catches an inside-out wall.
    double opposingFraction(List<double> p, List<double> n, List<int> idx) {
      var against = 0, total = 0;
      for (var t = 0; t + 2 < idx.length; t += 3) {
        final a = idx[t] * 3, b = idx[t + 1] * 3, c = idx[t + 2] * 3;
        final e1 = [p[b] - p[a], p[b + 1] - p[a + 1], p[b + 2] - p[a + 2]];
        final e2 = [p[c] - p[a], p[c + 1] - p[a + 1], p[c + 2] - p[a + 2]];
        final wx = e1[1] * e2[2] - e1[2] * e2[1];
        final wy = e1[2] * e2[0] - e1[0] * e2[2];
        final wz = e1[0] * e2[1] - e1[1] * e2[0];
        final d = wx * n[a] + wy * n[a + 1] + wz * n[a + 2];
        if (d == 0) continue;
        total++;
        if (d < 0) against++;
      }
      return total == 0 ? -1 : against / total;
    }

    test('punched openings wind the same way the shipping glazing does', () {
      const gen = BuildingGenerator();
      final ribbon = gen.generate(shop, lot(), seed: 2).model.foliage;
      final punched = gen
          .withStyle(ArchitectureStyle.masonryStreet)
          .generate(shop, lot(), seed: 2)
          .model
          .foliage;

      final want =
          opposingFraction(ribbon.positions, ribbon.normals, ribbon.indices);
      expect(want, isNot(-1), reason: 'the reference produced no glazing');
      expect(
          opposingFraction(punched.positions, punched.normals, punched.indices),
          closeTo(want, 0.05),
          reason: 'the punched wall renders inside out');
    });

    test('every wall gets openings, not just two of the four', () {
      // The bug this guards is a winding or axis slip that silently drops one
      // face: count DISTINCT window planes instead of triangles, because a
      // missing wall still leaves plenty of triangles behind.
      final b = const BuildingGenerator()
          .withStyle(const ArchitectureStyle(
            id: 'test-all-faces',
            label: 'test',
            note: 'party walls off, so all four faces are glazed',
            frontSetbackM: 0,
            sideSetbackM: 0,
            rhythm: FacadeRhythm.punched,
          ))
          .generate(shop, lot());
      final normals = <String>{};
      final n = b.model.foliage.normals;
      for (var i = 0; i + 2 < n.length; i += 3) {
        normals.add('${n[i].round()},${n[i + 1].round()},${n[i + 2].round()}');
      }
      // Not an equality: the glazing channel also carries the lamp heads over
      // the car park, which face up.
      expect(normals,
          containsAll(<String>['0,-1,0', '0,1,0', '1,0,0', '-1,0,0']),
          reason: 'a wall lost its openings: $normals');
    });

    test('the cap and the roof are built, and stay inside the walls', () {
      final plain = const BuildingGenerator().generate(shop, lot(), seed: 5);
      final capped = const BuildingGenerator()
          .withStyle(ArchitectureStyle.masonryStreet)
          .generate(shop, lot(), seed: 5);

      expect(capped.model.solid.triangleCount,
          greaterThan(plain.model.solid.triangleCount * 1.5),
          reason: 'piers, cornice, parapet and roof plant are all geometry');

      // Roof plant must not push out through the parapet it hides behind.
      // The topmost OCCUPIED volume. Taking the tallest volume of any kind
      // picks the rooftop plant box on a stepped-back building, and then
      // "above the roof" is empty by construction and this proves nothing.
      final roofTop = capped.massing.volumes
          .where((v) => v.floors > 0)
          .map((v) => v.top)
          .reduce((a, b) => a > b ? a : b);
      final fp = capped.massing.footprint;
      final p = capped.model.solid.positions;
      var above = 0;
      for (var i = 0; i + 2 < p.length; i += 3) {
        if (p[i + 2] <= roofTop + 0.01) continue;
        above++;
        // The cornice oversails; nothing on the roof may.
        expect(p[i].abs(), lessThanOrEqualTo(fp.width / 2 + 0.01));
      }
      expect(above, greaterThan(0), reason: 'nothing was built on the roof');
    });
  });

  group('facade materials', () {
    test('a wall stays inside its own band of the atlas', () {
      // The atlas is one texture holding eight masonries side by side, so a
      // wall that lets its U wander outside its band samples the neighbouring
      // brick — and a mip level that reaches across the boundary does it at
      // distance even when the geometry is right. Both are why the band is
      // inset and why the face is subdivided instead of relying on wrap.
      for (final m in [0, 3, kFacadeMaterials - 1]) {
        final (u0, u1) = BuildingGenerator.bandUV(m);
        expect(u0, greaterThan(m / kFacadeMaterials));
        expect(u1, lessThan((m + 1) / kFacadeMaterials));
        expect(u1, greaterThan(u0));
      }
    });

    test('the geometry actually samples the band it was given', () {
      final built = const BuildingGenerator()
          .withStyle(ArchitectureStyle.masonryStreet)
          .generate(shop, lot(), seed: 4);
      final (u0, u1) = BuildingGenerator.bandUV(built.massing.material);
      final (p0, p1) =
          BuildingGenerator.bandUV(FacadeMaterial.precast);
      final t = built.model.solid.texCoords;
      expect(t, isNotEmpty);
      for (var i = 0; i + 1 < t.length; i += 2) {
        final u = t[i];
        final inWall = u >= u0 - 1e-6 && u <= u1 + 1e-6;
        final inPlant = u >= p0 - 1e-6 && u <= p1 + 1e-6;
        expect(inWall || inPlant, isTrue,
            reason: 'u=$u is outside both the wall band and the plant band');
      }
    });

    test('a masonry street is not all one colour; a works is', () {
      final wall = {
        for (var i = 0; i < 12; i++)
          BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
              .massFor(shop, lot(), seed: i)
              .material
      };
      expect(wall.length, greaterThan(2),
          reason: 'a street of one brick reads as one enormous building');

      final shed = kZoneSpecs['industrial']![Density.high]!;
      final industrial = {
        for (var i = 0; i < 12; i++)
          BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
              .massFor(shed, lot(w: 60, d: 60), seed: i)
              .material
      };
      expect(industrial.every((m) =>
          m == FacadeMaterial.precast || m == FacadeMaterial.metalPanel),
          isTrue,
          reason: 'a fabrication shed faced in terracotta is a bug, not a '
              'style: $industrial');
    });
  });

  group('the corner, and the top', () {
    Parcel cornerLot({double w = 22, double d = 30}) => Parcel(
          id: 'corner',
          polygon: [
            Vec2(-w / 2, 0),
            Vec2(w / 2, 0),
            Vec2(w / 2, d),
            Vec2(-w / 2, d),
          ],
          frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
          sideStreet: (Vec2(w / 2, 0), Vec2(w / 2, d)),
        );

    test('a corner building has no blank flank on its second street', () {
      // The masonry kit blanks its party walls, which is right in the middle
      // of a block and wrong on a corner: it would put a windowless brick wall
      // on a street.
      //
      // A warehouse, because it draws NO car park — and the car park's lamp
      // heads ride the same glazing channel the windows do, with a box's full
      // set of face normals. Measured on an ordinary spec this test passed
      // against the lamps rather than against the wall.
      final store =
          kUtilCatalog.firstWhere((s) => s.label == 'Warehouse');
      final mid = const BuildingGenerator()
          .withStyle(ArchitectureStyle.masonryStreet)
          .generate(store, lot());
      final corner = const BuildingGenerator()
          .withStyle(ArchitectureStyle.masonryStreet)
          .generate(store, cornerLot());
      expect(mid.massing.parking, isNull,
          reason: 'a car park here means this measures its lamps');

      Set<String> planes(dynamic mesh) {
        final n = mesh.normals as List<double>;
        return {
          for (var i = 0; i + 2 < n.length; i += 3)
            '${n[i].round()},${n[i + 1].round()},${n[i + 2].round()}'
        };
      }

      expect(planes(mid.model.foliage), isNot(contains('1,0,0')),
          reason: 'a mid-block party wall must stay blank');
      expect(planes(corner.model.foliage), contains('1,0,0'),
          reason: 'the corner never opened onto its second street');
    });

    test('a corner is the tall one on the block', () {
      final mid = BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
          .massFor(shop, lot(), seed: 2);
      final corner =
          BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
              .massFor(shop, cornerLot(), seed: 2);
      expect(corner.floors, greaterThanOrEqualTo(mid.floors));
      expect(corner.corner, isTrue);
      expect(mid.corner, isFalse);
    });

    test('cornices land on a shared datum, so a row has a level top', () {
      // Free-running floor counts come out of a division and land a metre or
      // two apart on every lot, which gives a block a ragged top edge that
      // none of the reference streets has. Quantising the COUNT is what makes
      // neighbours actually coincide.
      const style = ArchitectureStyle.masonryStreet;
      expect(style.corniceDatumFloors, greaterThan(1));
      final heights = <double>{};
      for (var i = 0; i < 14; i++) {
        final m = BuildingMassingRules(style: style)
            .massFor(shop, lot(w: 20 + i * 0.4), seed: i);
        if (m.floors > 2) heights.add(m.height.roundToDouble());
      }
      expect(heights.length, lessThan(6),
          reason: 'fourteen neighbours produced $heights distinct rooflines');
    });

    test('the utilitarian kit is left alone by all of it', () {
      // Every one of these is a masonry-kit decision. The office park must
      // come out exactly as it always did.
      const u = ArchitectureStyle.utilitarian;
      expect(u.corniceDatumFloors, 1);
      expect(u.awnings, isFalse);
      expect(u.fireEscapes, isFalse);
      expect(u.bayProjectionM, 0);
    });
  });

  group('height comes from the land, not from the tenant', () {
    // The regression this exists for: floors were derived purely from
    // required-floor-area over footprint. A "Business District" spec asks for
    // 60 jobs — 1,320 m² — which on a full-lot street-wall footprint is TWO
    // STOREYS, so a whole generated downtown came out two and three storeys
    // tall while looking arithmetically impeccable.
    final downtown = kZoneSpecs['commercial']![Density.high]!;
    final corner = kZoneSpecs['commercial']![Density.low]!;

    BuildingMassing mass(CityBuildingSpec spec, int seed) =>
        BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
            .massFor(spec, lot(), seed: seed);

    test('a business district lot is a tower, not a two-storey box', () {
      final floors = [for (var i = 0; i < 24; i++) mass(downtown, i).floors];
      floors.sort();
      final median = floors[floors.length ~/ 2];
      expect(median, greaterThan(18),
          reason: 'downtown came out $floors — the two-storey CBD is back');
      expect(floors.last, greaterThan(35),
          reason: 'nothing in the whole district actually towers');
    });

    test('and the bands step down: high over medium over low', () {
      int median(CityBuildingSpec s) {
        final f = [for (var i = 0; i < 24; i++) mass(s, i).floors]..sort();
        return f[f.length ~/ 2];
      }

      final high = median(downtown);
      final med = median(kZoneSpecs['commercial']![Density.medium]!);
      final low = median(corner);
      expect(high, greaterThan(med));
      expect(med, greaterThan(low));
      expect(low, lessThan(6), reason: 'a corner shop is not a mid-rise');
    });

    test('a downtown is not one extruded slab', () {
      // Every tower stopping at the same floor reads as a single block. The
      // spread is what makes a skyline.
      final floors = {for (var i = 0; i < 24; i++) mass(downtown, i).floors};
      expect(floors.length, greaterThan(6),
          reason: 'only ${floors.length} distinct heights downtown');
    });

    test('the same lot is the same height every time it is regenerated', () {
      expect(mass(downtown, 7).floors, mass(downtown, 7).floors);
      expect(mass(downtown, 7).floors, isNot(mass(downtown, 8).floors));
    });

    test('demand is a FLOOR under the zone target, never a ceiling', () {
      // A tiny lot cannot hold its tenant on the zone's target number of
      // floors, and must grow past it rather than be clamped to it.
      final tight =
          BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
              .massFor(kZoneSpecs['residential']![Density.high]!,
                  lot(w: 10, d: 12), seed: 1);
      final roomy =
          BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
              .massFor(kZoneSpecs['residential']![Density.high]!,
                  lot(w: 60, d: 60), seed: 1);
      expect(tight.floors, greaterThan(roomy.floors),
          reason: 'the same tenant on a quarter of the land must go up');
    });

    test('industry stays low, and the office park is left alone', () {
      final shed = BuildingMassingRules(style: ArchitectureStyle.masonryStreet)
          .massFor(kZoneSpecs['industrial']![Density.high]!, lot(w: 60, d: 60),
              seed: 3);
      expect(shed.floors, lessThanOrEqualTo(2),
          reason: 'a works does not become a tower because it is zoned high');

      // The setback kit sets no zone target at all, so it keeps the pure
      // demand-driven behaviour every existing test measures.
      expect(ArchitectureStyle.utilitarian.zoneFloors, isEmpty);
      expect(
          ArchitectureStyle.utilitarian.targetFloors(downtown, 1), 0);
    });
  });

  test('the kits are distinct and resolvable by id', () {
    expect(ArchitectureStyle.kits.map((s) => s.id).toSet().length,
        ArchitectureStyle.kits.length);
    for (final s in ArchitectureStyle.kits) {
      expect(ArchitectureStyle.byId(s.id), same(s));
    }
    expect(ArchitectureStyle.byId('nope'), ArchitectureStyle.utilitarian,
        reason: 'an unknown id must fall back, not throw, on a saved setting');
  });

  test('two styles are two archetypes, so a switch cannot serve stale mesh',
      () {
    final lib = BuildingLibrary(
        generator: const BuildingGenerator()
            .withStyle(ArchitectureStyle.masonryStreet));
    final other = BuildingLibrary(generator: const BuildingGenerator());
    final a = lib.get(shop, lot());
    final b = other.get(shop, lot());
    expect(a.model.solid.triangleCount,
        isNot(b.model.solid.triangleCount));
  });
}
