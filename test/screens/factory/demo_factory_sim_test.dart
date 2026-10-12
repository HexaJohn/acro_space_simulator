// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
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
}
