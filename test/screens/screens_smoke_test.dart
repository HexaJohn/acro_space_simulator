// Smoke test: pump each menu/feature screen and confirm it builds without
// throwing (catches init-time domain-binding errors the analyzer can't see).
import 'package:acro_space_simulator/infrastructure/flutter/screens/ascent_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
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
}
