// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_factory_sim.dart';

/// Found building the tutorial: the palette shared ONE item choice across
/// every dock, so a shipping dock placed right after a Tubes receiving dock
/// came out tubes-only and silently refused frames. Each kind now keeps its
/// own choice; a shipping dock defaults to any item.
void main() {
  test('a shipping dock does not inherit the receiving dock item', () {
    final c = FactoryEditorController(
        FakeFactorySim(FloorBlueprint(name: 't', hall: const HallSize(20, 15))),
        InfiniteColonyPort());
    c.choose(EntityKind.receivingDock);
    expect(c.itemChoice, FactoryItems.ore.id, reason: 'receiving defaults to ore');
    c.setItemChoice(FactoryItems.tubes.id);
    c.choose(EntityKind.shippingDock);
    expect(c.itemChoice, isNull, reason: 'shipping defaults to any item');
    c.choose(EntityKind.receivingDock);
    expect(c.itemChoice, FactoryItems.tubes.id,
        reason: 'the receiving choice is remembered');
  });
}
