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
import 'package:acro_space_simulator/domain/colony/city/factory/factory_pathing.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_vehicles.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Every 2 x 2 staging pad or charging bay can be its own drivable island,
/// so "can a vehicle do this job" is a question about the part of the
/// floor the vehicle is actually on, not about its kind's layer as a
/// whole. These tests pin the three ways that went wrong: a request from
/// an island no vehicle can reach starving a reachable one, new vehicles
/// spawning on an island, and two wide aisles joined only through a
/// one-tile neck no forklift could fit through.
void main() {
  setUpAll(ensureFactoryCatalog);

  /// Tiles of every aisle and staging area of [f]: where a forklift's
  /// anchor may stand on these floors (no charging bays).
  Set<TilePos> aisleNetwork(FactoryFloor f, {Set<int> except = const {}}) => {
    for (final p in f.blueprint.placements)
      if ((p.kind == EntityKind.aisle || p.kind == EntityKind.staging) &&
          !except.contains(p.id))
        ...p.footprint.tiles,
  };

  test('an ore source no forklift can reach never starves one it can', () {
    // Island: ore dock D1 → staging S1 right beside the smelter's west
    // side, a 2 x 2 pad no aisle touches. Network: a 2-wide aisle down the
    // smelter's east side and along the bottom to staging S2 in front of
    // a second ore dock. One forklift, on the network. The smelter faces
    // north so its hand port (where a forklift loads it) is (7, 1), worked
    // from (8, 1) on the aisle.
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.staging, 2, 0, span: (2, 2));
    final smelter = l.add(
      EntityKind.machine,
      4,
      0,
      dir: Dir4.north,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.assisted,
    );
    l.add(EntityKind.aisle, 8, 0, span: (2, 8));
    l.add(EntityKind.aisle, 10, 6, span: (4, 2));
    l.add(EntityKind.staging, 12, 8, span: (2, 2));
    l.add(EntityKind.receivingDock, 10, 8, item: 'ore');
    final f = FactoryFloor.fromBlueprint(
      l.blueprint(17, 12, crew: {HandlerKind.forklift: 1}),
    );
    final port = InfiniteColonyPort();
    f.step(120, port);
    // Nothing takes the smelter's output away, so it fills and blocks after
    // a few batches; what matters is that it got ore to smelt at all.
    expect(
      f.craftNet['pigIron'] ?? 0,
      greaterThanOrEqualTo(6),
      reason: 'the forklift brings the far dock ore: the smelter runs',
    );
    expect(f.ledger.itemMetres, greaterThan(0));
    expect(
      f.statusOf(smelter),
      isNot(MachineStatus.starved),
      reason: 'never reserved away by the unreachable island ore',
    );
    expect(conservationError(f), isEmpty);
  });

  test('a hired forklift lands on the aisle network, not on an island', () {
    // A lone 2 x 2 staging pad (the lowest id: the old "first staging"
    // home), then dock → staging → aisle → smelter. The smelter faces south
    // so its hand port is (12, 2), worked from (11, 2): the aisle is three
    // rows deep so a forklift's square covers that tile.
    final l = Lay();
    final island = l.add(EntityKind.staging, 0, 6, span: (2, 2));
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.staging, 2, 0, span: (2, 2));
    l.add(EntityKind.aisle, 4, 0, span: (8, 3));
    final smelter = l.add(
      EntityKind.machine,
      12,
      0,
      dir: Dir4.south,
      recipe: SteelRecipes.smelt.id,
      mode: MachineMode.assisted,
    );
    final f = FactoryFloor.fromBlueprint(l.blueprint(16, 8));
    expect(f.hire(HandlerKind.forklift, 1).ok, isTrue);
    final h = f.handlers.single;
    final network = aisleNetwork(f, except: {island});
    expect(
      network,
      contains(TilePos(h.x.round(), h.y.round())),
      reason: 'spawned on the aisle network',
    );
    final port = InfiniteColonyPort();
    f.step(120, port);
    expect(f.ledger.itemMetres, greaterThan(0), reason: 'it serves');
    expect(f.statusOf(smelter), isNot(MachineStatus.starved));
    expect(conservationError(f), isEmpty);
  });

  test('two wide aisles joined by a one-tile neck do not connect', () {
    // Aisle A (x 4-7, y 0-1) and aisle B (x 8-11) one row lower: they
    // touch along one tile edge, and every tile is in some 2 x 2 marked
    // square, but no 2 x 2 vehicle can slide from one onto the other. B is
    // three rows deep and the smelter faces south, so its hand port (12, 2)
    // is worked from (11, 2) on B in both layouts.
    (FactoryFloor, int) floor(int bY) {
      final l = Lay();
      l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
      l.add(EntityKind.staging, 2, 0, span: (2, 2));
      l.add(EntityKind.aisle, 4, 0, span: (4, 2));
      l.add(EntityKind.aisle, 8, bY, span: (4, 3));
      final smelter = l.add(
        EntityKind.machine,
        12,
        0,
        dir: Dir4.south,
        recipe: SteelRecipes.smelt.id,
        mode: MachineMode.assisted,
      );
      return (
        FactoryFloor.fromBlueprint(
          l.blueprint(16, 8, crew: {HandlerKind.forklift: 1}),
        ),
        smelter,
      );
    }

    final port = InfiniteColonyPort();
    final (pinch, smelter) = floor(1);
    for (var i = 0; i < 4 * 120; i++) {
      pinch.step(0.25, port);
      expect(
        pinch.handlers.single.carrying,
        isNull,
        reason: 'no drivable route through the neck: never sent',
      );
    }
    expect(pinch.contentsOf(smelter)['ore'] ?? 0, 0);
    expect(pinch.pendingRequests, greaterThan(0), reason: '"widen the aisle"');
    expect(conservationError(pinch), isEmpty);

    // The same aisles aligned: served.
    final (aligned, smelter2) = floor(0);
    aligned.step(120, port);
    expect(aligned.ledger.itemMetres, greaterThan(0));
    expect(aligned.statusOf(smelter2), isNot(MachineStatus.starved));
  });

  test('driveAnchors: coverage joins the neck, connectivity does not', () {
    const hall = HallSize(12, 4);
    final m = Uint8List(12 * 4);
    for (var x = 4; x < 8; x++) {
      m[x] = 1;
      m[12 + x] = 1;
    }
    for (var x = 8; x < 12; x++) {
      m[12 + x] = 1;
      m[24 + x] = 1;
    }
    final open = FloorPathing(hall, driveMask(hall, m, 2));
    expect(
      open.regionAt(0, const TilePos(4, 0)),
      open.regionAt(0, const TilePos(11, 2)),
      reason: 'the tile set ([driveMask]) is one piece through the neck',
    );
    final anchors = FloorPathing(hall, driveAnchors(hall, m, 2));
    expect(anchors.regionAt(0, const TilePos(4, 0)), greaterThanOrEqualTo(0));
    expect(anchors.regionAt(0, const TilePos(10, 1)), greaterThanOrEqualTo(0));
    expect(
      anchors.regionAt(0, const TilePos(4, 0)),
      isNot(anchors.regionAt(0, const TilePos(10, 1))),
      reason: 'a 2 x 2 vehicle cannot sweep through a 1-tile neck',
    );
  });
}
