// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The road tool in the real view: picking, the pick layer's gestures, the
// keys. Driven with real pointer and key events against the city mode's
// flight view, and read back through the dev hook's status.
//
// The 3D backend, because ground picking needs the scene snapshot only it
// captures. Its GPU asset warnings are expected here.
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/render_backend.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<CitySim> pumpCity(WidgetTester t) async {
    t.view.physicalSize = const Size(1600, 1000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final colony = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth', latitude: 12, longitude: 20),
      id: 'roads',
    );
    await t.pumpWidget(MaterialApp(
      home: SimulationView(
        injectedCity: colony,
        cityMode: true,
        spawnDemoOrbiter: false,
        initialBackend: RenderBackend.flutterScene,
      ),
    ));
    // A few frames: picking needs the scene snapshot the frame captures.
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    return colony;
  }

  Map<String, Object?> status() => SimViewControl.instance.status!();
  Map<String, Object?> road([Map<String, String> p = const {}]) =>
      SimViewControl.instance.roadTool!(p);

  /// A real mouse click: down, a few pixels of hand jitter, up.
  Future<void> jitteryClick(WidgetTester t, Offset at,
      {int buttons = kPrimaryButton}) async {
    final g =
        await t.createGesture(kind: PointerDeviceKind.mouse, buttons: buttons);
    await g.down(at);
    await t.pump();
    await g.moveBy(const Offset(3, 1));
    await t.pump();
    await g.up();
    await t.pump();
  }

  Future<void> holdRoadTool(WidgetTester t) async {
    await jitteryClick(t, t.getCenter(find.text('Road')));
    await t.pump();
    expect(road()['tool'], 'roadSpline');
  }

  /// Open ground in the middle of the view, clear of the top bar and the
  /// toolbar.
  const world = Offset(800, 450);

  testWidgets('a click with a few pixels of jitter still starts a road',
      (t) async {
    // The pick layer declared a pan for every held tool, and a mouse's pan
    // slop (2 px) beats a tap's (18 px): a click that wobbled was won by a
    // pan that did nothing, and the road tool placed nothing at all.
    await pumpCity(t);
    await holdRoadTool(t);
    expect(road()['anchor'], isNull);
    final before = status();
    await jitteryClick(t, world);
    expect(road()['anchor'], isNotNull, reason: 'the pan beat the tap');
    final after = status();
    expect(after['azimuth'], before['azimuth']);
    expect(after['elevation'], before['elevation']);
  });

  testWidgets('a second click builds the stretch and charges for it',
      (t) async {
    final colony = await pumpCity(t);
    await holdRoadTool(t);
    road({'snap': ''});
    final roads = colony.layout.roads.length;
    final funds = colony.funds;
    await jitteryClick(t, const Offset(700, 380));
    await jitteryClick(t, const Offset(900, 380));
    final s = road();
    final q = s['lastQuote']! as Map;
    expect(q['ok'], isTrue, reason: '${q['reason']}');
    expect(colony.layout.roads.length, greaterThan(roads));
    final cost = q['cost']! as double;
    expect(cost, greaterThan(0));
    // The tick runs between the clicks, so the treasury moves a hair on its
    // own; the build is the step.
    expect(colony.funds, closeTo(funds - cost, cost * 0.05));
    expect(s['anchor'], isNotNull, reason: 'the chain carries on');
  });

  testWidgets('PAGE UP raises the road, held it repeats, PAGE DOWN lowers it',
      (t) async {
    await pumpCity(t);
    await t.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await t.pump();
    expect(road()['elevationM'], 0.0, reason: 'only while the road tool is held');
    await holdRoadTool(t);
    await t.sendKeyDownEvent(LogicalKeyboardKey.pageUp);
    await t.pump();
    expect(road()['elevationM'], 12.0);
    await t.sendKeyRepeatEvent(LogicalKeyboardKey.pageUp);
    await t.pump();
    expect(road()['elevationM'], 24.0);
    await t.sendKeyUpEvent(LogicalKeyboardKey.pageUp);
    await t.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await t.pump();
    expect(road()['elevationM'], 12.0);
    expect(find.text('+12 m'), findsOneWidget, reason: 'the bar agrees');
  });

  testWidgets('a right-click ends the road being drawn, and orbits nothing',
      (t) async {
    await pumpCity(t);
    await holdRoadTool(t);
    await jitteryClick(t, world);
    expect(road()['anchor'], isNotNull);
    final before = status();
    await jitteryClick(t, world, buttons: kSecondaryMouseButton);
    expect(road()['anchor'], isNull);
    expect(status()['azimuth'], before['azimuth']);
  });

  testWidgets('Esc ends the road being drawn', (t) async {
    await pumpCity(t);
    await holdRoadTool(t);
    await jitteryClick(t, world);
    expect(road()['anchor'], isNotNull);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(road()['anchor'], isNull);
  });

  testWidgets('the mode chips switch the mode', (t) async {
    await pumpCity(t);
    await holdRoadTool(t);
    expect(road()['mode'], 'straight');
    for (final (label, mode) in const [
      ('Curved', 'curved'),
      ('Freeform', 'freeform'),
      ('Upgrade', 'upgrade'),
      ('Straight', 'straight'),
    ]) {
      await jitteryClick(t, t.getCenter(find.text(label)));
      expect(road()['mode'], mode);
    }
  });

  testWidgets('the snapping menu switches an option; the click that closes '
      'it starts no road', (t) async {
    await pumpCity(t);
    await holdRoadTool(t);
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    await t.tap(find.byTooltip('Snapping'));
    await settle();
    // The menu ITEM, not its label: the label paints but is not what a
    // pointer hits.
    await t.tap(find.byWidgetPredicate((w) =>
        w is CheckedPopupMenuItem &&
        w.child is Text &&
        (w.child! as Text).data == 'Angles'));
    await settle();
    expect(road()['snap'], isNot(contains('angles')));
    expect(road()['snap'], contains('roads'));

    await t.tap(find.byTooltip('Snapping'));
    await settle();
    expect(find.text('Guidelines'), findsOneWidget, reason: 'the menu is up');
    await t.tapAt(world);
    await settle();
    expect(find.text('Guidelines'), findsNothing, reason: 'dismissed');
    expect(road()['anchor'], isNull,
        reason: 'the barrier took the click, not the ground');
    // And the keys still reach the world once the menu is gone.
    await t.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await t.pump();
    expect(road()['elevationM'], 12.0);
  });

  testWidgets('typing a road name never walks, zones or flies the world',
      (t) async {
    final colony = await pumpCity(t);
    expect(colony.layout.nearestRoadPoint(const Vec2(0, 0), withinM: 30),
        isNotNull,
        reason: 'the starter kit is a crossroads at the site');
    await jitteryClick(t, t.getCenter(find.text('Traffic')));
    await jitteryClick(t, t.getCenter(find.text('Adjust')));
    expect(road()['trafficView'], 'adjust');
    // The site is under the pivot, the middle of the view.
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(const Offset(800, 500));
    await t.pump();
    await g.up();
    await t.pump();
    final id = road()['selectedRoadId'] as String?;
    expect(id, isNotNull, reason: 'a click on a road picks it in Adjust');
    expect(find.byType(TextField), findsOneWidget);

    await t.tap(find.byType(TextField));
    await t.pump();
    for (final k in [
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyZ,
      LogicalKeyboardKey.keyW,
    ]) {
      await t.sendKeyEvent(k);
      await t.pump();
    }
    expect(status()['walk'], isFalse, reason: 'G typed is a letter, not a walk');
    expect(CityNodes.zoneOverlay, isFalse);

    await t.enterText(find.byType(TextField), 'Harbour Road');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(colony.roadNameOf(id!), 'Harbour Road');
  });

  testWidgets('the dev hook draws the ghost through the same paths',
      (t) async {
    await pumpCity(t);
    road({'tool': 'road', 'snap': ''});
    road({'click': '0.44,0.38'});
    final s = road({'hover': '0.56,0.38'});
    final overlay = s['overlay']! as Map;
    expect(overlay['ghostPoints'], greaterThan(1));
    expect(overlay['ghostState'], 'ok');
    expect(s['preview'], isNotNull);
    road({'key': 'escape'});
    expect(road()['anchor'], isNull);
    road({'tool': 'look'});
    expect((road()['overlay']! as Map)['ghostPoints'], 0,
        reason: 'putting the tool down takes its ghost with it');
  });

  testWidgets("Enter in a road's name hands the keys back to the world",
      (t) async {
    // The field's own Enter left focus on the route's scope, an ancestor
    // of the view's key node: every key after it went nowhere until the
    // world was clicked.
    final colony = await pumpCity(t);
    await jitteryClick(t, t.getCenter(find.text('Traffic')));
    await jitteryClick(t, t.getCenter(find.text('Adjust')));
    final g = await t.createGesture(
        kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
    await g.down(const Offset(800, 500));
    await t.pump();
    await g.up();
    await t.pump();
    final id = road()['selectedRoadId'] as String?;
    expect(id, isNotNull, reason: 'a click on a road picks it in Adjust');
    await t.tap(find.byType(TextField));
    await t.pump();
    await t.enterText(find.byType(TextField), 'Harbour Road');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(colony.roadNameOf(id!), 'Harbour Road');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(road()['selectedRoadId'], isNull,
        reason: 'Esc reached the view and dropped the selection');
  });

  testWidgets('the lot-sized ground cursor shows only for the tools that '
      'work on lots', (t) async {
    // On the road tool it hid most of a short road's ghost and its arrows,
    // and on Look it marked a lot nothing was going to happen to.
    CityNodes.cursorBF = null;
    await pumpCity(t);
    const at = '0.5,0.45';
    for (final tool in ['road', 'traffic', 'look']) {
      road({'tool': tool, 'hover': at});
      expect(CityNodes.cursorBF, isNull, reason: tool);
    }
    for (final label in ['Zone', 'Build', 'Clear']) {
      await jitteryClick(t, t.getCenter(find.text(label)));
      road({'hover': at});
      expect(CityNodes.cursorBF, isNotNull, reason: label);
      // And a road tool picked up after it takes the cursor away again.
      road({'tool': 'road', 'hover': at});
      expect(CityNodes.cursorBF, isNull, reason: 'Road after $label');
    }
  });

  testWidgets('loading a save puts the road tool down with the editor',
      (t) async {
    await pumpCity(t);
    road({'tool': 'road', 'snap': ''});
    road({'click': '0.44,0.38'});
    road({'hover': '0.56,0.38'});
    final o = RoadOverlayState.instance;
    expect(o.ghostBF, isNotEmpty);
    expect(o.markers, isNotEmpty, reason: 'the anchor ring');
    Finder fab(String tag) => find.byWidgetPredicate(
        (w) => w is FloatingActionButton && w.heroTag == tag);
    await t.tap(fab('save'));
    await t.pump();
    await t.tap(fab('load'));
    await t.pump();
    expect(o.ghostBF, isEmpty, reason: 'the ghost went with the editor');
    expect(o.markers, isEmpty);
    expect(o.lines, isEmpty);
    // Let the save and load notices run out.
    await t.pump(const Duration(seconds: 3));
  });
}
