// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:acro_space_simulator/application/factory/floor_measure_runner.dart';
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

/// Exactly the settings the template file tells the lead to measure it
/// with, so the spec-rate test proves THAT figure is enough (a 600 s
/// warm-up here once hid that the floor needs ~240 s to prime).
const _settings = kElectronicsMeasureSettings;

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
  test('steady state is the spec rate within 5%, and nothing else moves', skip: 'awaiting port redraw (#19)', () {
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

  /// The floor primes for ~240 s and ships in crates of ten, so the
  /// standard measurement (60 s + 300 s) reads it far under spec. The
  /// template therefore names the settings it must be measured with; they
  /// must clear the priming with margin and make one crate a small share
  /// of the window, or "Reset to template" would cut the plant's
  /// off-screen output.
  test('names measurement settings that clear its priming', skip: 'awaiting port redraw (#19)', () async {
    expect(kElectronicsMeasureSettings.warmupS, greaterThanOrEqualTo(300));
    expect(kElectronicsMeasureSettings.windowS, greaterThanOrEqualTo(1200));
    // The settings as they cross to a measure worker survive the trip.
    final back = MeasureSettings.fromJson(kElectronicsMeasureSettings.toJson());
    expect(back.warmupS, kElectronicsMeasureSettings.warmupS);
    expect(back.windowS, kElectronicsMeasureSettings.windowS);
    // And through the runner the lead will use, the template reads spec.
    final r = SyncFloorMeasureRunner(FactoryFloor.fromBlueprint,
        setup: registerElectronicsChain);
    await expectLater(
        r.measure(electronicsTemplate(), settings: kElectronicsMeasureSettings)
            .then((m) => m.outPerS['electronics']),
        completion(closeTo(_spec.outputs['electronics']!,
            _spec.outputs['electronics']! * 0.05)));
  });

  /// A save holding an electronics floor can be loaded, and a template
  /// measured, in an isolate whose registries start empty (a fresh process,
  /// or the measure runner's worker) once `registerElectronicsChain` — and
  /// nothing else — has run there. Without it the floor's recipes are
  /// unknown, which is why the template's doc makes the hook blocking.
  test('a fresh isolate loads a saved floor after only the chain setup', skip: 'awaiting port redraw (#19)',
      () async {
    final f = FactoryFloor.fromBlueprint(electronicsTemplate());
    final pf = InfiniteColonyPort();
    f.step(300, pf);
    final saved = jsonEncode(f.toJson());
    f.step(60, pf);
    final expected = jsonEncode(f.toJson());
    final bpJson = jsonEncode(electronicsTemplate().toJson());

    // Without the setup a fresh isolate does not know the chain.
    final known = await Isolate.run(
        () => FactoryRecipes.byId(ElectronicsRecipes.stamp.id) != null);
    expect(known, isFalse, reason: 'statics really start empty');

    final (resumed, rates) = await Isolate.run(() {
      registerElectronicsChain();
      final g = FactoryFloor.fromJson(
          jsonDecode(saved) as Map<String, Object?>);
      g.step(60, InfiniteColonyPort());
      final m = measureBlueprintJson(
          FactoryFloor.fromBlueprint,
          jsonDecode(bpJson) as Map<String, Object?>,
          kElectronicsMeasureSettings.toJson());
      return (jsonEncode(g.toJson()), m);
    });
    expect(resumed, expected, reason: 'continues as the original does');
    expect(MeasuredRates.fromJson(rates).outPerS['electronics'],
        closeTo(_spec.outputs['electronics']!,
            _spec.outputs['electronics']! * 0.05));
  });

  /// The doc's handling figures are measured, not guessed: walkers' longest
  /// tray and kit hauls (path walked while carrying) match the constants
  /// the doc cites, to a tile.
  test('walker hauls match the documented figures', skip: 'awaiting port redraw (#19)', () {
    final f = FactoryFloor.fromBlueprint(electronicsTemplate());
    final p = InfiniteColonyPort();
    final last = <int, (double, double, String?)>{};
    final walked = <int, double>{};
    final longest = <String, double>{};
    for (var t = 0; t < 12000; t++) {
      f.step(kFactoryStepS, p);
      for (final h in f.handlers) {
        if (h.kind != HandlerKind.onFoot) continue;
        final prev = last[h.id];
        final held = prev?.$3;
        if (prev != null && held != null) {
          final d = (walked[h.id] ?? 0) +
              sqrt(pow(h.x - prev.$1, 2) + pow(h.y - prev.$2, 2));
          walked[h.id] = d;
          if (h.carrying != held) {
            longest[held] = max(longest[held] ?? 0, d * kFactoryTileM);
            walked[h.id] = 0;
          }
        }
        last[h.id] = (h.x, h.y, h.carrying);
      }
    }
    expect(longest[ElectronicsItems.canTray.id],
        closeTo(kElectronicsTrayHaulM, kFactoryTileM));
    expect(longest[ElectronicsItems.boardKit.id],
        closeTo(kElectronicsKitHaulM, kFactoryTileM));
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
  test('a realistic mix: people, a forklift and belts all pull weight', skip: 'awaiting port redraw (#19)', () {
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
  test('an improved design beats it', skip: 'awaiting port redraw (#19)', () {
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
  test('deterministic, and save/load mid-run continues identically', skip: 'awaiting port redraw (#19)', () {
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
