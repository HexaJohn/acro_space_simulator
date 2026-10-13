// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_capex.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// Placing a plant with its template floor must cost what placing that
/// plant always cost (the spec's ore `buildCost`), or stamping a template
/// would quietly change the colony's economy. And the costs must point the
/// right way for the design puzzle: a bigger hall, a lights-out station, a
/// vehicle or a dock conveyor each costs more than going without.
void main() {
  test('the Steel Mill template costs the spec buildCost within 10%', () {
    final spec = kUtilCatalog.firstWhere((s) => s.type == kSteelMillType);
    final c = capexOf(factoryTemplateFor(kSteelMillType)!);
    expect(
      c.total,
      closeTo(spec.buildCost, spec.buildCost * 0.10),
      reason: '$c against ${spec.buildCost} ore',
    );
    for (final part in [
      c.hall,
      c.machines,
      c.conveyors,
      c.storage,
      c.vehicles,
    ]) {
      expect(part, greaterThan(0), reason: 'every line of $c is charged');
    }
    expect(
      c.total,
      closeTo(c.hall + c.machines + c.conveyors + c.storage + c.vehicles, 1e-9),
    );
  });

  test('costs point the designer the right way', () {
    final base = factoryTemplateFor(kSteelMillType)!;
    final t0 = capexOf(base).total;

    final bigger = base.copy()..hall = HallSize(base.hall.w + 10, base.hall.h);
    expect(capexOf(bigger).hall, greaterThan(capexOf(base).hall));

    final automated = base.copy();
    for (var i = 0; i < automated.placements.length; i++) {
      final p = automated.placements[i];
      if (p.kind == EntityKind.machine) {
        automated.placements[i] = p.copyWith(mode: MachineMode.automated);
      }
    }
    expect(capexOf(automated).machines, greaterThan(capexOf(base).machines));

    final fleet = base.copy()..roster[HandlerKind.agv] = 2;
    expect(capexOf(fleet).vehicles, greaterThan(capexOf(base).vehicles));

    // Without the dock conveyors: the docks set ore down on staging.
    final manualDocks = base.copy();
    var conveyors = 0;
    for (final p in [...manualDocks.placements]) {
      if (p.kind != EntityKind.receivingDock) continue;
      conveyors++;
      final front = manualDocks.placements.firstWhere(
        (q) => q.pos == TilePos(p.pos.x + 2, p.pos.y),
      );
      manualDocks.placements.remove(front);
    }
    expect(conveyors, 2);
    expect(
      capexOf(manualDocks).conveyors,
      closeTo(
        capexOf(base).conveyors -
            2 * kCapexDockConveyorOre -
            2 * kCapexBeltTileOre,
        1e-9,
      ),
      reason: 'each dock conveyor is charged as the upgrade it is',
    );
    expect(t0, greaterThan(0));
  });
}
