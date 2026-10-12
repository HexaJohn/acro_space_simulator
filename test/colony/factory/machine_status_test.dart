// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// A machine's status drives the editor's bottleneck overlay (§4), so each
/// one must mean exactly what it says: starved (no input), blocked (output
/// full), unstaffed (crew not there), unpowered (no power) and working.
/// Staffing is handed out by placement id and a station short of its full
/// crew does not run — partial crews are not a thing.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Dock → belt → smelter, with nothing clearing the smelter's output.
  (Lay, int) fedSmelter({MachineMode mode = MachineMode.assisted}) {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    l.beltRow(2, 3, 1);
    final m = l.add(EntityKind.machine, 4, 0,
        recipe: SteelRecipes.smelt.id, mode: mode);
    return (l, m);
  }

  test('starved, then working, then blocked', () {
    final l = Lay();
    final lone = l.add(EntityKind.machine, 0, 0,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
    final f0 = FactoryFloor.fromBlueprint(l.blueprint(6, 6));
    f0.step(5, InfiniteColonyPort());
    expect(f0.statusOf(lone), MachineStatus.starved);
    expect(f0.powerDemandKw, 0, reason: 'a starved station draws nothing');

    final (lay, m) = fedSmelter();
    final floor = FactoryFloor.fromBlueprint(lay.blueprint(10, 5));
    final port = InfiniteColonyPort();
    floor.step(8, port);
    expect(floor.statusOf(m), MachineStatus.working);
    expect(floor.powerDemandKw, greaterThan(SteelRecipes.smelt.powerKw));
    floor.step(60, port);
    expect(floor.statusOf(m), MachineStatus.blocked,
        reason: 'two crafts fill the output buffer and nothing clears it');
    expect(floor.contentsOf(m)['pigIron'], 2 * 3);
  });

  test('unstaffed when the colony cannot crew it, by placement id', () {
    final l = Lay();
    final a = l.add(EntityKind.machine, 0, 0,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.manual);
    final b = l.add(EntityKind.machine, 5, 0,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.manual);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(10, 5));
    expect(floor.jobDemand, 4);

    floor.step(1, StockColonyPort(staffingShare: 0));
    expect(floor.statusOf(a), MachineStatus.unstaffed);
    expect(floor.statusOf(b), MachineStatus.unstaffed);

    floor.step(1, StockColonyPort(staffingShare: 0.5));
    expect(floor.statusOf(a), MachineStatus.starved,
        reason: 'two of four jobs filled: the lower id gets its full crew');
    expect(floor.statusOf(b), MachineStatus.unstaffed);

    floor.step(1, StockColonyPort(staffingShare: 0.7));
    expect(floor.statusOf(b), MachineStatus.unstaffed,
        reason: 'floor(4 × 0.7) = 2: a station never runs short-handed');
  });

  test('unpowered with no power; a brownout slows the craft', () {
    final (lay, m) = fedSmelter();
    final floor = FactoryFloor.fromBlueprint(lay.blueprint(10, 5));
    floor.step(10, StockColonyPort(stock: {'ore': 100}, powerShare: 0));
    expect(floor.statusOf(m), MachineStatus.unpowered);

    // Same feed at full and half power: the half-power smelter finishes
    // its first craft later.
    double firstCraftAt(double share) {
      final (lay, m) = fedSmelter();
      final f = FactoryFloor.fromBlueprint(lay.blueprint(10, 5));
      final port = StockColonyPort(stock: {'ore': 100}, powerShare: share);
      while ((f.contentsOf(m)['pigIron'] ?? 0) == 0) {
        f.step(0.25, port);
        if (f.simSeconds > 120) break;
      }
      return f.simSeconds;
    }

    final full = firstCraftAt(1), half = firstCraftAt(0.5);
    expect(half - full, closeTo(SteelRecipes.smelt.seconds, 0.5),
        reason: 'a 4 s craft takes 8 s at half power');
  });
}
