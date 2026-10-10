// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_atmosphere_repository.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the tower family's state and readouts do when a frame-budgeted
/// colony — every player colony — holds its ticks and replays them after the
/// host loop, so its flows land a tick late and all at once.
///
/// Read off whichever flows landed in a step, the Retention Arrays' hold
/// dropped on every tick after a frame's first wherever an inline colony
/// shared the world, and the atmosphere panel's tower and colony lines
/// alternated between twice the real rate and nothing. These pin that a
/// multi-tick frame reads like a one-tick one.
void main() {
  CityBuildingSpec spec(String type) =>
      kUtilCatalog.firstWhere((s) => s.type == type);
  const tuning = TerraformTuning();

  /// A powered, staffed colony on [bodyId] running [types] at full throttle.
  CitySim towered(List<CelestialBody> bodies, String bodyId, String id,
      List<String> types) {
    final city = CitySim.found(
      CityConfig(bodyId: bodyId, gridSize: 30),
      bodies: bodies,
      id: id,
    )..infiniteRobotics = true;
    final g = city.grid;
    final h = city.hubKey;
    for (var x = -5; x <= 12; x++) {
      city.addRoad(h - g + x);
    }
    city.placeUtil(h - 1, spec('fusion'));
    city.placeUtil(h - 2, spec('fusion'));
    city.placeUtil(h - 3, spec('datacenter'));
    city.placeUtil(h - 4, spec('datacenter'));
    for (var i = 0; i < types.length; i++) {
      city.placeUtil(h + 1 + 3 * i, spec(types[i]));
    }
    city.population = 2000;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();
    return city;
  }

  /// [city], its ticks held and replayed as SimulationView's are.
  CitySim held(CitySim city) => city
    ..agents.enabled = true
    ..agents.frameBudgeted = true;

  group('Retention Arrays hold through a frame of held ticks', () {
    /// The Moon's suppression after every tick of [frames] frames of
    /// [ticks] ticks: a held colony running an array (and two towers to
    /// give the sky something to hold), optionally beside an inline
    /// colony running none.
    List<double> suppressions(
        {required int ticks, required bool neighbour, int frames = 6}) {
      final w = _World((bodies) => [
            held(towered(bodies, 'moon', 'held', [
              TerraformTowers.oxygenator,
              TerraformTowers.oxygenator,
              TerraformTowers.retentionArray,
            ])),
            if (neighbour)
              CitySim.found(const CityConfig(bodyId: 'moon', gridSize: 12),
                  bodies: bodies, id: 'inline'),
          ]);
      final out = <double>[];
      for (var f = 0; f < frames; f++) {
        w.frame(ticks: ticks, after: () => out.add(w.moon.escapeSuppression));
      }
      expect(w.cities.byId('held')!.towerRuns.retention, greaterThan(0),
          reason: 'the array must run for its hold to be tested');
      return out;
    }

    for (final ticks in [2, 4]) {
      test('$ticks ticks a frame, an inline neighbour running none', () {
        final alone = suppressions(ticks: ticks, neighbour: false);
        final shared = suppressions(ticks: ticks, neighbour: true);
        // From the held colony's first report on, every tick is held at its
        // array: the neighbour's empty reports between replays take nothing
        // from it.
        final first = alone.indexWhere((s) => s > 0);
        expect(first, greaterThanOrEqualTo(0));
        final s = alone[first];
        expect(s, closeTo(tuning.suppressionFor(1), 1e-9));
        expect(alone.sublist(first), everyElement(s));
        expect(shared.sublist(first), everyElement(closeTo(s, 1e-12)));
      });
    }

    test('a deleted colony\'s arrays stop holding the sky', () {
      final w = _World((bodies) => [
            held(towered(bodies, 'moon', 'held', [
              TerraformTowers.oxygenator,
              TerraformTowers.retentionArray,
            ])),
          ]);
      w.frame(ticks: 2);
      w.frame(ticks: 2);
      expect(w.moon.escapeSuppression, greaterThan(0));
      w.cities.remove('held');
      w.tick.execute(w.clock);
      expect(w.moon.escapeSuppression, 0);
      expect(w.moon.arraysByColony, isEmpty);
    });

    test('the arrays each colony runs are saved', () {
      final w = _World((bodies) => [
            held(towered(bodies, 'moon', 'held', [
              TerraformTowers.oxygenator,
              TerraformTowers.retentionArray,
            ])),
          ]);
      w.frame(ticks: 2);
      w.frame(ticks: 2);
      final json = w.moon.toJson();
      final back = PlanetAtmosphere.seed(
          RealSolarSystem.build().require(const BodyId('moon')))!
        ..restore(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(back.arraysByColony, w.moon.arraysByColony);
      expect(back.escapeSuppression, w.moon.escapeSuppression);
    });
  });

  group("the panel's ledger reads a held colony as an inline one", () {
    /// The Mars ledger's tower O2 rate and colony ids as the repaint reads
    /// them — at the end of each frame — over [frames] frames of [ticks].
    List<(double, List<String>)> ledgers(
        {required int ticks, required bool budgeted, int frames = 6}) {
      final w = _World((bodies) {
        final c = towered(bodies, 'mars', 'c', [
          TerraformTowers.oxygenator,
          TerraformTowers.oxygenator,
        ]);
        return [budgeted ? held(c) : c];
      });
      final out = <(double, List<String>)>[];
      for (var f = 0; f < frames; f++) {
        w.frame(ticks: ticks);
        final l = w.mars.ledger;
        out.add((
          l?.rate(GasProcess.oxygenator, AtmosphereGas.oxygen.name) ?? 0,
          l?.colonies.keys.toList() ?? const <String>[],
        ));
      }
      return out;
    }

    for (final ticks in [1, 2, 4]) {
      test('$ticks ticks a frame', () {
        final inline = ledgers(ticks: ticks, budgeted: false);
        final late = ledgers(ticks: ticks, budgeted: true);
        final nominal = inline.last.$1;
        expect(nominal, closeTo(2 * tuning.oxygenatorRate, 1e-6 * nominal));
        // Past the first frame (whose replays have not landed yet), every
        // frame's ledger has the towers at their real rate, credited to the
        // colony running them.
        for (final (rate, colonies) in late.skip(1)) {
          expect(rate, closeTo(nominal, 1e-6 * nominal));
          expect(colonies, ['c']);
        }
      });
    }

    test("the temperature trend is the window's, not the empty tick's", () {
      List<double> trends({required bool budgeted}) {
        final w = _World((bodies) {
          final c = towered(bodies, 'mars', 'c', [
            TerraformTowers.greenhouseFactory,
            TerraformTowers.greenhouseFactory,
          ]);
          return [budgeted ? held(c) : c];
        });
        return [
          for (var f = 0; f < 40; f++)
            (w..frame(ticks: 2)).mars.ledger?.temperatureRateKPerS ?? 0,
        ];
      }

      final inline = trends(budgeted: false);
      final late = trends(budgeted: true);
      // Once the agent's first, steepest warming is past, the held
      // colony's world warms at the inline one's rate (a tick behind it),
      // not at twice it and then not at all.
      for (var f = 30; f < 40; f++) {
        expect(inline[f], greaterThan(0));
        expect(late[f], closeTo(inline[f], 0.05 * inline[f]),
            reason: 'frame $f');
      }
    });
  });

  test('a loaded colony has its air handle before the first tick', () {
    final a = _World((bodies) => [
          towered(bodies, 'mars', 'c', [TerraformTowers.oxygenator]),
        ]);
    a.frame(ticks: 2);
    final json = a.save();
    final b = _World((bodies) => [
          CitySim.found(const CityConfig(bodyId: 'mars', gridSize: 12),
              bodies: bodies, id: 'c'),
        ]);
    b.load(json);
    final city = b.cities.all().single;
    expect(city.planetAir, isNotNull,
        reason: 'a save loaded paused runs no tick to set it');
    expect(identical(city.planetAir, b.mars), isTrue);
  });
}

const _codec = GameStateCodec();

/// One world: the repositories a session owns, and a tick built over them.
class _World {
  _World(List<CitySim> Function(List<CelestialBody> bodies) colonies) {
    final system = RealSolarSystem.build();
    universe = StaticUniverseRepository(system);
    air = InMemoryAtmosphereRepository.seeded(system);
    bodies = system.all.where((b) => !b.isStar).toList();
    cities = InMemoryCityRepository(colonies(bodies));
    tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository(),
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: cities,
      atmosphere: air,
    );
  }

  late final StaticUniverseRepository universe;
  late final InMemoryAtmosphereRepository air;
  late final List<CelestialBody> bodies;
  late final InMemoryCityRepository cities;
  late final AdvanceSimulationTick tick;
  final SimulationClock clock = SimulationClock(warpFactor: 1, fixedStep: 3600);

  PlanetAtmosphere get moon => air.forBody('moon')!;
  PlanetAtmosphere get mars => air.forBody('mars')!;

  /// [ticks] host ticks ([after] each), then the frame's replays as
  /// SimulationView runs them, worked off until no backlog is left.
  void frame({required int ticks, void Function()? after}) {
    for (var i = 0; i < ticks; i++) {
      tick.execute(clock);
      after?.call();
    }
    for (final c in cities.all()) {
      for (var f = 0; f < 64 && c.agents.heldTicks > 0; f++) {
        c.agents.endFrame();
      }
      expect(c.agents.heldTicks, 0, reason: 'the backlog is worked off');
    }
  }

  Map<String, dynamic> save() {
    for (final c in cities.all()) {
      c.agents.flushHeld();
    }
    return jsonDecode(jsonEncode(_codec.encode(
      vessels: InMemoryVesselRepository(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: clock,
      cities: cities,
      atmospheres: air,
    ))) as Map<String, dynamic>;
  }

  void load(Map<String, dynamic> json) {
    _codec.decode(
      json,
      vessels: InMemoryVesselRepository(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: clock,
      cities: cities,
      bodies: bodies,
      atmospheres: air,
      universe: universe,
    );
  }
}
