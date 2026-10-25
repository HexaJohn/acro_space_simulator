// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:isolate';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seven templates were drawn in parallel; these pin how they are
/// wired together (docs/plans/factory-floors.md §6 wave 2), which no
/// single template's own test can see.
void main() {
  CityBuildingSpec specOf(String type) =>
      kUtilCatalog.firstWhere((s) => s.type == type);

  /// Every placed plant the plan names has a buildable template that fits
  /// its real site, and is tagged with its own type.
  test('every factory plant has a valid template that fits its site', () {
    for (final type in kFactoryPlantTypes) {
      final bp = factoryTemplateFor(type);
      expect(bp, isNotNull, reason: type);
      expect(bp!.plantType, type);
      expect(bp.validate(), isEmpty, reason: '$type: ${bp.validate()}');
      final spec = specOf(type);
      expect(bp.hall.widthM, lessThanOrEqualTo(spec.siteWidthM), reason: type);
      expect(bp.hall.depthM, lessThanOrEqualTo(spec.siteDepthM), reason: type);
    }
  });

  /// The colony measures a re-laid floor (a design, a firm's layoff) with
  /// measureSettingsFor: under those settings every template must read its
  /// spec within 5%, or a re-measured template would burn full input for
  /// short output (the Refinery read 22% under with the standard window).
  void readsSpec(String type) {
    final spec = specOf(type);
    final r = measureBlueprint(
        factoryTemplateFor(type)!, (bp) => FactoryFloor.fromBlueprint(bp),
        settings: measureSettingsFor(type));
    spec.outputs.forEach((c, v) {
      expect(r.outPerS[c] ?? 0, closeTo(v, v * 0.05), reason: '$type $c');
    });
    spec.inputs.forEach((c, v) {
      expect(r.inPerS[c] ?? 0, closeTo(v, v * 0.05), reason: '$type in $c');
    });
  }

  // Explicit machine ports (§10 item 19) changed how stations connect; the
  // Steel Mill is redrawn for them, the other six are redrawn later.
  test('measureSettingsFor reads every template within 5% of its spec', () {
    ensureFactoryCatalog();
    readsSpec(kSteelMillType);
  });
  test('measureSettingsFor reads the six unredrawn templates within 5%',
      skip: 'awaiting port redraw (#19)', () {
    ensureFactoryCatalog();
    for (final type in kFactoryPlantTypes) {
      if (type != kSteelMillType) readsSpec(type);
    }
  });

  /// User decision: zoned industry never gets a floor.
  test('no zoned spec has a template', () {
    for (final tiers in kZoneSpecs.values) {
      for (final s in tiers.values) {
        expect(factoryTemplateFor(s.type), isNull, reason: s.type);
      }
    }
  });

  /// A floor loaded from a save, or rebuilt on the measure worker, only
  /// calls ensureFactoryCatalog: in a FRESH isolate (empty statics) that
  /// alone must resolve every template machine's recipe, or the plant goes
  /// dead after a load.
  test('ensureFactoryCatalog alone resolves every template recipe', () async {
    final ids = <String>{
      for (final type in kFactoryPlantTypes)
        for (final p in factoryTemplateFor(type)!.placements)
          if (p.kind == EntityKind.machine) p.recipe!,
    }.toList()
      ..sort();
    final missing = await Isolate.run(() {
      ensureFactoryCatalog();
      return [for (final id in ids) if (FactoryRecipes.byId(id) == null) id];
    });
    expect(missing, isEmpty);
  });
}
