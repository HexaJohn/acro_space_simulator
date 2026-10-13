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
import 'package:acro_space_simulator/domain/colony/city/factory/templates/electronics_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

/// The Electronics Plant's spec, read live so the template is held to
/// whatever the colony's flat rate says, not to numbers copied here.
final CityBuildingSpec _spec =
    kUtilCatalog.firstWhere((s) => s.type == kElectronicsType);

/// Warm-up past every buffer filling (the 36 m chassis belt and the board
/// shop take a few minutes), then a 20-minute window: ~70 crates either
/// way, so one crate of lumpiness is under 2%.
const _settings = MeasureSettings(warmupS: 600, windowS: 1200, earlyStop: false);

MeasuredRates _measure(FloorBlueprint bp) =>
    measureBlueprint(bp, FactoryFloor.fromBlueprint, settings: _settings);

/// A copy of the template with every station running [recipes] set to
/// [mode] — the designer's cheapest edit.
FloorBlueprint _recrew(Set<String> recipes, MachineMode mode) {
  final bp = electronicsTemplate();
  for (var i = 0; i < bp.placements.length; i++) {
    final p = bp.placements[i];
    if (recipes.contains(p.recipe)) bp.placements[i] = p.copyWith(mode: mode);
  }
  return bp;
}

void main() {
  /// The regression test of the template (docs/plans/factory-floors.md §3
  /// "Templates"): opening the plant's floor must not change what the
  /// colony gets from it, in commodity units, nor what it takes — steel in,
  /// electronics out, every byproduct (offcut, cans, kits) used up inside.
  test('steady state is the spec rate within 5%, and nothing else moves', () {
    final r = _measure(electronicsTemplate());
    final steelIn = _spec.inputs['steel']!;
    final elecOut = _spec.outputs['electronics']!;
    expect(r.inPerS.keys, ['steel'], reason: 'takes nothing but steel');
    expect(r.inPerS['steel']!, closeTo(steelIn, steelIn * 0.05));
    expect(r.outPerS.keys, ['electronics'],
        reason: 'ships nothing but electronics');
    expect(r.outPerS['electronics']!, closeTo(elecOut, elecOut * 0.05));
    expect(r.jobs, closeTo(_spec.jobs, _spec.jobs * 0.10));
  });

  /// Placing a templated plant must cost what the plant always cost (the
  /// spec's buildCost, ore), and the hall must be a believable fab shed
  /// that fits the campus it is stamped onto.
  test('costs the spec build cost and fits the site', () {
    final bp = electronicsTemplate();
    expect(bp.validate(), isEmpty);
    expect(capexOf(bp).total,
        closeTo(_spec.buildCost, _spec.buildCost * 0.10));
    expect(bp.hall.widthM, lessThanOrEqualTo(_spec.siteWidthM));
    expect(bp.hall.depthM, lessThanOrEqualTo(_spec.siteDepthM));
    expect(bp.hall.widthM, inInclusiveRange(40, 250));
    expect(bp.hall.depthM, inInclusiveRange(40, 250));
    expect(bp.plantType, kElectronicsType);
    expect(identical(electronicsTemplate(), electronicsTemplate()), isFalse,
        reason: 'each call is a fresh blueprint the caller may edit');
  });

  /// The user's brief: people and vehicles move the freight, belts carry
  /// the steady flows, and almost nothing is lights-out. So every station
  /// is manned or operator-assisted, the forklift really works the doors,
  /// walkers really carry the board shop's trays and kits, and conveyors
  /// run the line.
  test('a realistic mix: people, a forklift and belts all pull weight', () {
    final bp = electronicsTemplate();
    final floor = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    floor.step(600, port);
    floor.takeLedger();
    floor.step(600, port);
    final l = floor.takeLedger();

    expect(bp.roster.keys.toSet(), {HandlerKind.onFoot, HandlerKind.forklift});
    expect(l.itemMetres, greaterThan(0), reason: 'walkers carry freight');
    expect(l.equipmentSeconds[HandlerKind.forklift], greaterThan(0),
        reason: 'the forklift works the doors');
    expect(bp.placements.where((p) => p.kind == EntityKind.belt).length,
        greaterThan(30), reason: 'belts run the line');
    for (final p in bp.placements) {
      if (p.kind != EntityKind.machine) continue;
      expect(p.crew, isNot(MachineMode.automated),
          reason: 'the template is not lights-out (${p.recipe})');
      expect(floor.statusOf(p.id), isNot(MachineStatus.unstaffed));
      expect(floor.statusOf(p.id), isNot(MachineStatus.broken));
    }
  });

  /// Engagement is optional but REWARDED (§3 "Reward"): the template must
  /// leave room for better designs. Two of the levers its doc names are
  /// proved here — servo-assisting the pacemaker press buys output (more
  /// electronics within the docks' supply, with a job fewer), and giving
  /// the board and assembly benches an operator each holds the output with
  /// a quarter fewer jobs.
  test('an improved design beats it', () {
    final base = _measure(electronicsTemplate());

    final faster =
        _measure(_recrew({ElectronicsRecipes.stamp.id}, MachineMode.assisted));
    expect(faster.outPerS.keys, ['electronics']);
    expect(faster.outPerS['electronics']!,
        greaterThan(base.outPerS['electronics']! * 1.1),
        reason: '${faster.outPerS} vs ${base.outPerS}');
    expect(faster.jobs, lessThanOrEqualTo(base.jobs));

    final leaner = _recrew(
        {ElectronicsRecipes.board.id, ElectronicsRecipes.assemble.id},
        MachineMode.assisted);
    leaner.roster[HandlerKind.onFoot] = kElectronicsWalkers - 2;
    final lean = _measure(leaner);
    expect(lean.jobs, lessThanOrEqualTo(base.jobs * 0.85),
        reason: '${lean.jobs} jobs against ${base.jobs}');
    expect(lean.outPerS['electronics']!,
        greaterThanOrEqualTo(base.outPerS['electronics']! * 0.95),
        reason: '${lean.outPerS} vs ${base.outPerS}');
  });

  /// Measured rates feed the colony's aggregate mode, and saves hold full
  /// floor state: the same template must measure the same every time, and
  /// a save → load mid-run must continue bit for bit.
  test('deterministic, and save/load mid-run continues identically', () {
    final a = _measure(electronicsTemplate());
    final b = _measure(electronicsTemplate());
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));

    final f = FactoryFloor.fromBlueprint(electronicsTemplate());
    final pf = InfiniteColonyPort();
    f.step(437.3, pf); // mid-run, with a part sub-step in the carry
    final saved = jsonEncode(f.toJson());
    final g = FactoryFloor.fromJson(jsonDecode(saved) as Map<String, Object?>);
    expect(jsonEncode(g.toJson()), saved, reason: 'load is lossless');
    final pg = InfiniteColonyPort();
    for (var i = 0; i < 4; i++) {
      f.step(75.1, pf);
      g.step(75.1, pg);
    }
    expect(jsonEncode(g.toJson()), jsonEncode(f.toJson()));
    expect(pg.given, isNotEmpty);
  });

  /// The floor may never mint or lose goods: everything taken, made,
  /// shipped and still on the floor balances in commodity units.
  test('conserves commodity units over its own run', () {
    final f = FactoryFloor.fromBlueprint(electronicsTemplate());
    final port = InfiniteColonyPort();
    for (var i = 0; i < 12; i++) {
      f.step(50, port);
      expect(conservationError(f), isEmpty, reason: 'at ${f.simSeconds} s');
    }
  });

  /// Chains register in parallel tracks into shared tables, so this one
  /// must only add its own 'electronics:' ids, reuse the colony goods
  /// (steel, electronics and their packs) as defined once, and tolerate
  /// being registered any number of times.
  test('registers only its own prefixed ids, idempotently', () {
    registerElectronicsChain();
    registerElectronicsChain();
    for (final i in ElectronicsItems.all) {
      expect(i.id, startsWith('electronics:'));
      expect(identical(FactoryItems.byId(i.id), i), isTrue);
    }
    for (final r in ElectronicsRecipes.all) {
      expect(r.id, startsWith('electronics:'));
      expect(identical(FactoryRecipes.byId(r.id), r), isTrue);
      for (final q in [...r.inputs, ...r.outputs]) {
        expect(q.def, isNotNull, reason: '${r.id} uses unknown ${q.item}');
      }
    }
    expect(electronicsTemplate().placements
        .where((p) => p.kind == EntityKind.receivingDock)
        .map((p) => p.item), [FactoryItems.crateSteel.id]);
    expect(kFactoryTileM, 2.0, reason: 'hall sizes above assume 2 m tiles');
  });
}
