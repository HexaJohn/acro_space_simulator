// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// `setDir` and `rotate(ccw:)` (docs/plans/factory-floors.md §10 items 7
/// and 8): the editor redirects a belt run by re-pointing its tiles, and
/// that must keep every item riding on them — remove + place would have
/// spilled them as piles. Conservation is what makes the floor's books
/// trustworthy, so it is checked after every edit.
void main() {
  /// A dock feeding a dead-end belt row until it is full.
  (FactoryFloor, InfiniteColonyPort, List<int>) loadedBelt() {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    final belts = l.beltRow(2, 6, 1);
    final f = FactoryFloor.fromBlueprint(l.blueprint(12, 6));
    final port = InfiniteColonyPort();
    f.step(60, port);
    return (f, port, belts);
  }

  int onBelts(FactoryFloor f, List<int> ids) =>
      ids.fold(0, (n, id) => n + (f.contentsOf(id)['ore'] ?? 0));

  test('setDir re-points a loaded belt and keeps every item on it', () {
    final (f, port, belts) = loadedBelt();
    final before = onBelts(f, belts);
    expect(before, greaterThan(0));
    final floorBefore = f.itemsOnFloor;
    final rev = f.layoutRev;
    expect(f.setDir(belts.last, Dir4.north).ok, isTrue);
    expect(f.blueprint.byId(belts.last)!.dir, Dir4.north);
    expect(f.layoutRev, greaterThan(rev));
    expect(onBelts(f, belts), before, reason: 'nothing left the belt');
    expect(f.itemsOnFloor, floorBefore);
    expect(f.piles, isEmpty, reason: 'a redirect spills nothing');
    expect(conservationError(f), isEmpty);
    // The items carry on the new way: north off the last tile onto a
    // shipping dock placed there, and the floor still conserves.
    expect(f.place(const Placement(
            id: 0, kind: EntityKind.shippingDock, pos: TilePos(6, 2),
            dir: Dir4.north))
        .ok, isTrue);
    f.step(30, port);
    expect(f.lifetime.shipped['ore'] ?? 0, greaterThan(0));
    expect(conservationError(f), isEmpty);
  });

  test('setDir to the facing it already has is a no-op', () {
    final (f, _, belts) = loadedBelt();
    final rev = f.layoutRev;
    final r = f.setDir(belts.first, Dir4.east);
    expect(r.ok, isTrue);
    expect(r.placementId, belts.first);
    expect(f.layoutRev, rev, reason: 'nothing changed, nothing to redraw');
  });

  test('setDir follows rotate rules: missing ids and overlaps refuse', () {
    final l = Lay();
    final dock = l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    l.add(EntityKind.chest, 0, 1);
    final f = FactoryFloor.fromBlueprint(l.blueprint(8, 8));
    expect(f.setDir(99, Dir4.north).refusal, EditRefusal.noSuchPlacement);
    // A 2 x 1 dock turned north would cover (0, 1), where the chest is.
    final r = f.setDir(dock, Dir4.north);
    expect(r.refusal, EditRefusal.overlaps);
    expect(f.blueprint.byId(dock)!.dir, Dir4.east);
  });

  test('rotate turns clockwise by default and counter-clockwise on ask', () {
    final (f, _, belts) = loadedBelt();
    final id = belts[2];
    final before = onBelts(f, belts);
    expect(f.rotate(id).ok, isTrue);
    expect(f.blueprint.byId(id)!.dir, Dir4.east.turnCw);
    expect(f.rotate(id, ccw: true).ok, isTrue);
    expect(f.blueprint.byId(id)!.dir, Dir4.east);
    expect(f.rotate(id, ccw: true).ok, isTrue);
    expect(f.blueprint.byId(id)!.dir, Dir4.east.turnCcw);
    expect(onBelts(f, belts), before);
    expect(conservationError(f), isEmpty);
  });

  test('the picker names loose and packed goods from their data', () {
    expect(FactoryItems.electronics.pickerLabel, 'Electronics (loose · hand)');
    expect(FactoryItems.crateElectronics.pickerLabel,
        'Electronics ×10 (crate · pallet)');
    expect(FactoryItems.toteWater.pickerLabel, 'Water ×1000 (tote · pallet)');
    expect(FactoryItems.packOxygen.pickerLabel,
        'Oxygen ×100 (pack · pallet)');
    expect(FactoryItems.ore.pickerLabel, 'Ore (loose · pallet)');
  });
}
