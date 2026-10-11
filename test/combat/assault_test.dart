// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/launch/snapshots.dart';
import 'package:acro_space_simulator/domain/combat/objective.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/preview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'combat_fixtures.dart';

/// A source of [troopers] in barracks of 30 jobs (15 ready each).
SourceSnapshot source({int troopers = 45, String id = 'src'}) {
  final sites = <TrooperSource>[];
  var left = troopers, i = 0;
  while (left > 0) {
    final n = left > 15 ? 15 : left;
    sites.add(TrooperSource(
      siteId: 'b$i',
      type: 'barracks',
      jobs: 30,
      ready: true,
      available: n,
      kitPerTrooperDay: const {'rations': 2, 'guns': 0.2, 'ammo': 1.2},
    ));
    left -= n;
    i++;
  }
  return SourceSnapshot(
    colonyId: id,
    name: 'Garrison Town',
    bodyId: 'moon',
    sources: sites,
    stock: const {'rations': 9999, 'guns': 999, 'ammo': 9999, 'fuel': 999},
  );
}

/// An independent colony laid out on a line: the port east, the seat west.
LaunchSnapshot independentTown({
  int regulars = 0,
  List<EmplacementSite> emplacements = const [],
  double population = 120,
  double shelter = 0,
  double boost = 0,
}) =>
    LaunchSnapshot(
      colonyId: 'rebels',
      bodyId: 'moon',
      population: population,
      mood: 0.6,
      hunger: 0,
      severity: 0.4,
      wish: 0,
      spaceportJobs: 20,
      gunsInStock: 10,
      portSeized: false,
      independent: true,
      regulars: regulars,
      emplacements: emplacements,
      shelterCover: shelter,
      resolveBoost: boost,
      objectives: const [
        ObjectiveSite(kind: 'seat', siteId: 'hall', e: -300, n: 0, areaM2: 4000),
        ObjectiveSite(kind: 'port', siteId: 'pad', e: 300, n: 0, areaM2: 20000),
        ObjectiveSite(kind: 'lifeSupport', siteId: 'farm', e: 0, n: 200, areaM2: 160000),
        ObjectiveSite(kind: 'power', siteId: 'solar', e: 0, n: -250, areaM2: 600000),
      ],
    );

PlannedOperation plan(LaunchSnapshot t,
        {int troopers = 45, Roe roe = Roe.restrained, int garrison = 4, int opId = 1}) =>
    planColonyAssault(
      operationId: opId,
      target: t,
      sources: [source(troopers: troopers)],
      draws: [
        for (final s in source(troopers: troopers).sources)
          TrooperDraw('src', s.siteId, s.available)
      ],
      garrison: garrison,
      // Two objectives' fighting: three days of kit is one port's worth.
      kitDays: 6,
      roe: roe,
    );

void main() {
  group('the battle graph', () {
    test('objectives come from the colony, the LZ lands out past the port', () {
      final op = plan(independentTown()).operation!;
      expect([for (final o in op.graph.objectives) o.id],
          ['lifeSupport', 'lz', 'port', 'power', 'seat']);
      expect(op.goalId, 'seat');
      expect(op.kind, OperationKind.colonyAssault);
      // Every node is linked to two others at least once, no pair twice.
      final pairs = {for (final l in op.graph.links) '${l.a}-${l.b}'};
      expect(pairs.length, op.graph.links.length);
      for (final l in op.graph.links) {
        expect(l.marchS, greaterThanOrEqualTo(kMinMarchS));
      }
      // The LZ is 450 m east of the port, linked to it and to the farm; the
      // shortest march to the seat skirts the port by the farm.
      expect(op.path, ['lz', 'lifeSupport', 'seat']);
    });

    test('the shortest path is by march time, ties by id', () {
      final op = Operation(
        id: 1,
        targetColonyId: 't',
        goalId: 'seat',
        lzId: 'lz',
        graph: ObjectiveGraph([
          for (final id in ['lz', 'port', 'power', 'seat'])
            Objective(id: id, kind: ObjectiveKind.values.byName(id), value: 1, width: 10)
        ], const [
          ObjectiveLink('lz', 'port', 100),
          ObjectiveLink('lz', 'power', 100),
          ObjectiveLink('port', 'seat', 100),
          ObjectiveLink('power', 'seat', 50),
        ]),
        formations: const [],
        militia: MilitiaPool(),
        defenderFaction: 'colony:t',
      );
      expect(op.path, ['lz', 'power', 'seat']);
    });

    test('defenders: holders at the port, regulars at the seat, guns where they '
        'stand', () {
      final op = plan(independentTown(regulars: 20, emplacements: const [
        EmplacementSite('gun-1', 280, 30, 4),
        EmplacementSite('gun-2', -310, -20, 4),
      ])).operation!;
      final def = [for (final f in op.formations) if (f.side == CombatSide.defender) f];
      expect(def.where((f) => f.kind == FormationKind.militia).single.at, 'port');
      final regs = def.where((f) => f.kind == FormationKind.regular).toList();
      expect([for (final f in regs) f.count], [7, 7, 6]);
      expect(regs.every((f) => f.at == 'seat'), isTrue);
      final guns = def.where((f) => f.kind == FormationKind.emplacement).toList();
      expect([for (final g in guns) g.at], ['port', 'seat']);
      expect(guns.every((g) => g.counterClass == CounterClass.empHmg), isTrue);
    });

    test('it refuses a colony that takes orders, and a plan with no garrison', () {
      final colonial = LaunchSnapshot(
        colonyId: 'c',
        bodyId: 'moon',
        population: 50,
        mood: 0.5,
        hunger: 0,
        severity: 0,
        wish: 0,
        spaceportJobs: 10,
        gunsInStock: 0,
        portSeized: false,
      );
      expect(plan(colonial).refusal, contains('takes your orders'));
      expect(plan(independentTown(), garrison: 0).refusal, contains('garrison'));
    });
  });

  group('the fight', () {
    test('a strong force takes the objectives on its way in order, and wins', () {
      final op = plan(independentTown(), troopers: 45).operation!;
      final taken = <String>[];
      var guard = 0;
      while (!op.resolved && guard++ < 20000) {
        op.advance(1);
        for (final o in op.graph.objectives) {
          if (o.kind != ObjectiveKind.lz && o.control >= 0.5 && !taken.contains(o.id)) {
            taken.add(o.id);
          }
        }
      }
      expect(op.outcome, OperationOutcome.won, reason: '${op.band}');
      expect(taken, ['lifeSupport', 'seat']);
      // ignore: avoid_print
      print('45 troopers vs ${op.defenderRaised}: ${op.band}, ${op.attackerDead} dead, '
          '${op.seconds.round()} s, taken $taken');
    });

    test('guns and regulars make the same force pay more', () {
      int lost(LaunchSnapshot t) {
        var sum = 0;
        for (var i = 1; i <= 12; i++) {
          final op = plan(t, opId: i).operation!;
          runOp(op, dt: 1, maxS: 20000);
          sum += op.attackerRemoved;
        }
        return sum;
      }

      final open = lost(independentTown());
      final held = lost(independentTown(regulars: 16, emplacements: const [
        EmplacementSite('gun-1', 280, 30, 4),
      ]));
      expect(held, greaterThan(open));
    });

    test('a gun emplacement never leaves its ground, broken or not', () {
      final op = plan(independentTown(emplacements: const [
        EmplacementSite('gun-1', 280, 30, 4),
      ])).operation!;
      final gun = op.formations.firstWhere((f) => f.kind == FormationKind.emplacement);
      var guard = 0;
      while (!op.resolved && guard++ < 20000) {
        op.advance(1);
        expect(gun.at, 'port');
      }
    });

    test('Standard ROE fights harder and kills townsfolk; shelters spare them', () {
      final r = plan(independentTown(), roe: Roe.restrained).operation!;
      final s = plan(independentTown(), roe: Roe.standard).operation!;
      final sh = plan(independentTown(shelter: 1), roe: Roe.standard).operation!;
      for (final op in [r, s, sh]) {
        runOp(op, dt: 1, maxS: 20000);
      }
      expect(r.civilianDead, 0);
      expect(s.defenderDead, greaterThan(0));
      expect(s.civilianDead, greaterThan(0));
      expect(sh.civilianDead, 0);
      expect(s.resolvedAtStep, lessThanOrEqualTo(r.resolvedAtStep));
    });

    test('a beaten-off attack hardens the town: resolve raises the militia', () {
      final calm = plan(independentTown()).operation!;
      final angry = plan(independentTown(boost: 0.2)).operation!;
      expect(angry.militia.total, greaterThan(calm.militia.total));
    });
  });

  group('determinism', () {
    test('twin runs agree to the byte, and a save resumes as if it never stopped',
        () {
      final a = plan(independentTown(regulars: 8)).operation!;
      final b = plan(independentTown(regulars: 8)).operation!;
      runOp(a, dt: 0.5, maxS: 20000);
      for (var i = 0; i < 400; i++) {
        b.advance(0.5);
      }
      final resumed = Operation.fromJson(
          (jsonDecode(jsonEncode(b.toJson())) as Map).cast<String, dynamic>());
      runOp(resumed, dt: 0.5, maxS: 20000);
      expect(jsonEncode(resumed.toJson()), jsonEncode(a.toJson()));
    });

    test('the preview runs an assault, and shows a spread', () {
      final p = OperationPreview(plan(independentTown(regulars: 12)).operation!, runs: 16)
        ..runAll();
      expect(p.results, hasLength(16));
      expect(p.wins, greaterThan(0));
    });
  });
}
