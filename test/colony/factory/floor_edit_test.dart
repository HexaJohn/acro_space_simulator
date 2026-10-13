// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_unlocks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// The editor (phase 2) edits a LIVE floor through [FactoryFloorEditor].
/// Every edit must obey the blueprint's own rules (in the hall, no solid
/// overlap, known recipe), refuse with a reason the UI can show, and bump
/// [FactoryFloorView.layoutRev] only when it changed something — the
/// renderer's and the path cache's invalidation key.
void main() {
  setUpAll(ensureFactoryCatalog);

  FactoryFloor floor() {
    final l = Lay();
    l.add(EntityKind.machine, 2, 2,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
    return FactoryFloor.fromBlueprint(l.blueprint(12, 10));
  }

  test('place refuses overlap, out-of-hall and unknown recipes', () {
    final f = floor();
    final rev = f.layoutRev;
    final over = f.place(const Placement(
        id: 0, kind: EntityKind.chest, pos: TilePos(3, 3)));
    expect(over.refusal, EditRefusal.overlaps);
    expect(over.otherId, 1);
    expect(f.place(const Placement(
            id: 0, kind: EntityKind.belt, pos: TilePos(12, 0)))
        .refusal, EditRefusal.outOfHall);
    expect(f.place(const Placement(
            id: 0, kind: EntityKind.machine, pos: TilePos(7, 0),
            recipe: 'nope'))
        .refusal, EditRefusal.unknownRecipe);
    expect(f.layoutRev, rev, reason: 'refused edits change nothing');

    final ok = f.place(const Placement(
        id: 99, kind: EntityKind.aisle, pos: TilePos(0, 0), span: (12, 2)));
    expect(ok.ok, isTrue, reason: 'an aisle is a marking over anything');
    expect(ok.placementId, 2, reason: 'the floor assigns ids');
    expect(f.layoutRev, rev + 1);
  });

  test('rotate, setRecipe, setMode, remove and hire', () {
    final f = floor();
    var rev = f.layoutRev;
    final belt = f.place(const Placement(
        id: 0, kind: EntityKind.belt, pos: TilePos(9, 2))).placementId!;
    expect(f.layoutRev, ++rev);
    expect(f.rotate(belt).ok, isTrue);
    expect(f.blueprint.byId(belt)!.dir, Dir4.east.turnCw);
    expect(f.layoutRev, ++rev);

    // A furnace (4x3) at (6, 6) facing north is 3x4: it would hit the chest
    // at (7, 9).
    expect(f.place(const Placement(
        id: 0, kind: EntityKind.chest, pos: TilePos(7, 9))).ok, isTrue);
    final m = f.place(const Placement(id: 0, kind: EntityKind.machine,
        pos: TilePos(6, 6), recipe: 'steel:cast')).placementId!;
    rev = f.layoutRev;
    expect(f.rotate(m).refusal, EditRefusal.overlaps);
    expect(f.layoutRev, rev);

    expect(f.setRecipe(belt, 'steel:cast').refusal, EditRefusal.wrongKind);
    expect(f.setRecipe(1, 'nope').refusal, EditRefusal.unknownRecipe);
    expect(f.setRecipe(1, 'steel:tube').ok, isTrue);
    expect(f.setMode(1, MachineMode.manual).ok, isTrue);
    expect(f.jobDemand, 2 + 1, reason: 'manual pair + assisted furnace');

    f.unlocks = FactoryUnlocks.starter;
    expect(f.hire(HandlerKind.forklift, 1).refusal, EditRefusal.notAllowed,
        reason: 'a starter colony has no forklifts yet');
    f.unlocks = FactoryUnlocks.all;
    expect(f.hire(HandlerKind.onFoot, 2).ok, isTrue);
    expect(f.handlers.length, 2);
    expect(f.hire(HandlerKind.onFoot, -3).refusal, EditRefusal.notAllowed);
    expect(f.hire(HandlerKind.onFoot, -1).ok, isTrue);
    expect(f.handlers.single.id, 1, reason: 'the newest hire goes first');

    expect(f.remove(belt).ok, isTrue);
    expect(f.remove(belt).refusal, EditRefusal.noSuchPlacement);
    expect(f.blueprint.validate(), isEmpty);
  });

  test('a wall placed mid-trip re-routes the worker', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'steel');
    l.add(EntityKind.chest, 2, 0);
    final packer = l.add(EntityKind.machine, 9, 2,
        recipe: SteelRecipes.packSteel.id, mode: MachineMode.manual);
    final f = FactoryFloor.fromBlueprint(l.blueprint(14, 9, walkers: 1));
    final port = InfiniteColonyPort();
    f.step(6, port); // the worker is on its way
    final rev = f.layoutRev;
    for (var y = 0; y <= 6; y++) {
      expect(f.place(Placement(id: 0, kind: EntityKind.chest,
          pos: TilePos(6, y))).ok, isTrue);
    }
    expect(f.layoutRev, rev + 7);
    for (var i = 0; i < 4 * 120; i++) {
      f.step(0.25, port);
      final h = f.handlers.single;
      if (h.x > 5 && h.x < 7) {
        expect(h.y, greaterThanOrEqualTo(6.99), reason: 'went through the wall');
      }
    }
    expect(f.contentsOf(packer)['steel'], greaterThan(0));
  });
}
