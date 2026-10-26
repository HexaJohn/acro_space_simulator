// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/dock_geometry.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_capex.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/station_ports.dart';
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

  /// The long-run steady state: five minutes of warm-up, then 40 minutes
  /// measured. Tubes and electronics arrive loose, so one unit either side
  /// of the window is under 0.1% of a rate here. Back-to-back 1200 s windows
  /// read the spec too (see the windows test below); the long window is
  /// not what makes this pass.
  MeasuredRates steady(FactoryFloor f) =>
      measure(f, InfiniteColonyPort(), warmupS: 300, windowS: 2400);

  /// Every dock rate within 5% of the spec, counted in commodity units,
  /// and nothing else in or out: the frames and harnesses are used up
  /// inside, so the colony sees only the spec's goods.
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

  /// What the game really reads. `FloorMeasureRunner` re-measures a floor
  /// with `MeasureSettings.standard` (60 s warm-up, at most 300 s), for
  /// example when the editor closes. An untouched template must read the
  /// spec there too, or opening and closing the floor would change what the
  /// colony gets. Start-up stock (belts and pads still filling, buffers
  /// still priming) counts as intake in so short a window, so this is the
  /// test that keeps the floor's stock small and quick to fill.
  test('the game\'s standard re-measure reads the spec within 5%', () {
    final r = measureBlueprint(rocketfactoryTemplate(), FactoryFloor.fromBlueprint,
        settings: MeasureSettings.standard);
    expect(r.inPerS.keys.toSet(), spec.inputs.keys.toSet());
    expect(r.outPerS.keys.toSet(), spec.outputs.keys.toSet());
    spec.inputs.forEach((c, rate) {
      expect(r.inPerS[c]!, closeTo(rate, rate * 0.05),
          reason: 'in $c: ${r.inPerS}');
    });
    spec.outputs.forEach((c, rate) {
      expect(r.outPerS[c]!, closeTo(rate, rate * 0.05),
          reason: 'out $c: ${r.outPerS}');
    });
  });

  /// The steady state really is steady: four back-to-back 1200 s windows
  /// each read the spec within 1%, and the floor's stock is the same at the
  /// end of each. So a pass is not bought with a long window's averaging
  /// (with crates, 1200 s windows swung about ±6% on electronics).
  test('back-to-back 1200 s windows each read the spec, stock flat', () {
    final f = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final port = InfiniteColonyPort();
    f.step(300, port);
    f.takeLedger();
    Map<String, int>? stock;
    for (var i = 0; i < 4; i++) {
      f.step(1200, port);
      final l = f.takeLedger();
      final r = ratesOf(l, jobs: f.jobDemand);
      spec.inputs.forEach((c, rate) {
        expect(r.inPerS[c]!, closeTo(rate, rate * 0.01),
            reason: 'window $i in $c: ${r.inPerS}');
      });
      spec.outputs.forEach((c, rate) {
        expect(r.outPerS[c]!, closeTo(rate, rate * 0.01),
            reason: 'window $i out $c: ${r.outPerS}');
      });
      // Raw materials on the floor (rollers and buffers) hold level; the
      // few frames, harnesses and parts in flight vary by a lump or two.
      final s = {
        for (final k in ['tubes', 'electronics']) k: f.itemsOnFloor[k] ?? 0,
      };
      if (stock != null) expect(s, stock, reason: 'window $i stock');
      stock = s;
    }
  });

  /// The fleet's slack is what the library doc says it is: four forklifts
  /// hold the long-run rate and two do not, and four walkers hold even the
  /// game's short re-measure. The template keeps five forklifts and nine
  /// walkers, so both are levers, not needs.
  test('four forklifts and four walkers hold the rate; two forklifts do not',
      () {
    FloorBlueprint crewed(HandlerKind k, int n) =>
        rocketfactoryTemplate()..roster[k] = n;
    final parts = spec.outputs[Commodity.rocketParts]!;
    final four = steady(FactoryFloor.fromBlueprint(
        crewed(HandlerKind.forklift, 4)));
    expect(four.outPerS['rocketParts']!, closeTo(parts, parts * 0.05));
    final two = steady(FactoryFloor.fromBlueprint(
        crewed(HandlerKind.forklift, 2)));
    expect(two.outPerS['rocketParts']!, lessThan(parts * 0.95),
        reason: 'two forklifts should fall short: ${two.outPerS}');
    final walkers = measureBlueprint(
        crewed(HandlerKind.onFoot, 4), FactoryFloor.fromBlueprint);
    expect(walkers.outPerS['rocketParts']!, closeTo(parts, parts * 0.05));
    expect(kRocketPartsForklifts, greaterThan(4));
    expect(kRocketPartsWalkers, greaterThan(4));
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
    // A real assembly shop: big enough for two lines of 6 m cells and bays
    // with a forklift aisle, nowhere near the size of the site.
    expect(bp.hall.widthM, inInclusiveRange(40, 250));
    expect(bp.hall.depthM, inInclusiveRange(30, 200));
    expect(bp.plantType, kRocketPartsType);
    // Every door is a door: its back edge on the hall's outer wall.
    for (final p in bp.placements.where((p) => isDockKind(p.kind))) {
      expect(dockOnOuterWall(p, bp.hall), isTrue, reason: '$p');
    }
    expect(identical(rocketfactoryTemplate(), rocketfactoryTemplate()),
        isFalse, reason: 'each call is a fresh blueprint the caller may edit');
  });

  /// The port layout (§10 item 19) as the template's doc draws it: every
  /// tube and electronics door feeds its station's input port, every bay's
  /// product port feeds the roller to its shipping door, and no arm is
  /// left over to touch a machine.
  test('every feed is a port: doors and rollers into ports, none by arm', () {
    final bp = rocketfactoryTemplate();
    expect(bp.placements.where((p) => p.kind == EntityKind.arm), isEmpty);
    final belts = {
      for (final p in bp.placements)
        if (p.kind == EntityKind.belt) p.pos: p,
    };
    final docks = bp.placements
        .where((p) => p.kind == EntityKind.receivingDock)
        .toList();
    final machines =
        bp.placements.where((p) => p.kind == EntityKind.machine).toList();
    var fedPorts = 0, productPorts = 0;
    for (final m in machines) {
      final r = FactoryRecipes.byId(m.recipe!)!;
      for (final port in portsOf(m)) {
        final q = recipeSlotItem(r, port);
        if (q == null) continue;
        if (port.role == PortRole.input) {
          final b = belts[port.outside];
          final dockEnd = docks.any((d) =>
              d.item == q.item &&
              d.footprint.contains(port.outside) &&
              d.dir == port.feedDir);
          if ((b != null && port.connectsBelt(b.dir)) || dockEnd) fedPorts++;
        } else if (port.role == PortRole.output) {
          final b = belts[port.outside];
          if (b != null && port.connectsBelt(b.dir)) productPorts++;
        }
      }
    }
    // Six cells (tubes by roller) and six benches (electronics from the
    // door's open end); the bays' frames and harnesses come by hand.
    expect(fedPorts, 12);
    // Six bays push rocket parts onto their door rollers.
    expect(productPorts, 6);
  });

  /// The user's brief: people work with forklifts and cranes, or on their
  /// own, and almost no plant is lights-out. So every station has a crew,
  /// walkers really carry the harnesses, forklifts really run the frames,
  /// and the heavy rocket parts and the steady tube flow ride rollers.
  test('a realistic, crewed plant: walkers, forklifts and belts', () {
    final f = FactoryFloor.fromBlueprint(rocketfactoryTemplate());
    final port = InfiniteColonyPort();
    f.step(300, port);
    f.takeLedger();
    f.step(600, port);
    final l = f.takeLedger();
    final bp = f.blueprint;
    expect(bp.roster.keys.toSet(), {HandlerKind.onFoot, HandlerKind.forklift});
    expect(l.itemMetres, greaterThan(0), reason: 'handlers carry freight');
    expect(l.equipmentSeconds[HandlerKind.forklift], greaterThan(0));
    expect(l.workerSeconds[WorkRole.handler], greaterThan(0));
    expect(bp.placements.where((p) => p.kind == EntityKind.belt), isNotEmpty);
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
    // Rocket parts are heavy: no handler here can lift one, so they leave
    // only by the bays' rollers.
    expect(FactoryItems.rocketParts.loadClass, LoadClass.heavy);
    for (final k in bp.roster.keys) {
      expect(kHandlerSpecs[k]!.canLift(LoadClass.heavy), isFalse);
    }
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
    // stays the recipe's (a window cuts a lump or two, hence the 5%).
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

  /// A save mid-run — tubes mid-roller, a forklift mid-run, walkers mid-trip,
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
