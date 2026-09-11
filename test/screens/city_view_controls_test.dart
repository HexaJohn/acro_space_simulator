// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Cover for "the flight view's buttons sit on the city toolbar".
//
// The flight view's control stack was the Scaffold's floating action button
// in every mode, and a Scaffold draws that over its body — so in city mode
// the right-hand column and the bottom icon row covered the end of the road
// menu, the readouts and the Budget drawer at the default window size, however
// topmost the toolbar and the HUD were inside the body. City mode keeps only
// what the city uses, beneath the toolbar and the HUD.
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/road_tool_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The desktop window's default size, where the live run saw it.
  const window = Size(1084, 681);

  Future<void> pumpCity(WidgetTester t) async {
    t.view.physicalSize = window;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final colony = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth', latitude: 12, longitude: 20),
      id: 'controls',
    );
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
      ),
    ));
    await t.pump(const Duration(milliseconds: 16));
  }

  Finder fab(String tag) => find.byWidgetPredicate(
      (w) => w is FloatingActionButton && w.heroTag == tag);

  /// A pointer across [f]'s middle — near each end and at the centre of
  /// what of it is on screen — lands on [f] itself, not on something drawn
  /// over it.
  void expectUncovered(WidgetTester t, Finder f, String what) {
    final box = t.renderObject(f) as RenderBox;
    final r = (box.localToGlobal(Offset.zero) & box.size)
        .intersect(Offset.zero & window);
    expect(r.width > 8 && r.height > 8, isTrue, reason: '$what is on screen');
    for (final fx in const [0.15, 0.5, 0.85]) {
      final p = Offset(r.left + r.width * fx, r.center.dy);
      final hit = t.hitTestOnBinding(p);
      expect(hit.path.any((e) => e.target == box), isTrue,
          reason: '$what is covered at $p');
    }
  }

  testWidgets('at the default window size nothing covers the road menu',
      (t) async {
    await pumpCity(t);
    await t.tap(find.text('Road'));
    await t.pump();
    final small = [
      for (final type in kRoadCatalog)
        if (type.group == RoadGroup.small) type
    ];
    expect(small.length, greaterThanOrEqualTo(7));
    for (final type in small) {
      final cell = find
          .ancestor(
              of: find.text(roadTypeShortLabel(type)),
              matching: find.byType(InkWell))
          .first;
      // The row scrolls sideways when the window is narrower than the
      // menu; what is scrolled away is not covered, just not shown yet.
      await t.ensureVisible(cell);
      await t.pump();
      expectUncovered(t, cell, type.label);
    }
  });

  testWidgets('at the default window size nothing covers the Budget drawer',
      (t) async {
    await pumpCity(t);
    await t.tap(find.text('Budget'));
    await t.pump();
    expect(find.text('Tax rate'), findsOneWidget);
    expectUncovered(t, find.byType(Slider), 'the tax slider');
  });

  testWidgets('city mode keeps Save and Load, and drops the flight controls',
      (t) async {
    await pumpCity(t);
    // Open what reaches furthest into the corners, and the city's own
    // controls must still be clear of it.
    await t.tap(find.text('Road'));
    await t.pump();
    await t.tap(find.text('Budget'));
    await t.pump();
    for (final tag in ['save', 'load']) {
      expect(fab(tag).hitTestable(), findsOneWidget, reason: tag);
    }
    for (final tag in [
      'collapse',
      'manual',
      'cammode',
      'view',
      'zoomin',
      'zoomout',
      'freecam',
      'walk',
      'lamp',
      'alignUp',
      'inertialTrails',
      'renderBackend',
    ]) {
      expect(fab(tag), findsNothing, reason: '$tag is a flight control');
    }
  });
}
