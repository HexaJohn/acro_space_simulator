// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/combat/base/base_modules.dart';
import 'package:acro_space_simulator/domain/combat/base/forward_base.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/preview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// The forward base: combat.md §7C.
void main() {
  SourceSnapshot source({
    int troopers = 30,
    List<String> buildings = const ['barracks', 'gunfactory', 'spaceport'],
    double ore = 9999,
  }) {
    final s = a.source(troopers: troopers);
    return SourceSnapshot(
      colonyId: s.colonyId,
      name: s.name,
      bodyId: s.bodyId,
      sources: s.sources,
      stock: {...s.stock, 'ore': ore},
      supportAvailable: 20,
      buildings: buildings,
    );
  }

  Operation assault({
    int troopers = 30,
    BaseManifest? base = const BaseManifest(),
    List<String> buildings = const ['barracks', 'gunfactory', 'spaceport'],
    int regulars = 0,
    int opId = 1,
  }) {
    final src = source(troopers: troopers, buildings: buildings);
    final p = planColonyAssault(
      operationId: opId,
      target: a.independentTown(regulars: regulars),
      sources: [src],
      draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
      garrison: 2,
      kitDays: 6,
      base: base,
    );
    expect(p.refusal, isNull);
    return p.operation!;
  }

  void until(Operation op, bool Function() done, {int max = 5000}) {
    for (var i = 0; i < max && !done(); i++) {
      op.advance(1);
    }
  }

  test('the core deploys 30 s after the squads are down, with its landing turret', () {
    final op = assault();
    final b = op.base!;
    expect(b.materielC, 300 * 100 ~/ 4, reason: 'a quarter lands unpacked');
    expect(b.reserve, 10);
    until(op, () => op.phase == OperationPhase.engaged);
    expect(b.deployed, isFalse);
    until(op, () => b.deployed);
    expect(op.clock.steps, op.engagedAtStep + kDeployS + 1);
    final turret = b.modules.single;
    expect(turret.kind, ModuleKind.turret);
    final f = op.formationById(turret.formationId!)!;
    expect(f.kind, FormationKind.emplacement);
    expect(f.side, CombatSide.attacker);
    expect(f.at, op.lzId);
    expect(f.count, 2, reason: 'its crew, from the support staff');
    expect(b.reserve, 8);
  });

  test('Balanced builds pad, pod, turret — paying up front, one line, within power', () {
    final op = assault();
    final b = op.base!;
    until(op, () => b.modules.length >= 4 || op.resolved, max: 3000);
    expect(b.modules.map((m) => m.kind).toList().sublist(0, 4),
        [ModuleKind.turret, ModuleKind.supplyPad, ModuleKind.barracksPod, ModuleKind.turret]);
    expect(b.powerDemand, lessThanOrEqualTo(kCorePowerKw));
    // A second pad would push demand past the core's 20 kW: never built.
    for (var i = 0; i < 300; i++) {
      op.advance(1);
    }
    expect(b.countOf(ModuleKind.supplyPad), 1);
  });

  test('a module needs its home gate: no Arms Factory, no second turret', () {
    final op = assault(buildings: const ['barracks', 'spaceport']);
    final b = op.base!;
    until(op, () => b.deployed);
    expect(b.whyNot(ModuleKind.turret, 1), contains('Arms Factory'));
    for (var i = 0; i < 600; i++) {
      op.advance(1);
    }
    expect(b.countOf(ModuleKind.turret), 1, reason: 'only the landing turret');
  });

  test('pallets unpack at 0.5/s, and 1 more per supply pad', () {
    final op = assault(base: const BaseManifest(materiel: 600));
    final b = op.base!;
    until(op, () => b.deployed);
    final before = b.materielC + b.palletsC;
    op.advance(1);
    // Nothing is spent in this second (the first pick is waiting or paid).
    expect(b.materielC + b.palletsC + (b.job?.paidC ?? 0), greaterThanOrEqualTo(before - 1));
    expect(b.unpackC, kCoreUnpackC);
    until(op, () => b.padsOnline > 0);
    expect(b.unpackC, kCoreUnpackC + kPadUnpackC);
  });

  test("a player's order goes first, and a cancel refunds half", () {
    final op = assault(base: const BaseManifest(materiel: 600));
    final b = op.base!..autoBuild = false;
    until(op, () => b.deployed);
    expect(b.orderBuild(ModuleKind.barracksPod, 2), isTrue);
    op.advance(1);
    expect(b.job?.kind, ModuleKind.barracksPod);
    final left = b.materielC;
    b.cancelJob();
    expect(b.materielC, left + 50 * 100 ~/ 2);
    expect(b.orderBuild(ModuleKind.supplyPad, 9), isFalse, reason: 'no such socket');
  });

  test('squads at the LZ or one link out refill their kit from the base', () {
    final op = assault();
    final b = op.base!;
    // No militia to raid the LZ: kit is spent only in contact.
    op.militia
      ..armed = 0
      ..improvised = 0;
    until(op, () => b.deployed);
    final f = op.formations.firstWhere(
        (f) => f.side == CombatSide.attacker && f.kind == FormationKind.infantry);
    f.at = op.lzId;
    f.arriveStep = op.clock.steps;
    f.kitDays = 1;
    final rations = b.stockOf('rations');
    op.setOrder(OrderKind.hold);
    for (var i = 0; i < 30; i++) {
      op.advance(1);
    }
    expect(f.kitDays, closeTo(2, 0.05));
    expect(b.stockOf('rations'), lessThan(rations));
  });

  test('a base draws raids, fights them from behind its works, and can be overrun', () {
    // A strong town against a held force: the defender raids the LZ.
    final op = assault(troopers: 15, regulars: 40);
    final b = op.base!;
    op.setOrder(OrderKind.hold);
    until(op, () => b.deployed);
    var raided = false;
    until(op, () {
      raided = raided ||
          op.formations.any((f) => f.side == CombatSide.defender && f.at == op.lzId);
      return b.overrun || op.resolved;
    }, max: 6000);
    expect(raided, isTrue, reason: 'the LZ is worth raiding once a base stands on it');
    // ignore: avoid_print
    print('raid: overrun ${b.overrun}, outcome ${op.outcome}, captured ${b.capturedMaterielC / 100}');
    if (b.overrun) {
      expect(b.modules, isEmpty);
      expect(b.supportDead + b.supportWounded, greaterThan(0));
    }
  });

  test('held by the defender for a minute, the base is overrun: modules lost, crews hit, '
      'half the stock the target\'s', () {
    final op = assault();
    final b = op.base!;
    until(op, () => b.modules.length >= 2);
    final stock = b.stockOf('rations');
    final m = b.materielC + b.palletsC;
    final lz = op.graph.byId(op.lzId)!;
    for (var i = 0; i < 61 && !b.overrun; i++) {
      lz.control = -1;
      op.advance(1);
    }
    expect(b.overrun, isTrue);
    expect(b.modules, isEmpty);
    expect(b.standing, isFalse);
    expect(b.capturedStockC[kBaseStock.indexOf('rations')], closeTo(stock / 2, stock * 0.05 + 2));
    expect(b.capturedMaterielC, lessThanOrEqualTo(m ~/ 2 + 100));
    expect(b.fAttBonus(op.lzId, op.lzId), 0);
    expect(b.events.map((e) => e.$1), contains(BaseEventKind.overrun));
  });

  test('supply runs are asked for every 3 days less pads, and land once shipped', () {
    final op = assault();
    final b = op.base!;
    until(op, () => b.runs.isNotEmpty, max: 6000);
    final r = b.runs.first;
    expect(r.posted, isFalse, reason: 'the world posts it to the source');
    expect(r.materielC, kRunMateriel * 100);
    r.posted = true;
    final pallets = b.palletsC;
    b.runShipped(r.id, 4000, [1000, 0, 1000], op.clock.steps + 10);
    for (var i = 0; i < 12; i++) {
      op.advance(1);
    }
    expect(b.runs, isEmpty);
    expect(b.palletsC + b.materielC, greaterThan(pallets));
  });

  test('a light operation fights as before; a preview of a base runs its doctrine', () {
    final light = assault(base: null);
    expect(light.base, isNull);
    final p = OperationPreview(assault(), runs: 4)..runAll();
    expect(p.results, hasLength(4));
  });

  test('save, load and carry on equals carrying on, mid-build', () {
    final x = assault(), y = assault();
    until(x, () => x.base!.job != null);
    until(y, () => y.base!.job != null);
    final back = Operation.fromJson(
        (jsonDecode(jsonEncode(y.toJson())) as Map).cast<String, dynamic>());
    for (var i = 0; i < 800; i++) {
      x.advance(1);
      back.advance(1);
    }
    expect(jsonEncode(back.toJson()), jsonEncode(x.toJson()));
  });

  test('the base catalog is the combat\'s own, never a colony building', () {
    final colony = {for (final s in kUtilCatalog) s.label};
    for (final m in kBaseModules) {
      expect(colony.contains(m.label), isFalse, reason: m.label);
    }
    expect(ForwardBase.socketLabel(SocketKind.turret, 0), 'Landing turret');
  });

  test('a base the lead source cannot pay for is refused, and says why', () {
    final poor = source(ore: 50);
    final p = planColonyAssault(
      operationId: 1,
      target: a.independentTown(),
      sources: [poor],
      draws: [for (final s in poor.sources) TrooperDraw('src', s.siteId, s.available)],
      base: const BaseManifest(materiel: 300),
    );
    expect(p.refusal, contains('only 50 ore'));
    final plan = planColonyAssault(
      operationId: 1,
      target: a.independentTown(),
      sources: [source()],
      draws: [for (final s in source().sources) TrooperDraw('src', s.siteId, s.available)],
      base: const BaseManifest(),
    );
    final support = plan.debits.firstWhere((d) => d.siteId == 'support');
    expect(support.troopers, 10);
    expect(support.kit['ore'], 300);
  });
}
