// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A floor stays with ITS plant (docs/plans/factory-floors.md §3
/// "Persistence"): across `expandLand`, which renumbers every grid cell and
/// so every `cell-N` site id, and across a load, which must never let a
/// record run a plant it wasn't drawn for, and which re-seeds a template
/// from today's spec.
library;

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_colony_fixture.dart';

/// [sim] saved and loaded back, as a colony file would be.
CitySim reloaded(CitySim sim) => CitySim.fromJson(
      (jsonDecode(jsonEncode(sim.toJson())) as Map).cast<String, dynamic>(),
      bodies: fixtureBodies(),
    );

void main() {
  // The collision the descending order exists for: the rocket plant's NEW
  // id is the mill's OLD one (rekey(r·g + c) = r·g + c + 2r on a grid that
  // grows by two columns). Carried in the wrong order, or not at all, the
  // rocket plant would come to run the mill's blueprint — ore in, steel
  // out — and the mill would fall back to its flat recipe, design lost.
  test('expandLand carries every grid floor to its plant\'s new id', () {
    final sim = foundedColony()..funds = 1e9;
    final g = sim.grid;
    const row = 3, col = 1;
    final rocketCell = row * g + col;
    final millCell = rocketCell + 2 * row; // = rekey(rocketCell)
    sim.placeUtil(millCell, specOf('steelmill'));
    sim.placeUtil(rocketCell, specOf('rocketfactory'));
    final millOld = CitySim.siteIdOfCell(millCell);
    final rocketOld = CitySim.siteIdOfCell(rocketCell);
    expect(sim.factoryFloors[millOld]!.blueprint.plantType, 'steelmill');
    // The mill's floor is designed, owes ore and has books of its own.
    sim.factoryFloors[millOld]!.designed = true;
    sim.pendingFloorInvestment[millOld] = 7;
    sim.colonyEconomy.books[millOld] =
        FirmBook(owner: const Ownership.private('mill-firm'), cash: 123);

    sim.expandLand();
    expect(sim.grid, g + 2, reason: 'the land was bought');
    int rekey(int k) => (k ~/ g) * (g + 2) + k % g;
    final millNew = CitySim.siteIdOfCell(rekey(millCell));
    final rocketNew = CitySim.siteIdOfCell(rekey(rocketCell));
    expect(rocketNew, millOld, reason: 'the collision this test is about');
    expect(sim.siteSpec(millNew)?.type, 'steelmill');
    expect(sim.siteSpec(rocketNew)?.type, 'rocketfactory');

    final mill = sim.factoryFloors[millNew];
    expect(mill, isNotNull, reason: 'the mill\'s floor followed it');
    expect(mill!.blueprint.plantType, 'steelmill');
    expect(sim.floorIsDesigned(millNew), isTrue);
    expect(sim.pendingFloorInvestment[millNew], 7);
    expect(sim.colonyEconomy.books[millNew]?.cash, 123);
    expect(sim.factoryFloors[rocketNew]!.blueprint.plantType, 'rocketfactory',
        reason: 'the rocket plant kept its own floor, not the mill\'s');
    expect(sim.floorIsDesigned(rocketNew), isFalse);
    expect(sim.factoryFloors.siteIds.toSet(), {millNew, rocketNew});
    expect(sim.factoryFloors[rocketOld], isNull);
  });

  // However a record came to name the wrong building, a load must never
  // run it: dropped, and the plant gets its own template.
  test('a load replaces a record drawn for another plant', () {
    final sim = foundedColony();
    sim.placeUtil(5, specOf('rocketfactory'));
    final site = CitySim.siteIdOfCell(5);
    sim.factoryFloors
        .assign(site, factoryTemplateFor('steelmill')!, designed: true);
    final loaded = reloaded(sim);
    final rec = loaded.factoryFloors[site]!;
    expect(rec.blueprint.plantType, 'rocketfactory');
    expect(rec.designed, isFalse);
    expect(rec.rates.outPerS, flatRatesOf(specOf('rocketfactory')).outPerS);
  });

  // The template runs at TODAY's flat rate (the user's rule): a save made
  // before a balance change must not keep the old rates and layout.
  test('a template record is re-seeded from today\'s spec on load', () {
    final sim = foundedColony();
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    final rec = sim.factoryFloors[lot]!;
    rec.rates = const MeasuredRates(
        inPerS: {'ore': 9}, outPerS: {'steel': 9}, powerKw: 1, jobs: 1,
        seconds: 300);
    rec.blueprint.roster[HandlerKind.onFoot] = 99;
    final loaded = reloaded(sim).factoryFloors[lot]!;
    final flat = flatRatesOf(specOf('steelmill'));
    expect(loaded.rates.outPerS, flat.outPerS);
    expect(loaded.rates.inPerS, flat.inPerS);
    expect(loaded.rates.powerKw, flat.powerKw);
    expect(loaded.rates.jobs, flat.jobs);
    expect(loaded.blueprint.roster, factoryTemplateFor('steelmill')!.roster);
    expect(loaded.dirty, isFalse);
    expect(loaded.owner?.firmId, rec.owner?.firmId, reason: 'the owner stays');
  });

  // ...but a design, or a template a firm has cut (it hires them back on
  // recovery), is the plant's own state and stays as saved.
  test('a designed or laid-off record loads as saved', () {
    final sim = foundedColony();
    final a = placeOnFreeLot(sim, specOf('steelmill'));
    final b = placeOnFreeLot(sim, specOf('steelmill'));
    const odd = MeasuredRates(
        inPerS: {'ore': 1}, outPerS: {'steel': 1}, powerKw: 1, jobs: 1,
        seconds: 300);
    sim.factoryFloors[a]!
      ..rates = odd
      ..designed = true;
    sim.factoryFloors[b]!
      ..rates = odd
      ..dirty = false;
    sim.colonyEconomy.laidOff[b] = {HandlerKind.onFoot: 1};
    final loaded = reloaded(sim);
    expect(loaded.factoryFloors[a]!.rates.outPerS, odd.outPerS);
    expect(loaded.factoryFloors[b]!.rates.outPerS, odd.outPerS);
    expect(loaded.colonyEconomy.laidOff[b], {HandlerKind.onFoot: 1});
  });
}
