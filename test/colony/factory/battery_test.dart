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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_vehicles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Forklifts need a charging bay (§3 handler table): a low battery sends
/// one to charge once its current drop is done, and it then goes back to
/// work. Without a bay it may still be hired, but it stops dead when flat
/// — a floor that "works for a few days then jams" is exactly the kind of
/// design fault the editor must make visible, not hide.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// A forklift keeps a smelter in ore down a 2-wide aisle; [bay] adds a
  /// charging bay off the aisle. The smelter sits north of the aisle's east
  /// end so its hand port (south face, outside tile (13, 1)) is on the
  /// aisle: a forklift works a machine there and nowhere else.
  FactoryFloor busyForklift({required bool bay}) {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.staging, 2, 0, span: (2, 2));
    l.add(EntityKind.aisle, 4, 0, span: (10, 2));
    // Smelter 4×4 at (12, 2): input port (12, 3), pig iron out at (15, 3),
    // slag out at (14, 5), hand port (13, 2).
    l.add(
      EntityKind.machine,
      12,
      2,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.assisted,
    );
    // Its pig iron and slag leave by port belts to shipping, so it never
    // blocks and the forklift only ever hauls ore.
    l.add(EntityKind.belt, 16, 3);
    l.add(EntityKind.shippingDock, 17, 3);
    l.add(EntityKind.belt, 14, 6, dir: Dir4.north);
    l.add(EntityKind.shippingDock, 14, 7);
    if (bay) l.add(EntityKind.chargingBay, 6, 2);
    final f = FactoryFloor.fromBlueprint(
      l.blueprint(20, 9, crew: {HandlerKind.forklift: 1}),
    );
    return f;
  }

  double battery(FactoryFloor f) =>
      ((f.toJson()['h'] as List).single as Map)['bt'] as double;

  test('a low forklift finishes its drop, charges, and goes back to work', () {
    final f = busyForklift(bay: true);
    final port = InfiniteColonyPort();
    const full = 360.0;
    expect(kBatteryRuntimeS[HandlerKind.forklift], full);
    var charged = false, resumed = false;
    var lowest = full;
    for (var i = 0; i < 4 * 900 && !resumed; i++) {
      final before = f.handlers.single.state;
      f.step(0.25, port);
      final h = f.handlers.single;
      final bt = battery(f);
      if (bt < lowest) lowest = bt;
      if (h.state == HandlerState.charging) {
        expect(h.carrying, isNull, reason: 'it set its load down first');
        if (before != HandlerState.charging) {
          expect(
            before,
            HandlerState.idle,
            reason: 'it went to charge between jobs, never mid-trip',
          );
          expect(bt, lessThanOrEqualTo(kBatteryLowFrac * full + 1e-9));
        }
        charged = true;
      } else if (charged && h.state != HandlerState.idle) {
        resumed = true;
        expect(bt, closeTo(full, 1), reason: 'it left the bay full');
      }
    }
    expect(charged, isTrue, reason: 'it ran low and went to charge');
    expect(resumed, isTrue, reason: 'and then went back to work');
    expect(lowest, greaterThan(0), reason: 'it never ran flat');
    expect(conservationError(f), isEmpty);
  });

  test('with no charging bay it works until flat, then stops', () {
    final f = busyForklift(bay: false);
    final port = InfiniteColonyPort();
    f.step(900, port);
    expect(battery(f), 0);
    final h = f.handlers.single;
    expect(h.state, HandlerState.idle, reason: 'flat: idle, not charging');
    expect(h.carrying, isNull, reason: 'it finished its last trip');
    final hauled = f.ledger.itemMetres;
    f.step(120, port);
    expect(
      f.ledger.itemMetres,
      hauled,
      reason: 'a flat forklift moves nothing',
    );
    expect((f.handlers.single.x, f.handlers.single.y), (h.x, h.y));
    expect(
      f.pendingRequests,
      greaterThan(0),
      reason: 'the smelter keeps asking: the floor shows the fault',
    );
    expect(conservationError(f), isEmpty);
  });
}
