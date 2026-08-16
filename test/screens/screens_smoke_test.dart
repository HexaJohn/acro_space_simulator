// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Smoke test: pump each menu/feature screen and confirm it builds without
// throwing (catches init-time domain-binding errors the analyzer can't see).
import 'package:acro_space_simulator/infrastructure/flutter/screens/ascent_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft_assembly_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/main_menu_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/maneuver_planner_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/megastructure_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/mining_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/multiplayer_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/options_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester t, Widget screen) async {
  // pumpWidget rethrows any error from build/initState, so reaching the
  // assertion means the screen mounted cleanly.
  await t.pumpWidget(MaterialApp(home: screen));
  await t.pump(const Duration(milliseconds: 16));
  expect(t.takeException(), isNull);
}

void main() {
  testWidgets('main menu builds', (t) async {
    await _pump(t, const MainMenuScreen());
    expect(find.text('ACRO SPACE SIMULATOR'), findsOneWidget);
  });
  testWidgets('options builds', (t) async => _pump(t, const OptionsScreen()));
  testWidgets('maneuver planner builds',
      (t) async => _pump(t, const ManeuverPlannerScreen()));
  testWidgets('craft assembly builds',
      (t) async => _pump(t, const CraftAssemblyScreen()));
  testWidgets('new city setup builds',
      (t) async => _pump(t, const NewCityScreen()));
  testWidgets('city builder builds',
      (t) async => _pump(t, const CityBuilderScreen()));
  testWidgets('mining builds', (t) async => _pump(t, const MiningScreen()));
  testWidgets('landing builds',
      (t) async => _pump(t, const AscentScreen(descent: true)));
  testWidgets('ascent builds', (t) async => _pump(t, const AscentScreen()));
  testWidgets('megastructure builds',
      (t) async => _pump(t, const MegastructureScreen()));
  testWidgets('multiplayer builds',
      (t) async => _pump(t, const MultiplayerScreen()));

  // The craft editor is the one screen whose layout changes shape rather than
  // reflowing, so building at the default 800x600 only ever exercises half of
  // it. Both sizes are pinned here because an overflow is reported through
  // `takeException` at paint time and would otherwise never be seen: the wide
  // layout puts a 3D view between two panes, and the narrow one stacks it over
  // a tabbed sheet.
  group('craft assembly at both layout sizes', () {
    testWidgets('wide keeps the viewport between the two panes', (t) async {
      await _pumpSized(t, const CraftAssemblyScreen(), const Size(1280, 800));
      final view = t.getRect(find.byType(CraftEditorViewport));
      expect(view.left, greaterThan(0),
          reason: 'nothing to the left of the 3D view: the catalog is missing');
      expect(view.right, lessThan(1280),
          reason: 'nothing to the right of the 3D view: the inspector is '
              'missing');
      expect(view.height, greaterThan(300));
      _expectNoPageScroll();
    });

    testWidgets('narrow stacks the viewport above the sheet', (t) async {
      await _pumpSized(t, const CraftAssemblyScreen(), const Size(400, 800));
      final view = t.getRect(find.byType(CraftEditorViewport));
      // Directly under the title bar: the 3D view is the subject of the narrow
      // layout, and the old screen's habit of giving the top half to a parts
      // list is exactly what this layout replaces.
      expect(view.top, lessThan(80),
          reason: 'something is stacked above the 3D view');
      expect(view.width, 400);
      expect(view.bottom, lessThan(800 * 0.75),
          reason: 'the viewport swallowed the whole column, leaving no room '
              'for the tool strip or the sheet');
      _expectNoPageScroll();
    });
  });
}

/// Pump [screen] at an exact logical size, then assert it laid out cleanly.
///
/// `takeException` is what catches a `RenderFlex overflowed` — the failure mode
/// a fixed-size layout has and a reflowing one does not — because Flutter
/// reports it as an error during paint rather than as a thrown exception out of
/// `pumpWidget`.
Future<void> _pumpSized(WidgetTester t, Widget screen, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: screen));
  await t.pump(const Duration(milliseconds: 16));
  expect(t.takeException(), isNull);
}

/// NEITHER craft-editor layout scrolls as a page: every pane is bounded and
/// scrolls inside itself.
///
/// Stated as "the 3D view has no scrollable ancestor" because that is the
/// consequence that matters. A viewport inside a scrolling page has no
/// predictable height, and the whole editor computes screen pixels from that
/// height to decide what a click is aimed at.
void _expectNoPageScroll() {
  expect(
    find.ancestor(
        of: find.byType(CraftEditorViewport), matching: find.byType(Scrollable)),
    findsNothing,
  );
}
