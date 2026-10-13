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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rocketfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

/// The Rocket Parts Factory template is that plant's regression test
/// (docs/plans/factory-floors.md §3 "Templates"): opening its floor must not
/// change what the colony gets from it, what it costs to build, or how many
/// people it employs. The spec's flat rate is 0.5 tubes + 0.3 electronics →
/// 0.4 rocket parts per second with 50 jobs on a 700 × 500 m site.
void main() {
  final spec = kUtilCatalog.firstWhere((s) => s.type == kRocketPartsType);

  /// The steady state the spec is checked against: five minutes of warm-up
  /// (belts filling, crates staged, walkers out to their first pickups),
  /// then 40 minutes measured — crates land ten units at a time, so a long
  /// window keeps one crate's lump under 1% of a rate.
  MeasuredRates steady(FactoryFloor f) =>
      measure(f, InfiniteColonyPort(), warmupS: 300, windowS: 2400);

  /// Every dock rate within 5% of the spec, counted in commodity units (a
  /// crate counts its ten), and nothing else in or out: the frames and
  /// harnesses are used up inside, so the colony sees only the spec's goods.
  test('steady state is the spec rate within 5%, and nothing else', () {
    final r = steady(FactoryFloor.fromBlueprint(rocketfactoryTemplate()));
    expect(r.inPerS.keys.toSet(), spec.inputs.keys.toSet(),
        reason: 'takes nothing but tubes and electronics: ${r.inPerS}');
    expect(r.outPerS.keys.toSet(), spec.outputs.keys.toSet(),
        reason: 'ships nothing but rocket parts: ${r.outPerS}');
    spec.inputs.forEach((c, rate) {
      expect(r.inPerS[c]!, closeTo(rate, rate * 0.05), reason: 'in $c');
    });
    spec.outputs.forEach((c, rate) {
      expect(r.outPerS[c]!, closeTo(rate, rate * 0.05), reason: 'out $c');
    });
    expect(r.jobs, closeTo(spec.jobs, spec.jobs * 0.10));
  });

  /// Placing the plant with its template costs what the plant always cost,
  /// and the hall is a believable shed that fits the site.
  test('builds for the spec cost, in a hall that fits the site', () {
    final bp = rocketfactoryTemplate();
    expect(bp.validate(), isEmpty);
    final c = capexOf(bp);
    expect(c.total, closeTo(spec.buildCost, spec.buildCost * 0.10),
        reason: '$c against ${spec.buildCost} ore');
    expect(bp.hall.widthM, lessThanOrEqualTo(spec.siteWidthM));
    expect(bp.hall.depthM, lessThanOrEqualTo(spec.siteDepthM));
    // Stage-sized parts want a long shed, but not a site-sized one.
    expect(bp.hall.widthM, inInclusiveRange(60, 250));
    expect(bp.hall.depthM, inInclusiveRange(30, 200));
    expect(bp.plantType, kRocketPartsType);
    expect(identical(rocketfactoryTemplate(), rocketfactoryTemplate()),
        isFalse, reason: 'each call is a fresh blueprint the caller may edit');
  });

  /// The user's brief: people work with forklifts and cranes, or on their
  /// own, and almost no plant is lights-out. So every station has a crew,
  /// people really carry freight, a forklift really unloads, a crane really
  /// lifts the heavy sections, and conveyors carry the steady tube flow.
  test('a realistic, crewed plant: walkers, forklifts, cranes and belts', () {
    final f = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final port = InfiniteColonyPort();
    f.step(300, port);
    f.takeLedger();
    f.step(600, port);
    final l = f.takeLedger();
    final bp = f.blueprint;
    expect(bp.roster.keys.toSet(),
        {HandlerKind.onFoot, HandlerKind.forklift, HandlerKind.crane});
    expect(l.itemMetres, greaterThan(0), reason: 'walkers carry freight');
    expect(l.equipmentSeconds[HandlerKind.forklift], greaterThan(0));
    expect(l.equipmentSeconds[HandlerKind.crane], greaterThan(0));
    expect(l.workerSeconds[WorkRole.handler], greaterThan(0));
    expect(bp.placements.where((p) => p.kind == EntityKind.belt), isNotEmpty);
    expect(bp.placements.where((p) => p.kind == EntityKind.craneBay).length,
        kRocketPartsCranes);
    final machines =
        bp.placements.where((p) => p.kind == EntityKind.machine).toList();
    for (final p in machines) {
      expect(p.crew, isNot(MachineMode.automated),
          reason: 'no lights-out station in the template (${p.recipe})');
      expect(f.statusOf(p.id), isNot(MachineStatus.unstaffed));
      expect(f.statusOf(p.id), isNot(MachineStatus.broken));
    }
    expect(machines.where((p) => p.crew == MachineMode.manual).length,
        greaterThan(machines.length ~/ 2),
        reason: 'mostly hand work: this is a template, not a showpiece');
    // Rocket parts are heavy: only the cranes can have moved them.
    expect(FactoryItems.rocketParts.loadClass, LoadClass.heavy);
    expect(l.shipped['rocketParts'], greaterThan(0));
  });

  /// The chain registers only its own, prefixed ids, and doing it again is
  /// harmless (a save, the editor and a template may all ask first).
  test('chain registration is idempotent and prefixed', () {
    registerRocketPartsChain();
    registerRocketPartsChain();
    for (final i in RocketPartsItems.all) {
      expect(i.id, startsWith('$kRocketPartsType:'));
      expect(identical(FactoryItems.byId(i.id), i), isTrue);
    }
    for (final r in RocketPartsRecipes.all) {
      expect(r.id, startsWith('$kRocketPartsType:'));
      expect(identical(FactoryRecipes.byId(r.id), r), isTrue);
    }
  });

  /// Engagement is optional but rewarded (§3 "Reward"): the template must
  /// leave room for a better design. Here a designer gives every manual
  /// station one operator and its controls instead of a two-person crew,
  /// and gets at least the same parts from far fewer people.
  test('a re-crewed design matches the output with 15%+ fewer jobs', () {
    final r0 = steady(FactoryFloor.fromBlueprint(rocketfactoryTemplate()));
    final bp = rocketfactoryTemplate();
    for (var i = 0; i < bp.placements.length; i++) {
      final p = bp.placements[i];
      if (p.kind != EntityKind.machine) continue;
      bp.placements[i] = p.copyWith(mode: MachineMode.assisted);
    }
    final r1 = steady(FactoryFloor.fromBlueprint(bp));
    expect(r1.jobs, lessThanOrEqualTo(r0.jobs * 0.85),
        reason: '${r1.jobs} jobs against the template\'s ${r0.jobs}');
    expect(r1.outPerS['rocketParts']!,
        greaterThanOrEqualTo(r0.outPerS['rocketParts']! * 0.98),
        reason: '${r1.outPerS} vs ${r0.outPerS}');
    // The gain is real, not bought with extra material: input per part
    // stays the recipe's (crates land in lumps, hence the 5%).
    final p0 = r0.outPerS['rocketParts']!, p1 = r1.outPerS['rocketParts']!;
    for (final c in spec.inputs.keys) {
      expect(r1.inPerS[c]! / p1, lessThanOrEqualTo(r0.inPerS[c]! / p0 * 1.05),
          reason: '$c per part: ${r1.inPerS} for $p1 vs ${r0.inPerS} for $p0');
    }
    printOnFailure('template $r0\nre-crewed $r1');
  });

  /// No RNG, clock or hash order: two builds run identically.
  test('deterministic: two builds measure identically', () {
    final a = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final b = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final ra = measure(a, InfiniteColonyPort(), warmupS: 300, windowS: 1200);
    final rb = measure(b, InfiniteColonyPort(), warmupS: 300, windowS: 1200);
    expect(rb.inPerS, ra.inPerS);
    expect(rb.outPerS, ra.outPerS);
    expect(rb.powerKw, ra.powerKw);
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
  });

  /// A save mid-run — tubes mid-belt, a crane mid-lift, walkers mid-trip,
  /// a part-run sub-step in the carry — must continue exactly as if the
  /// game had never stopped.
  test('save → load → step equals an uninterrupted run', () {
    final a = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final pa = InfiniteColonyPort();
    a.step(437.3, pa); // leaves 0.05 s in the sub-step carry
    final saved = jsonEncode(a.toJson());
    final snap = jsonDecode(saved) as Map<String, Object?>;
    expect(snap['cr'], isNot(0.0));
    expect(a.beltItems, isNotEmpty);
    expect(a.handlers.any((h) => h.state != HandlerState.idle), isTrue);

    final b = FactoryFloor.fromJson(snap);
    expect(jsonEncode(b.toJson()), saved, reason: 'load is lossless');
    final pb = InfiniteColonyPort();
    for (var i = 0; i < 6; i++) {
      a.step(50.1, pa);
      b.step(50.1, pb);
    }
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(pb.given['rocketParts'], greaterThan(0));
  });

  /// Nothing is made or lost: what is on the floor is what came in, less
  /// what went out, plus what the crafts turned it into.
  test('conserves every commodity over its own run', () {
    final f = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final port = InfiniteColonyPort();
    for (final dt in [0.25, 37.3, 300.0, 600.0]) {
      f.step(dt, port);
      expect(conservationError(f), isEmpty, reason: 'after +$dt s');
    }
    expect(f.ledger.shipped['rocketParts'], greaterThan(0));
  });
}
