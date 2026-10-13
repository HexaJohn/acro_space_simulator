// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_vehicles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Lights-out is not free (§3 "Stations: manned vs automated"): an
/// automated station needs a share of a technician, and those technicians
/// are real jobs the colony must staff. Without them the station wears out
/// and breaks down; with them it is repaired and runs again. All of it a
/// plain accumulator — no RNG — so a floor's breakdowns replay exactly.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Dock → belt → automated smelter → arm → shipping: it runs flat out.
  (FactoryFloor, int) autoSmelter() {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    l.beltRow(2, 3, 1);
    final m = l.add(
      EntityKind.machine,
      4,
      0,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.automated,
    );
    l.add(EntityKind.arm, 8, 1);
    l.add(EntityKind.shippingDock, 9, 1);
    l.add(EntityKind.arm, 8, 2);
    l.add(EntityKind.shippingDock, 9, 2);
    return (FactoryFloor.fromBlueprint(l.blueprint(12, 5)), m);
  }

  test('technicians are job demand, booked as maintenance', () {
    final (f, _) = autoSmelter();
    expect(
      f.jobDemand,
      MachineMode.automated.maintenance,
      reason: 'no crew, a quarter technician',
    );
    f.step(10, StockColonyPort(stock: {'ore': 1000}));
    expect(
      f.ledger.workerSeconds[WorkRole.maintenance],
      closeTo(2.5, 1e-9),
      reason: 'a quarter technician for ten seconds',
    );
  });

  test('unmaintained it breaks down; a technician repairs it', () {
    final (f, m) = autoSmelter();
    final noTech = StockColonyPort(stock: {'ore': 1e6}, staffingShare: 0);
    var workedS = 0.0;
    while (f.statusOf(m) != MachineStatus.broken) {
      f.step(kFactoryStepS, noTech);
      if (f.statusOf(m) == MachineStatus.working) workedS += kFactoryStepS;
      expect(
        f.simSeconds,
        lessThan(4 * kWearToBreakS),
        reason: 'it must break down eventually',
      );
    }
    expect(
      workedS,
      closeTo(kWearToBreakS, kFactoryStepS),
      reason: 'it broke after $kWearToBreakS s of unmaintained running',
    );

    // Broken: no crafts, however long, while nobody fixes it.
    final made = f.craftNet['pigIron'] ?? 0;
    f.step(120, noTech);
    expect(f.statusOf(m), MachineStatus.broken);
    expect(f.craftNet['pigIron'] ?? 0, made);

    // A technician on hand: repaired after kRepairS, then it runs again.
    final staffed = StockColonyPort(stock: {'ore': 1e6});
    f.step(kRepairS - 1, staffed);
    expect(f.statusOf(m), MachineStatus.broken, reason: 'still in repair');
    f.step(2, staffed);
    expect(f.statusOf(m), isNot(MachineStatus.broken));
    f.step(60, staffed);
    expect(
      f.craftNet['pigIron'] ?? 0,
      greaterThan(made),
      reason: 'repaired, it smelts again',
    );
    // Maintained, it never breaks again.
    f.step(4 * kWearToBreakS, staffed);
    expect(f.statusOf(m), isNot(MachineStatus.broken));
    expect(conservationError(f), isEmpty);
  });

  test('the breakdown and repair survive a save mid-repair', () {
    final (f, m) = autoSmelter();
    final noTech = StockColonyPort(stock: {'ore': 1e6}, staffingShare: 0);
    f.step(3 * kWearToBreakS, noTech);
    expect(f.statusOf(m), MachineStatus.broken);
    final staffed = StockColonyPort(stock: {'ore': 1e6});
    f.step(kRepairS / 2, staffed);
    final g = FactoryFloor.fromJson(f.toJson());
    g.step(kRepairS, staffed);
    f.step(kRepairS, staffed);
    expect(g.toJson(), f.toJson());
    expect(g.statusOf(m), isNot(MachineStatus.broken));
  });
}
