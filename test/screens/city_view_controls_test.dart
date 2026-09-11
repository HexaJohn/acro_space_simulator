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
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
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

  /// Tap [f] where it is shown: scrolled into view first — the toolbar and
  /// the HUD's bar scroll sideways where the (test) font runs wide — and
  /// then really hittable, so a tap that would miss fails here rather than
  /// leaving the check after it vacuous.
  Future<void> tapShown(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.pump();
    expect(f.hitTestable(), findsOneWidget, reason: '$f is clickable');
    await t.tap(f);
    await t.pump();
  }

  testWidgets('at the default window size nothing covers the Budget drawer',
      (t) async {
    await pumpCity(t);
    await tapShown(t, find.text('Budget'));
    expect(find.text('Tax rate'), findsOneWidget);
    expectUncovered(t, find.byType(Slider), 'the tax slider');
  });

  testWidgets('city mode keeps Save and Load, and drops the flight controls',
      (t) async {
    await pumpCity(t);
    // Open what reaches furthest into the corners, and the city's own
    // controls must still be clear of it.
    await tapShown(t, find.text('Road'));
    await tapShown(t, find.text('Budget'));
    expect(find.text('Tax rate'), findsOneWidget);
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

  testWidgets('with any tool held, every city control stays clickable',
      (t) async {
    await pumpCity(t);
    void expectControls(String when) {
      for (final tag in ['save', 'load', 'warpdown', 'warpup', 'debug']) {
        expect(fab(tag).hitTestable(), findsOneWidget, reason: '$tag $when');
      }
    }

    // A readout tab, not a word of the same spelling in its drawer: the
    // tabs come first in the toolbar's column.
    Finder tab(CityReadout r) => find
        .descendant(
            of: find.byType(CityEditOverlay), matching: find.text(r.label))
        .first;

    // The open readout drawer is on screen, shows something, and can be
    // scrolled to its end: squeezed under the controls it scrolls, and
    // nothing of it is out of reach.
    Future<void> expectDrawerReachable(String when) async {
      final list = find.descendant(
          of: find.byType(CityEditOverlay),
          matching: find.byWidgetPredicate((w) => w is ListView && w.shrinkWrap));
      expect(list, findsOneWidget, reason: 'the drawer is open $when');
      final box = t.renderObject(list) as RenderBox;
      final r = box.localToGlobal(Offset.zero) & box.size;
      expect(r.top >= 0 && r.bottom <= window.height, isTrue,
          reason: 'the drawer is on screen $when: $r');
      expect(r.height, greaterThan(48), reason: 'the drawer shows rows $when');
      expect(list.hitTestable(), findsOneWidget,
          reason: 'the drawer takes a drag $when');
      final pos = t
          .state<ScrollableState>(
              find.descendant(of: list, matching: find.byType(Scrollable)))
          .position;
      // Drag after drag, as a player would: each loses its start to the
      // touch slop, and a half-height drag keeps the pointer on the list.
      for (var i = 0; i < 20 && pos.pixels < pos.maxScrollExtent - 0.5; i++) {
        await t.drag(list, Offset(0, -r.height / 2));
        await t.pump();
      }
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 0.5),
          reason: 'drags reach the end of the drawer $when');    }

    // Build's row of buildings is the toolbar's tallest; it once covered
    // the debug toggle at the foot of a ~320 px column. A readout drawer
    // is full width and up to 45% of the window: open under Road's or
    // Build's row it once reached up over Save, Load, warp and debug.
    for (final tool in ['Zone', 'Road', 'Traffic', 'Build', 'Clear']) {
      await tapShown(t, find.text(tool).first);
      expectControls('with the $tool tool held');
      if (tool != 'Road' && tool != 'Build') continue;
      for (final r in CityReadout.values) {
        await tapShown(t, tab(r));
        // The drawers share one list, and the last one's scroll carries
        // over and springs back into the new one's range: let it settle.
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expectControls('with $tool held and the ${r.label} drawer open');
        await expectDrawerReachable('with $tool held, ${r.label}');
      }
      // The open tab again: the drawer shuts.
      await tapShown(t, tab(CityReadout.values.last));
      expect(
          find.descendant(
              of: find.byType(CityEditOverlay),
              matching:
                  find.byWidgetPredicate((w) => w is ListView && w.shrinkWrap)),
          findsNothing);
    }
  });

  /// The city game as the app opens it: pushed over a page, so that
  /// leaving has somewhere to go back to.
  Future<CitySim> pushCity(WidgetTester t, {bool withColony = true}) async {
    t.view.physicalSize = window;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final colony = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth', latitude: 12, longitude: 20),
      id: 'controls',
    );
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SimulationView(
                  injectedCity: withColony ? colony : null,
                  cityMode: true,
                  spawnDemoOrbiter: false,
                ),
              )),
              child: const Text('open the colony'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open the colony'));
    // The route's transition; the view's ticker never lets it settle.
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(SimulationView), findsOneWidget);
    return colony;
  }

  Finder leaveButton() => find.byTooltip('Leave the colony');

  testWidgets('the city game offers no Close editor to strand the player on',
      (t) async {
    await pushCity(t);
    // Closing the editor took the HUD — and its exit — with it, and left a
    // bare planet with nothing to reopen it by.
    expect(find.byTooltip('Close editor'), findsNothing);
    expect(leaveButton().hitTestable(), findsOneWidget);
  });

  testWidgets('Load puts the player back in the editor, exit and all',
      (t) async {
    final injected = await pushCity(t);
    await tapShown(t, fab('save'));
    await tapShown(t, fab('load'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    // The editor is open again on the colony the load brought back: a new
    // object with the same id, not the ghost the load replaced. That is
    // also the proof the load ran — a Load that did nothing would leave the
    // editor on the injected colony. (Its snackbar is no proof here: it
    // queues behind Save's.)
    final overlay = find.byType(CityEditOverlay);
    expect(overlay, findsOneWidget);
    final city = t.widget<CityEditOverlay>(overlay).city;
    expect(city.id, 'controls');
    expect(identical(city, injected), isFalse,
        reason: 'the editor must follow the loaded colony');
    expect(t.widget<CityGameHud>(find.byType(CityGameHud)).city, same(city));
    expect(leaveButton().hitTestable(), findsOneWidget);
    expect(fab('save').hitTestable(), findsOneWidget);
  });

  testWidgets('with no colony up, city mode still has a way home', (t) async {
    await pushCity(t, withColony: false);
    expect(find.byType(CityGameHud), findsNothing);
    await tapShown(t, fab('menu'));
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(SimulationView), findsNothing);
    expect(find.text('open the colony'), findsOneWidget);
  });
}
