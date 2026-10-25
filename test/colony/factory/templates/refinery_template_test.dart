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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/refinery_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

/// The spec the template must reproduce: read from the catalog, not
/// copied, so a rebalanced Refinery spec fails here until the template
/// follows it.
final CityBuildingSpec _spec =
    kUtilCatalog.firstWhere((s) => s.type == kRefineryType);

/// The plan's measurement: five minutes to settle (belts, tanks and
/// buffers filling), then twenty minutes measured — many cycles of the
/// slowest station (16 s), so lumpy shipping averages out.
MeasuredRates _measure(FactoryFloor f) =>
    measure(f, InfiniteColonyPort(), warmupS: 300, windowS: 1200);

void main() {
  /// The regression test of the template (docs/plans/factory-floors.md §3
  /// "Templates"): opening a Refinery's floor must not change what the
  /// colony gets from it, so every dock rate lands within 5% of the flat
  /// spec — in commodity units — and nothing else crosses a dock (clinker
  /// and catalyst stay inside).
  test('steady state is the spec rate within 5%, and nothing else', skip: 'awaiting port redraw (#19)', () {
    final r = _measure(FactoryFloor.fromBlueprint(refineryTemplate()));

    expect(r.inPerS.keys.toSet(), _spec.inputs.keys.toSet(),
        reason: 'takes nothing but ore: ${r.inPerS}');
    expect(r.outPerS.keys.toSet(), _spec.outputs.keys.toSet(),
        reason: 'ships nothing but fuel and oxidizer: ${r.outPerS}');
    _spec.inputs.forEach((c, want) => expect(r.inPerS[c]!,
        closeTo(want, want * 0.05), reason: '$c in: ${r.inPerS[c]}'));
    _spec.outputs.forEach((c, want) => expect(r.outPerS[c]!,
        closeTo(want, want * 0.05), reason: '$c out: ${r.outPerS[c]}'));
    expect(r.jobs, closeTo(_spec.jobs, _spec.jobs * 0.10));
  });

  /// Stamping the template must cost what placing a Refinery always cost
  /// (the spec's `buildCost`), or opening floors would quietly reprice
  /// the plant.
  test('build cost is the spec\'s within 10%', () {
    final c = capexOf(refineryTemplate());
    expect(c.total, closeTo(_spec.buildCost, _spec.buildCost * 0.10),
        reason: '$c');
  });

  /// A template is a real building on a real site: it must validate, fit
  /// the spec's site, be a believable process hall (not a shed, not the
  /// whole site), and be a fresh copy the caller may edit.
  test('a valid, believable hall that fits the site', () {
    final bp = refineryTemplate();
    expect(bp.validate(), isEmpty);
    expect(bp.plantType, kRefineryType);
    expect(bp.hall.widthM, lessThanOrEqualTo(_spec.siteWidthM));
    expect(bp.hall.depthM, lessThanOrEqualTo(_spec.siteDepthM));
    expect(bp.hall.widthM, inInclusiveRange(40, 250));
    expect(bp.hall.depthM, inInclusiveRange(40, 250));
    expect(identical(refineryTemplate(), refineryTemplate()), isFalse);
  });

  /// Chains register into shared open tables, so a chain must be safe to
  /// register twice and must only add ids under its own prefix: colony
  /// goods (fuel, oxidizer, ore) are used as `FactoryItems` defines them.
  test('the chain registers idempotently under its own prefix', () {
    registerRefineryChain();
    registerRefineryChain();
    for (final i in RefineryItems.all) {
      expect(i.id, startsWith('refinery:'));
      expect(identical(FactoryItems.byId(i.id), i), isTrue);
    }
    for (final r in RefineryRecipes.all) {
      expect(r.id, startsWith('refinery:'));
      expect(identical(FactoryRecipes.byId(r.id), r), isTrue);
      for (final q in [...r.inputs, ...r.outputs]) {
        expect(FactoryItems.byId(q.item), isNotNull, reason: q.item);
      }
    }
    expect(FactoryItems.byId('fuel'), same(FactoryItems.fuel));
    expect(FactoryItems.byId('oxidizer'), same(FactoryItems.oxidizer));
  });

  /// The user's brief: workers with heavy vehicles or on their own move
  /// the freight, and almost nothing is lights-out. So every station has a
  /// crew, forklifts really load the shipping doors, cranes really lift
  /// the clinker and walkers really carry the catalyst.
  test('realistic mix: crewed stations, forklifts, cranes and walkers', skip: 'awaiting port redraw (#19)', () {
    final bp = refineryTemplate();
    for (final p in bp.placements) {
      if (p.kind != EntityKind.machine) continue;
      expect(p.crew, isNot(MachineMode.automated), reason: '${p.recipe}');
    }
    expect(bp.roster.keys.toSet(),
        containsAll({HandlerKind.onFoot, HandlerKind.forklift,
            HandlerKind.crane}));

    final floor = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    floor.step(300, port);
    floor.takeLedger();
    floor.step(300, port);
    final l = floor.takeLedger();
    expect(l.equipmentSeconds[HandlerKind.forklift], greaterThan(0));
    expect(l.equipmentSeconds[HandlerKind.crane], greaterThan(0));
    expect(l.itemMetres, greaterThan(0));
    for (final p in bp.placements) {
      if (p.recipe == null) continue;
      expect(floor.statusOf(p.id), isNot(MachineStatus.unstaffed));
    }
  });

  /// "Fine, not great" (§3 Reward): a designer who automates the hot and
  /// chemical stations and gives each press and filler one operator ships
  /// at least as much for far fewer jobs (the labour lever) — proof the
  /// reward exists. The template's own forklifts keep up with the faster
  /// stations, so no extra vehicle is bought: measured 17 jobs against 29
  /// (-41%), and the 0.6 bound pins that figure.
  test('an improved design beats it on labour at the same output', skip: 'awaiting port redraw (#19)', () {
    final r0 = _measure(FactoryFloor.fromBlueprint(refineryTemplate()));

    final bp = refineryTemplate();
    for (var i = 0; i < bp.placements.length; i++) {
      final p = bp.placements[i];
      if (p.kind != EntityKind.machine) continue;
      final hot = p.recipe == RefineryRecipes.roast.id ||
          p.recipe == RefineryRecipes.synthesise.id;
      bp.placements[i] =
          p.copyWith(mode: hot ? MachineMode.automated : MachineMode.assisted);
    }
    final r1 = _measure(FactoryFloor.fromBlueprint(bp));

    // The plan's bar is >= 15% fewer jobs; 0.6 also pins the reported
    // 17-of-29 design (18 jobs, e.g. with a needless extra forklift, fails).
    expect(r1.jobs, lessThanOrEqualTo(r0.jobs * 0.6),
        reason: '${r1.jobs} jobs against the template\'s ${r0.jobs}');
    for (final c in _spec.outputs.keys) {
      expect(r1.outPerS[c]!, greaterThanOrEqualTo(r0.outPerS[c]! * 0.98),
          reason: '$c: ${r1.outPerS[c]} vs ${r0.outPerS[c]}');
    }
    for (final c in _spec.inputs.keys) {
      expect(r1.inPerS[c]!, lessThanOrEqualTo(r0.inPerS[c]! * 1.02),
          reason: 'no more ore than the template takes');
    }
  });

  /// Off-screen rates and saves both rely on a floor being a pure
  /// function of its layout and its runtime state: two builds must agree
  /// bit for bit, and a save taken mid-run must continue exactly as the
  /// floor it came from.
  test('deterministic, and save/load mid-run continues identically', () {
    final a = FactoryFloor.fromBlueprint(refineryTemplate());
    final b = FactoryFloor.fromBlueprint(refineryTemplate());
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    a.step(400, pa);
    b.step(400, pb);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));

    final saved = jsonEncode(a.toJson());
    final c = FactoryFloor.fromJson(
        (jsonDecode(saved) as Map).cast<String, Object?>());
    expect(jsonEncode(c.toJson()), saved, reason: 'load is lossless');
    a.step(300.6, pa);
    c.step(300.6, InfiniteColonyPort());
    expect(jsonEncode(c.toJson()), jsonEncode(a.toJson()));
  });

  /// Nothing is created or lost on the floor: every commodity unit held,
  /// shipped or crafted away is accounted for by what was received.
  test('conserves every commodity over its own run', () {
    final f = FactoryFloor.fromBlueprint(refineryTemplate());
    final port = InfiniteColonyPort();
    for (var i = 0; i < 6; i++) {
      f.step(100, port);
      expect(conservationError(f), isEmpty, reason: 'after ${(i + 1) * 100} s');
    }
  });
}
