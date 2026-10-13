// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Automation is unlocked by milestone or research (phase 4), so a young
/// colony's floor must REFUSE what it hasn't unlocked — hiring a forklift,
/// switching a station to lights-out, laying a crane bay — with the same
/// `notAllowed` the editor shows. And the editor's ghost preview (`check`)
/// must answer exactly what `place` would, without touching the floor, or
/// the preview would lie about the click.
void main() {
  setUpAll(ensureFactoryCatalog);

  FactoryFloor starterFloor() {
    final l = Lay();
    l.add(
      EntityKind.machine,
      0,
      0,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.manual,
    );
    return FactoryFloor.fromBlueprint(
      l.blueprint(20, 10),
      unlocks: FactoryUnlocks.starter,
    );
  }

  test('a starter colony refuses locked hires, modes and placements', () {
    final f = starterFloor();
    for (final k in [
      HandlerKind.forklift,
      HandlerKind.crane,
      HandlerKind.agv,
    ]) {
      expect(f.hire(k, 1).refusal, EditRefusal.notAllowed, reason: k.name);
    }
    expect(f.hire(HandlerKind.onFoot, 1).ok, isTrue);
    expect(f.hire(HandlerKind.palletJack, 1).ok, isTrue);

    expect(f.setMode(1, MachineMode.automated).refusal, EditRefusal.notAllowed);
    expect(f.setMode(1, MachineMode.assisted).ok, isTrue);

    Placement at(EntityKind k, int x, {MachineMode? mode, (int, int)? span}) =>
        Placement(
          id: 0,
          kind: k,
          pos: TilePos(x, 6),
          recipe: k == EntityKind.machine ? SteelRecipes.cast.id : null,
          mode: mode,
          span: span,
        );
    expect(
      f.place(at(EntityKind.machine, 5, mode: MachineMode.automated)).refusal,
      EditRefusal.notAllowed,
    );
    expect(
      f.place(at(EntityKind.craneBay, 5, span: (3, 3))).refusal,
      EditRefusal.notAllowed,
    );
    expect(
      f.place(at(EntityKind.chargingBay, 5)).refusal,
      EditRefusal.notAllowed,
    );
    expect(
      f.place(at(EntityKind.machine, 5)).ok,
      isTrue,
      reason: 'the default (assisted) station is a starter mode',
    );
    expect(
      f.place(at(EntityKind.aisle, 10, span: (4, 2))).ok,
      isTrue,
      reason: 'aisles are paint: always allowed',
    );
  });

  test('unlocks gate purchases, never what is already on the floor', () {
    // A template uses forklifts and cranes whatever the colony has.
    final f = FactoryFloor.fromBlueprint(
      factoryTemplateFor('steelmill')!,
      unlocks: FactoryUnlocks.starter,
    );
    expect(f.handlers.where((h) => h.kind == HandlerKind.crane), hasLength(2));
    expect(
      f.hire(HandlerKind.forklift, -1).ok,
      isTrue,
      reason: 'letting a locked vehicle go is always allowed',
    );
    expect(f.hire(HandlerKind.forklift, 1).refusal, EditRefusal.notAllowed);

    // Revoking: a lights-out station keeps running as it was.
    final g = starterFloor()..unlocks = FactoryUnlocks.all;
    expect(g.setMode(1, MachineMode.automated).ok, isTrue);
    g.unlocks = FactoryUnlocks.starter;
    g.step(10, InfiniteColonyPort());
    expect(g.blueprint.byId(1)!.crew, MachineMode.automated);
    expect(g.statusOf(1), isNot(MachineStatus.unstaffed));
  });

  test('unlocks are the colony\'s: never in the floor\'s save', () {
    final f = starterFloor();
    final g = FactoryFloor.fromJson(f.toJson());
    expect(
      g.unlocks,
      same(FactoryUnlocks.all),
      reason: 'a load takes what the colony passes (default: all)',
    );
    expect(jsonEncode(f.toJson()), jsonEncode(g.toJson()));
  });

  test('check() answers what place() would, and changes nothing', () {
    final f = FactoryFloor.fromBlueprint(
      factoryTemplateFor('steelmill')!,
      unlocks: FactoryUnlocks.starter,
    );
    f.step(30, InfiniteColonyPort());
    final probes = [
      Placement(id: 0, kind: EntityKind.chest, pos: const TilePos(0, 27)),
      Placement(id: 0, kind: EntityKind.chest, pos: const TilePos(4, 4)),
      Placement(id: 0, kind: EntityKind.chest, pos: const TilePos(99, 0)),
      Placement(
        id: 0,
        kind: EntityKind.machine,
        pos: const TilePos(20, 0),
        recipe: 'nope',
      ),
      Placement(
        id: 0,
        kind: EntityKind.machine,
        pos: const TilePos(0, 24),
        recipe: SteelRecipes.packSteel.id,
        mode: MachineMode.automated,
      ),
      Placement(
        id: 0,
        kind: EntityKind.craneBay,
        pos: const TilePos(0, 26),
        span: (3, 2),
      ),
      Placement(
        id: 0,
        kind: EntityKind.aisle,
        pos: const TilePos(0, 26),
        span: (3, 2),
      ),
    ];
    for (final p in probes) {
      final before = jsonEncode(f.toJson());
      final rev = f.layoutRev;
      final c = f.check(p);
      expect(jsonEncode(f.toJson()), before, reason: 'check mutated: $p');
      expect(f.layoutRev, rev);
      final r = f.place(p);
      expect(
        (c.ok, c.refusal, c.otherId, c.placementId),
        (r.ok, r.refusal, r.otherId, r.placementId),
        reason: 'check and place disagree on $p',
      );
      if (r.ok) expect(f.remove(r.placementId!).ok, isTrue);
    }
  });
}
