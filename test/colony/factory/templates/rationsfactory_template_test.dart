// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_capex.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/template_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rationsfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

/// The flat-rate spec the template must reproduce.
final CityBuildingSpec _spec =
    kUtilCatalog.firstWhere((s) => s.type == kRationsType);

/// The spec's long measurement: 300 s warm-up, a full 1200 s window, no
/// early stop — the floor's settled rate.
const MeasureSettings _long =
    MeasureSettings(warmupS: 300, windowS: 1200, earlyStop: false);

MeasuredRates _measure(FloorBlueprint bp,
        {MeasureSettings settings = _long}) =>
    measureBlueprint(bp, FactoryFloor.fromBlueprint, settings: settings);

/// The template with a different crew [roster], for headcount sweeps.
FloorBlueprint _withRoster(Map<HandlerKind, int> roster) {
  final t = rationsfactoryTemplate();
  return FloorBlueprint(
      name: t.name,
      plantType: t.plantType,
      hall: t.hall,
      placements: t.placements,
      roster: roster);
}

/// A designer's take on the template: the case carriers replaced by a dock
/// conveyor and a short belt with an arm into each kettle. Same stations,
/// same modes, same forklift — only the receiving labour is engineered
/// away (and paid for in conveyor capex).
FloorBlueprint _improved() {
  final t = rationsfactoryTemplate();
  final l = TemplateLayout();
  // The dock unloads onto a belt along the kettles' north side.
  l.add(EntityKind.receivingDock, 0, 11, item: 'food');
  l.beltEast(2, 4, 11);
  l.arm(2, 10, Dir4.south); // into kettle A
  l.machine(1, 6, RationsRecipes.cook);
  l.arm(5, 7, Dir4.east);
  l.machine(6, 10, RationsRecipes.cook);
  l.arm(5, 11, Dir4.east); // belt end into kettle B
  l.arm(7, 9, Dir4.south);
  l.machine(6, 6, RationsRecipes.fill);
  l.add(EntityKind.aisle, 9, 2, span: (2, 7));
  l.add(EntityKind.chargingBay, 11, 6);
  l.machine(11, 2, RationsRecipes.retort);
  l.arm(12, 1, Dir4.south);
  l.add(EntityKind.shippingDock, 12, 0, item: 'rations');
  return FloorBlueprint(
    name: 'Rations Plant (designed)',
    plantType: kRationsType,
    hall: t.hall,
    placements: l.out,
    roster: {HandlerKind.forklift: 1},
  );
}

void main() {
  late MeasuredRates base;

  setUpAll(() {
    base = _measure(rationsfactoryTemplate());
  });

  test('steady state is the spec rate within 5%, in commodity units', () {
    // Spec: 1.0 food → 0.8 rations per second, over the spec's ≥ 300 s
    // warm-up and ≥ 1200 s window.
    expect(_spec.inputs, {'food': 1.0});
    expect(_spec.outputs, {'rations': 0.8});
    expect(base.inPerS.keys, ['food'], reason: 'takes nothing but food');
    expect(base.outPerS.keys, ['rations'],
        reason: 'ships nothing but rations (the steam is vented)');
    expect(base.inPerS['food']!, closeTo(1.0, 0.05));
    expect(base.outPerS['rations']!, closeTo(0.8, 0.04));
  });

  test('the colony\'s own measurement reads the spec rate too', () {
    // The colony measures every assigned floor with
    // MeasureSettings.standard (one minute of warm-up from an empty floor,
    // at most five minutes measured). A template that is only on spec over
    // hours would change what the colony gets the moment its floor is
    // opened — a pallet-lumped version read 3.3 food/s in and no rations
    // out here.
    final r = _measure(rationsfactoryTemplate(),
        settings: MeasureSettings.standard);
    expect(r.inPerS.keys, ['food']);
    expect(r.outPerS.keys, ['rations']);
    expect(r.inPerS['food']!, closeTo(1.0, 0.05), reason: '${r.inPerS}');
    expect(r.outPerS['rations']!, closeTo(0.8, 0.04), reason: '${r.outPerS}');
  });

  test('jobs and build cost match the spec within 10%', () {
    // Opening the floor must not change the plant's place in the colony's
    // labour and ore budgets.
    expect(base.jobs, closeTo(_spec.jobs, _spec.jobs * 0.1));
    expect(capexOf(rationsfactoryTemplate()).total,
        closeTo(_spec.buildCost, _spec.buildCost * 0.1));
  });

  test('a valid hall that fits the site and is plant-sized', () {
    final bp = rationsfactoryTemplate();
    expect(bp.validate(), isEmpty);
    expect(bp.plantType, kRationsType);
    expect(bp.hall.widthM, lessThanOrEqualTo(_spec.siteWidthM));
    expect(bp.hall.depthM, lessThanOrEqualTo(_spec.siteDepthM));
    // A real food-packing hall: bigger than a shed, smaller than the lot
    // (the yard, truck apron and parking take the rest).
    expect(bp.hall.areaM2, inInclusiveRange(4000, 20000));
    expect(identical(rationsfactoryTemplate(), rationsfactoryTemplate()),
        isFalse, reason: 'each call is a fresh blueprint the caller may edit');
  });

  test('the chain registers idempotently, under its own prefix only', () {
    // The template, a save loader and the editor may all register it;
    // parallel chains must never collide on an unprefixed id.
    registerRationsChain();
    registerRationsChain();
    for (final i in RationsItems.all) {
      expect(i.id, startsWith('rationsfactory:'));
      expect(identical(FactoryItems.byId(i.id), i), isTrue);
    }
    for (final r in RationsRecipes.all) {
      expect(r.id, startsWith('rationsfactory:'));
      expect(identical(FactoryRecipes.byId(r.id), r), isTrue);
    }
    // The docks use the colony's own goods as they are.
    expect(identical(FactoryItems.byId('food'), FactoryItems.food), isTrue);
    expect(
        identical(FactoryItems.byId('rations'), FactoryItems.rations), isTrue);
  });

  test('realistic: people and vehicles move the freight, not lights-out', () {
    // The user's brief: workers and vehicles move freight; very few plants
    // run from unloading to loading without anyone lifting a finger. So
    // every station is crewed, people carry the cases in, and the forklift
    // does a real share of work, not a token hop.
    final bp = rationsfactoryTemplate();
    for (final p in bp.placements) {
      if (p.kind != EntityKind.machine) continue;
      expect(p.crew, isNot(MachineMode.automated), reason: '${p.recipe}');
    }
    expect(bp.roster.keys.toSet(), {HandlerKind.onFoot, HandlerKind.forklift});

    final floor = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    floor.step(300, port);
    floor.takeLedger();
    const window = 1200;
    var walkerCarried = false;
    final working = <int, int>{};
    for (var i = 0; i < window; i++) {
      floor.step(1, port);
      walkerCarried |= floor.handlers.any((h) =>
          h.kind == HandlerKind.onFoot &&
          h.state == HandlerState.carrying &&
          h.carrying == FactoryItems.food.id);
      for (final p in floor.blueprint.placements) {
        if (p.recipe == null) continue;
        expect(floor.statusOf(p.id), isNot(MachineStatus.unstaffed));
        if (floor.statusOf(p.id) == MachineStatus.working) {
          working[p.id] = (working[p.id] ?? 0) + 1;
        }
      }
    }
    final l = floor.takeLedger();
    expect(walkerCarried, isTrue, reason: 'walkers carry the food cases');
    // Each vehicle earns its place: the forklift drives carts for a real
    // share of the window (measured ~30%), not the <1% of a one-tile hop.
    for (final k in bp.roster.keys) {
      if (k == HandlerKind.onFoot) continue;
      expect(l.equipmentSeconds[k] ?? 0, greaterThan(0.15 * window),
          reason: '$k: ${l.equipmentSeconds}');
    }
    // Every station's crew is at work for a real share of the time.
    for (final p in floor.blueprint.placements) {
      if (p.recipe == null) continue;
      expect(working[p.id] ?? 0, greaterThan(0.4 * window),
          reason: '${p.recipe} #${p.id}');
    }
  });

  test('no padded headcount: one carrier fewer falls short', () {
    // Every carrier is needed: the walk from the cold store is tuned so
    // eight carry ~0.94 food/s and only nine hold the spec's 1.0. A
    // template that held the rate with fewer would be padding its jobs.
    final short = _measure(_withRoster({
      HandlerKind.onFoot: kRationsWalkers - 1,
      HandlerKind.forklift: kRationsForklifts,
    }));
    expect(short.inPerS['food']!, lessThan(0.97),
        reason: '${short.inPerS} with ${kRationsWalkers - 1} carriers');
    expect(base.inPerS['food']!, greaterThan(0.99));
  });

  test('fine, not great: a designed floor beats it on labour', () {
    // The Reward lever (§3): replace the case carriers with a dock
    // conveyor and arms, and the same rations come out with half the
    // workforce freed for the rest of the colony.
    final bp = _improved();
    expect(bp.validate(), isEmpty);
    final r = _measure(bp);
    expect(r.outPerS['rations']!,
        greaterThanOrEqualTo(base.outPerS['rations']! * 0.98),
        reason: '${r.outPerS} vs ${base.outPerS}');
    expect(r.inPerS['food']!, lessThanOrEqualTo(base.inPerS['food']! * 1.02),
        reason: 'no more food for it');
    expect(r.jobs, lessThanOrEqualTo(base.jobs * 0.85),
        reason: '${r.jobs} jobs against the template\'s ${base.jobs}');
  });

  test('deterministic, and save/load mid-run continues identically', () {
    // Two builds must measure the same (aggregate mode caches the
    // measurement), and a mid-run save — cases in carriers' hands, a cart
    // on the forklift — must resume bit for bit.
    final again = _measure(rationsfactoryTemplate());
    expect(jsonEncode(again.toJson()), jsonEncode(base.toJson()));

    final a = FactoryFloor.fromBlueprint(rationsfactoryTemplate());
    final pa = InfiniteColonyPort();
    a.step(1234.3, pa);
    final saved = jsonEncode(a.toJson());
    final b = FactoryFloor.fromJson(jsonDecode(saved) as Map<String, Object?>);
    expect(jsonEncode(b.toJson()), saved, reason: 'load is lossless');
    // Fresh tallies on both sides from the save on.
    final pa2 = InfiniteColonyPort(), pb = InfiniteColonyPort();
    for (var i = 0; i < 6; i++) {
      a.step(250.1, pa2);
      b.step(250.1, pb);
    }
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(pb.given, pa2.given);
    expect(pb.taken, pa2.taken);
    expect(pb.given, isNotEmpty);
  });

  test('conserves every commodity unit over its own run', () {
    // Cases carried, food cooked, steam vented: held + shipped − received
    // − what crafts made must stay zero, checked as it runs.
    final f = FactoryFloor.fromBlueprint(rationsfactoryTemplate());
    final port = InfiniteColonyPort();
    for (var i = 0; i < 40; i++) {
      f.step(100, port);
      expect(conservationError(f), isEmpty, reason: 'at ${f.simSeconds} s');
    }
    expect(port.given['rations'], greaterThan(0));
  });
}
