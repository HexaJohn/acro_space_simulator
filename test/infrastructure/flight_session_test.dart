// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/infrastructure/flutter/flight_session.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The world behind the flight view is no longer trapped inside a State — so
/// it can be built and advanced with no widget in sight, which is most of the
/// reason for pulling it out.
void main() {
  FlightSession session({FlightCheats? cheats, void Function(DomainEvent)? on}) {
    final system = SampleWorld.realSystem();
    return FlightSession(
      system: system,
      fleet: [SampleWorld.buildVessel(altitude: 400000)],
      cheats: cheats ?? const FlightCheats(),
      onEvent: on,
    );
  }

  test('a session builds a whole world with no widget', () {
    final s = session();
    expect(s.vessels.all(), hasLength(1));
    expect(s.universe.current().all, isNotEmpty);
    expect(s.clock.warpFactor, 1);
  });

  test('stepping advances the clock and the craft', () {
    final s = session();
    final before = s.vessels.all().first.state.position;
    for (var i = 0; i < 20; i++) {
      s.step();
    }
    expect(s.vessels.all().first.state.position.x, isNot(before.x));
  });

  test('a colony registered with the session runs on its tick', () {
    final s = session();
    final colony = CitySim.found(
      const CityConfig(bodyId: 'earth'),
      bodies: s.universe.current().all.where((b) => !b.isStar).toList(),
      id: 'c1',
    );
    s.cities.add(colony);
    final day = colony.dayPhase;
    for (var i = 0; i < 50; i++) {
      s.step();
    }
    expect(colony.dayPhase, isNot(day),
        reason: 'the colony advances with the world, not with a screen');
  });

  test('changing a cheat rebuilds the tick without losing terrain edits', () {
    final s = session();
    final before = s.advance;
    // Whatever has already been dug must survive: the toggles rebuild the
    // tick, and a fresh edit store would erase every crater on the planet.
    final edits = s.terrainEdits;

    s.cheats = s.cheats.copyWith(disableCrater: true);

    expect(identical(s.advance, before), isFalse, reason: 'tick rebuilt');
    expect(identical(s.terrainEdits, edits), isTrue);
    expect(s.advance.disableCrater, isTrue);
  });

  test('domain events reach the subscriber given at construction', () {
    final seen = <DomainEvent>[];
    final s = session(on: seen.add);
    s.events.publish(SituationEntered(
        s.vessels.all().first.id, 'lowOrbit:earth'));
    expect(seen, hasLength(1));
  });
}
