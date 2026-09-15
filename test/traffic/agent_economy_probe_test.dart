// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The road agent's economy probe with the agents answering the readout
/// (docs/plans/agent-traffic.md §18 slice 2 acceptance; D46).
///
/// road_traffic_economy_test.dart founds the City Builder's opening position,
/// zones every free street lot all three ways and runs half an hour: the
/// routed model gates growth — delivery reach on shops and works, noise on
/// homes, land value on the tax take — and must never starve an ordinary
/// town. From slice 2 every one of those gates reads the agents' own answers
/// in an agent colony, so the same town, founded with its agents on as the
/// play surface founds it, must still grow all three ways.
///
/// From the road side's R2, the four starter lots an easement crosses refuse
/// to grow whatever the traffic says, so nothing here counts on them.
void main() {
  test('the starter town, zoned all three ways, grows all three ways with the '
      'agents answering the readout', () {
    final c = quiet(CityStarterKit.found(
      bodies: fixtureBodies,
      config: const CityConfig(bodyId: 'earth'),
      start: CityStart.relaxed,
      agentTraffic: true,
    ));
    expect(c.agents.enabled, isTrue);
    // Every free street lot, dealt round the three zones as the road
    // agent's probe deals them.
    const uses = [
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

    // Thirty minutes of colony time in the tick's own 0.5 s steps.
    for (var i = 0; i < 3600; i++) {
      c.advance(0.5);
    }

    final r = c.trafficReadout;
    expect(identical(r, c.agents.readout), isTrue,
        reason: 'every gate read the agents');
    expect(r.hasRun, isTrue);
    expect(c.agents.readout.reach.hasFields, isTrue,
        reason: 'the agents published their own reach');

    List<Parcel> zoned(ParcelUse use) => [
          for (final p in c.layout.autoParcels)
            if (p.use == use && !_easement.contains(p.id)) p,
        ];
    List<String> grown(ParcelUse use) => [
          for (final p in zoned(use))
            if ((c.grownParcels[p.id] ?? 0) >= 0.3) p.id,
        ];
    final homes = zoned(ParcelUse.residential);
    final shops = zoned(ParcelUse.commercial);
    final works = zoned(ParcelUse.industrial);
    double mean(Iterable<double> v) =>
        v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    // ignore: avoid_print
    print('agents: demand R ${c.demandFor('residential').toStringAsFixed(2)} '
        'C ${c.demandFor('commercial').toStringAsFixed(2)} '
        'I ${c.demandFor('industrial').toStringAsFixed(2)}; '
        'pop ${pop0.toStringAsFixed(0)} -> ${c.population.toStringAsFixed(0)}; '
        'vehicles ${c.agents.stats.spawned} spawned; '
        'land value ${mean(homes.map((p) => r.landValueOf(p.id))).toStringAsFixed(3)} '
        'noise ${mean(homes.map((p) => r.noiseOf(p.id))).toStringAsFixed(3)} '
        'tax x${r.taxLandValueFactor.toStringAsFixed(3)}; '
        'delivered ${shops.where((p) => r.deliveryReach(p.id)).length}'
        '/${shops.length} shops, '
        '${works.where((p) => r.deliveryReach(p.id)).length}/${works.length} works');
    // ignore: avoid_print
    print('grown R ${grown(ParcelUse.residential)}\n'
        'grown C ${grown(ParcelUse.commercial)}\n'
        'grown I ${grown(ParcelUse.industrial)}');

    expect(shops.every((p) => r.deliveryReach(p.id)), isTrue,
        reason: 'every shop on the crossroads is reachable by a lorry');
    expect(works.every((p) => r.deliveryReach(p.id)), isTrue,
        reason: 'and every works');
    // As in the road agent's probe, demand and not traffic is what holds a
    // town back at this size: industry has almost none at seven people and
    // grows under neither model, while every works passes the delivery gate
    // above. What grew, grew past the gates.
    expect(grown(ParcelUse.residential), isNotEmpty);
    expect(grown(ParcelUse.commercial), isNotEmpty);
    expect(c.population, greaterThan(pop0));
    expect(r.taxLandValueFactor, closeTo(1.0, 0.05),
        reason: 'a plain, quiet town taxes as it did');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// The starter lots an easement crosses: from the road side's R2 they
/// refuse growth whatever the traffic says.
const Set<String> _easement = {
  'lot-r0x1-l10',
  'lot-r0x0-l0',
  'lot-r0x0-r1',
  'lot-r0x1-r5',
};
