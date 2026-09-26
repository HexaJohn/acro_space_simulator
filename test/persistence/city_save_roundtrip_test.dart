// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A founded colony survives save and load. Before this, loading a game
/// silently discarded every city in it.
void main() {
  List<dynamic> bodies() =>
      RealSolarSystem.build().all.where((b) => !b.isStar).toList();

  CitySim buildCity() {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 20, latitude: 12, longitude: 34),
      bodies: bodies().cast(),
      id: 'redtown',
      name: 'Redtown',
    );
    city.layout.settings =
        city.layout.settings.copyWith(frontageM: 30, depthM: 40);
    city.layout.addRoad(const RoadSpline(
        id: 'road-0',
        roadClass: RoadClass.avenue,
        controls: [Vec2(0, -200), Vec2(30, 0), Vec2(0, 200)]));
    // Zone a lot, grow another, hand-place a third, and one manual megalot.
    final lots = city.layout.autoParcels;
    city.layout.setUse(lots[0].id, ParcelUse.residential);
    city.grownParcels[lots[1].id] = 2.4; // a medium-density block
    city.layout.setUse(lots[1].id, ParcelUse.residential);
    city.parcelBuildings[lots[2].id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
    city.layout.addManualParcel(const [
      Vec2(600, 600),
      Vec2(1400, 600),
      Vec2(1400, 1400),
      Vec2(600, 1400),
    ], use: ParcelUse.utility);
    city.stock['ore'] = 321;
    city.population = 87;
    city.funds = 1234;
    return city;
  }

  test('a colony round-trips through the save intact', () {
    const codec = GameStateCodec();
    final city = buildCity();
    final lots = city.layout.autoParcels;
    final grownId = lots[1].id;
    final portId = lots[2].id;

    final saved = jsonEncode(codec.encode(
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: InMemoryCityRepository([city]),
    ));

    final restored = InMemoryCityRepository();
    codec.decode(
      jsonDecode(saved) as Map<String, dynamic>,
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: restored,
      bodies: bodies().cast(),
    );

    final back = restored.byId('redtown')!;
    expect(back.name, 'Redtown');
    expect(back.body.id.value, 'mars');
    expect(back.cityLat, 12);
    expect(back.population, 87);
    expect(back.funds, 1234);
    expect(back.stock['ore'], 321);

    // The layout came back: same roads, same settings, same lot count.
    expect(back.layout.roads.map((r) => r.id), contains('road-0'));
    expect(back.layout.settings.frontageM, 30);
    expect(back.layout.autoParcels.length, lots.length);
    expect(back.layout.manualParcels, hasLength(1));

    // The KEYS survived: the deterministic lot ids mean the grown block and
    // the spaceport landed back on the same ground they left.
    expect(back.grownParcels[grownId], 2.4);
    expect(back.parcelBuildings[portId]!.label, 'Spaceport');
    expect(back.parcelGrownSpec(grownId, ParcelUse.residential)!.type, 'r-med');
    expect(back.hasSpaceport, isTrue);

    // Zoning on auto lots came back too.
    final zoned = back.layout.autoParcels
        .firstWhere((p) => p.id == lots[0].id);
    expect(zoned.use, ParcelUse.residential);
  });

  test('loading replaces the city list, never merges into it', () {
    const codec = GameStateCodec();
    final saved = jsonEncode(codec.encode(
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: InMemoryCityRepository([buildCity()]),
    ));

    // A live repo holding a DIFFERENT colony that is not in the save.
    final live = InMemoryCityRepository([
      CitySim.found(
        const CityConfig(bodyId: 'earth'),
        bodies: bodies().cast(),
        id: 'doomed',
      ),
    ]);
    codec.decode(
      jsonDecode(saved) as Map<String, dynamic>,
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: live,
      bodies: bodies().cast(),
    );

    expect(live.byId('doomed'), isNull,
        reason: 'half-merging a save into a live world is how a city ends up '
            'with old roads and new buildings');
    expect(live.byId('redtown'), isNotNull);
  });

  test('a colony with agents keeps them across a save and a load', () {
    // Slice 1 saves only the flag (docs/plans/agent-traffic.md §14.1):
    // vehicles in flight re-derive, but a City Builder game must not come
    // back from a load with its traffic switched off.
    const codec = GameStateCodec();
    final agentville = CityStarterKit.found(
      bodies: bodies().cast(),
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
      id: 'agentville',
      agentTraffic: true,
    )..advance(0.5);
    final saved = jsonDecode(jsonEncode(codec.encode(
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: InMemoryCityRepository([agentville, buildCity()]),
    ))) as Map<String, dynamic>;
    Map<String, dynamic> cityJson(String id) => (saved['cities'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((c) => c['id'] == id);
    // The flag, and from slice 3 the population's own state beside it: the
    // ledger's budgets and the realisation's stream, which a colony whose
    // agents own its population always has (docs/plans/agent-traffic.md
    // §14.1, §6.2). The parked cars and the citizens themselves are there
    // when it has any; one tick of a bare starter kit has neither.
    final block = cityJson('agentville')['agents']! as Map<String, dynamic>;
    expect(block['v'], 2);
    expect(block['enabled'], isTrue);
    expect(block.containsKey('ledger'), isTrue,
        reason: 'the budgets ride the save, so a load does not reconcile a '
            'second town on top of the one it restored');
    expect(cityJson('redtown').containsKey('agents'), isFalse,
        reason: 'a colony without agents saves exactly as it always has');

    final restored = InMemoryCityRepository();
    codec.decode(
      saved,
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: restored,
      bodies: bodies().cast(),
    );
    final back = restored.byId('agentville')!;
    expect(back.agents.enabled, isTrue);
    expect(identical(back.trafficReadout, back.agents.readout), isTrue);
    expect(back.agents.laneGraph, isNull,
        reason: 'the agents re-derive on their first advance, not at load');
    back.advance(0.5);
    expect(back.agents.laneGraph, isNotNull);
    expect(restored.byId('redtown')!.agents.enabled, isFalse);
  });

  test('a load that has not settled still saves its citizens', () {
    // §14.1 as built, and slice 3's half of it. `CityAgents.restore` only
    // STORES the block — lot ids and site plans exist from the first advance
    // on — so a save taken in that window is written out of what is held.
    // Before slice 3 that was the cars; it is now the people, the budgets
    // and the realisation's stream as well, and losing any of them would
    // turn a save-load-save into a colony with fewer citizens than the one
    // it was loaded from.
    final block = <String, Object?>{
      'v': 2,
      'enabled': true,
      'sites': ['lot-a', 'lot-b'],
      'cars': [
        [1, 0, 0, 0, 77, 0, 3],
      ],
      'cit': {
        'home': [0, 1, -1],
        'work': [1, -1, -1],
        'state': [0, 2, 3],
        'wakeInUs': [1500000, -200000, 0],
        'flags': [4, 0, 0],
      },
      'ledger': {'mig': 0.4, 'death': 0.7, 'ext': 0.0, 'last': 203.7},
      'pop': {
        'rng': [1, 2, 3, 4],
        'arr': 203,
        'dep': 1,
        'dead': 2,
        'adopt': 1,
        'legacy': 1,
      },
    };
    final city = CityStarterKit.found(
      bodies: bodies().cast(),
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
      id: 'holdtown',
      agentTraffic: true,
    );
    city.agents.restore(jsonDecode(jsonEncode(block)));
    expect(city.agents.enabled, isTrue);
    expect(jsonEncode(city.agents.toJson()), jsonEncode(block),
        reason: 'the block that was loaded is the block that is saved, down '
            'to the byte, while the colony has not put it down yet');
  });

  test('an old save with no cities key loads without complaint', () {
    const codec = GameStateCodec();
    final saved = jsonEncode(codec.encode(
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      // no cities passed: the key is absent, as in every pre-existing save
    ));
    final live = InMemoryCityRepository([buildCity()]);
    codec.decode(
      jsonDecode(saved) as Map<String, dynamic>,
      vessels: InMemoryVesselRepository(const []),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.02),
      cities: live,
      bodies: bodies().cast(),
    );
    // No key -> no opinion: the live cities are left alone.
    expect(live.byId('redtown'), isNotNull);
  });
}
