// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling_dispatch.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Floors are measured headless and re-run after load (§3 "Off-screen"),
/// so the same layout must always produce the same floor: two identical
/// floors stepped identically must print identical JSON, whatever chunks
/// the caller hands [FactoryFloor.step]. The dispatcher's tie-break (lowest
/// id) and its lift rule are pinned directly because they are where an
/// accidental hash-order or "close enough" handler would creep in.
void main() {
  setUpAll(ensureFactoryCatalog);

  // Each check runs on the Steel Mill template and on [busyPortFloor], a
  // small port-era floor whose handlers are guaranteed to be mid-trip (a
  // jack clearing a smelter's slag from its hand port, a crane feeding a
  // mill at its hand port), so the comparison always covers live handler
  // state whatever the template's own layout does.
  final floors = <String, FloorBlueprint Function()>{
    'steelmill': () => factoryTemplateFor('steelmill')!,
    'port floor': busyPortFloor,
  };

  test('identical floors stepped identically stay identical', () {
    for (final MapEntry(key: name, value: bp) in floors.entries) {
      final a = FactoryFloor.fromBlueprint(bp());
      final b = FactoryFloor.fromBlueprint(bp());
      final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
      for (var t = 0; t < 6; t++) {
        a.step(50, pa);
        b.step(50, pb);
        expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()),
            reason: '$name diverged by ${(t + 1) * 50} s');
      }
      if (name == 'port floor') {
        expect(a.handlers.any((h) => h.state != HandlerState.idle), isTrue,
            reason: 'the comparison covered handlers mid-trip');
      }
    }
  });

  test('the caller\'s step size never changes the result', () {
    for (final MapEntry(key: name, value: bp) in floors.entries) {
      final a = FactoryFloor.fromBlueprint(bp());
      final b = FactoryFloor.fromBlueprint(bp());
      final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
      for (var i = 0; i < 1200; i++) {
        a.step(0.25, pa); // 300 s in sub-steps
      }
      for (var i = 0; i < 40; i++) {
        b.step(7.5, pb); // 300 s in big frames
      }
      expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()), reason: name);
    }
  });

  test('dispatch: nearest capable handler, ties to the lowest id', () {
    FloorHandler h(int id) =>
        FloorHandler(id: id, kind: HandlerKind.onFoot, at: const TilePos(0, 0));
    final hs = [h(1), h(2), h(3)];
    final dist = {1: 5, 2: 3, 3: 3};
    final q = [
      MoveRequest(item: 'tubes', count: 2, from: 10, to: 20),
      MoveRequest(item: 'ore', count: 1, from: 10, to: 20),
    ];
    Dispatcher.assign(q, hs,
        distTo: (h, _) => dist[h.id]!, routable: (_, _, _) => true);
    expect(hs[1].job?.count, 1, reason: '#2 and #3 tie at 3 tiles: #2 wins');
    expect(hs[2].job?.count, 1, reason: 'the split remainder goes to #3');
    expect(hs[0].job, isNull,
        reason: 'ore is a pallet load: the worker on foot is never sent');
    expect(q.single.item, 'ore', reason: 'it waits for a jack or forklift');
  });
}

/// A small floor wired by machine ports with handlers always at work:
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
