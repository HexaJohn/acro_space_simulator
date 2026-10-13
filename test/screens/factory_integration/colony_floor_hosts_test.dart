// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every colony host shows the plant economy's asks and its floors cleanly
/// (docs/plans/factory-floors.md §4, §7 Q11): the city game's HUD, the
/// flight view's in-world editor and the flat builder all toast a reverted
/// edit and put a failed firm's offer in front of the player; the flight
/// view takes its own flight controls down while a floor is open; one floor
/// replacing another stays open; and a scripted close names its floor.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_game_hud.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_site_actions.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/colony_floor_ui.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/sim_view_control.dart';
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/render_backend.dart';
import 'package:acro_space_simulator/main_city_game_dev.dart' show factoryHook;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

/// A colony whose Steel Mill's floor edit was undone for want of ore: the
/// reason is queued for the HUD. Returns the colony and the lot.
(CitySim, String) revertedEdit() {
  final city = foundedColony()..population = 300;
  final lot = placeOnFreeLot(city, specOf('steelmill'));
  expect(city.openFloor(lot)!.hire(HandlerKind.forklift, 3).ok, isTrue);
  expect(city.closeFloor(lot).capexDelta, greaterThan(0));
  city.stock[Commodity.ore] = 0;
  final rec = city.factoryFloors[lot]!;
  expect(city.applyFloorMeasure(lot, rec.rates, rev: rec.rev), isTrue);
  expect(city.colonyEconomy.notices, hasLength(1));
  return (city, lot);
}

/// [city] with a closed plant's offer waiting on [lot].
void offerOn(CitySim city, String lot) => city.colonyEconomy.offers.add(
    FirmOffer(site: lot, options: closureOptions(city.economyKind)));

Future<void> sized(WidgetTester t) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// The flight (or city-game) view over [colony], software backend.
Future<void> pumpView(WidgetTester t, CitySim colony,
    {required bool cityMode}) async {
  await sized(t);
  await t.pumpWidget(MaterialApp(
    home: SimulationView(
      injectedCity: colony,
      cityMode: cityMode,
      spawnDemoOrbiter: false,
      initialBackend: RenderBackend.software,
    ),
  ));
  await t.pump(const Duration(milliseconds: 16));
}

Future<void> frames(WidgetTester t, int n) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('notices', () {
    // The edit snapped back; the player is told why, once, and the site
    // panel keeps the reason after the toast is gone.
    testWidgets('the HUD toasts a reverted floor edit', (t) async {
      final (city, lot) = revertedEdit();
      await sized(t);
      await t.pumpWidget(
          MaterialApp(home: Scaffold(body: CityGameHud(city: city))));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('economy-notice')), findsOneWidget);
      expect(find.textContaining('the old layout stays'), findsOneWidget);
      expect(city.colonyEconomy.notices, isEmpty, reason: 'drained');
      expect(floorSiteLines(city, lot),
          contains(startsWith('Last edit undone: ')));
    });

    // The flight view has no HUD: its in-world editor toasts instead.
    testWidgets('the in-world editor toasts when it hosts the economy',
        (t) async {
      final (city, _) = revertedEdit();
      await sized(t);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CityEditOverlay(
                  controller: CityEditController(),
                  city: city,
                  onClose: null,
                  hostsPlantEconomy: true))));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('economy-notice')), findsOneWidget);
    });

    // Under the city game's HUD the editor leaves both to the HUD.
    testWidgets('the editor under a HUD leaves notices alone', (t) async {
      final (city, _) = revertedEdit();
      await sized(t);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CityEditOverlay(
                  controller: CityEditController(),
                  city: city,
                  onClose: null))));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('economy-notice')), findsNothing);
      expect(city.colonyEconomy.notices, hasLength(1));
    });

    testWidgets('the flat builder toasts a reverted floor edit', (t) async {
      final (city, _) = revertedEdit();
      await sized(t);
      await t.pumpWidget(MaterialApp(home: CityBuilderScreen(sim: city)));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('economy-notice')), findsOneWidget);
    });
  });

  group('firm offers', () {
    testWidgets('the in-world editor shows a closed plant\'s offer',
        (t) async {
      final city = foundedColony();
      final lot = placeOnFreeLot(city, specOf('steelmill'));
      offerOn(city, lot);
      await sized(t);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: CityEditOverlay(
                  controller: CityEditController(),
                  city: city,
                  onClose: null,
                  hostsPlantEconomy: true))));
      await t.pump();
      expect(find.byKey(const Key('firm-offer')), findsOneWidget);
      await t.tap(find.byKey(const Key('firm-offer-sellToNewFirm')));
      await t.pump();
      expect(city.pendingFirmOffers, isEmpty);
      expect(city.ownerOf(lot).isState, isFalse);
    });

    testWidgets('the flat builder shows a closed plant\'s offer', (t) async {
      final city = foundedColony();
      final lot = placeOnFreeLot(city, specOf('steelmill'));
      offerOn(city, lot);
      await sized(t);
      await t.pumpWidget(MaterialApp(home: CityBuilderScreen(sim: city)));
      await t.pump();
      expect(find.byKey(const Key('firm-offer')), findsOneWidget);
      await t.tap(find.byKey(const Key('firm-offer-nationalise')));
      await t.pump();
      expect(city.ownerOf(lot).isState, isTrue);
    });

    // Any host's site menu: a closed plant offers its own options — a sale
    // too, which "Nationalise" alone never reached.
    testWidgets('a closed plant\'s site menu offers the sale', (t) async {
      final city = foundedColony()..economy = Economy.capitalism;
      final lot = placeOnFreeLot(city, specOf('steelmill'));
      final firm = city.ownerOf(lot).firmId;
      offerOn(city, lot);
      t.view.physicalSize = const Size(1200, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCitySiteMenu(
                context: context,
                sim: city,
                site: lot,
                spec: city.siteSpec(lot)!,
                onChanged: () {},
                hooks: const CitySiteHooks(),
              ),
              child: const Text('open menu'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open menu'));
      await t.pumpAndSettle();
      expect(find.text('Sell to new firm'), findsOneWidget);
      await t.tap(find.text('Sell to new firm'));
      await t.pumpAndSettle();
      expect(city.pendingFirmOffers, isEmpty);
      expect(city.ownerOf(lot).isState, isFalse);
      expect(city.ownerOf(lot).firmId, isNot(firm));
    });
  });

  group('flat builder', () {
    // Clear wipes the grid; the floors, books and offers of the plants on
    // it go too, or they'd be saved and booked for buildings that are gone.
    testWidgets('Clear drops the grid plants\' floors and offers',
        (t) async {
      final city = foundedColony();
      city.placeUtil(5, specOf('steelmill'));
      final site = CitySim.siteIdOfCell(5);
      offerOn(city, site);
      await sized(t);
      await t.pumpWidget(MaterialApp(home: CityBuilderScreen(sim: city)));
      await t.pump();
      await t.tap(find.byTooltip('Clear'));
      await t.pump();
      expect(city.factoryFloors[site], isNull);
      expect(city.pendingFirmOffers, isEmpty);
    });

    // Opening and closing a floor must not re-inflate the page: the same
    // Scaffold state before, during and after.
    testWidgets('opening a floor keeps the page\'s state', (t) async {
      final city = foundedColony();
      final lot = placeOnFreeLot(city, specOf('steelmill'));
      await sized(t);
      await t.pumpWidget(MaterialApp(home: CityBuilderScreen(sim: city)));
      await t.pump();
      final before = t.state<ScaffoldState>(find.byType(Scaffold).first);
      final builder = t.state(find.byType(CityBuilderScreen));
      // The site menu's hook, as the player's click calls it.
      (builder as dynamic).openFactoryFloor(lot);
      await t.pump();
      expect(find.byType(FactoryFloorScreen), findsOneWidget);
      expect(t.state<ScaffoldState>(find.byType(Scaffold).first),
          same(before));
      await t.tap(find.byKey(const Key('factory-back')));
      await t.pump();
      expect(find.byType(FactoryFloorScreen), findsNothing);
      expect(t.state<ScaffoldState>(find.byType(Scaffold).first),
          same(before));
    });
  });

  group('flight view', () {
    // Out of city mode the flight FABs paint over the body: with a floor
    // open they must be gone, and the editor keeps the keyboard.
    testWidgets('no flight button stands over an open floor', (t) async {
      final colony = foundedColony();
      final lot = placeOnFreeLot(colony, specOf('steelmill'));
      await pumpView(t, colony, cityMode: false);
      expect(find.byType(FloatingActionButton), findsWidgets,
          reason: 'the flight controls are up before');
      final open = SimViewControl.instance.factoryFloor!(lot);
      expect(open['open'], lot);
      // The Scaffold scales its button stack out: let the exit run.
      await frames(t, 40);
      expect(find.byType(FactoryFloorScreen), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'factory-floor');
      await t.tap(find.byKey(const Key('factory-back')));
      await frames(t, 40);
      expect(find.byType(FloatingActionButton), findsWidgets,
          reason: 'and back once it closes');
    });

    // Opening B over A closes A; A's overlay, still up for a frame, sees
    // its floor gone and reports it — which used to take B down too.
    testWidgets('opening a second floor over the first keeps it open',
        (t) async {
      final colony = foundedColony();
      final a = placeOnFreeLot(colony, specOf('steelmill'));
      final b = placeOnFreeLot(colony, specOf('refinery'));
      await pumpView(t, colony, cityMode: true);
      SimViewControl.instance.factoryFloor!(a);
      await t.pump();
      expect(SimViewControl.instance.factoryFloor!(b)['open'], b);
      await frames(t, 3);
      expect(find.byType(FactoryFloorScreen), findsOneWidget);
      expect(colony.factoryFloors[b]!.live, isNotNull);
      expect(colony.factoryFloors[a]!.live, isNull);
    });

    // A scripted close names the floor it means: closing another plant's
    // would settle that one's edit instead.
    testWidgets('the dev hook refuses to close a floor that is not open',
        (t) async {
      final colony = foundedColony();
      final a = placeOnFreeLot(colony, specOf('steelmill'));
      final b = placeOnFreeLot(colony, specOf('refinery'));
      await pumpView(t, colony, cityMode: true);
      factoryHook(colony, 'open:$a');
      await t.pump();
      final wrong = factoryHook(colony, 'close:$b') as Map;
      expect(wrong['error'], contains(b));
      await t.pump();
      expect(colony.factoryFloors[a]!.live, isNotNull, reason: 'A stays open');
      final right = factoryHook(colony, 'close:$a') as Map;
      expect(right['closed'], a);
      await t.pump();
      expect(find.byType(FactoryFloorScreen), findsNothing);
    });
  });

  // The hover's misfit message comes down once the pick fits again, and
  // only the hover's own.
  test('misfitRefusal takes back only its own message', () {
    const m = 'does not fit';
    var r = misfitRefusal(misfit: m, blocked: null, shown: null);
    expect(r, (blocked: m, shown: m));
    r = misfitRefusal(misfit: null, blocked: m, shown: m);
    expect(r, (blocked: null, shown: null), reason: 'the pick fits again');
    r = misfitRefusal(misfit: null, blocked: 'Needs ore', shown: m);
    expect(r, (blocked: 'Needs ore', shown: null),
        reason: 'someone else\'s refusal stays');
  });
}
