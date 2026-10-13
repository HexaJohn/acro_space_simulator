// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

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

/// Forklifts trade floor space for speed (§3 "Space is the cost"): they
/// drive only on marked aisles at least two tiles wide. A forklift that
/// can't reach a job must never be sent on it — the job waits, and that
/// waiting queue is the player's "lay an aisle" signal — and one with a
/// proper aisle must actually serve it.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// An ore dock unloads into staging; a hand-fed smelter at the far end
  /// of an aisle [width] tiles wide wants the ore; one forklift, no
  /// walkers (ore is pallet work anyway).
  (FactoryFloor, int) aisleFloor(int width) {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.staging, 2, 0, span: (2, 2));
    l.add(EntityKind.aisle, 4, 0, span: (8, width));
    final smelter = l.add(
      EntityKind.machine,
      12,
      0,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.assisted,
    );
    final f = FactoryFloor.fromBlueprint(
      l.blueprint(16, 8, crew: {HandlerKind.forklift: 1}),
    );
    return (f, smelter);
  }

  test('a 1-wide aisle never gets the forklift sent; the job waits', () {
    final (f, smelter) = aisleFloor(1);
    final port = InfiniteColonyPort();
    for (var i = 0; i < 4 * 120; i++) {
      f.step(0.25, port);
      final h = f.handlers.single;
      expect(
        h.state,
        HandlerState.idle,
        reason: 'no drivable route to the smelter: never assigned',
      );
    }
    expect(
      f.pendingRequests,
      greaterThan(0),
      reason: 'the smelter still asks: "lay an aisle"',
    );
    expect(f.contentsOf(smelter)['ore'] ?? 0, 0);
    expect(f.ledger.itemMetres, 0);
    expect(conservationError(f), isEmpty);
  });

  test('a 2-wide aisle lets the forklift serve, on marked floor only', () {
    final (f, smelter) = aisleFloor(2);
    final port = InfiniteColonyPort();
    final drivable = <TilePos>{
      for (final p in f.blueprint.placements)
        if (p.kind == EntityKind.aisle || p.kind == EntityKind.staging)
          ...p.footprint.tiles,
    };
    for (var i = 0; i < 4 * 120; i++) {
      f.step(0.25, port);
      final h = f.handlers.single;
      for (final x in {h.x.floor(), h.x.ceil()}) {
        for (final y in {h.y.floor(), h.y.ceil()}) {
          expect(
            drivable,
            contains(TilePos(x, y)),
            reason: 'the forklift left its aisle at ($x, $y)',
          );
        }
      }
    }
    expect(f.ledger.itemMetres, greaterThan(0));
    expect(f.ledger.equipmentSeconds[HandlerKind.forklift], greaterThan(0));
    expect(
      f.statusOf(smelter),
      isNot(MachineStatus.starved),
      reason: 'the forklift keeps the smelter fed',
    );
    expect(conservationError(f), isEmpty);
  });

  test('"wide enough": some 2x2 square of marked tiles covers the tile', () {
    // A 2-wide L-shaped aisle with a 1-tile spur and a lone 1-wide strip:
    //   y=4  . . . . . . S .      S = 1-tile spur off the L
    //   y=3  # # . . . . # #
    //   y=2  # # . . . . # #      # = marked
    //   y=1  # # # # # # # #
    //   y=0  # # # # # # # #
    //   and x=0..6 at y=6 is a lone 1-wide strip.
    const hall = HallSize(8, 7);
    final m = Uint8List(8 * 7);
    void mark(int x, int y) => m[y * 8 + x] = 1;
    for (var x = 0; x < 8; x++) {
      mark(x, 0);
      mark(x, 1);
    }
    for (final y in [2, 3]) {
      for (final x in [0, 1, 6, 7]) {
        mark(x, y);
      }
    }
    mark(6, 4);
    for (var x = 0; x < 7; x++) {
      mark(x, 6);
    }
    final d = driveMask(hall, m, 2);
    bool at(int x, int y) => d[y * 8 + x] == 1;
    expect(at(3, 0) && at(3, 1), isTrue, reason: 'the 2-wide run');
    expect(at(0, 3) && at(7, 3) && at(6, 2), isTrue, reason: 'both legs');
    expect(at(6, 4), isFalse, reason: 'a 1-tile spur is too narrow');
    expect(at(3, 6), isFalse, reason: 'a 1-wide strip is too narrow');
    expect(at(3, 3), isFalse, reason: 'unmarked floor');
    expect(
      driveMask(hall, m, 1),
      m,
      reason: 'width 1 drives every marked tile',
    );
  });
}
