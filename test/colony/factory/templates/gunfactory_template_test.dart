// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/application/factory/floor_measure_runner_isolate.dart';
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
import 'package:acro_space_simulator/domain/colony/city/factory/templates/gunfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

/// The Arms Factory template is that plant's regression test
/// (docs/plans/factory-floors.md §3 "Templates"): opening its floor must
/// not change what the colony gets from it, what it costs to build, or how
/// many people it employs. Every figure is read from the spec itself, so a
/// retuned spec fails here until the template follows it.
CityBuildingSpec get _spec =>
    kUtilCatalog.firstWhere((s) => s.type == kArmsType);

/// Measured the way the colony must measure this plant
/// ([kArmsMeasureSettings]): the template's promise is about THAT reading,
/// so the test uses the same settings, not hand-picked longer ones.
MeasuredRates _measure(
  FloorBlueprint bp, [
  MeasureSettings settings = kArmsMeasureSettings,
]) => measureBlueprint(
  bp,
  _build,
  port: InfiniteColonyPort(),
  settings: settings,
);

/// Top-level so it can cross to a measurement worker isolate.
FactorySim _build(FloorBlueprint bp) => FactoryFloor.fromBlueprint(bp);

/// Each spec rate (inputs and outputs) against [r], as relative errors.
Map<String, double> _errors(MeasuredRates r) => {
  for (final e in {..._spec.inputs, ..._spec.outputs}.entries)
    e.key: ((r.inPerS[e.key] ?? r.outPerS[e.key] ?? 0) - e.value) / e.value,
};

void main() {
  // The template floor's measurement is shared by the tests that read it.
  late final MeasuredRates rates = _measure(gunfactoryTemplate());

  test('the chain registers once, under its own prefix only', () {
    // Parallel chains share one item and recipe registry: an id outside
    // the 'gunfactory:' prefix would collide with another plant's.
    registerArmsChain();
    registerArmsChain();
    for (final i in ArmsItems.all) {
      expect(i.id, startsWith('gunfactory:'));
      expect(identical(FactoryItems.byId(i.id), i), isTrue);
    }
    for (final r in ArmsRecipes.all) {
      expect(r.id, startsWith('gunfactory:'));
      expect(identical(FactoryRecipes.byId(r.id), r), isTrue);
      // Colony goods are the shared FactoryItems, never redefined here.
      for (final q in [...r.inputs, ...r.outputs]) {
        if (q.item.startsWith('gunfactory:')) continue;
        expect(const [
          'steel',
          'crate:steel',
          'electronics',
          'guns',
          'crate:guns',
          'ammo',
          'crate:ammo',
        ], contains(q.item));
      }
    }
  });

  test('steady state is the spec rate within 5%, and nothing else', () {
    // Commodity units: a steel crate counts as ten steel, an ammo pallet
    // as fifty ammo. Swarf, cases and bullets never leave the plant.
    final spec = _spec;
    expect(
      rates.inPerS.keys.toSet(),
      spec.inputs.keys.toSet(),
      reason: 'takes nothing but ${spec.inputs.keys}: ${rates.inPerS}',
    );
    expect(
      rates.outPerS.keys.toSet(),
      spec.outputs.keys.toSet(),
      reason: 'ships nothing but ${spec.outputs.keys}: ${rates.outPerS}',
    );
    spec.inputs.forEach(
      (c, v) => expect(rates.inPerS[c]!, closeTo(v, v * 0.05), reason: 'in $c'),
    );
    spec.outputs.forEach(
      (c, v) =>
          expect(rates.outPerS[c]!, closeTo(v, v * 0.05), reason: 'out $c'),
    );
  });

  test('any reasonable warm-up and window reads the spec within 5%', () {
    // The floor ships in lumps (a 50-round pallet, a 10-gun case) and has
    // no exact cycle, so a reading that only passes on one hand-picked,
    // lump-aligned window proves little. Sweep misaligned warm-ups (the
    // floor settles by ~180 s) against windows of 1800 s and more — one
    // pallet is under 3% of those — plus the plan's own minimum (300 s
    // warm-up, 1200 s window), where one pallet is 4.2% and the margin is
    // thinnest. A floor still filling its belts (the old 1.2 blanks/s saw
    // took ~600 s) reads its fill as intake and fails here.
    for (final (warm, win) in [
      (180.0, 1800.0),
      (kArmsMeasureSettings.warmupS, kArmsMeasureSettings.windowS),
      (263.0, 1837.0),
      (317.0, 1871.0),
      (409.0, 2003.0),
      (300.0, 1200.0),
    ]) {
      final r = _measure(
        gunfactoryTemplate(),
        MeasureSettings(warmupS: warm, windowS: win, earlyStop: false),
      );
      _errors(r).forEach(
        (c, e) => expect(e.abs(), lessThan(0.05), reason: '$c at $warm/$win'),
      );
    }
  });

  test('the colony\'s standard measurement is too short for this floor', () {
    // Why kArmsMeasureSettings exists (library doc, "Measuring it"): from
    // a cold start the first ammo pallet can't leave before ~200 s, and the
    // belts are still filling after the standard 60 s warm-up, so the
    // standard 300 s reading is far off. If this ever reads within 5%, the
    // floor settles fast enough for the standard settings: drop
    // kArmsMeasureSettings and this test with it.
    final std = _measure(gunfactoryTemplate(), MeasureSettings.standard);
    expect(
      _errors(std).values.any((e) => e.abs() > 0.05),
      isTrue,
      reason: '${std.inPerS} ${std.outPerS}',
    );
    // And the documented settings cost no more than ~7x the standard run:
    // affordable on the measurement worker.
    expect(
      kArmsMeasureSettings.warmupS + kArmsMeasureSettings.windowS,
      lessThanOrEqualTo(
        7 *
            (MeasureSettings.standard.warmupS +
                MeasureSettings.standard.windowS),
      ),
    );
  });

  test(
    'a fresh worker isolate measures it, with or without the chain setup',
    () async {
      // The off-thread runner builds floors in an isolate whose registries
      // start empty and are filled only by ensureFactoryCatalog. Since the
      // wiring, that call registers every template chain, so the bare runner
      // and one given registerArmsChain as setup must both measure it.
      final bare = PlatformFloorMeasureRunner(_build);
      addTearDown(bare.dispose);
      final unset = await bare
          .measure(gunfactoryTemplate(), settings: MeasureSettings.standard)
          .then<MeasuredRates?>((r) => r, onError: (Object _) => null);
      // Wired (wave 2): ensureFactoryCatalog registers every template
      // chain, so a bare worker already knows the 'gunfactory:*' recipes.
      expect(unset?.outPerS['guns'] ?? 0, greaterThan(0),
          reason: 'ensureFactoryCatalog brings every chain to the worker');

      final runner = PlatformFloorMeasureRunner(
        _build,
        setup: registerArmsChain,
      );
      addTearDown(runner.dispose);
      final r = await runner.measure(
        gunfactoryTemplate(),
        settings: kArmsMeasureSettings,
      );
      expect(jsonEncode(r.toJson()), jsonEncode(rates.toJson()));
    },
  );

  test('jobs and build cost are the spec\'s', () {
    // Stamping the template must not change staffing or the ore a colony
    // pays to place the plant (within the plan's 10%).
    final spec = _spec;
    expect(rates.jobs, closeTo(spec.jobs, spec.jobs * 0.1));
    final capex = capexOf(gunfactoryTemplate());
    expect(
      capex.total,
      closeTo(spec.buildCost, spec.buildCost * 0.1),
      reason: '$capex',
    );
  });

  test('the hall fits the site and is a believable building', () {
    // A hall bigger than the site can't be stamped; a tiny one would be a
    // toy. 60-250 m a side is a real machining hall.
    final bp = gunfactoryTemplate();
    final spec = _spec;
    expect(bp.validate(), isEmpty);
    expect(bp.hall.widthM, lessThanOrEqualTo(spec.siteWidthM));
    expect(bp.hall.depthM, lessThanOrEqualTo(spec.siteDepthM));
    expect(bp.hall.widthM, inInclusiveRange(60, 250));
    expect(bp.hall.depthM, inInclusiveRange(40, 250));
    expect(bp.plantType, kArmsType);
    expect(
      identical(gunfactoryTemplate(), gunfactoryTemplate()),
      isFalse,
      reason: 'each call is a fresh blueprint the caller may edit',
    );
  });

  test('people and vehicles share the freight; nothing is lights-out', () {
    // The user's brief: workers on their own or with forklifts and cranes,
    // and very few plants run from unloading to loading untouched.
    final bp = gunfactoryTemplate();
    final machines = [
      for (final p in bp.placements)
        if (p.kind == EntityKind.machine) p,
    ];
    expect(machines.where((p) => p.crew == MachineMode.automated), isEmpty);
    expect(
      machines.where((p) => p.crew == MachineMode.manual).length,
      greaterThan(machines.length ~/ 2),
    );
    expect(machines.where((p) => p.crew == MachineMode.assisted), isNotEmpty);
    expect(bp.roster.keys.toSet(), {
      HandlerKind.onFoot,
      HandlerKind.forklift,
      HandlerKind.crane,
    });

    // The steel dock is manual: bundles are set down in a staging yard
    // (the crane's), not dropped onto a conveyor.
    final dock = bp.placements.firstWhere(
      (p) => p.kind == EntityKind.receivingDock && p.item == 'crate:steel',
    );
    expect(dock.dir, Dir4.east);
    final front = TilePos(dock.footprint.x1, dock.footprint.y0);
    expect(
      bp.placements.any(
        (p) => p.kind == EntityKind.staging && p.footprint.contains(front),
      ),
      isTrue,
    );

    final floor = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    floor.step(600, port);
    floor.takeLedger();
    floor.step(600, port);
    final l = floor.takeLedger();
    expect(
      l.itemMetres,
      greaterThan(0),
      reason: 'walkers carry the swarf and the gun cases',
    );
    expect(
      l.equipmentSeconds[HandlerKind.forklift],
      greaterThan(0),
      reason: 'a forklift drives the ammo pallets',
    );
    expect(
      l.equipmentSeconds[HandlerKind.crane],
      greaterThan(0),
      reason: 'the crane lifts the steel bundles',
    );
    for (final p in machines) {
      expect(floor.statusOf(p.id), isNot(MachineStatus.unstaffed));
      expect(floor.statusOf(p.id), isNot(MachineStatus.broken));
    }
  });

  test('a better design beats it: same output, far fewer jobs', () {
    // "Fine, not great" (§3 Reward): one operator per station instead of
    // a manual pair — the fitting bench excepted, it sets the pace — and
    // the nine walkers it really needs: 23 jobs against 35 (34% fewer) for
    // the same guns and ammo, past the >= 15% the plan asks: the labour
    // lever exists.
    final bp = gunfactoryTemplate();
    for (var i = 0; i < bp.placements.length; i++) {
      final p = bp.placements[i];
      if (p.kind != EntityKind.machine || p.recipe == ArmsRecipes.fit.id) {
        continue;
      }
      bp.placements[i] = p.copyWith(mode: MachineMode.assisted);
    }
    bp.roster[HandlerKind.onFoot] = 9;
    final better = _measure(bp);
    expect(
      better.jobs,
      lessThanOrEqualTo(rates.jobs * 0.85),
      reason: '${better.jobs} jobs against ${rates.jobs}',
    );
    for (final c in _spec.outputs.keys) {
      expect(
        better.outPerS[c]!,
        greaterThanOrEqualTo(rates.outPerS[c]! * 0.98),
        reason: '$c: ${better.outPerS[c]} vs ${rates.outPerS[c]}',
      );
    }
  });

  test('deterministic, and save/load mid-run continues bit for bit', () {
    // Two builds must measure identically (aggregate mode re-measures
    // off-thread), and a colony save must not change what a plant makes.
    final a = FactoryFloor.fromBlueprint(gunfactoryTemplate());
    final b = FactoryFloor.fromBlueprint(gunfactoryTemplate());
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    a.step(437.3, pa);
    b.step(437.3, pb);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));

    final saved = jsonEncode(a.toJson());
    expect(
      a.handlers.any((h) => h.state != HandlerState.idle),
      isTrue,
      reason: 'the save catches a worker mid-trip',
    );
    final c = FactoryFloor.fromJson(jsonDecode(saved) as Map<String, Object?>);
    expect(jsonEncode(c.toJson()), saved, reason: 'load is lossless');
    final pc = InfiniteColonyPort();
    for (var i = 0; i < 6; i++) {
      a.step(50.1, pa);
      c.step(50.1, pc);
    }
    expect(jsonEncode(c.toJson()), jsonEncode(a.toJson()));
    expect(pc.given, isNotEmpty, reason: 'the reloaded plant ships');
  });

  test('conserves every commodity unit over its own run', () {
    // Crates unpacked at the saw, swarf pressed to bullets, rounds
    // palletised: every unit in is on the floor, crafted away or shipped.
    final f = FactoryFloor.fromBlueprint(gunfactoryTemplate());
    final port = InfiniteColonyPort();
    for (var i = 0; i < 12; i++) {
      f.step(100, port);
      expect(conservationError(f), isEmpty, reason: 't=${f.simSeconds}');
    }
  });
}
