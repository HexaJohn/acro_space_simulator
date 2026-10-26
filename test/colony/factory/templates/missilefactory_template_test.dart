// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:isolate';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_capex.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
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
import 'package:acro_space_simulator/domain/colony/city/factory/templates/missilefactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

/// The Missile Plant spec every number here is checked against.
final CityBuildingSpec _spec =
    kUtilCatalog.firstWhere((s) => s.type == kMissileType);

/// True steady state, as a check apart from the colony's own short
/// measurement: 600 s of warm-up and 2400 s measured in full, long enough
/// that neither the first pass nor any lump moves a rate. The design work
/// (better layouts) is compared on this.
const MeasureSettings _steady =
    MeasureSettings(warmupS: 600, windowS: 2400, earlyStop: false);

MeasuredRates _measure(FloorBlueprint bp) =>
    measureBlueprint(bp, FactoryFloor.fromBlueprint, settings: _steady);

/// Every spec input and output of [r] within 5% of the spec rate, and
/// nothing else in or out.
void _expectSpecRates(MeasuredRates r, String when) {
  expect(r.inPerS.keys.toSet(), _spec.inputs.keys.toSet(),
      reason: '$when: takes only tubes, rocket parts and electronics');
  expect(r.outPerS.keys.toSet(), _spec.outputs.keys.toSet(),
      reason: '$when: ships only missiles');
  _spec.inputs.forEach((c, rate) {
    expect(r.inPerS[c]!, closeTo(rate, rate * 0.05), reason: '$when in: $c');
  });
  _spec.outputs.forEach((c, rate) {
    expect(r.outPerS[c]!, closeTo(rate, rate * 0.05),
        reason: '$when out: $c');
  });
}

/// In a fresh isolate (empty registries, as on the measure worker): only
/// `ensureFactoryCatalog`, then load the saved floor and step it. Returns
/// the blueprint's issues and the floor's JSON after [stepS].
Future<(String, String)> _loadInFreshIsolate(String saved, double stepS) =>
    Isolate.run(() {
      ensureFactoryCatalog();
      final j = (jsonDecode(saved) as Map).cast<String, Object?>();
      final bp = FloorBlueprint.fromJson(
          (j['bp'] as Map).cast<String, Object?>());
      final f = FactoryFloor.fromJson(
          (j['floor'] as Map).cast<String, Object?>());
      f.step(stepS, InfiniteColonyPort());
      return ('${bp.validate()}', jsonEncode(f.toJson()));
    });

/// A copy of [bp] with every placement passed through [f].
FloorBlueprint _edit(FloorBlueprint bp, Placement Function(Placement) f) {
  final out = bp.copy();
  for (var i = 0; i < out.placements.length; i++) {
    out.placements[i] = f(out.placements[i]);
  }
  return out;
}

void main() {
  /// The template is the Missile Plant's regression test (§3 "Templates"):
  /// opening its floor must not change what the colony gets from it or
  /// what it costs. Rates are in COMMODITY units, so a pallet of ten tubes
  /// counts ten; nothing may come in or go out but the spec's goods.
  test('steady state is the spec rate within 5%, nothing else in or out',
      () {
    final r = _measure(missilefactoryTemplate());
    _expectSpecRates(r, 'steady');
    expect(r.jobs, closeTo(_spec.jobs, _spec.jobs * 0.1));
  });

  /// The colony measures with `MeasureSettings.standard` (60 s warm-up,
  /// at most 300 s, early stop), from a FRESH floor every time an editor
  /// closes, and from a running floor's save when it re-measures. The
  /// template must read its spec rate on exactly that path, or opening and
  /// closing its floor would change the plant: a floor that settles slowly
  /// reads low, and a ten-unit crate is 17% of a 300 s window.
  test("reads the spec rate under the colony's own measurement settings",
      () {
    final fresh = measureBlueprint(
        missilefactoryTemplate(), FactoryFloor.fromBlueprint);
    _expectSpecRates(fresh, 'fresh floor');
    expect(fresh.seconds, kMeasureWindowS,
        reason: 'lumpy missile windows never stop the measurement early');
    // Re-measured mid-run, at several phases of the line's cycle.
    for (final t in [600.0, 637.0, 711.0, 1123.0]) {
      final f = FactoryFloor.fromBlueprint(missilefactoryTemplate());
      f.step(t, InfiniteColonyPort());
      final saved = (jsonDecode(jsonEncode(f.toJson())) as Map)
          .cast<String, Object?>();
      _expectSpecRates(measureSaved(saved, FactoryFloor.fromJson),
          'saved at ${t}s');
    }
  });

  /// Placing a templated plant must cost what it always did (the spec's
  /// `buildCost`), and the hall must be a building that stands on the
  /// plant's site — not a shed, not a city block.
  test('costs the spec build ore and fits a believable hall on the site',
      () {
    final bp = missilefactoryTemplate();
    expect(bp.validate(), isEmpty);
    expect(capexOf(bp).total,
        closeTo(_spec.buildCost, _spec.buildCost * 0.1),
        reason: '${capexOf(bp)}');
    expect(bp.hall.widthM, lessThanOrEqualTo(_spec.siteWidthM));
    expect(bp.hall.depthM, lessThanOrEqualTo(_spec.siteDepthM));
    expect(bp.hall.widthM, inInclusiveRange(40, 250));
    expect(bp.hall.depthM, inInclusiveRange(40, 250));
    expect(bp.plantType, kMissileType);
    expect(identical(missilefactoryTemplate(), missilefactoryTemplate()),
        isFalse,
        reason: 'each call is a fresh blueprint the caller may edit');
  });

  /// Chains register in parallel tracks into shared tables, so this one
  /// may only add ids under its own prefix, and registering twice (every
  /// template build does) must be harmless.
  test('registers only prefixed ids, idempotently', () {
    registerMissileChain();
    registerMissileChain();
    for (final i in MissileItems.all) {
      expect(i.id, startsWith('$kMissileType:'));
      expect(identical(FactoryItems.byId(i.id), i), isTrue);
    }
    for (final r in MissileRecipes.all) {
      expect(r.id, startsWith('$kMissileType:'));
      expect(identical(FactoryRecipes.byId(r.id), r), isTrue);
      for (final q in [...r.inputs, ...r.outputs]) {
        expect(FactoryItems.byId(q.item), isNotNull, reason: q.item);
      }
    }
  });

  /// Statics are per isolate, and a floor loaded from a save or rebuilt
  /// from blueprint JSON on the measure worker only ever calls
  /// `ensureFactoryCatalog`. That call must bring this chain too, or such
  /// a floor has no `missilefactory:` recipes (an unknown-recipe floor, or
  /// a crash on lookup). The fresh isolate here starts with empty tables
  /// and never touches the template.
  test('a saved floor loads and runs where only the catalog was ensured',
      () async {
    final bp = missilefactoryTemplate();
    final f = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    f.step(437.3, port);
    final saved = jsonEncode({'bp': bp.toJson(), 'floor': f.toJson()});

    final (issues, after) = await _loadInFreshIsolate(saved, 75.1);
    expect(issues, '[]', reason: 'every missile recipe is known');
    f.step(75.1, port);
    expect(after, jsonEncode(f.toJson()),
        reason: 'continues as it would have here');
  });

  /// The user's brief: workers move freight with forklifts, pallet jacks
  /// and cranes or on their own, and almost no plant is lights-out. So the
  /// template unloads every door into staging (no dock conveyor), walks the
  /// tubes into the saws' hand ports, swings electronics off its staging by
  /// arm onto port belts, belts the steady segment, board, motor and round
  /// flows, forklifts the airframe pallets, cranes the rocket parts, and
  /// crews its stations. Under the port rules (§10 item 19) no arm touches
  /// a machine.
  test('a realistic mix: people, forklifts, cranes, belts; crewed stations',
      () {
    final bp = missilefactoryTemplate();
    final floor = FactoryFloor.fromBlueprint(bp);
    final port = InfiniteColonyPort();
    floor.step(600, port);
    floor.takeLedger();
    floor.step(600, port);
    final l = floor.takeLedger();

    expect(l.itemMetres, greaterThan(0),
        reason: 'workers on foot really carry the hand loads');
    expect(l.equipmentSeconds[HandlerKind.forklift], greaterThan(0));
    expect(l.equipmentSeconds[HandlerKind.crane], greaterThan(0));
    expect(floor.beltItems, isNotEmpty, reason: 'the belts run');

    // Every receiving door unloads into staging: people and vehicles, not
    // a dock conveyor.
    final staging = [
      for (final p in bp.placements)
        if (p.kind == EntityKind.staging) p.footprint,
    ];
    for (final d in bp.placements) {
      if (d.kind != EntityKind.receivingDock) continue;
      // The tile a door sets freight down on: just beyond it, the way it
      // faces.
      final f = d.footprint;
      final front = switch (d.dir) {
        Dir4.east => TilePos(f.x1, f.y0),
        Dir4.west => TilePos(f.x0 - 1, f.y0),
        Dir4.north => TilePos(f.x0, f.y1),
        Dir4.south => TilePos(f.x0, f.y0 - 1),
      };
      expect(staging.any((s) => s.contains(front)), isTrue,
          reason: '${d.item} door unloads into staging');
    }

    // Crewed, not lights-out: the only automated station is the
    // propellant cell.
    final machines = [
      for (final p in bp.placements)
        if (p.kind == EntityKind.machine) p,
    ];

    // Arms work staging and belts only: neither end of any arm is a
    // machine (they would do nothing there).
    for (final a in bp.placements) {
      if (a.kind != EntityKind.arm) continue;
      for (final t in [a.pos.step(a.dir), a.pos.step(a.dir.opposite)]) {
        expect(machines.any((m) => m.footprint.contains(t)), isFalse,
            reason: '$a touches a machine at $t');
      }
    }
    final auto = machines.where((p) => p.crew == MachineMode.automated);
    expect(auto.map((p) => p.recipe).toSet(), {MissileRecipes.castMotor.id});
    expect(auto.length * 4, lessThan(machines.length));

    // Every station works once settled: nothing is unstaffed or broken.
    for (final p in machines) {
      expect(floor.statusOf(p.id),
          isNot(anyOf(MachineStatus.unstaffed, MachineStatus.broken)),
          reason: p.recipe);
    }
  });

  /// Engagement is optional but REWARDED (§3 "Reward"): the template must
  /// leave a better design to find. Its tube crews are overstaffed (the
  /// saws' hand ports open onto the staging they idle on): a designer who
  /// releases most of the walkers holds the missile rate on a third fewer
  /// jobs (the labour lever). Crewing the three kitting stations — the pace
  /// — as assisted ships far more from the same floor, up to the one
  /// welder's ceiling (the throughput lever).
  test('a better design beats it: same output for fewer jobs, or more', () {
    final r0 = _measure(missilefactoryTemplate());

    final lean = missilefactoryTemplate().copy()
      ..roster[HandlerKind.onFoot] = 12;
    final r1 = _measure(lean);
    expect(r1.jobs, lessThanOrEqualTo(r0.jobs * 0.85),
        reason: "${r1.jobs} jobs against the template's ${r0.jobs}");
    expect(r1.outPerS['missiles']!,
        greaterThanOrEqualTo(r0.outPerS['missiles']! * 0.98));

    final pacers = {
      MissileRecipes.cutTubes.id,
      MissileRecipes.kitElectronics.id,
      MissileRecipes.kitMotor.id,
    };
    final faster = _edit(
        missilefactoryTemplate(),
        (p) => pacers.contains(p.recipe)
            ? p.copyWith(mode: MachineMode.assisted)
            : p);
    final r2 = _measure(faster);
    expect(r2.outPerS['missiles']!,
        greaterThan(r0.outPerS['missiles']! * 1.15),
        reason: '${r2.outPerS} against ${r0.outPerS}');
  });

  /// No RNG, no clock, no hash order: two builds of the template measure
  /// identically, or an off-screen re-measure could change a plant's rate
  /// for nothing.
  test('deterministic: two builds measure identically', () {
    final a = _measure(missilefactoryTemplate());
    final b = _measure(missilefactoryTemplate());
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
  });

  /// A colony save holds the floor mid-run (§3 "Persistence"): workers
  /// mid-trip, cranes mid-lift, crates part-unpacked. Loading must go on
  /// bit for bit as if the game had never stopped.
  test('save → load mid-run continues identically', () {
    final a = FactoryFloor.fromBlueprint(missilefactoryTemplate());
    final pa = InfiniteColonyPort();
    a.step(437.3, pa); // leaves a part sub-step in the carry
    expect(a.handlers.any((h) => h.state != HandlerState.idle), isTrue,
        reason: 'the save catches handlers at work');

    final saved = jsonEncode(a.toJson());
    final b = FactoryFloor.fromJson(
        (jsonDecode(saved) as Map).cast<String, Object?>());
    expect(jsonEncode(b.toJson()), saved, reason: 'load is lossless');

    final pb = InfiniteColonyPort();
    for (var i = 0; i < 4; i++) {
      a.step(75.1, pa);
      b.step(75.1, pb);
    }
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(pb.given['missiles'], greaterThan(0));
  });

  /// Nothing is made from nothing: every commodity unit on the floor came
  /// through a receiving door or a craft, at every point of the run
  /// (start-up rush included), so the plant can't mint missiles.
  test('conserves every commodity unit through its own run', () {
    final f = FactoryFloor.fromBlueprint(missilefactoryTemplate());
    final port = InfiniteColonyPort();
    for (var i = 0; i < 12; i++) {
      f.step(100, port);
      expect(conservationError(f), isEmpty, reason: 'after ${f.simSeconds}s');
    }
    expect(f.ledger.shipped['missiles'], greaterThan(0));
  });
}
