// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Arms are the fixed short hop between belts, chests and docks (§3; since
/// §10 item 19 they never touch machines, which connect by ports). They
/// pick from the tile BEHIND and drop on the tile in FRONT, one item per
/// swing, and — like an inserter — only pick what the front can take now,
/// which is what lets one mixed belt load a filtered chest without jamming
/// its arm.
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

  // Arms no longer feed machines (station_ports.dart rule 1: belts connect
  // to machine ports), so the inserter rule is pinned on what arms still
  // load: a filtered chest in front takes only its item, an unfiltered one
  // anything.
  test('an arm only picks what the chest in front accepts', () {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 1, item: 'ore');
    // A side dock pushes slag onto the same belt from below.
    l.add(EntityKind.receivingDock, 3, 3, dir: Dir4.south, item: 'slag');
    l.add(EntityKind.belt, 3, 2, dir: Dir4.south);
    l.beltRow(2, 6, 1);
    // An ore-only chest first: its arm must let the slag ride past.
    final feed = l.add(EntityKind.arm, 4, 2, dir: Dir4.north);
    final oreChest = l.add(EntityKind.chest, 4, 3, item: 'ore');
    // Then a filterless arm into an unfiltered chest, which takes anything.
    final out = l.add(EntityKind.arm, 5, 2, dir: Dir4.north);
    final anyChest = l.add(EntityKind.chest, 5, 3);
    final floor = FactoryFloor.fromBlueprint(l.blueprint(12, 8));
    final port = InfiniteColonyPort();

    // 24 s: short of filling either 32-item chest.
    var sawSlagInArm = false;
    for (var i = 0; i < 96; i++) {
      floor.step(0.25, port);
      if ((floor.contentsOf(feed)['slag'] ?? 0) > 0) sawSlagInArm = true;
    }
    expect(sawSlagInArm, isFalse);
    expect(floor.contentsOf(oreChest)['slag'] ?? 0, 0);
    expect(floor.contentsOf(oreChest)['ore'], greaterThan(0),
        reason: 'the filtered chest got the ore it accepts');
    expect(floor.contentsOf(anyChest)['slag'], greaterThan(0),
        reason: 'slag rode past the ore arm, and a filterless arm into an '
            'unfiltered chest takes it');
    expect(floor.contentsOf(out).length, lessThanOrEqualTo(1));
    expect(conservationError(floor), isEmpty);
  });
}
