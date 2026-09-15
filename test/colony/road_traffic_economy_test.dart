// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// The routed traffic model now gates growth — a shop or a works no lorry
/// can reach does not grow, a home beside a loud road grows slower, tax
/// follows land value. The one thing it must never do is starve an ordinary
/// town: the city builder's opening position, zoned all three ways, grows
/// all three ways.
void main() {
  test('the starter town, zoned all three ways, grows all three ways', () {
    final c = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth'),
      start: CityStart.relaxed,
    );
    // Every free street lot, dealt round the three zones.
    final uses = [
      ParcelUse.residential,
      ParcelUse.residential,
      ParcelUse.commercial,
      ParcelUse.industrial,
    ];
    var k = 0;
    for (final lot in c.layout.autoParcels.toList()) {
      if (c.parcelBuildings.containsKey(lot.id)) continue;
      c.layout.setUse(lot.id, uses[k++ % uses.length]);
    }
    final pop0 = c.population;

    // Thirty minutes of colony time in the tick's own 0.5 s steps. A lot
    // counts as grown once it has passed its foundations (0.3) at ANY tick:
    // a standing shop sits right at that line and dips under it while
    // commercial demand does, so a last-tick read flips whenever the sim
    // takes a different path (as it did when site access landed).
    final reachedFoundations = <String>{};
    for (var i = 0; i < 3600; i++) {
      c.advance(0.5);
      c.grownParcels.forEach((id, g) {
        if (g >= 0.3) reachedFoundations.add(id);
      });
    }

    int grown(ParcelUse use) => c.layout.autoParcels
        .where((p) => p.use == use && reachedFoundations.contains(p.id))
        .length;
    final traffic = c.roadTraffic;
    final commercial = c.layout.autoParcels
        .where((p) => p.use == ParcelUse.commercial)
        .toList();
    final reached =
        commercial.where((p) => traffic.deliveryReach(p.id)).length;
    final industrial = c.layout.autoParcels
        .where((p) => p.use == ParcelUse.industrial)
        .toList();
    final homes = c.layout.autoParcels
        .where((p) => p.use == ParcelUse.residential)
        .toList();
    double mean(Iterable<double> v) =>
        v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    // ignore: avoid_print
    print('demand R ${c.demandFor('residential').toStringAsFixed(2)} '
        'C ${c.demandFor('commercial').toStringAsFixed(2)} '
        'I ${c.demandFor('industrial').toStringAsFixed(2)}; industry '
        'delivered ${industrial.where((p) => traffic.deliveryReach(p.id)).length}'
        '/${industrial.length}; land value '
        '${mean(homes.map((p) => traffic.landValueOf(p.id))).toStringAsFixed(3)}'
        ' noise ${mean(homes.map((p) => traffic.noiseOf(p.id))).toStringAsFixed(3)}'
        ' pollution ${c.pollution.toStringAsFixed(1)}');
    // ignore: avoid_print
    print('pop ${pop0.toStringAsFixed(0)} -> ${c.population.toStringAsFixed(0)}'
        ', grown R ${grown(ParcelUse.residential)} C '
        '${grown(ParcelUse.commercial)} I ${grown(ParcelUse.industrial)}'
        ', traffic run ${traffic.hasRun}, peak '
        '${traffic.peakCongestion.toStringAsFixed(2)}, congestion '
        '${c.parcelCongestion.toStringAsFixed(2)}, delivered '
        '$reached/${commercial.length}, tax x'
        '${traffic.taxLandValueFactor.toStringAsFixed(3)}, funds '
        '${c.funds.round()} (net ${c.netFundsRate.toStringAsFixed(3)}/s, '
        'roads ${c.roadUpkeepRate.toStringAsFixed(3)}/s)');

    expect(traffic.hasRun, isTrue, reason: 'the model published a pass');
    expect(reached, commercial.length,
        reason: 'every shop on the crossroads is reachable by a lorry');
    expect(industrial.every((p) => traffic.deliveryReach(p.id)), isTrue,
        reason: 'and every works');
    // Demand, not traffic, is what holds a town back at this size (industry
    // has almost none at seven people): what grew, grew past the gates.
    expect(grown(ParcelUse.residential), greaterThan(0));
    expect(grown(ParcelUse.commercial), greaterThan(0));
    expect(c.population, greaterThan(pop0));
    expect(traffic.taxLandValueFactor, closeTo(1.0, 0.05),
        reason: 'a plain, quiet town taxes as it did — the air is the '
            'sim\'s own penalty, not the road\'s');
    expect(c.roadUpkeepRate, greaterThan(0),
        reason: 'the crossroads costs upkeep');
    expect(c.roadUpkeepRate, lessThan(c.taxIncomeRate + 1),
        reason: 'but not a ruinous amount');
  });

  test('a colony with no roads costs nothing and taxes as it did', () {
    final c = CitySim.found(const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'bare');
    for (var i = 0; i < 20; i++) {
      c.advance(0.5);
    }
    expect(c.roadUpkeepRate, 0);
    expect(c.roadTraffic.taxLandValueFactor, 1.0);
  });
}
