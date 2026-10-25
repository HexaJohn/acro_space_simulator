// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rocketfactory_template.dart';
import 'package:flutter_test/flutter_test.dart';

/// A request posted before an edit must not outlive the reason it was
/// posted (found by the Rocket Parts tutorial): frames with no consumer are
/// pushed to the shipping dock, and once a player places an assembler that
/// takes frames, the frames already queued for the dock must go to the
/// assembler instead — before the fix the pallet jack kept running a dock
/// buffer's worth of them out while the new bay starved.
void main() {
  test('placing a consumer cancels queued pushes of what it consumes', () {
    registerRocketPartsChain();
    final f = FactoryFloor.fromBlueprint(
        FloorBlueprint(name: 'stale', hall: const HallSize(30, 12)));
    final port = InfiniteColonyPort();
    // A tube door unloading straight into a welding cell, a shipping door,
    // one pallet jack.
    expect(
        f.place(Placement(id: 0, kind: EntityKind.receivingDock,
            pos: const TilePos(0, 4), item: 'tubes')).ok,
        isTrue);
    expect(
        f.place(Placement(id: 0, kind: EntityKind.machine,
            pos: const TilePos(2, 3),
            recipe: RocketPartsRecipes.weldFrame.id)).ok,
        isTrue);
    expect(
        f.place(Placement(id: 0, kind: EntityKind.shippingDock,
            pos: const TilePos(26, 0), dir: Dir4.north)).ok,
        isTrue);
    f.hire(HandlerKind.palletJack, 1);
    final frame = RocketPartsItems.frame.id;
    // Two cycles: four frames made, pushes queued for the dock, the jack on
    // its first trip.
    f.step(80, port);
    expect(f.pendingRequests, greaterThan(0));
    int carried() => f.handlers
        .where((h) => h.carrying == frame)
        .fold(0, (n, h) => n + h.carryingCount);
    final committed = (f.lifetime.shipped[frame] ?? 0) + carried();
    // Now a bay that takes frames (its harness side starves; that's fine).
    final bay = f.place(Placement(id: 0, kind: EntityKind.machine,
        pos: const TilePos(14, 6), recipe: RocketPartsRecipes.assemble.id));
    expect(bay.ok, isTrue);
    f.step(400, port);
    expect(f.lifetime.shipped[frame] ?? 0, lessThanOrEqualTo(committed),
        reason: 'only a frame already in hand may still reach the dock');
    expect(f.contentsOf(bay.placementId!)[frame] ?? 0, greaterThan(0),
        reason: 'the frames go to the new consumer');
    expect(f.statusOf(bay.placementId!), MachineStatus.starved);
  });
}
