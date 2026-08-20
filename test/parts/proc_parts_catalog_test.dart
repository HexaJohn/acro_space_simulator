// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/parts/proc_parts.dart';
import 'package:acro_space_simulator/domain/parts/proc_shape.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_primitives_category.dart';
import 'package:flutter_test/flutter_test.dart';

/// The procedural family's CATALOG DATA: the contracts that make a generated
/// part behave like any other part everywhere else in the app, none of which
/// is visible in review.
///
/// The two that matter most: spec == size (the drawn box, the declared box and
/// the editor's picked box are one box only because these are pinned equal),
/// and derived tank arithmetic (capacity and dry mass are the FL-T400's
/// densities through each tank's true volume — a hand-edited number that
/// quietly makes one tank better per cubic metre than the rest of the roster
/// fails here instead of shipping as a balance bug).
void main() {
  final catalog = PartCatalog.standard();

  test('every ProcParts def is registered, procedural, and bake-free', () {
    expect(ProcParts.all, isNotEmpty);
    for (final def in ProcParts.all) {
      expect(catalog.byId(def.id), isNotNull,
          reason: '${def.id} is not in the standard catalog');
      expect(def.procShape, isNotNull,
          reason: '${def.id} is in the procedural family with no ProcShape');
      expect(def.modelAsset, isNull,
          reason: '${def.id} declares a bake; a part is baked or generated, '
              'never both');
    }
  });

  test('family ids collide with nothing else in the roster', () {
    // PartCatalog maps by id, so a collision does not fail — it silently
    // REPLACES the earlier part. Count survival proves uniqueness.
    final family = ProcParts.ids;
    final inCatalog =
        catalog.all.where((p) => family.contains(p.id)).length;
    expect(inCatalog, family.length);
    expect(family.length, ProcParts.all.length,
        reason: 'two family parts share an id');
  });

  test('spec extent equals declared size, so the drawn box is the picked box',
      () {
    for (final def in ProcParts.all) {
      final e = def.procShape!.extentM;
      expect(e.x, def.size.x, reason: '${def.id} X');
      expect(e.y, def.size.y, reason: '${def.id} Y');
      expect(e.z, def.size.z, reason: '${def.id} Z');
      // And therefore the renderer's stand-in scale is exactly 1: the mesh is
      // generated at true size and drawn untouched.
      final s = PartPrimitivesByCategory.standInScaleM(def);
      expect(s.x, closeTo(1, 1e-9), reason: '${def.id} scale X');
      expect(s.y, closeTo(1, 1e-9), reason: '${def.id} scale Y');
      expect(s.z, closeTo(1, 1e-9), reason: '${def.id} scale Z');
    }
  });

  test('tank capacity and dry mass are FL-T400 densities, not invention', () {
    // The reference the whole stock roster flies with.
    final flT400 = catalog.byId('fl-t400')!;
    final flVol = math.pi * 0.625 * 0.625 * 1.9;
    final flUnits = flT400.resources.fold(0.0, (s, r) => s + r.capacity);
    final unitsPerM3 = flUnits / flVol;
    final dryPerM3 = flT400.dryMass / flVol;

    double volumeOf(ProcShape s) => switch (s) {
          ProcSphere p => math.pi / 6 * math.pow(p.diameterM, 3).toDouble(),
          ProcPill p => math.pi *
                  (p.diameterM / 2) *
                  (p.diameterM / 2) *
                  (p.lengthM - p.diameterM) +
              math.pi / 6 * math.pow(p.diameterM, 3).toDouble(),
          _ => fail('not a tank shape'),
        };

    final tanks =
        ProcParts.all.where((p) => p.category == PartCategory.fuelTank);
    expect(tanks, isNotEmpty);
    for (final def in tanks) {
      final vol = volumeOf(def.procShape!);
      final units = def.resources.fold(0.0, (s, r) => s + r.capacity);
      expect(units / vol, closeTo(unitsPerM3, unitsPerM3 * 0.02),
          reason: '${def.id} holds a different density than the FL-T400');
      expect(def.dryMass / vol, closeTo(dryPerM3, dryPerM3 * 0.02),
          reason: '${def.id} walls weigh differently than the FL-T400\'s');
      final lf = def.resources
          .firstWhere((r) => r.type == ResourceType.liquidFuel)
          .capacity;
      expect(lf / units, closeTo(180 / 400, 0.005),
          reason: '${def.id} drifted off the FL-T400 45/55 split');
    }
  });

  test('plates carry the armor flag their name promises', () {
    ProcPlate plateOf(String id) =>
        catalog.byId(id)!.procShape! as ProcPlate;
    expect(plateOf('plate-1m').armor, isFalse);
    expect(plateOf('plate-2m').armor, isFalse);
    expect(plateOf('armor-plate-2m').armor, isTrue);
    // Armor is also the family's one heat-rated part: it exists to face
    // things the skin cannot.
    expect(catalog.byId('armor-plate-2m')!.maxTemperature,
        greaterThan(catalog.byId('plate-2m')!.maxTemperature));
  });
}
