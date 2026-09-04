// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl's zoning: which mile square is which, from the seed and the
/// shape of the metro. The roads and the sections' own streets are plat,
/// laid by the generator — see sprawl_roads_test and sprawl_plat_test.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const spec = SprawlSpec(seed: 3, coreRadiusM: 1100);
  final plan = SprawlPlan.generate(spec);

  test('the same spec zones the same sprawl', () {
    final again = SprawlPlan.generate(spec);
    expect(again.sections.length, plan.sections.length);
    for (var i = 0; i < plan.sections.length; i++) {
      expect(again.sections[i].use, plan.sections[i].use);
      expect(again.sections[i].centre.e, plan.sections[i].centre.e);
    }
    // A different seed is a different city.
    final other = SprawlPlan.generate(const SprawlSpec(seed: 4, coreRadiusM: 1100));
    expect(
        other.sections.map((s) => s.use.index).join(),
        isNot(plan.sections.map((s) => s.use.index).join()));
  });

  test('twenty miles across: sections fill the outline past the core', () {
    expect(spec.milesAcross, closeTo(20, 1e-9));
    expect(plan.sections.length, greaterThan(250));
    for (final s in plan.sections) {
      expect(plan.outline.fractionOf(s.centre), lessThanOrEqualTo(1.1));
      expect(s.centre.length, greaterThan(spec.coreRadiusM));
    }
  });

  test('the outline is organic: lobed along the interstates, never a disc', () {
    final o = plan.outline;
    var lo = double.infinity, hi = 0.0;
    for (var i = 0; i < 64; i++) {
      final r = o.radiusAt(i / 64 * 2 * math.pi);
      lo = math.min(lo, r);
      hi = math.max(hi, r);
    }
    expect(hi / lo, greaterThan(1.25), reason: 'a disc has one radius');
    expect(lo, greaterThan(spec.radiusM * 0.55));
    expect(hi, lessThan(spec.radiusM * 1.55));
    var bulge = 0.0;
    for (final lobe in o.lobes) {
      bulge += o.radiusAt(lobe) -
          (o.radiusAt(lobe - 0.5) + o.radiusAt(lobe + 0.5)) / 2;
    }
    expect(bulge / o.lobes.length, greaterThan(spec.radiusM * 0.05));
    // The same outline every time, and the one the road layer uses.
    expect(SprawlPlan.outlineOf(spec).radiusAt(1.0), o.radiusAt(1.0));
  });

  test('farms at the edge, subdivisions in the middle, industry by the line',
      () {
    final outer = plan.sections.where((s) => plan.outline.fractionOf(s.centre) > 0.9);
    final farmsOut = outer.where((s) => s.use == SprawlUse.farmland).length;
    expect(farmsOut / outer.length, greaterThan(0.6));
    final inner = plan.sections.where((s) => plan.outline.fractionOf(s.centre) < 0.45);
    final homesIn = inner.where((s) => s.use == SprawlUse.residential).length;
    expect(homesIn / inner.length, greaterThan(0.4));
    final railSide = plan.sections.where((s) {
      final b = math.atan2(s.centre.n, s.centre.e);
      final d = (b - spec.railBearing).abs();
      return math.min(d, 2 * math.pi - d) < 0.5 && plan.outline.fractionOf(s.centre) < 0.8;
    });
    final industry = railSide.where((s) => s.use == SprawlUse.industrial).length;
    expect(industry / railSide.length, greaterThan(0.3));
  });

  test('commerce zones round the interchanges the roads put on the spec', () {
    // Eight residential sections in the middle of town become interchange
    // sites; most of them turn commercial.
    final sites = plan.sections
        .where((s) =>
            s.use == SprawlUse.residential &&
            plan.outline.fractionOf(s.centre) < 0.5)
        .take(8)
        .map((s) => s.centre)
        .toList();
    expect(sites.length, 8);
    final zoned = SprawlPlan.generate(
        spec.copyWith(interchanges: [for (final p in sites) [p.e, p.n]]));
    final commercial = zoned.sections
        .where((s) =>
            s.use == SprawlUse.commercial &&
            sites.any((p) => p.distanceTo(s.centre) < spec.sectionM * 0.9))
        .length;
    expect(commercial, greaterThan(0));
    expect(commercial, greaterThan(
        plan.sections
            .where((s) =>
                s.use == SprawlUse.commercial &&
                sites.any((p) => p.distanceTo(s.centre) < spec.sectionM * 0.9))
            .length));
  });

  test('a built section knows where its own collectors are', () {
    final built = plan.sections.firstWhere((s) => s.use == SprawlUse.residential);
    expect(built.streetsAcross, 12);
    expect(built.collectorOffsetsE, [-spec.sectionM / 4, spec.sectionM / 4]);
    expect(built.collectorOffsetsN, [-spec.sectionM / 4, spec.sectionM / 4]);
    expect(SprawlSection.collectorIndices(12), {3, 9});
    expect(SprawlSection.collectorIndices(8), {2, 6});
    expect(plan.sections.firstWhere((s) => s.use == SprawlUse.farmland).streetsAcross, 0);
  });

  test('the core outline is honoured: the sections meet it', () {
    // A ragged core: further east than north.
    final radii = [for (var i = 0; i < 16; i++) 900.0 + 300 * math.cos(i / 16 * 2 * math.pi)];
    final ragged = SprawlSpec(seed: 3, coreRadiusM: 1000, coreRadii: radii);
    expect(ragged.coreRadiusAt(0), closeTo(1200, 1e-9));
    expect(ragged.coreRadiusAt(math.pi), closeTo(600, 1e-9));
    // Interpolated between samples, not stepped.
    final between = ragged.coreRadiusAt(math.pi / 16);
    expect(between, lessThan(1200));
    expect(between, greaterThan(radii[1]));
    final p = SprawlPlan.generate(ragged);
    // The four sections round downtown are zoned.
    final central = p.sections.where((s) => s.centre.length < ragged.sectionM);
    expect(central.length, 4);
    expect(SprawlSpec.fromJson(ragged.toJson()), ragged);
  });

  test('the inner suburbs carry the plat\'s grid on: their streets are its '
      'lines, and their collectors are the lines nearest the quarter points',
      () {
    const withGrid = SprawlSpec(
      seed: 3,
      coreRadiusM: 1100,
      gridOriginE: -880,
      gridOriginN: -416,
      gridStepE: 220,
      gridStepN: 104,
      coreAvenuesE: [-880, -220, 440],
      coreAvenuesN: [-416, 0, 416],
      arteries: true,
    );
    final p = SprawlPlan.generate(withGrid);
    final inner = p.sections.where((s) => s.continuesCoreGrid).toList();
    final outer = p.sections.where((s) => !s.continuesCoreGrid && s.streetsAcross > 0);
    expect(inner, isNotEmpty);
    expect(outer, isNotEmpty);
    for (final s in inner) {
      final bearing = math.atan2(s.centre.n, s.centre.e);
      expect(s.centre.length - s.sizeM * math.sqrt2 / 2,
          lessThanOrEqualTo(withGrid.coreRadiusAt(bearing) + 300));
      for (final e in s.streetLinesE) {
        final abs = e + s.centre.e;
        final k = (abs - withGrid.gridOriginE) / withGrid.gridStepE;
        expect((k - k.round()).abs(), lessThan(1e-6));
        expect(withGrid.coreAvenuesE.any((a) => (a - abs).abs() < 1), isFalse);
      }
      for (final n in s.streetLinesN) {
        final abs = n + s.centre.n;
        final k = (abs - withGrid.gridOriginN) / withGrid.gridStepN;
        expect((k - k.round()).abs(), lessThan(1e-6));
      }
      for (final c in s.collectorOffsetsE) {
        expect(s.streetLinesE.contains(c), isTrue);
        expect((c.abs() - s.sizeM / 4).abs(), lessThan(withGrid.gridStepE));
      }
      for (final c in s.collectorOffsetsN) {
        expect(s.streetLinesN.contains(c), isTrue);
        expect((c.abs() - s.sizeM / 4).abs(), lessThan(withGrid.gridStepN));
      }
    }
    for (final s in outer) {
      expect(s.streetLinesE, isEmpty);
      expect(s.collectorOffsetsE, [-s.sizeM / 4, s.sizeM / 4]);
    }
    expect(SprawlSpec.fromJson(withGrid.toJson()), withGrid);
  });

  test('the spec survives a save, plots and interchanges included', () {
    const full = SprawlSpec(
      seed: 3,
      coreRadiusM: 1100,
      clearings: [
        [-2000.0, -2000.0, -1200.0, -2000.0, -1200.0, -1200.0, -2000.0, -1200.0]
      ],
      interchanges: [
        [4828.0, 0.0],
        [0.0, -4828.0]
      ],
      frontageRoads: [
        [56, -1040, 1040]
      ],
    );
    final back = SprawlSpec.fromJson(full.toJson());
    expect(back, full);
    expect(back.hashCode, full.hashCode);
    expect(full.inClearing(const Vec2(-1600, -1600)), isTrue);
    expect(full.inClearing(const Vec2(-1600, -2100)), isFalse);
    expect(full.inClearing(const Vec2(-1600, -2100), marginM: 150), isTrue);
    expect(back == spec, isFalse);
  });
}
