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

/// Measurement for this plant. Food arrives 500 units to a pallet (one
/// every 500 s) and rations leave 200 to a pallet (one every 250 s), so a
/// short window reads whole pallets, not a rate: 1200 s would see two or
/// three food pallets, ±20%. 20 000 s (40 food pallets, 80 ration pallets)
/// brings one pallet's quantisation under 2.5%. The 1500 s warm-up covers
/// the first depalletise (250 s), the kettles' first batches and the first
/// full ration pallet.
const MeasureSettings _settings = MeasureSettings(
    warmupS: 1500, windowS: 20000, subWindowS: 500, earlyStop: false);

MeasuredRates _measure(FloorBlueprint bp) =>
    measureBlueprint(bp, FactoryFloor.fromBlueprint, settings: _settings);

/// A designer's take on the template: the filling table moved between the
/// two kettles with an arm from each, so no one carries the pans at all,
/// and the pouches belt round to the same retort line. Same stations, same
/// modes — only the haul is engineered away.
FloorBlueprint _improved() {
  final t = rationsfactoryTemplate();
  final l = TemplateLayout();
  const y = 15; // the template's food row
  l.add(EntityKind.staging, 16, y + 8, span: (3, 2));
  l.add(EntityKind.receivingDock, 0, y + 1, item: 'crate:food');
  l.add(EntityKind.staging, 2, y, span: (2, 2));
  l.machine(8, y, RationsRecipes.depalletise);
  l.arm(11, y, Dir4.east);
  l.beltEast(12, 28, y);
  l.machine(16, y + 2, RationsRecipes.cook);
  l.arm(17, y + 1, Dir4.north);
  l.machine(25, y + 2, RationsRecipes.cook);
  l.arm(28, y + 1, Dir4.north);
  // The filler between the kettles; an arm from each feeds it pans.
  l.machine(21, y + 2, RationsRecipes.fill);
  l.arm(20, y + 2, Dir4.east);
  l.arm(24, y + 2, Dir4.west);
  // Pouches up and across to the retort.
  l.arm(22, y + 5, Dir4.north);
  l.beltRun(y + 6, 25, 22, Dir4.north);
  l.beltEast(22, 48, 26);
  l.arm(49, 26, Dir4.east);
  l.machine(50, 26, RationsRecipes.retort, mode: MachineMode.assisted);
  l.arm(54, 26, Dir4.east);
  l.machine(55, 26, RationsRecipes.pack);
  l.add(EntityKind.aisle, 58, 0, span: (2, t.hall.h));
  l.add(EntityKind.shippingDock, 60, 26, item: 'crate:rations');
  l.add(EntityKind.chargingBay, 60, 30);
  return FloorBlueprint(
    name: 'Rations Plant (designed)',
    plantType: kRationsType,
    hall: t.hall,
    placements: l.out,
    roster: {HandlerKind.palletJack: 1, HandlerKind.forklift: 1},
  );
}

void main() {
  late MeasuredRates base;

  setUpAll(() {
    base = _measure(rationsfactoryTemplate());
  });

  test('steady state is the spec rate within 5%, in commodity units', () {
    // Spec: 1.0 food → 0.8 rations per second. Pallets count their
    // commodity units at the docks, so these are colony units, not items.
    expect(_spec.inputs, {'food': 1.0});
    expect(_spec.outputs, {'rations': 0.8});
    expect(base.inPerS.keys, ['food'], reason: 'takes nothing but food');
    expect(base.outPerS.keys, ['rations'],
        reason: 'ships nothing but rations (the steam is vented)');
    expect(base.inPerS['food']!, closeTo(1.0, 0.05));
    expect(base.outPerS['rations']!, closeTo(0.8, 0.04));
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
    // The docks use the colony's own packs as they are.
    expect(identical(FactoryItems.byId('crate:food'), FactoryItems.crateFood),
        isTrue);
    expect(identical(
            FactoryItems.byId('crate:rations'), FactoryItems.crateRations),
        isTrue);
  });

  test('realistic: people and vehicles move the freight, not lights-out', () {
    // The user's brief: workers, jacks and forklifts move freight; very
    // few plants run from unloading to loading without anyone lifting a
    // finger. So every station is crewed, the docks are worked by
    // vehicles, and walkers really carry the pans.
    final bp = rationsfactoryTemplate();
    for (final p in bp.placements) {
      if (p.kind != EntityKind.machine) continue;
      expect(p.crew, isNot(MachineMode.automated), reason: '${p.recipe}');
    }
    expect(bp.placements.where((p) => p.kind == EntityKind.belt), isNotEmpty,
        reason: 'belts through the core where the flow is steady');
    expect(bp.roster.keys.toSet(),
        {HandlerKind.onFoot, HandlerKind.palletJack, HandlerKind.forklift});

    final floor = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    floor.step(1500, port);
    floor.takeLedger();
    var walkerCarried = false;
    for (var i = 0; i < 1000; i++) {
      floor.step(1, port);
      walkerCarried |= floor.handlers.any((h) =>
          h.kind == HandlerKind.onFoot &&
          h.state == HandlerState.carrying &&
          h.carrying == RationsItems.tray.id);
    }
    final l = floor.takeLedger();
    expect(walkerCarried, isTrue, reason: 'walkers carry the hot pans');
    expect(l.equipmentSeconds[HandlerKind.palletJack], greaterThan(0),
        reason: 'a jack takes food pallets from the receiving bay');
    expect(l.equipmentSeconds[HandlerKind.forklift], greaterThan(0),
        reason: 'a forklift takes ration pallets to the shipping door');
    expect(l.itemMetres, greaterThan(0));
    for (final p in floor.blueprint.placements) {
      if (p.recipe == null) continue;
      expect(floor.statusOf(p.id), isNot(MachineStatus.unstaffed));
    }
    // The kettles set the pace, so they never wait on the line.
    for (final p in floor.blueprint.placements) {
      if (p.recipe != RationsRecipes.cook.id) continue;
      expect(floor.statusOf(p.id), isNot(MachineStatus.starved));
    }
  });

  test('fine, not great: a designed floor beats it on labour', () {
    // The Reward lever (§3): engineer the pan haul away — the filler
    // between the kettles, fed by arms — and the same rations come out
    // with every walker freed for the rest of the colony.
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
    // measurement), and a mid-run save — pans in walkers' hands, food on
    // the belt — must resume bit for bit.
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
    // Pallets broken down, food cooked, steam vented: held + shipped −
    // received − what crafts made must stay zero, checked as it runs.
    final f = FactoryFloor.fromBlueprint(rationsfactoryTemplate());
    final port = InfiniteColonyPort();
    for (var i = 0; i < 40; i++) {
      f.step(100, port);
      expect(conservationError(f), isEmpty, reason: 'at ${f.simSeconds} s');
    }
    expect(port.given['rations'], greaterThan(0));
  });
}
