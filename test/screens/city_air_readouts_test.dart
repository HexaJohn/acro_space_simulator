// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/app_theme.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_panels.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_site_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// What the colony's readouts SAY about its air, now that it breathes the
/// planet's real sky (docs/plans/terraforming.md §3.4, phase 2): the World
/// drawer's oxygen line on the partial cover, the harvester's site sheet
/// when the sky cannot feed it, and the spaceport's pad row on a port that
/// refuses the player. The domain behind them is pinned in city_air_test;
/// nothing pumped these texts, so they drifted from it.
void main() {
  const atm = 101325.0;
  final mars = fixtureBodies.firstWhere((b) => b.id.value == 'mars');

  /// Mars with its oxygen raised to [pO2Atm], as the inventory publishes it.
  CelestialBody marsWith(double pO2Atm) {
    final a = PlanetAtmosphere.seed(mars)!;
    a.add(
        AtmosphereGas.oxygen,
        a.molesForPartialPressure(a.moles, AtmosphereGas.oxygen, pO2Atm * atm) -
            a.molesOf(AtmosphereGas.oxygen));
    return a.applyTo(mars);
  }

  CitySim marsKit([CelestialBody? sky]) {
    final city = starterKit(body: 'mars');
    if (sky != null) city.body = sky;
    return city;
  }

  Future<_PanelHostState> pumpWorld(WidgetTester t, CitySim city) async {
    t.view.physicalSize = const Size(900, 3000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: _PanelHost(city)));
    return t.state<_PanelHostState>(find.byType(_PanelHost));
  }

  /// The resource detail's how-to-grow hint for oxygen.
  Future<String> oxygenHint(WidgetTester t, _PanelHostState s) async {
    s.showResourceDetail(Commodity.oxygen);
    await t.pumpAndSettle();
    final hint = t
        .widgetList<Text>(find.descendant(
            of: find.byType(Dialog), matching: find.byType(Text)))
        .map((w) => w.data ?? '')
        .firstWhere((d) => d.contains('Electrolysis') || d.contains('sky') ||
            d.contains('oxygen is free'));
    Navigator.of(t.element(find.byType(Dialog))).pop();
    await t.pumpAndSettle();
    return hint;
  }

  group("the World drawer's oxygen line reads the partial cover", () {
    testWidgets('a sky that gives half of each breath says so', (t) async {
      final city = marsKit(marsWith(0.08));
      expect(city.airO2, closeTo(0.5, 1e-9));
      final s = await pumpWorld(t, city);
      expect(find.textContaining('the sky supplies 50% of each breath'),
          findsOneWidget);
      expect(find.textContaining('make the rest: harvest or split water'),
          findsOneWidget);
      expect(await oxygenHint(t, s),
          'The sky supplies 50% of each breath. Build Electrolysis Plants '
          '(split water) or an O₂ Harvester for the rest.');
    });

    testWidgets('a sky that gives every breath asks for no oxygen plant',
        (t) async {
      final city = marsKit(marsWith(0.17));
      expect(city.breathable, isFalse);
      expect(city.airO2, 1.0);
      final s = await pumpWorld(t, city);
      expect(find.textContaining('no oxygen plant needed'), findsOneWidget);
      expect(find.textContaining('harvest or split water'), findsNothing,
          reason: 'it used to say "Thin O₂ (97%) — harvest or split water."');
      final line = t.widget<Text>(find.textContaining('no oxygen plant needed'));
      expect(line.style?.color, AppTheme.accent2,
          reason: 'not in warning colour');
      expect(find.byIcon(Icons.masks), findsNothing);
      expect(await oxygenHint(t, s), contains('no oxygen plant needed'));
    });

    testWidgets('reference Mars: nothing to harvest, split water', (t) async {
      final city = marsKit();
      expect(city.airO2, 0.0);
      final s = await pumpWorld(t, city);
      expect(find.textContaining('No breathable O₂ — split water'),
          findsOneWidget);
      expect(await oxygenHint(t, s), 'Build Electrolysis Plants (split water).',
          reason: 'no harvester offered where it would sit idle');
    });

    testWidgets('the meter that only flips the biome is not "Terraforming"',
        (t) async {
      final city = marsKit()..terraform = 0.4;
      await pumpWorld(t, city);
      expect(find.text('Biome reclamation'), findsOneWidget);
      expect(find.text('Terraforming'), findsNothing);
    });
  });

  group('a harvester the sky cannot feed', () {
    final harvester = kUtilCatalog.firstWhere((s) => s.type == 'o2harvester');

    testWidgets('its status says idle and its sheet shows no output',
        (t) async {
      final city = marsKit();
      final lot = freeLots(city).first.id;
      city.parcelBuildings[lot] = harvester;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showCitySiteDetail(ctx, city, lot, harvester),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.textContaining('+0.0 Oxygen/s'), findsOneWidget);
      expect(find.textContaining('+2.0 Oxygen/s'), findsNothing);

      // Fed, it reports its yield, and is not idle.
      city.body = marsWith(0.08);
      expect(citySiteStatus(city, lot, harvester).label,
          isNot('Idle — no oxygen to draw'));
    });

    test('idle ranks before the colony mood', () {
      // A connected grid harvester on a colony whose mood would otherwise
      // be the report.
      final city = marsKit()..happiness = 0.1;
      final g = city.grid;
      final hy = city.hubKey ~/ g;
      for (var x = 0; x < g; x++) {
        final k = hy * g + x;
        if (k != city.hubKey) city.addRoad(k);
      }
      for (var x = 0; x < g; x++) {
        if (!city.footprintFree(x, hy + 1, harvester)) continue;
        final anchor = city.key(x, hy + 1);
        city.placeUtil(anchor, harvester);
        city.recompute();
        final site = CitySim.siteIdOfCell(anchor);
        if (!city.siteConnected(site)) continue;
        expect(citySiteStatus(city, site, harvester).label,
            'Idle — no oxygen to draw');
        return;
      }
      fail('no connected cell for a harvester');
    });
  });

  testWidgets("an independent port's pad row says it is unwelcome",
      (t) async {
    t.view.physicalSize = const Size(1200, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final city = starterKit();
    final site = city.landingPads().first.$1.id;
    final spec = city.siteSpec(site)!;
    String? targeted;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showCitySiteMenu(
                context: ctx,
                sim: city,
                site: site,
                spec: spec,
                onChanged: () {},
                hooks: CitySiteHooks(onTargetPad: (s) => targeted = s)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    String padSubtitle() {
      final tile = t.widget<ListTile>(find.ancestor(
          of: find.text('Target this pad'), matching: find.byType(ListTile)));
      return (tile.subtitle! as Text).data!;
    }

    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(padSubtitle(), isNot(contains('Unwelcome')));
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();

    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded;
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(padSubtitle(),
        'Unwelcome — ${city.loyalty.portHoldReason}. Your craft can still '
        'land here.');
    // Still live: the player's own craft is deliberately not gated.
    await t.tap(find.text('Target this pad'));
    await t.pumpAndSettle();
    expect(targeted, site);
  });
}

/// A bare host for the colony panels, as the flat builder and the in-world
/// editor wear them.
class _PanelHost extends StatefulWidget {
  const _PanelHost(this.city);
  final CitySim city;
  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> with CityPanels<_PanelHost> {
  @override
  CitySim get sim => widget.city;

  @override
  void panelChanged() => setState(() {});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: ListView(children: cityWorldPanel()),
      );
}
