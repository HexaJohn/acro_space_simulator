// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_scenario.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/product_tree.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/product_tree_panel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/recipe_info_panel.dart';
import 'package:acro_space_simulator/main_factory_dev.dart';
import 'package:acro_space_simulator/main_factory_tutorial.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The product tree is a debug tool now; the game gets Recipe info
/// (docs/plans/factory-floors.md §10 item 15): ONE level of components, or
/// the raw total per unit, never the chain between.
void main() {
  late FactoryFloor floor;

  Future<void> open(WidgetTester t, {bool debugTools = false}) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    floor = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    await t.pumpWidget(MaterialApp(
        home: FactoryFloorScreen(sim: floor, debugTools: debugTools)));
    await t.pump();
  }

  Future<void> openInfo(WidgetTester t) async {
    await t.tap(find.byKey(const Key('recipe-info-button')));
    await t.pump();
    await t.pump();
  }

  RecipeInfoPanelState info(WidgetTester t) =>
      t.state<RecipeInfoPanelState>(find.byType(RecipeInfoPanel));

  testWidgets('without debugTools there is no product tree to open',
      (t) async {
    await open(t);
    expect(find.byKey(const Key('product-tree-button')), findsNothing);
    final st =
        t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen));
    st.openProductTree();
    await t.pump();
    expect(st.treeOpen, isFalse, reason: 'not even programmatically');
    expect(find.byType(ProductTreePanel), findsNothing);
    expect(find.byKey(const Key('recipe-info-button')), findsOneWidget);
  });

  testWidgets('with debugTools the full tree is still there', (t) async {
    await open(t, debugTools: true);
    await t.tap(find.byKey(const Key('product-tree-button')));
    await t.pump();
    await t.pump();
    expect(find.byType(ProductTreePanel), findsOneWidget);
    // Recipe info takes the same spot: opening it closes the tree.
    await openInfo(t);
    expect(find.byType(ProductTreePanel), findsNothing);
    expect(find.byType(RecipeInfoPanel), findsOneWidget);
  });

  testWidgets('the dev entry has debug tools; the tutorial game mode has not',
      (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const FactoryDevApp());
    await t.pump();
    expect(
        t.widget<FactoryFloorScreen>(find.byType(FactoryFloorScreen))
            .debugTools,
        isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(const FactoryTutorialApp());
    await t.pump();
    expect(
        t.widget<FactoryFloorScreen>(find.byType(FactoryFloorScreen))
            .debugTools,
        isFalse);
    expect(find.byKey(const Key('product-tree-button')), findsNothing);
  });

  testWidgets('Components lists the direct recipes, one level only',
      (t) async {
    await open(t);
    await openInfo(t);
    final item = info(t).item;
    final rs = RecipeGraph.catalog().producersOf(item);
    expect(rs, isNotEmpty);
    for (final r in rs) {
      expect(find.byKey(Key('rinfo-recipe-${r.id}')), findsOneWidget);
      expect(find.byKey(Key('rinfo-in-${r.id}')), findsOneWidget);
      expect(find.byKey(Key('rinfo-station-${r.id}')), findsOneWidget);
    }
    // One level: no recipe that makes one of those inputs is listed.
    for (final r in rs) {
      for (final q in r.inputs) {
        for (final deeper in RecipeGraph.catalog().producersOf(q.item)) {
          if (rs.contains(deeper)) continue;
          expect(find.byKey(Key('rinfo-recipe-${deeper.id}')), findsNothing,
              reason: '${deeper.id} is a step down the chain');
        }
      }
    }
  });

  testWidgets('Raw total shows the tree summary per unit and nothing between',
      (t) async {
    await open(t);
    await openInfo(t);
    await t.tap(find.byKey(const Key('rinfo-tab-raw')));
    await t.pump();
    final item = info(t).item;
    final want =
        summarizeProductTree(buildProductTree(item, ratePerS: 1)).rawPerS;
    expect(want, isNotEmpty);
    expect(rawPerUnit(item), want);
    for (final k in want.keys) {
      expect(find.byKey(Key('rinfo-raw-$k')), findsOneWidget);
    }
    // No intermediate of the tree is named in the panel.
    final tree = buildProductTree(item, ratePerS: 1);
    final panel = find.byKey(const Key('rinfo-raw'));
    for (final n in tree.walk()) {
      if (n.leaf != ProductLeaf.none || n.item == item) continue;
      expect(
          find.descendant(
              of: panel, matching: find.textContaining(n.label)),
          findsNothing,
          reason: '${n.item} is an intermediate step');
    }
    // Neither view shows recipes on this tab.
    expect(find.byKey(const Key('rinfo-components')), findsNothing);
  });

  testWidgets('the item is chosen with the searchable picker', (t) async {
    await open(t);
    await openInfo(t);
    await t.tap(find.byKey(const Key('rinfo-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('picker-search')), 'missi');
    await t.pump();
    expect(find.byKey(const Key('picker-option-missiles')), findsOneWidget);
    expect(find.byKey(const Key('picker-option-steel')), findsNothing);
    await t.tap(find.byKey(const Key('picker-option-missiles')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(info(t).item, 'missiles');
    for (final r in RecipeGraph.catalog().producersOf('missiles')) {
      expect(find.byKey(Key('rinfo-recipe-${r.id}')), findsOneWidget);
    }
  });

  testWidgets('Esc closes Recipe info', (t) async {
    await open(t);
    await openInfo(t);
    expect(find.byType(RecipeInfoPanel), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byType(RecipeInfoPanel), findsNothing);
  });

  test('the tutorial read step points at Recipe info, not the tree', () {
    final s = rocketPartsScenario();
    final read = s.steps.firstWhere((x) => x.id == 'read');
    expect(read.hint!.targets, contains(ScenarioHintTarget.recipeInfo));
    expect(read.hint!.targets, isNot(contains(ScenarioHintTarget.productTree)));
    expect(read.body, contains('Recipe info'));
    expect(read.body, isNot(contains('Product tree')));
  });
}
