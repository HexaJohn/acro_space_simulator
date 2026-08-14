// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// A craft with real mass dropped straight down at the Moon (a terrain body).
///
/// Spawned just above the LOCAL ground, not the datum. The Moon's relief runs
/// to +-3 km, so `radius + 10` can be a three-kilometre drop — enough for
/// gravity alone to turn a nominally gentle descent into a lethal one and make
/// the impact speed unrelated to the [speed] asked for here.
Vessel _faller({required double speed, double mass = 9000}) {
  final body = SampleWorld.realSystem().require(SampleWorld.moon);
  final ground =
      body.terrainGroundRadius(Vector3(body.radius, 0, 0), Epoch.zero);
  return Vessel(
    id: const VesselId('faller'),
    name: 'Faller',
    ownerId: 'p',
    state: StateVector(
      // PURELY radial, deliberately. The Moon is airless, so this propagates on
      // Kepler rails rather than by integration — the exact path that used to
      // convert a rectilinear fall into a circular orbit and leave the craft
      // hanging at its release altitude forever. If that regresses, every test
      // below fails.
      position: Vector3(ground + 5, 0, 0),
      velocity: Vector3(-speed, 0, 0),
    ),
    dominantBody: SampleWorld.moon,
    stages: [
      Stage(index: 0, parts: [
        Part(
          id: const PartId('hull-0'),
          name: 'Hull',
          dryMass: mass,
          crossSectionArea: 4,
        ),
      ]),
    ],
  );
}

({
  AdvanceSimulationTick tick,
  InMemoryVesselRepository vessels,
  InMemoryTerrainEditsRepository edits,
  CelestialBody moon,
}) _build(Vessel v,
    {bool disableCraftDestruction = false, bool disableCrater = false}) {
  final system = SampleWorld.realSystem();
  final vessels = InMemoryVesselRepository([v]);
  final edits = InMemoryTerrainEditsRepository();
  return (
    tick: AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      terrainEdits: edits,
      disableCraftDestruction: disableCraftDestruction,
      disableCrater: disableCrater,
    ),
    vessels: vessels,
    edits: edits,
    moon: system.require(SampleWorld.moon),
  );
}

/// Advance [steps] ticks. Pass a [clock] to continue an existing timeline — a
/// fresh clock restarts at tick 0, which would make two impacts look
/// simultaneous.
SimulationClock _run(
  AdvanceSimulationTick tick, {
  int steps = 12,
  double dt = 0.5,
  SimulationClock? clock,
}) {
  final c = clock ?? SimulationClock(warpFactor: 1, fixedStep: dt);
  for (var i = 0; i < steps; i++) {
    tick.execute(c);
  }
  return c;
}

void main() {
  registerBakedDemsForTest(); // moon terrain now reads the baked DEM

  test('a hard impact digs a crater into the body', () {
    final w = _build(_faller(speed: 300));
    expect(w.edits.forBody(SampleWorld.moon), isNull, reason: 'starts pristine');

    _run(w.tick);

    expect(w.vessels.byId(const VesselId('faller')), isNull, reason: 'destroyed');
    final edits = w.edits.forBody(SampleWorld.moon);
    expect(edits, isNotNull);
    expect(edits!.length, 1);
    expect(edits.all.single.kind, TerrainBrushKind.crater);
  });

  test('the crater actually lowers the collision surface', () {
    final w = _build(_faller(speed: 300));
    _run(w.tick);

    final edits = w.edits.forBody(SampleWorld.moon)!;
    final crater = edits.all.single;
    // Probe along the crater's OWN body-fixed radial. The body rotates while
    // the craft falls, so the inertial ray it came down is not the body-fixed
    // ray the crater ended up on.
    final c = crater.centreBF;
    final before = w.moon.terrainField!.groundRadiusAt(c.x, c.y, c.z);
    final after = w.moon.terrainFieldWith(edits)!.groundRadiusAt(c.x, c.y, c.z);

    expect(after, lessThan(before), reason: 'the ground should have sunk');
    expect(before - after, closeTo(crater.depthM, crater.depthM * 0.1));
  });

  test('a gentle landing leaves the ground untouched', () {
    final w = _build(_faller(speed: 2));
    _run(w.tick, steps: 20, dt: 1.0);
    expect(w.vessels.byId(const VesselId('faller'))!.landed, isTrue);
    expect(w.edits.forBody(SampleWorld.moon), isNull);
  });

  test('destruction cheat: the craft survives but the crater is still dug', () {
    // The cheats are ORTHOGONAL: one switch for the craft's fate, one for the
    // ground's. A destruction-cheated hard impact keeps deforming terrain.
    final w = _build(_faller(speed: 300), disableCraftDestruction: true);
    final clock = _run(w.tick);
    final survivor = w.vessels.byId(const VesselId('faller'));
    expect(survivor, isNotNull, reason: 'destruction was cheated off');
    expect(survivor!.landed, isTrue);
    final edits = w.edits.forBody(SampleWorld.moon);
    expect(edits, isNotNull, reason: 'cratering is independent of destruction');
    // And the survivor settled onto the DEFORMED ground, not the surface the
    // impact just removed from under it. Probed through the EPOCH-AWARE
    // helper: the landed craft co-rotates with the body, so its inertial
    // position must be rotated into the body frame before sampling the field
    // or the probe walks off the crater as the body spins.
    final ground = w.moon.terrainGroundRadius(
        survivor.state.position, clock.epoch,
        edits: edits);
    expect((survivor.state.position.length - ground).abs(), lessThan(1.0),
        reason: 'survivor floats over its own crater');
  });

  test('the crater cheat keeps the destruction but not the deformation', () {
    final w = _build(_faller(speed: 300), disableCrater: true);
    _run(w.tick);
    expect(w.vessels.byId(const VesselId('faller')), isNull,
        reason: 'disableCrater must not shield the craft');
    expect(w.edits.forBody(SampleWorld.moon), isNull,
        reason: 'the deformation was cheated off');
  });

  test('both cheats: the craft survives and the ground stays pristine', () {
    final w = _build(_faller(speed: 300),
        disableCraftDestruction: true, disableCrater: true);
    _run(w.tick);
    expect(w.vessels.byId(const VesselId('faller')), isNotNull);
    expect(w.edits.forBody(SampleWorld.moon), isNull);
  });

  test('a tiny impactor is not worth a permanent edit', () {
    // Comfortably past every safe-touchdown threshold (so it is destroyed) but
    // far too little energy to leave anything a chunk could mesh.
    final w = _build(_faller(speed: 90, mass: 2));
    _run(w.tick);
    expect(w.vessels.byId(const VesselId('faller')), isNull, reason: 'destroyed');
    expect(w.edits.forBody(SampleWorld.moon), isNull);
  });

  test('successive impacts accumulate in tick order', () {
    final w = _build(_faller(speed: 300));
    final clock = _run(w.tick);
    // A second craft into the same ground, on the SAME timeline.
    w.vessels.save(_faller(speed: 420));
    _run(w.tick, clock: clock);

    final edits = w.edits.forBody(SampleWorld.moon)!;
    expect(edits.length, 2);
    expect(edits.all[0].tick, lessThan(edits.all[1].tick));
    // Faster craft, bigger hole.
    expect(edits.all[1].radiusM, greaterThan(edits.all[0].radiusM));
  });

  group('replication', () {
    test('edits ride the snapshot and round-trip through JSON', () {
      final w = _build(_faller(speed: 300));
      _run(w.tick);
      final snap = WorldSnapshot.capture(
        7,
        w.vessels,
        system: SampleWorld.realSystem(),
        terrainEdits: w.edits,
      );
      expect(snap.terrainEdits, hasLength(1));
      expect(snap.terrainEdits.single.body, 'moon');

      final round = WorldSnapshot.fromJson(snap.toJson());
      expect(round.terrainEdits, hasLength(1));
      final a = w.edits.forBody(SampleWorld.moon)!.all.single;
      final b = round.terrainEdits.single.toBrush();
      expect(b.kind, a.kind);
      expect(b.radiusM, a.radiusM);
      expect(b.depthM, a.depthM);
      expect(b.rimHeightM, a.rimHeightM);
      expect(b.centreBF, a.centreBF);
      expect(b.tick, a.tick);
    });

    test('editsForBody rebuilds a usable store, and only for that body', () {
      final w = _build(_faller(speed: 300));
      _run(w.tick);
      final snap = WorldSnapshot.capture(
        7,
        w.vessels,
        system: SampleWorld.realSystem(),
        terrainEdits: w.edits,
      );
      final rebuilt = snap.editsForBody('moon');
      expect(rebuilt, isNotNull);
      expect(rebuilt!.length, 1);
      expect(snap.editsForBody('earth'), isNull);

      // The rebuilt store must reproduce the server's collision surface — this
      // is the whole point of replicating edits rather than re-deriving them.
      final probe = Vector3(w.moon.radius + 10, 0, 0);
      expect(
        w.moon.terrainGroundRadius(probe, Epoch.zero, edits: rebuilt),
        w.moon.terrainGroundRadius(probe, Epoch.zero,
            edits: w.edits.forBody(SampleWorld.moon)),
      );
    });

    test('deformation changes the determinism fingerprint', () {
      final w = _build(_faller(speed: 300));
      _run(w.tick);
      final system = SampleWorld.realSystem();
      final withEdits = WorldSnapshot.capture(7, w.vessels,
          system: system, terrainEdits: w.edits);
      final without = WorldSnapshot.capture(7, w.vessels, system: system);
      // A client that missed the crater would otherwise reconcile silently onto
      // ground the server does not have.
      expect(withEdits.fingerprint, isNot(without.fingerprint));
      expect(withEdits.fingerprint,
          WorldSnapshot.fromJson(withEdits.toJson()).fingerprint);
    });
  });
}
