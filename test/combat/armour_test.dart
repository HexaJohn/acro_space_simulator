// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/combat/base/base_modules.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/resolver.dart';
import 'package:acro_space_simulator/domain/combat/resolver_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'assault_test.dart' as a;

/// Armour, heavy weapons and destruction: combat.md §7L.
void main() {
  SourceSnapshot source() {
    final s = a.source(troopers: 30);
    return SourceSnapshot(
      colonyId: s.colonyId,
      name: s.name,
      bodyId: s.bodyId,
      sources: s.sources,
      stock: {...s.stock, 'ore': 9999, 'steel': 500, 'electronics': 50},
      supportAvailable: 20,
      buildings: const ['barracks', 'gunfactory', 'spaceport', 'base'],
    );
  }

  Operation assault({Roe roe = Roe.restrained, BaseManifest? base}) {
    final src = source();
    return planColonyAssault(
      operationId: 1,
      target: a.independentTown(regulars: 6),
      sources: [src],
      draws: [for (final s in src.sources) TrooperDraw('src', s.siteId, s.available)],
      garrison: 2,
      kitDays: 6,
      roe: roe,
      base: base,
    ).operation!;
  }

  void until(Operation op, bool Function() done, {int max = 6000}) {
    for (var i = 0; i < max && !done(); i++) {
      op.advance(1);
    }
  }

  test('the vehicle bay needs the Fortress, then rolls out a crewed APC', () {
    final op = assault(
        base: const BaseManifest(materiel: 900, support: 16, steel: 200, doctrine: Doctrine.manual));
    final b = op.base!;
    until(op, () => b.deployed);
    expect(b.whyNot(ModuleKind.vehicleBay, 1), contains('Fortress'));
    expect(b.orderUpgrade(BaseTier.station), isTrue);
    until(op, () => b.core!.tier == BaseTier.station, max: 300);
    expect(b.orderUpgrade(BaseTier.fortress), isTrue);
    until(op, () => b.core!.tier == BaseTier.fortress, max: 300);
    expect(b.whyNot(ModuleKind.vehicleBay, 1), isNull);
    expect(b.orderBuild(ModuleKind.vehicleBay, 1), isTrue);
    until(op, () => b.apcsBuilt > 0 || op.resolved, max: 600);
    expect(b.apcsBuilt, 1);
    final apc = op.formations.lastWhere((f) => f.kind == FormationKind.armour);
    expect(apc.counterClass, CounterClass.arm);
    expect(apc.count, kApcCrew);
    expect(formationStrength(apc, op.tuning, armed: true),
        greaterThan(formationStrength(apc, op.tuning, armed: true) / op.tuning.armourPower * 3));
  });

  test('an AT turret is an anti-armour gun; the counters favour it against armour', () {
    final op = assault(base: const BaseManifest(materiel: 600, steel: 100, doctrine: Doctrine.manual));
    final b = op.base!;
    until(op, () => b.deployed);
    expect(b.orderBuild(ModuleKind.atTurret, 1), isTrue);
    until(op, () => b.countOf(ModuleKind.atTurret) == 1 && b.modules.any((m) => m.kind == ModuleKind.atTurret && m.formationId != null),
        max: 300);
    final m = b.modules.firstWhere((m) => m.kind == ModuleKind.atTurret);
    expect(op.formationById(m.formationId!)!.counterClass, CounterClass.empAt);
    expect(kCounters.factor(CounterClass.empAt, CounterClass.arm), greaterThan(1));
    expect(kCounters.factor(CounterClass.inf, CounterClass.arm), lessThan(1));
    expect(CounterTuning.byName('halo1').factor(CounterClass.inf, CounterClass.arm), 1,
        reason: 'an operation launched on the old table keeps it');
  });

  test('Heavy rules: harder fire, more civilians, the Seat strikeable, the fought-over razed', () {
    final heavy = assault(roe: Roe.heavy);
    final std = assault(roe: Roe.standard);
    for (final op in [heavy, std]) {
      until(op, () => op.resolved, max: 20000);
    }
    expect(heavy.razedSites, isNotEmpty);
    expect(std.razedSites, isEmpty);
    expect(heavy.razedSites, isNot(contains('farm')), reason: 'never life support');
    expect(heavy.strikeAllowed(heavy.graph.byId('seat')!), isTrue);
    expect(std.strikeAllowed(std.graph.byId('seat')!), isFalse);
    expect(heavy.civilianDead, greaterThan(0));
  });
}
