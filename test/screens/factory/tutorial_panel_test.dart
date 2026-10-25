// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_scenario.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/rocketfactory_template.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/recipe_info_panel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/tutorial_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tutorial card on the real floor editor: it must render the step,
/// move with Next / Back / Skip, advance by itself when the player does the
/// thing, show live goal progress after the tutorial, point at the right
/// palette entry — and never take a click meant for the floor.
void main() {
  late FactoryFloor floor;
  late FactoryEditorController c;
  late ScenarioRunner run;
  late Finder canvas;

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = rocketPartsScenario();
    floor = FactoryFloor.fromBlueprint(s.blueprint());
    await t.pumpWidget(MaterialApp(
        home: FactoryFloorScreen(sim: floor, scenario: s)));
    await t.pump();
    final st =
        t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen));
    c = st.controller;
    run = st.runner!;
    canvas = find.byKey(const Key('factory-canvas'));
  }

  /// Long enough for the editor's live tick (0.25 s), which polls the
  /// runner.
  Future<void> live(WidgetTester t) async {
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
  }

  String stepTitle(WidgetTester t) =>
      t.widget<Text>(find.byKey(const Key('tutorial-step-title'))).data!;

  Offset at(WidgetTester t, TilePos p) =>
      t.getTopLeft(canvas) + c.tileCenterLocal(p);

  testWidgets('the card renders and Next, Back and Skip work', (t) async {
    await open(t);
    expect(find.byKey(const Key('tutorial-panel')), findsOneWidget);
    expect(stepTitle(t), 'Welcome to the factory floor');
    expect(find.textContaining('STEP 1 / 9'), findsOneWidget);
    await t.tap(find.byKey(const Key('tutorial-next')));
    await t.pump();
    expect(stepTitle(t), 'Bring tubes in');
    // A doing step: Next is off until it is done.
    expect(
        t.widget<FilledButton>(find.byKey(const Key('tutorial-next')))
            .onPressed,
        isNull);
    await t.tap(find.byKey(const Key('tutorial-back')));
    await t.pump();
    expect(stepTitle(t), 'Welcome to the factory floor');
    await t.tap(find.byKey(const Key('tutorial-skip')));
    await t.pump();
    expect(run.inGoals, isTrue);
    expect(find.byKey(const Key('tutorial-goals-title')), findsOneWidget);
    expect(find.byKey(const Key('tutorial-goal-ship20')), findsOneWidget);
  });

  testWidgets('a step completes by itself after the placement, with a ✓',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('tutorial-next')));
    await t.pump();
    // The hint pulses the palette entry it names.
    await live(t);
    expect(
        find.ancestor(
            of: find.byKey(const Key('palette-receivingDock')),
            matching: find.byKey(const Key('hint-pulse'))),
        findsOneWidget);
    expect(c.hintTargets, {ScenarioHintTarget.receivingDock});
    floor.place(const Placement(
        id: 0, kind: EntityKind.receivingDock, pos: TilePos(4, 0),
        dir: Dir4.north, item: 'tubes'));
    await live(t);
    expect(stepTitle(t), 'Lay a belt');
    expect(find.byKey(const Key('tutorial-flash')), findsOneWidget);
    expect(find.textContaining('✓ Bring tubes in'), findsOneWidget);
    expect(c.hintTargets, {ScenarioHintTarget.belt});
    // The flash goes after a moment.
    for (var i = 0; i < 6; i++) {
      await live(t);
    }
    expect(find.byKey(const Key('tutorial-flash')), findsNothing);
  });

  testWidgets('a canvas click still lands while the card is shown',
      (t) async {
    await open(t);
    final card = t.getRect(find.byKey(const Key('tutorial-panel')));
    await t.tap(find.byKey(const Key('palette-chest')));
    await t.pump();
    // A tile well clear of the card: the hall's far corner.
    const spot = TilePos(55, 2);
    expect(card.contains(at(t, spot)), isFalse);
    final g = await t.startGesture(at(t, spot), kind: PointerDeviceKind.mouse);
    await g.up();
    await t.pump();
    expect(floor.blueprint.placements, hasLength(1));
    expect(floor.blueprint.placements.single.pos, spot);
    // A click ON the card is the card's, not the floor's.
    final g2 = await t.startGesture(card.center, kind: PointerDeviceKind.mouse);
    await g2.up();
    await t.pump();
    expect(floor.blueprint.placements, hasLength(1));
    expect(stepTitle(t), 'Welcome to the factory floor');
  });

  testWidgets('the goal view shows live progress and switches supply',
      (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('tutorial-skip')));
    await t.pump();
    expect(find.text('0 / 20 shipped'), findsOneWidget);
    // A test line straight from frames and harnesses: widen the supply so
    // docks can bring them, step the floor directly (the widget test clock
    // feeds the sim only 0.1 s a frame), then let the card poll.
    run.port.setSupply({
      'tubes', 'electronics', RocketPartsItems.frame.id,
      RocketPartsItems.avionics.id,
    });
    void put(Placement p) => expect(floor.place(p).ok, isTrue);
    put(Placement(id: 0, kind: EntityKind.machine, pos: const TilePos(10, 10),
        recipe: RocketPartsRecipes.assemble.id));
    put(Placement(id: 0, kind: EntityKind.receivingDock,
        pos: const TilePos(8, 11), item: RocketPartsItems.frame.id));
    put(Placement(id: 0, kind: EntityKind.receivingDock,
        pos: const TilePos(11, 13), dir: Dir4.south,
        item: RocketPartsItems.avionics.id));
    // Parts leave by the output port (12, 11) onto a belt into the dock
    // (arms never unload a machine, §10 item 19).
    put(const Placement(id: 0, kind: EntityKind.belt, pos: TilePos(13, 11)));
    put(const Placement(
        id: 0, kind: EntityKind.shippingDock, pos: TilePos(14, 11)));
    floor.step(20, run.port);
    await live(t);
    final shipped = floor.lifetime.shipped['rocketParts'] ?? 0;
    expect(shipped, greaterThan(0));
    expect(find.text('${shipped.toStringAsFixed(0)} / 20 shipped'),
        findsOneWidget);
    final bar = t.widget<LinearProgressIndicator>(
        find.byKey(const Key('tutorial-goal-ship20-bar')));
    expect(bar.value, closeTo(shipped / 20, 1e-9));
    expect(find.byKey(const Key('tutorial-goal-summary')), findsOneWidget);
    // Ore only: the frame and harness docks are now unsupplied and say so.
    await t.ensureVisible(find.byKey(const Key('tutorial-supply-oreOnly')));
    await t.pump();
    await t.tap(find.byKey(const Key('tutorial-supply-oreOnly')));
    await t.pump();
    expect(run.port.supply, {'ore'});
    expect(find.textContaining('isn\'t supplied in this scenario'),
        findsNWidgets(2));
  });

  testWidgets('minimise folds the card to a chip and back', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('tutorial-minimise')));
    await t.pump();
    expect(find.byKey(const Key('tutorial-panel')), findsNothing);
    expect(find.text('Tutorial 1/9'), findsOneWidget);
    await t.tap(find.byKey(const Key('tutorial-expand')));
    await t.pump();
    expect(find.byKey(const Key('tutorial-panel')), findsOneWidget);
  });

  testWidgets('opening Recipe info on Rocket Parts sets the flag',
      (t) async {
    await open(t);
    // A game mode never offers the full product tree (§10 item 15).
    expect(find.byKey(const Key('product-tree-button')), findsNothing);
    await t.tap(find.byKey(const Key('recipe-info-button')));
    await t.pump();
    await t.pump();
    final first =
        t.state<RecipeInfoPanelState>(find.byType(RecipeInfoPanel)).item;
    expect(run.progress.recipeInfoSeen, {first});
    await t.tap(find.byKey(const Key('rinfo-item')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.enterText(find.byKey(const Key('picker-search')), 'rocket');
    await t.pump();
    await t.tap(find.byKey(const Key('picker-option-rocketParts')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(run.progress.recipeInfoSeen, contains('rocketParts'));
    expect(run.progress.treeItemsSeen, isEmpty);
    // And the Bottlenecks overlay, through the header chip.
    await t.tap(find.byKey(const Key('overlay-bottleneck')));
    await live(t);
    expect(run.progress.bottlenecksSeen, isTrue);
  });

  testWidgets('no scenario: no card, no runner', (t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final f = FactoryFloor.fromBlueprint(rocketPartsScenario().blueprint());
    await t.pumpWidget(MaterialApp(home: FactoryFloorScreen(sim: f)));
    await t.pump();
    expect(find.byType(TutorialPanel), findsNothing);
    expect(
        t.state<FactoryFloorScreenState>(find.byType(FactoryFloorScreen))
            .runner,
        isNull);
  });
}
