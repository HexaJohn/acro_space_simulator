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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Floors are measured headless and re-run after load (§3 "Off-screen",
/// "Persistence"), so vehicles must be as deterministic as walkers: two
/// identical mixed fleets print identical JSON, and a save taken with a
/// forklift on charge, another mid-trip and a crane mid-lift continues
/// bit for bit as if the game had never stopped.
void main() {
  setUpAll(ensureFactoryCatalog);

  const kPortMillHall = HallSize(28, 10);
  const kPortMillWalkers = 2;

  /// A compact port-correct steel line (the Steel Mill template's chain on
  /// a 28 × 10 hall), laid here so this test doesn't hang on the template's
  /// layout. Every machine faces east (ports per `station_ports.dart`):
  /// ore belts into the smelter's input port; pig iron leaves its front
  /// port by belt into the furnace; its slag port belts round into the tube
  /// press. The crane carries billets furnace → mill between their hand
  /// ports in one bay; steel belts mill → packer; the forklift clears steel
  /// crates from the packer's hand port (worked from the aisle) to the
  /// dock; walkers clear the press's tubes from its hand port to shipping.
  FloorBlueprint portMill() {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 3, item: 'ore');
    l.beltRow(2, 3, 3); // → smelter input (4, 3)
    l.add(EntityKind.machine, 4, 2, recipe: SteelRecipes.smelt.id);
    l.beltRow(8, 9, 3); // pig iron (7, 3) → furnace input (10, 3)
    l.add(EntityKind.machine, 10, 2,
        recipe: SteelRecipes.cast.id, mode: MachineMode.assisted);
    l.add(EntityKind.machine, 15, 2,
        recipe: SteelRecipes.roll.id, mode: MachineMode.assisted);
    // Hand ports (11, 2) and (17, 2) and their outside tiles under the hook.
    l.add(EntityKind.craneBay, 10, 1, span: (10, 4));
    l.add(EntityKind.belt, 20, 3); // steel (19, 3) → packer input (21, 3)
    l.add(EntityKind.machine, 21, 2, recipe: SteelRecipes.packSteel.id);
    // The packer's hand port (22, 2) is worked from (22, 1) on the aisle.
    l.add(EntityKind.aisle, 20, 0, span: (8, 2));
    l.add(EntityKind.chargingBay, 24, 2);
    l.add(EntityKind.shippingDock, 26, 2);
    // Slag (6, 5) → north, then east into the press input (8, 7).
    l.add(EntityKind.belt, 6, 6, dir: Dir4.north);
    l.beltRow(6, 7, 7);
    l.add(EntityKind.machine, 8, 6, recipe: SteelRecipes.tube.id);
    l.add(EntityKind.shippingDock, 12, 6); // tubes, walked from (9, 5)
    return FloorBlueprint(
      name: 'Port Mill',
      hall: kPortMillHall,
      placements: l.out,
      roster: {
        HandlerKind.onFoot: kPortMillWalkers,
        HandlerKind.forklift: 1,
        HandlerKind.crane: 1,
      },
    );
  }

  /// [portMill] plus a jack and an AGV: every kind on one floor.
  FactoryFloor mixed() {
    final f = FactoryFloor.fromBlueprint(portMill());
    expect(f.hire(HandlerKind.palletJack, 1).ok, isTrue);
    expect(f.hire(HandlerKind.agv, 1).ok, isTrue);
    return f;
  }

  test('two identical mixed fleets stay identical', () {
    final a = mixed(), b = mixed();
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    for (var t = 0; t < 8; t++) {
      a.step(40, pa);
      b.step(40, pb);
      expect(
        jsonEncode(a.toJson()),
        jsonEncode(b.toJson()),
        reason: 'diverged by ${(t + 1) * 40} s',
      );
    }
    expect({for (final h in a.handlers) h.kind}, HandlerKind.values.toSet());
  });

  test('save mid-charge, mid-trip and mid-lift → identical continuation', () {
    final f0 = mixed();
    final port = InfiniteColonyPort();
    f0.step(200, port);
    // Run the first forklift nearly flat so it charges soon.
    final j = f0.toJson();
    final forklift = (j['h'] as List).cast<Map<String, Object?>>().firstWhere(
      (h) => h['k'] == HandlerKind.forklift.name,
    );
    forklift['bt'] = 80.0;
    final a = FactoryFloor.fromJson(
      jsonDecode(jsonEncode(j)) as Map<String, Object?>,
    );

    bool caught() {
      final hs = a.handlers.toList();
      final charging = hs.any((h) => h.state == HandlerState.charging);
      final lifting = hs.any(
        (h) => h.kind == HandlerKind.crane && h.state == HandlerState.carrying,
      );
      final driving = hs.any(
        (h) =>
            (h.kind == HandlerKind.forklift || h.kind == HandlerKind.agv) &&
            h.state != HandlerState.idle &&
            h.state != HandlerState.charging,
      );
      return charging && lifting && driving;
    }

    while (!caught()) {
      a.step(kFactoryStepS, port);
      expect(a.simSeconds, lessThan(600), reason: 'never caught all three');
    }
    a.step(0.1, port); // and a part-run sub-step in the carry
    final saved = jsonEncode(a.toJson());
    final b = FactoryFloor.fromJson(jsonDecode(saved) as Map<String, Object?>);
    expect(jsonEncode(b.toJson()), saved, reason: 'load is lossless');
    final pb = InfiniteColonyPort();
    for (var i = 0; i < 6; i++) {
      a.step(33.3, port);
      b.step(33.3, pb);
      expect(
        jsonEncode(b.toJson()),
        jsonEncode(a.toJson()),
        reason: 'diverged ${(i + 1) * 33.3} s after the load',
      );
    }
  });
}
