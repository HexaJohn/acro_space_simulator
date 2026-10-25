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
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/floor_item_info.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/floor_layout_index.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory/factory_test_support.dart';

/// §10 items 17 and 18 in the editor: tooltips say what items ARE, the
/// legend lists what is on the floor, and the Clear tool posts real move
/// requests.
void main() {
  /// Dock (0,0) -> belts (1..4,0) -> chest (5,0), one pallet jack.
  ({FactoryFloor f, int belt, int chest}) lane() {
    final l = Lay();
    l.add(EntityKind.receivingDock, 0, 0, item: 'ore');
    final belts = l.beltRow(1, 4, 0);
    final chest = l.add(EntityKind.chest, 5, 0);
    l.add(EntityKind.chest, 8, 3);
    final f = FactoryFloor.fromBlueprint(
        l.blueprint(12, 6, crew: {HandlerKind.palletJack: 1}));
    f.step(3, InfiniteColonyPort());
    return (f: f, belt: belts.first, chest: chest);
  }

  FloorLayoutIndex ixOf(FactoryFloor f) =>
      FloorLayoutIndex(f.blueprint, f.layoutRev);

  test('a belt tile with items names them with count and load class', () {
    final w = lane();
    final on = w.f.beltItems.first.tile;
    final tip = tipAt(w.f, ixOf(w.f), on)!;
    expect(tip.title, 'Belt');
    expect(tip.rows.single.name, 'Ore');
    expect(tip.rows.single.loadClass, 'pallet');
    expect(tip.rows.single.count, greaterThan(0));
  });

  test('a chest lists its contents', () {
    final w = lane();
    w.f.step(30, InfiniteColonyPort());
    final tip = tipAt(w.f, ixOf(w.f), const TilePos(5, 0))!;
    expect(tip.title, 'Chest');
    expect(tip.rows.single.item, 'ore');
    expect(tip.rows.single.count, w.f.contentsOf(w.chest)['ore']);
  });

  test('a pile and a loaded handler show what they hold', () {
    final w = lane();
    w.f.step(30, InfiniteColonyPort());
    expect(w.f.remove(w.chest).ok, isTrue);
    final pile = w.f.piles.first;
    final tip = tipAt(w.f, ixOf(w.f), pile.tile)!;
    expect(tip.title, 'Pile');
    expect(tip.rows.single.count, pile.count);

    HandlerView? loaded;
    for (var i = 0; i < 2000 && loaded == null; i++) {
      w.f.step(0.25, InfiniteColonyPort());
      for (final h in w.f.handlers) {
        if (h.carryingCount > 0) loaded = h;
      }
    }
    expect(loaded, isNotNull);
    final h = loaded!;
    final ht = tipAt(w.f, ixOf(w.f), TilePos(h.x.floor(), h.y.floor()))!;
    expect(ht.title, startsWith('Pallet Jack'));
    expect(ht.rows.single.count, h.carryingCount);
  });

  test('the legend lists every item present, once', () {
    final w = lane();
    final legend = legendOf(w.f);
    expect(legend.map((e) => e.item), ['ore']);
    expect(legend.single.count, greaterThan(0));
    expect(legendOf(FactoryFloor.fromBlueprint(Lay().blueprint(4, 4))),
        isEmpty);
  });

  test('abbreviations are 2-3 letters', () {
    expect(itemAbbrev('ore'), 'Ore');
    expect(itemAbbrev('steelBillet'), 'SB');
    expect(itemAbbrev('pigIron'), 'PI');
  });

  testWidgets('hover tooltip, legend and the Clear tool on the real screen',
      (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final w = lane();
    final f = w.f;
    f.step(30, InfiniteColonyPort());
    expect(f.remove(w.chest).ok, isTrue);
    await t.pumpWidget(MaterialApp(home: FactoryFloorScreen(sim: f)));
    await t.pump();
    final c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    c.setSpeed(0);
    final canvas = find.byKey(const Key('factory-canvas'));
    final PileView pile = f.piles.first;
    Offset at(TilePos p) => t.getTopLeft(canvas) + c.tileCenterLocal(p);

    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at(pile.tile) + const Offset(0, 1));
    await g.moveTo(at(pile.tile));
    await t.pump();
    expect(find.byKey(const Key('floor-tip')), findsOneWidget);
    expect(find.textContaining('Ore ×${pile.count}'), findsOneWidget);

    await t.tap(find.byKey(const Key('floor-legend-toggle')));
    await t.pump();
    expect(find.textContaining('Ore  ×'), findsOneWidget);

    await t.tap(find.byKey(const Key('tool-clear')));
    await t.pump();
    expect(c.tool, FactoryTool.clear);
    final before = f.pendingRequests;
    await g.moveTo(at(TilePos(pile.tile.x - 1, pile.tile.y - 1)));
    await g.down(at(TilePos(pile.tile.x - 1, pile.tile.y - 1)));
    await g.moveTo(at(TilePos(pile.tile.x + 1, pile.tile.y + 1)));
    await g.up();
    await t.pump();
    f.step(1, InfiniteColonyPort());
    expect(f.pendingRequests, greaterThan(before));
  });
}
