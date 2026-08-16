// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = GameStateCodec();

  test('vessel state survives a JSON save/load round-trip', () {
    final v = SampleWorld.buildVessel(altitude: 123456);
    v.setThrottle(0.42);
    final vessels = InMemoryVesselRepository([v]);
    final colonies = InMemoryColonyRepository([SampleWorld.buildColony()]);
    final deposits = InMemoryDepositRepository([SampleWorld.buildDeposit()]);
    final clock = SimulationClock(tick: 99, warpFactor: 7);
    clock.epoch = clock.epoch + 5000;

    final json = jsonEncode(codec.encode(
      vessels: vessels,
      colonies: colonies,
      deposits: deposits,
      clock: clock,
    ));

    // Fresh empty repos + clock; restore into them.
    final v2 = InMemoryVesselRepository();
    final c2 = InMemoryColonyRepository([SampleWorld.buildColony()]);
    final d2 = InMemoryDepositRepository([SampleWorld.buildDeposit()]);
    final clock2 = SimulationClock();
    codec.decode(
      jsonDecode(json) as Map<String, dynamic>,
      vessels: v2,
      colonies: c2,
      deposits: d2,
      clock: clock2,
    );

    final restored = v2.byId(const VesselId('demo-1'))!;
    expect(restored.state.position.x, closeTo(v.state.position.x, 1e-6));
    expect(restored.state.velocity.y, closeTo(v.state.velocity.y, 1e-6));
    expect(restored.throttle, closeTo(0.42, 1e-9));
    expect(restored.dominantBody, v.dominantBody);
    expect(clock2.tick, 99);
    expect(clock2.warpFactor, 7);
    expect(clock2.epoch.seconds, closeTo(clock.epoch.seconds, 1e-6));
  });

  test('resource amounts persist', () {
    final v = SampleWorld.buildVessel();
    // Drain some fuel.
    final tank = v.allParts
        .expand((p) => p.resources)
        .firstWhere((r) => r.type == ResourceType.liquidFuel);
    tank.draw(150);
    final saved = tank.amount;

    final vessels = InMemoryVesselRepository([v]);
    final json = const GameStateCodec().encode(
      vessels: vessels,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );

    final v2 = InMemoryVesselRepository();
    const GameStateCodec().decode(
      json,
      vessels: v2,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    final restoredTank = v2
        .byId(const VesselId('demo-1'))!
        .allParts
        .expand((p) => p.resources)
        .firstWhere((r) => r.type == ResourceType.liquidFuel);
    expect(restoredTank.amount, closeTo(saved, 1e-6));
  });

  test('colony population and stockpile persist', () {
    final colony = SampleWorld.buildColony();
    colony.population = 137;
    final colonies = InMemoryColonyRepository([colony]);

    final json = const GameStateCodec().encode(
      vessels: InMemoryVesselRepository(),
      colonies: colonies,
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );

    final c2 = InMemoryColonyRepository([SampleWorld.buildColony()]);
    const GameStateCodec().decode(
      json,
      vessels: InMemoryVesselRepository(),
      colonies: c2,
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    expect(c2.byId('colony-1')!.population, 137);
  });

  test('an unknown part-equipped vessel restores its structure', () {
    final v = SampleWorld.buildVessel();
    expect(v.allParts.length, greaterThan(0));
    final vessels = InMemoryVesselRepository([v]);
    final json = const GameStateCodec().encode(
      vessels: vessels,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    final v2 = InMemoryVesselRepository();
    const GameStateCodec().decode(
      json,
      vessels: v2,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    final restored = v2.byId(const VesselId('demo-1'))!;
    expect(restored.allParts.map((p) => p.id), containsAll(v.allParts.map((p) => p.id)));
    // The restored part keeps its dry mass.
    expect(restored.mass, closeTo(v.mass, 1.0));
  });

  test('a catalog craft keeps the ids and poses its art is bound to', () {
    // Part.defId is what the renderer resolves a model by, and
    // rotationInVessel is how a radial part is aimed. Both are render-only, so
    // dropping them from a save leaves a craft that still flies perfectly and
    // silently comes back drawn as the wrong vehicle with its legs pointing
    // the wrong way — a save/load defect no flight-behaviour test can see.
    final catalog = PartCatalog.standard();
    final d = CraftDesign(name: 'Eagle')
      ..addPart(def: catalog.byId('eagle-command-pod')!, instanceId: 'cabin');
    for (var i = 1; i <= 4; i++) {
      d.attachPart(
        def: catalog.byId('eagle-rcs-block')!,
        instanceId: 'quad-$i',
        toInstanceId: 'cabin',
        parentNode: 'quad-$i',
        childNode: 'mount',
      );
    }
    final v = const VesselAssembler().assemble(
      id: 'lm-5',
      name: d.name,
      ownerId: 'crew',
      parts: d.parts,
      state: const StateVector(
          position: Vector3(1837400, 0, 0), velocity: Vector3(0, 1633, 0)),
      dominantBody: const BodyId('moon'),
    );
    // The quad ring starts at 45 degrees, so all four are turned — none of
    // them can ride through the save on the identity default.
    expect(v.allParts.where((p) => p.rotationInVessel.w != 1.0), hasLength(4));

    final v2 = InMemoryVesselRepository();
    const GameStateCodec().decode(
      const GameStateCodec().encode(
        vessels: InMemoryVesselRepository([v]),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        clock: SimulationClock(),
      ),
      vessels: v2,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );

    final restored = v2.byId(const VesselId('lm-5'))!;
    final before = {for (final p in v.allParts) p.id.value: p};
    for (final p in restored.allParts) {
      final was = before[p.id.value]!;
      expect(p.defId, was.defId, reason: p.id.value);
      expect(p.defId, isNotEmpty, reason: p.id.value);
      expect(p.rotationInVessel.w, closeTo(was.rotationInVessel.w, 1e-12));
      expect(p.rotationInVessel.z, closeTo(was.rotationInVessel.z, 1e-12));
    }
  });
}
