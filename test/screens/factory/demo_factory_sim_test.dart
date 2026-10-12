// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/demo_factory_sim.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dev entry's stand-in floor has to look alive (or the editor's
/// drawing paths go untested by eye) and refuse bad edits the way the real
/// floor will. These pin both, so a broken demo is caught before a playtest.
void main() {
  /// The demo layout is valid as built and moves freight: items ride belts,
  /// handlers leave their start, and something ships.
  test('the demo floor runs: belts carry, handlers walk, goods ship', () {
    final sim = DemoFactorySim.demo();
    expect(sim.blueprint.validate(), isEmpty);
    final start = {for (final h in sim.handlers) h.id: (h.x, h.y)};
    final port = InfiniteColonyPort();
    var sawBelt = false;
    for (var i = 0; i < 240; i++) {
      sim.step(0.5, port);
      if (sim.beltItems.isNotEmpty) sawBelt = true;
    }
    expect(sawBelt, isTrue);
    expect(sim.simSeconds, closeTo(120, 1e-9));
    expect(
        sim.handlers.any((h) => (h.x, h.y) != start[h.id]), isTrue);
    expect(port.taken['ore'] ?? 0, greaterThan(0));
    expect(port.given.values.fold(0.0, (a, b) => a + b), greaterThan(0));
    final statuses = {
      for (final p in sim.blueprint.placements)
        if (p.kind == EntityKind.machine) sim.statusOf(p.id),
    };
    expect(statuses, contains(MachineStatus.working));
  });

  /// Same inputs, same floor: no clock, no RNG, no hash order.
  test('the demo floor is deterministic', () {
    final a = DemoFactorySim.demo(), b = DemoFactorySim.demo();
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    for (var i = 0; i < 100; i++) {
      a.step(0.37, pa);
      b.step(0.37, pb);
    }
    expect([for (final h in a.handlers) (h.x, h.y)],
        [for (final h in b.handlers) (h.x, h.y)]);
    expect(pa.given, pb.given);
  });

  /// The toy refuses overlaps and out-of-hall placements like the real one.
  test('the demo floor refuses bad edits', () {
    final sim = DemoFactorySim.demo();
    final rev = sim.layoutRev;
    final dock = sim.blueprint.placements
        .firstWhere((p) => p.kind == EntityKind.receivingDock);
    expect(
        sim.place(Placement(id: 0, kind: EntityKind.chest, pos: dock.pos))
            .refusal,
        EditRefusal.overlaps);
    expect(
        sim.place(const Placement(id: 0, kind: EntityKind.chest,
            pos: TilePos(500, 5))).refusal,
        EditRefusal.outOfHall);
    expect(sim.layoutRev, rev);
    final ok = sim.place(const Placement(id: 0, kind: EntityKind.chest,
        pos: TilePos(70, 40)));
    expect(ok.ok, isTrue);
    expect(sim.layoutRev, rev + 1);
    expect(sim.remove(ok.placementId!).ok, isTrue);
  });

  /// A dock line of crates (10 steel each) on a belt run with a crossing,
  /// plus handlers shuttling between the same two docks.
  DemoFactorySim crateLine() {
    final sim = DemoFactorySim(FloorBlueprint(
        name: 'Crates', hall: const HallSize(20, 12)));
    sim.place(const Placement(id: 0, kind: EntityKind.receivingDock,
        pos: TilePos(2, 0), item: 'crate:steel'));
    for (var y = 1; y < 10; y++) {
      sim.place(Placement(id: 0,
          kind: y == 5 ? EntityKind.crossing : EntityKind.belt,
          pos: TilePos(2, y), dir: Dir4.north));
    }
    sim.place(const Placement(id: 0, kind: EntityKind.shippingDock,
        pos: TilePos(2, 10)));
    sim
      ..hire(HandlerKind.onFoot, 2)
      ..hire(HandlerKind.forklift, 1);
    return sim;
  }

  /// Steel units held inside the floor: on belts, in stores, on handlers.
  double heldSteel(DemoFactorySim sim) {
    double units(String item, int n) {
      final def = FactoryItems.byId(item);
      return (def?.commodity ?? item) == 'steel'
          ? n * (def?.commodityUnits ?? 1)
          : 0;
    }

    var total = 0.0;
    for (final p in sim.blueprint.placements) {
      sim.contentsOf(p.id).forEach((k, n) => total += units(k, n));
    }
    for (final h in sim.handlers) {
      final c = h.carrying;
      if (c != null) total += units(c, h.carryingCount);
    }
    return total;
  }

  /// Nothing is created or destroyed at the docks: partial grants go back,
  /// a handler carries only what it was granted, and a shipped item goes to
  /// the colony once (not also into the dock). Held to the last part-crate
  /// with a stock that is not a whole number of crates, uncapped and with a
  /// cap that refuses deliveries for a while.
  test('the demo floor conserves goods through a finite colony', () {
    for (final cap in const [double.infinity, 60.0]) {
      final sim = crateLine();
      final port = StockColonyPort(stock: {'steel': 95.5}, cap: cap);
      var shipped = 0.0;
      for (var i = 0; i < 600; i++) {
        sim.step(0.5, port);
        shipped += sim.takeLedger().shipped['steel'] ?? 0;
        expect((port.stock['steel'] ?? 0) + heldSteel(sim),
            closeTo(95.5, 1e-9), reason: 'cap $cap, step $i');
      }
      expect(shipped, greaterThan(0), reason: 'cap $cap: goods moved');
    }
  });

  /// A crossing is a belt tile with a walkway over it: items ride ON it
  /// (they are drawn there and counted there), not under it.
  test('items ride across a crossing tile', () {
    final sim = crateLine();
    final port = InfiniteColonyPort();
    var sawOnCrossing = false;
    for (var i = 0; i < 200 && !sawOnCrossing; i++) {
      sim.step(0.5, port);
      sawOnCrossing =
          sim.beltItems.any((b) => b.tile == const TilePos(2, 5));
    }
    expect(sawOnCrossing, isTrue);
  });

  /// toJson carries the runtime state (belt items, machines, stores,
  /// handlers) in id order, so equal runs serialise identically and a
  /// running floor differs from a fresh one.
  test('the demo toJson serialises runtime state deterministically', () {
    final a = DemoFactorySim.demo(), b = DemoFactorySim.demo();
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    final fresh = jsonEncode(DemoFactorySim.demo().toJson());
    for (var i = 0; i < 120; i++) {
      a.step(0.5, pa);
      b.step(0.5, pb);
    }
    final ja = a.toJson();
    expect(jsonEncode(ja), jsonEncode(b.toJson()));
    expect(jsonEncode(ja), isNot(fresh));
    expect((ja['belts']! as Map).isNotEmpty, isTrue);
    expect((ja['machines']! as Map).isNotEmpty, isTrue);
    final crew = ja['handlers']! as List;
    expect(crew, hasLength(a.handlers.length));
    final ids = [for (final h in crew) (h as Map)['id'] as int];
    expect(ids, [...ids]..sort());
    final beltIds = [
      for (final k in (ja['belts']! as Map).keys) int.parse(k as String),
    ];
    expect(beltIds, [...beltIds]..sort());
  });
}
