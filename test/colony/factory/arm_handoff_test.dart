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
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Arms are the fixed short hop between belts and stations (§3). They pick
/// from the tile BEHIND and drop on the tile in FRONT, one item per swing,
/// and — like an inserter — only pick what the front can take now, which is
/// what lets one mixed belt feed a station without jamming its arm.
void main() {
  setUpAll(ensureFactoryCatalog);

  test('an arm moves items from a belt into a chest, one per cycle', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    final belts = l.beltRow(2, 4, 1);
    final arm = l.add(EntityKind.arm, 4, 2, dir: Dir4.north);
    final chest = l.add(EntityKind.chest, 4, 3);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(8, 5));
    final port = InfiniteColonyPort();

    floor.step(20, port);
    final inChest = floor.contentsOf(chest)['ore'] ?? 0;
    expect(inChest, greaterThan(10),
        reason: 'the arm (2/s) keeps up with the dock (1/s)');
    var onFloor = inChest + (floor.contentsOf(arm)['ore'] ?? 0);
    for (final b in belts) {
      onFloor += floor.contentsOf(b)['ore'] ?? 0;
    }
    expect(onFloor, port.taken['ore']!.toInt(), reason: 'nothing lost');
  });

  test('an arm only picks what the station in front accepts', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    // A side dock pushes slag onto the same belt from below.
    l.add(EntityKind.receivingDock, 3, 3, dir: Dir4.south, item: 'slag');
    l.add(EntityKind.belt, 3, 2, dir: Dir4.south);
    final main = l.beltRow(2, 6, 1);
    final feed = l.add(EntityKind.arm, 6, 2, dir: Dir4.north);
    final smelter = l.add(EntityKind.machine, 5, 3,
        recipe: SteelRecipes.smelt.id, mode: MachineMode.assisted);
    final out = l.add(EntityKind.arm, 9, 4);
    final chest = l.add(EntityKind.chest, 10, 4);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(12, 8));
    final port = InfiniteColonyPort();

    var sawSlagInArm = false;
    for (var i = 0; i < 480; i++) {
      floor.step(0.25, port);
      if ((floor.contentsOf(feed)['slag'] ?? 0) > 0) sawSlagInArm = true;
    }
    expect(sawSlagInArm, isFalse);
    expect(floor.contentsOf(smelter)['slag'] ?? 0, 0);
    expect(floor.contentsOf(chest)['pigIron'], greaterThan(0),
        reason: 'the smelter crafted and its output arm cleared it');
    expect(floor.contentsOf(chest)['slag'], greaterThan(0),
        reason: 'a filterless arm into a chest takes any output');
    var slagOnBelt = 0;
    for (final b in main) {
      slagOnBelt += floor.contentsOf(b)['slag'] ?? 0;
    }
    expect(slagOnBelt, greaterThan(0), reason: 'slag rode past the feed arm');
    expect(floor.contentsOf(out).length, lessThanOrEqualTo(1));
  });
}
