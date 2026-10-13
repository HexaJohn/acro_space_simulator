// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Designing before building (docs/plans/factory-floors.md §3 "Design
/// before building"): the build palette's blueprint picker chooses what a
/// new plant is stamped with, "Design floor" opens a sandbox whose "Save as
/// blueprint" files the design in the colony's library and picks it, and
/// the in-world bulldozer asks before it loses a designed floor.
library;

import 'package:acro_space_simulator/domain/colony/city/city_factories.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/colony_floor_ui.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/factory/factory_floor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

Future<void> pumpHost(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await t.pump();
}

/// The Steel Mill template with one more forklift hired: a design that
/// costs more than the template's flat build cost.
FloorBlueprint richerMill() {
  final bp = FloorBlueprint.fromJson(
      {...factoryTemplateFor('steelmill')!.toJson(), 'plant': 'steelmill'});
  bp.roster[HandlerKind.forklift] = (bp.roster[HandlerKind.forklift] ?? 0) + 1;
  return bp;
}

void main() {
  // Picking a saved design makes it the one new plants are stamped with,
  // and the build cost follows it; "Template" goes back.
  testWidgets('the picker sets the blueprint for new plants', (t) async {
    final city = foundedColony();
    city.factoryFloors.saveBlueprint('Mill A', richerMill());
    final spec = specOf('steelmill');
    await pumpHost(
        t,
        StatefulBuilder(
            builder: (context, set) => FloorBlueprintPicker(
                city: city, spec: spec, onChanged: () => set(() {}))));
    expect(city.selectedFloorBlueprint['steelmill'], isNull);

    await t.tap(find.byKey(const Key('floor-pick-steelmill')));
    await t.pumpAndSettle();
    await t.tap(find.text('Mill A').last);
    await t.pumpAndSettle();
    expect(city.selectedFloorBlueprint['steelmill'], 'Mill A');
    expect(city.floorBlueprintFor('steelmill'), isNotNull);

    await t.tap(find.byKey(const Key('floor-pick-steelmill')));
    await t.pumpAndSettle();
    await t.tap(find.text('Template').last);
    await t.pumpAndSettle();
    expect(city.selectedFloorBlueprint['steelmill'], isNull);
  });

  // "Design floor" → a sandbox the editor drives itself; "Save as
  // blueprint" → named into the library and picked for the plant.
  testWidgets('a sandbox design saves into the library', (t) async {
    final city = foundedColony();
    final spec = specOf('steelmill');
    await pumpHost(
        t, FloorBlueprintPicker(city: city, spec: spec, onChanged: () {}));
    await t.tap(find.byKey(const Key('design-floor-steelmill')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final screen =
        t.widget<FactoryFloorScreen>(find.byKey(const Key('floor-sandbox')));
    expect(screen.drivesSim, isTrue, reason: 'the sandbox drives itself');

    await t.tap(find.byKey(const Key('save-blueprint')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.enterText(find.byKey(const Key('blueprint-name')), 'Lean mill');
    await t.tap(find.byKey(const Key('blueprint-name-save')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(city.factoryFloors.library.keys, contains('Lean mill'));
    expect(city.factoryFloors.library['Lean mill']!.plantType, 'steelmill');
    expect(city.selectedFloorBlueprint['steelmill'], 'Lean mill');
    // Closing the sandbox leaves the colony untouched otherwise.
    expect(city.factoryFloors.siteIds, isEmpty);
  });

  // The in-world bulldozer over a designed floor asks first, and demolishes
  // only on a yes; headless (no one to ask) it refuses and says why.
  test('the in-world bulldozer asks before losing a designed floor',
      () async {
    final city = foundedColony();
    final lot = placeOnFreeLot(city, specOf('steelmill'));
    city.factoryFloors[lot]!.designed = true;
    final edit = CityEditController()..set(CityEditTool.bulldoze);

    edit.applyToLot(city, lot);
    expect(city.parcelBuildings.containsKey(lot), isTrue);
    expect(edit.blocked, contains('custom floor design'));

    final asked = <String>[];
    var answer = false;
    edit.askFloorLoss = (site) async {
      asked.add(site);
      return answer;
    };
    edit.applyToLot(city, lot);
    await Future<void>.delayed(Duration.zero);
    expect(asked, [lot]);
    expect(city.parcelBuildings.containsKey(lot), isTrue, reason: 'refused');

    answer = true;
    edit.applyToLot(city, lot);
    await Future<void>.delayed(Duration.zero);
    expect(city.parcelBuildings.containsKey(lot), isFalse);
  });

  // A template floor is bulldozed as any building is: nothing to lose.
  test('a template floor is bulldozed without a question', () {
    final city = foundedColony();
    final lot = placeOnFreeLot(city, specOf('steelmill'));
    final edit = CityEditController()
      ..set(CityEditTool.bulldoze)
      ..askFloorLoss = (_) async => fail('asked about a template');
    edit.applyToLot(city, lot);
    expect(city.parcelBuildings.containsKey(lot), isFalse);
  });

  // A picked design too big for the site says so in the palette, before
  // the player goes looking for ground.
  testWidgets('a misfit pick says why it will not place', (t) async {
    final city = foundedColony();
    // A 10 km hall: no plant site is that big.
    city.factoryFloors.saveBlueprint(
        'Huge', richerMill()..hall = const HallSize(5000, 5000));
    city.selectFloorBlueprint('steelmill', 'Huge');
    final why = city.floorBlueprintRefusal(specOf('steelmill'));
    expect(why, isNotNull);
    await pumpHost(
        t,
        FloorBlueprintPicker(
            city: city, spec: specOf('steelmill'), onChanged: () {}));
    expect(find.text(why!), findsOneWidget);
  });

  // The palette's build cost is the design's capex once one is picked.
  test('buildCostOf follows the pick', () {
    final city = foundedColony();
    final spec = specOf('steelmill');
    expect(city.buildCostOf(spec), spec.buildCost);
    city.factoryFloors.saveBlueprint('Mill A', richerMill());
    city.selectFloorBlueprint('steelmill', 'Mill A');
    expect(city.buildCostOf(spec), greaterThan(spec.buildCost),
        reason: 'a design with an extra forklift costs more than the '
            "template's flat build cost");
  });
}
