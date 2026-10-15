// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/product_tree_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The product tree panel in the floor editor: it must open from the
/// header, build a tree for a picked product, fold and unfold, recompute
/// when a step's recipe is switched, and — the trap this screen has bitten
/// before — never let typing in it reach the editor's single-key tools.
void main() {
  late FactoryEditorController c;
  late FactoryFloor floor;

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    floor = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    await t.pumpWidget(MaterialApp(home: FactoryFloorScreen(sim: floor)));
    await t.pump();
    c = t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
        .controller;
    await t.tap(find.byKey(const Key('product-tree-button')));
    await t.pump();
    await t.pump();
  }

  ProductTreePanelState panel(WidgetTester t) =>
      t.state<ProductTreePanelState>(find.byType(ProductTreePanel));

  Finder row(String path) => find.byKey(Key('ptree-row-$path'));

  /// The panel opens from the header and starts on what THIS floor ships
  /// (a Steel Mill's first good, steel), with the tree and summary built.
  testWidgets('opens from the header on the floor\'s product', (t) async {
    await open(t);
    expect(find.byKey(const Key('ptree-panel')), findsOneWidget);
    expect(panel(t).item, 'steel');
    expect(row('steel'), findsOneWidget);
    expect(row('steel>steelBillet>pigIron>ore'), findsOneWidget);
    expect(find.byKey(const Key('ptree-raw-total-ore')), findsOneWidget);
  });

  /// Searching narrows the picker; picking a product rebuilds the tree on
  /// it, multi-plant chains included.
  testWidgets('picker selects a product and the tree renders', (t) async {
    await open(t);
    await t.enterText(find.byKey(const Key('ptree-search')), 'missi');
    await t.pump();
    expect(find.byKey(const Key('ptree-pick-missiles')), findsOneWidget);
    expect(find.byKey(const Key('ptree-pick-ore')), findsNothing);
    await t.tap(find.byKey(const Key('ptree-pick-missiles')));
    await t.pump();
    expect(panel(t).item, 'missiles');
    expect(find.text('Missile'), findsWidgets);
    expect(row('missiles'), findsOneWidget);
    expect(panel(t).summary.plants.length, greaterThanOrEqualTo(3));
  });

  /// Folding a node hides its subtree; expand-all brings everything back;
  /// collapse-all leaves the root's direct inputs.
  testWidgets('expand and collapse', (t) async {
    await open(t);
    const deep = 'steel>steelBillet>pigIron';
    expect(row(deep), findsOneWidget);
    await t.tap(find.byKey(const Key('ptree-toggle-steel>steelBillet')));
    await t.pump();
    expect(row(deep), findsNothing);
    expect(row('steel>steelBillet'), findsOneWidget);
    await t.tap(find.byKey(const Key('ptree-expand-all')));
    await t.pump();
    expect(row(deep), findsOneWidget);
    await t.tap(find.byKey(const Key('ptree-collapse-all')));
    await t.pump();
    expect(row('steel>steelBillet'), findsOneWidget);
    expect(row(deep), findsNothing);
  });

  /// Switching a node to an alternative recipe rebuilds that branch: steel
  /// unpacked from crates needs crates, not billets.
  testWidgets('alternative switch recomputes', (t) async {
    await open(t);
    // The screen's ticker never stops, so pumpAndSettle never would: pump
    // past the menu's open/close animation instead.
    await t.tap(find.byKey(const Key('ptree-alt-steel')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('ptree-alt-steel-electronics:unpack')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(panel(t).tree.recipe!.id, 'electronics:unpack');
    expect(row('steel>crate:steel'), findsOneWidget);
    expect(row('steel>steelBillet'), findsNothing);
  });

  /// Selecting a row outlines the floor's machines running its recipe.
  testWidgets('selecting a row highlights its recipe on the floor',
      (t) async {
    await open(t);
    await t.tap(row('steel>steelBillet>pigIron'));
    await t.pump();
    expect(c.highlightRecipe, 'steel:smelt');
    expect(c.machinesRunning('steel:smelt'), greaterThan(0));
    expect(find.byKey(const Key('ptree-here')), findsOneWidget);
  });

  /// "Used in" lists the recipes taking the selected item, across plants.
  testWidgets('used-in tab', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('ptree-tab-usedin')));
    await t.pump();
    expect(find.byKey(const Key('ptree-used-electronics:stamp')),
        findsOneWidget);
  });

  /// Typing in the search must not fire the editor's single-key tools: R
  /// would turn the placement ghost, Delete would remove the selection.
  testWidgets('keys in the search box stay out of the editor', (t) async {
    await open(t);
    final m = floor.blueprint.placements
        .firstWhere((p) => p.kind == EntityKind.machine);
    c.select(m.id);
    c.choose(EntityKind.belt);
    final dir = c.ghostDir;
    c.select(m.id);
    await t.tap(find.byKey(const Key('ptree-search')));
    await t.pump();
    await t.enterText(find.byKey(const Key('ptree-search')), 'ste');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.keyR);
    await t.sendKeyEvent(LogicalKeyboardKey.delete);
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.pump();
    // ...and the field still edits: Backspace reached the panel's own copy
    // of the text-editing shortcuts even though nothing bubbles past it.
    expect(t.widget<TextField>(find.byKey(const Key('ptree-search')))
        .controller!.text, 'st');
    expect(c.ghostDir, dir, reason: 'R went to the search box');
    expect(c.selectedId, m.id, reason: 'Delete went to the search box');
    expect(floor.blueprint.placements.any((p) => p.id == m.id), isTrue);
  });

  /// Esc closes the panel, from the search box or from the panel itself,
  /// and clears the floor highlight.
  testWidgets('Esc closes', (t) async {
    await open(t);
    await t.tap(row('steel'));
    await t.pump();
    expect(c.highlightRecipe, isNotNull);
    await t.tap(find.byKey(const Key('ptree-search')));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const Key('ptree-panel')), findsNothing);
    expect(c.highlightRecipe, isNull);

    await t.tap(find.byKey(const Key('product-tree-button')));
    await t.pump();
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byKey(const Key('ptree-panel')), findsNothing);
  });

  /// Clicks on the panel land on the panel, never on the floor under it.
  testWidgets('panel clicks do not reach the canvas', (t) async {
    await open(t);
    final before = floor.layoutRev;
    c.choose(EntityKind.chest);
    await t.tap(row('steel'));
    await t.pump();
    expect(floor.layoutRev, before);
    expect(c.tool, FactoryTool.place);
    // The canvas is still there, beside the panel rather than under it.
    expect(find.byKey(const Key('factory-canvas')), findsOneWidget);
  });
}
