// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/station_ports.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rocketfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Explicit machine ports (docs/plans/factory-floors.md §10 item 19): belts
/// connect to fixed input and output ports per recipe slot, handlers work a
/// station at its hand port, and arms no longer touch machines.
void main() {
  const pin = FactoryItem(
      id: 'test:pin', label: 'Pin', loadClass: LoadClass.hand, kgPerUnit: 1);
  const plate = FactoryItem(
      id: 'test:plate', label: 'Plate', loadClass: LoadClass.hand,
      kgPerUnit: 2);
  const joint = FactoryItem(
      id: 'test:joint', label: 'Joint', loadClass: LoadClass.hand,
      kgPerUnit: 3);
  /// Two inputs on two ports: pins on input 1 (west), plates on input 2
  /// (north).
  const join = FactoryRecipe(
      id: 'test:join', label: 'Join', station: StationKind.assembler,
      inputs: [ItemQty('test:pin', 1), ItemQty('test:plate', 1)],
      outputs: [ItemQty('test:joint', 1)], seconds: 1, powerKw: 1);

  setUpAll(() {
    ensureFactoryCatalog();
    registerRocketPartsChain();
    for (final i in [pin, plate, joint]) {
      FactoryItems.register(i);
    }
    FactoryRecipes.register(join);
  });

  test('every station kind has a port for every recipe slot it runs', () {
    for (final st in StationKind.values) {
      final l = kStationPorts[st];
      expect(l, isNotNull, reason: '$st has a layout');
      for (final r in FactoryRecipes.forStation(st)) {
        expect(l!.inputs.length, greaterThanOrEqualTo(r.inputs.length),
            reason: '${r.id} inputs on $st');
        expect(l.outputs.length, greaterThanOrEqualTo(r.outputs.length),
            reason: '${r.id} outputs on $st');
      }
      // Every port sits on the footprint's edge, facing out through it, and
      // no two share an outside tile.
      for (final dir in Dir4.values) {
        const at = TilePos(10, 10);
        final fp = Placement(
                id: 1,
                kind: EntityKind.machine,
                pos: at,
                dir: dir,
                recipe: FactoryRecipes.forStation(st).first.id)
            .footprint;
        final ports = stationPorts(st, at, dir);
        final outside = <TilePos>{};
        for (final p in ports) {
          expect(fp.contains(p.tile), isTrue, reason: '$st $dir $p inside');
          expect(fp.contains(p.outside), isFalse,
              reason: '$st $dir $p faces out');
          expect(outside.add(p.outside), isTrue,
              reason: '$st $dir $p has its own outside tile');
        }
      }
    }
  });

  test('rotation moves the ports with the facing', () {
    Placement asm(Dir4 d) => Placement(
        id: 1, kind: EntityKind.machine, pos: const TilePos(0, 0), dir: d,
        recipe: join.id);
    MachinePort in0(Dir4 d) =>
        portsOf(asm(d)).firstWhere((p) => p.role == PortRole.input);
    MachinePort out0(Dir4 d) =>
        portsOf(asm(d)).firstWhere((p) => p.role == PortRole.output);
    // East: in at the back (west) middle, out at the front (east) middle.
    expect(in0(Dir4.east).tile, const TilePos(0, 1));
    expect(in0(Dir4.east).feedDir, Dir4.east);
    expect(out0(Dir4.east).tile, const TilePos(2, 1));
    expect(out0(Dir4.east).out, Dir4.east);
    // North: flow runs south to north.
    expect(in0(Dir4.north).tile, const TilePos(1, 0));
    expect(in0(Dir4.north).feedDir, Dir4.north);
    expect(out0(Dir4.north).tile, const TilePos(1, 2));
    expect(out0(Dir4.north).out, Dir4.north);
    // West and south mirror them.
    expect(out0(Dir4.west).tile, const TilePos(0, 1));
    expect(out0(Dir4.west).out, Dir4.west);
    expect(out0(Dir4.south).tile, const TilePos(1, 0));
    expect(out0(Dir4.south).out, Dir4.south);
    // A non-square station keeps its ports on its own footprint.
    final mill = Placement(
        id: 1, kind: EntityKind.machine, pos: const TilePos(0, 0),
        dir: Dir4.north, recipe: 'steel:roll');
    for (final p in portsOf(mill)) {
      expect(mill.footprint.contains(p.tile), isTrue);
    }
  });

  test('slot items and labels follow the recipe', () {
    final m = Placement(
        id: 1, kind: EntityKind.machine, pos: const TilePos(0, 0),
        recipe: 'steel:smelt');
    final ports = portsOf(m);
    final r = FactoryRecipes.byId('steel:smelt')!;
    final outs = [for (final p in ports) if (p.role == PortRole.output) p];
    expect(recipeSlotItem(r, outs[0])!.item, 'pigIron');
    expect(recipeSlotItem(r, outs[1])!.item, 'slag');
    expect(portLabel(r, outs[1]), 'Output 2: Slag (byproduct)');
    final a = Placement(
        id: 1, kind: EntityKind.machine, pos: const TilePos(0, 0),
        recipe: RocketPartsRecipes.weldFrame.id);
    final ins = [for (final p in portsOf(a)) if (p.role == PortRole.input) p];
    expect(portLabel(RocketPartsRecipes.weldFrame, ins[0]), 'Input 1: Tubes');
    expect(portLabel(RocketPartsRecipes.weldFrame, ins[1]), 'Input 2: unused');
    expect(handPortOf(a)!.role, PortRole.hand);
  });

  /// pins → west input, plates → north input, joints out east to a
  /// shipping dock. [swap] lays the two feeds into the WRONG ports.
  FactoryFloor joinLine({bool swap = false, bool outBelt = true}) {
    final l = Lay();
    // Assembler 3×3 at (6, 2): input 1 is (6, 3) fed from (5, 3) going
    // east; input 2 is (7, 4) fed from (7, 5) going south; output 1 is
    // (8, 3) onto (9, 3).
    l.add(EntityKind.machine, 6, 2, recipe: join.id);
    l.add(EntityKind.receivingDock, 0, 3, item: swap ? plate.id : pin.id);
    l.beltRow(2, 5, 3);
    l.add(EntityKind.receivingDock, 7, 8,
        dir: Dir4.south, item: swap ? pin.id : plate.id);
    for (final y in [7, 6, 5]) {
      l.add(EntityKind.belt, 7, y, dir: Dir4.south);
    }
    if (outBelt) l.add(EntityKind.belt, 9, 3);
    l.add(EntityKind.shippingDock, 10, 3);
    return FactoryFloor.fromBlueprint(l.blueprint(14, 10));
  }

  test('belts into the right ports feed; the output port ships', () {
    final f = joinLine();
    final port = InfiniteColonyPort();
    f.step(60, port);
    expect(f.ledger.shipped['test:joint'], greaterThan(10));
    expect(conservationError(f), isEmpty);
  });

  test('a belt into the wrong port, or with the wrong item, does not feed',
      () {
    final f = joinLine(swap: true);
    f.step(60, InfiniteColonyPort());
    expect(f.ledger.shipped['test:joint'], isNull);
    final asm = f.blueprint.placements
        .firstWhere((p) => p.kind == EntityKind.machine);
    expect(f.contentsOf(asm.id), isEmpty, reason: 'nothing got in');
    expect(f.statusOf(asm.id), MachineStatus.starved);
    expect(conservationError(f), isEmpty);
    // A belt at the right tile but pointing past the port feeds nothing.
    final l = Lay();
    l.add(EntityKind.machine, 6, 2, recipe: join.id);
    l.add(EntityKind.receivingDock, 5, 0, dir: Dir4.north, item: pin.id);
    l.add(EntityKind.belt, 5, 2, dir: Dir4.north);
    l.add(EntityKind.belt, 5, 3, dir: Dir4.north); // past (6, 3), not into
    final g = FactoryFloor.fromBlueprint(l.blueprint(14, 10));
    g.step(30, InfiniteColonyPort());
    expect(g.contentsOf(1), isEmpty);
  });

  test('an output port with no belt and no handler blocks the station', () {
    final f = joinLine(outBelt: false);
    f.step(60, InfiniteColonyPort());
    final asm = f.blueprint.placements
        .firstWhere((p) => p.kind == EntityKind.machine);
    expect(f.statusOf(asm.id), MachineStatus.blocked);
    expect(f.ledger.shipped['test:joint'], isNull);
    expect(conservationError(f), isEmpty);
  });

  test('handlers drop and pick at the hand port, and only there', () {
    // Plates come by belt; pins sit in a chest a walker carries from. The
    // joints leave by the walker to a shipping dock (no output belt).
    final l = Lay();
    final asm = l.add(EntityKind.machine, 6, 2, recipe: join.id);
    l.add(EntityKind.receivingDock, 7, 8, dir: Dir4.south, item: plate.id);
    for (final y in [7, 6, 5]) {
      l.add(EntityKind.belt, 7, y, dir: Dir4.south);
    }
    l.add(EntityKind.receivingDock, 0, 0, item: pin.id);
    l.add(EntityKind.chest, 2, 0);
    l.add(EntityKind.shippingDock, 12, 0);
    final f = FactoryFloor.fromBlueprint(l.blueprint(16, 10, walkers: 1));
    final hand = handPortOf(f.blueprint.placements.first)!;
    expect(hand.outside, const TilePos(8, 1));
    final port = InfiniteColonyPort();
    final seen = <TilePos>{};
    for (var i = 0; i < 4 * 240; i++) {
      final job = handlerJobs(f).values.firstOrNull;
      f.step(0.25, port);
      final now = handlerJobs(f).values.firstOrNull;
      if (job == null) continue;
      final (state, j) = job;
      // A pick at the machine (toPickup → carrying) or a drop into it
      // (carrying → done): note where the walker stood.
      final picked = state == 'toPickup' && j[2] == asm && now?.$1 == 'carrying';
      final dropped = state == 'carrying' && j[3] == asm && now == null;
      if (picked || dropped) {
        final h = f.handlers.single;
        seen.add(TilePos(h.x.round(), h.y.round()));
      }
    }
    expect(f.ledger.shipped['test:joint'], greaterThan(0));
    expect(seen, {hand.outside});
    expect(conservationError(f), isEmpty);
  });

  test('arms refuse machines, and say so', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 3, item: pin.id);
    l.beltRow(2, 4, 3);
    final arm = l.add(EntityKind.arm, 5, 3); // belt (4, 3) → machine (6, 3)
    final asm = l.add(EntityKind.machine, 6, 2, recipe: join.id);
    final out = l.add(EntityKind.arm, 9, 3); // machine (8, 3) → chest
    l.add(EntityKind.chest, 10, 3);
    final f = FactoryFloor.fromBlueprint(l.blueprint(14, 10));
    f.step(30, InfiniteColonyPort());
    expect(f.contentsOf(asm), isEmpty, reason: 'the arm fed nothing');
    expect(f.contentsOf(arm), isEmpty, reason: 'it never even picked');
    final ix = {for (final p in f.blueprint.placements) p.id: p};
    Placement? at(TilePos t) {
      for (final p in f.blueprint.placements) {
        if (p.footprint.contains(t)) return p;
      }
      return null;
    }

    expect(armMachineNote(ix[arm]!, at), kArmMachineNote);
    expect(armMachineNote(ix[out]!, at), kArmMachineNote);
    expect(conservationError(f), isEmpty);
  });

  test('deterministic, and save/load mid-run continues identically', () {
    final a = joinLine(), b = joinLine();
    final port = InfiniteColonyPort();
    a.step(37.5, port);
    b.step(37.5, InfiniteColonyPort());
    expect(b.toJson().toString(), a.toJson().toString());
    final c = FactoryFloor.fromJson(a.toJson());
    a.step(40, port);
    c.step(40, InfiniteColonyPort());
    expect(c.toJson().toString(), a.toJson().toString());
  });
}
