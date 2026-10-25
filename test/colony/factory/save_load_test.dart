// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// A colony save holds every floor's full runtime state (§3
/// "Persistence"). Saving mid-run — items mid-belt, arms mid-swing,
/// workers mid-trip, a part-run sub-step in the carry — and loading must
/// continue exactly as if the game had never stopped, bit for bit, or a
/// reload would quietly change what a plant produces.
void main() {
  setUpAll(ensureFactoryCatalog);

  // Run on the Steel Mill template and on [busyPortFloor], a small floor
  // wired by machine ports whose handlers are guaranteed to be mid-trip at
  // the save (a jack clearing slag at a smelter's hand port, a crane
  // feeding a mill at its hand port), so the save always catches live
  // handler state whatever the template's own layout does.
  final floors = <String, FloorBlueprint Function()>{
    'steelmill': () => factoryTemplateFor('steelmill')!,
    'port floor': busyPortFloor,
  };

  test('save → load → step equals an uninterrupted run', () {
    for (final MapEntry(key: name, value: bp) in floors.entries) {
      final a = FactoryFloor.fromBlueprint(bp());
      final pa = InfiniteColonyPort();
      a.step(137.3, pa); // leaves 0.05 s in the sub-step carry

      final saved = jsonEncode(a.toJson());
      final snap = jsonDecode(saved) as Map<String, Object?>;
      expect(snap['cr'], isNot(0.0),
          reason: '$name: the remainder is part of it');
      expect(a.beltItems, isNotEmpty, reason: name);
      if (name == 'port floor') {
        expect(a.handlers.any((h) => h.state != HandlerState.idle), isTrue,
            reason: 'the save catches a worker mid-trip');
      }

      final b = FactoryFloor.fromJson(snap);
      expect(jsonEncode(b.toJson()), saved,
          reason: '$name: load is lossless');

      final pb = InfiniteColonyPort();
      for (var i = 0; i < 4; i++) {
        a.step(50.1, pa);
        b.step(50.1, pb);
      }
      expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()), reason: name);
      expect(pb.given, isNotEmpty, reason: name);
      if (name == 'port floor') {
        // The handler work is real: the jack ships the slag it cleared at
        // the hand port, the crane's billets become shipped bars.
        expect(a.ledger.shipped['slag'], greaterThan(0));
        expect(a.ledger.shipped['pigIron'], greaterThan(0));
        expect(a.ledger.shipped['steel'], greaterThan(0));
        expect(conservationError(b), isEmpty);
      }
    }
  });
}

/// A small floor wired by machine ports with handlers always at work (the
/// same layout as `dispatch_determinism_test.dart`'s):
///
/// * ore dock → belt → smelter (4×4 at (4, 1)) input port; pig iron out
///   its port belt, across an arm hop, to shipping; its slag port has no
///   belt, so a pallet jack clears the slag at the hand port (outside tile
///   (5, 0)) and walks it to a far shipping dock;
/// * billet dock → chest → crane → rolling mill (5×3 at (5, 8)) at its hand
///   port (7, 8), inside the crane bay; bars out the port belt to shipping.
FloorBlueprint busyPortFloor() {
  final l = Lay();
  l.add(EntityKind.receivingDock, 0, 2, item: 'ore');
  l.beltRow(2, 3, 2);
  l.add(EntityKind.machine, 4, 1,
      recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
  l.beltRow(8, 9, 2);
  l.add(EntityKind.arm, 10, 2);
  l.add(EntityKind.belt, 11, 2);
  l.add(EntityKind.shippingDock, 12, 2, item: 'pigIron');
  l.add(EntityKind.shippingDock, 20, 0, item: 'slag');
  l.add(EntityKind.receivingDock, 0, 9, item: 'steelBillet');
  l.add(EntityKind.chest, 2, 9);
  l.add(EntityKind.machine, 5, 8,
      recipe: SteelRecipes.roll.id, mode: MachineMode.assisted);
  l.add(EntityKind.belt, 10, 9);
  l.add(EntityKind.shippingDock, 11, 9);
  l.add(EntityKind.craneBay, 2, 8, span: (8, 3));
  return l.blueprint(24, 12,
      crew: {HandlerKind.palletJack: 1, HandlerKind.crane: 1});
}
