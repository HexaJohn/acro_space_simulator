// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/impact_scaling.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_edits.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// The headless half of "impacting the Moon leaves the crater site stuck on
/// its loading placeholder forever" (the streaming half needs a GPU — see the
/// note at the end of clipped_chunk_retry_test.dart).
///
/// The renderer invalidates every in-flight mesh a NEW edit touches
/// (`_staleInFlight` in terrain_nodes.dart), so the site can only finish
/// streaming if the edit store SETTLES after an impact. These tests pin the
/// two ways it could fail to:
///
///  1. The sim keeps RECORDING craters — normal play runs with
///     `disableCraftDestruction: true` (flight_session.dart), so the craft
///     survives, settles, and sits in its own crater; if anything re-judges
///     that contact as a fresh hard impact, every tick adds a brush and every
///     brush re-invalidates the site's in-flight meshes.
///  2. The mesher cannot mesh the crater it was handed — an impact-sized
///     crater brush must widen the radial band the way a drill bore does, at
///     every level forced refinement drives chunks to, or the site cycles
///     through the clipped-retry path instead of streaming in.
Vessel _faller({required double speed, double mass = 9000}) {
  final body = SampleWorld.realSystem().require(SampleWorld.moon);
  final ground =
      body.terrainGroundRadius(Vector3(body.radius, 0, 0), Epoch.zero);
  return Vessel(
    id: const VesselId('faller'),
    name: 'Faller',
    ownerId: 'p',
    state: StateVector(
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
}) _build(Vessel v, {required bool disableCraftDestruction}) {
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
    ),
    vessels: vessels,
    edits: edits,
  );
}

void main() {
  registerBakedDemsForTest();

  test('a surviving craft digs ONE crater, however long it then sits there',
      () {
    // Normal play's configuration: the destruction cheat is on, the craft
    // bounces. The impact happens within the first few ticks; everything
    // after is the craft SITTING in its own crater. The edit count must not
    // move again — each extra brush would re-invalidate the crater site's
    // in-flight meshes in the renderer, and a brush per tick keeps it on the
    // loading grid forever.
    final w = _build(_faller(speed: 300), disableCraftDestruction: true);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 12; i++) {
      w.tick.execute(clock);
    }
    final afterImpact = w.edits.forBody(SampleWorld.moon)?.length ?? 0;
    expect(afterImpact, 1, reason: 'the hard impact digs exactly one crater');
    expect(w.vessels.byId(const VesselId('faller'))!.landed, isTrue);

    // Ten minutes of sim time in the crater.
    for (var i = 0; i < 1200; i++) {
      w.tick.execute(clock);
    }
    expect(w.edits.forBody(SampleWorld.moon)!.length, afterImpact,
        reason: 'a settled craft must not keep re-impacting its own crater');
    expect(w.vessels.byId(const VesselId('faller'))!.landed, isTrue,
        reason: 'nothing should have un-landed it');
  });

  test('a destroyed craft digs ONE crater and the store stays settled', () {
    final w = _build(_faller(speed: 300), disableCraftDestruction: false);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 600; i++) {
      w.tick.execute(clock);
    }
    expect(w.edits.forBody(SampleWorld.moon)!.length, 1);
  });

  test('an impact-sized crater meshes clean at forced-refinement depths', () {
    // The renderer half of the trap: forced refinement drives the crater's
    // chunks far deeper than screen-space LOD ever selects, and each one is
    // meshed against the edited field. The crater brush must widen the
    // radial band the way clipped_chunk_retry_test.dart pins for drill
    // bores — clipped or empty here means the site cycles the retry path
    // instead of streaming in.
    final w = _build(_faller(speed: 300), disableCraftDestruction: true);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 12; i++) {
      w.tick.execute(clock);
    }
    final recorded = w.edits.forBody(SampleWorld.moon)!.all.single;
    expect(recorded.kind, TerrainBrushKind.crater);

    final moon = SampleWorld.realSystem().require(SampleWorld.moon);
    final edits = TerrainEdits()..add(recorded);
    final field = moon.terrainFieldWith(edits)!;
    final dir = recorded.centreBF.normalized;
    for (final level in [10, 12, 14, 16]) {
      final key = chunkAt(dir, level);
      final cell = meshTerrainCell(field, key, resolution: 24, skirtVoxels: 1);
      expect(cell.clipped, isFalse,
          reason: 'level $level: the band missed the surface the crater '
              '(r=${recorded.radiusM.toStringAsFixed(1)} m, '
              'depth=${recorded.depthM.toStringAsFixed(1)} m) moved');
      expect(cell.isEmpty, isFalse,
          reason: 'level $level lost its ground to the crater');
    }
  });

  test('the LOD tree settles under a crater\'s forced refinement', () {
    // The remaining headless-reachable failure mode: if the refined island
    // OSCILLATES — split one frame, merged back the next — `wanted` flickers,
    // every arriving mesh is refused by `admitsArrival` (its key is no longer
    // wanted the frame it lands), and the site cycles submit → arrive →
    // reject forever. The converges/hysteresis tests in terrain_lod_test.dart
    // pin this WITHOUT refine targets; a crater exercises the pinned() +
    // _applyRefinements + balance interaction they skip.
    final w = _build(_faller(speed: 300), disableCraftDestruction: true);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 12; i++) {
      w.tick.execute(clock);
    }
    final recorded = w.edits.forBody(SampleWorld.moon)!.all.single;
    final moon = SampleWorld.realSystem().require(SampleWorld.moon);

    // The renderer's own recipe (terrain_nodes.dart): resolution 24 boosted
    // x4, 8 voxels across a brush, targets clamped by the tree.
    final tree = TerrainLodTree(splitPx: 220);
    final targets = mergedRefinementsFor(
      [recorded],
      moon.radius,
      24 * 4,
      voxelsAcrossBrush: 8,
      maxLevel: tree.maxRefineLevel,
    );
    expect(targets, isNotEmpty,
        reason: 'a recorded crater must demand refinement');

    // A camera hovering ~100 m over the crater (the live repro's range).
    final focus = recorded.centreBF.normalized;
    double apparentPx(ChunkKey k) {
      final cos = k.centreDirection.dot(focus).clamp(-1.0, 1.0);
      final ang = math.acos(cos);
      final size = (math.pi / 2) / (1 << k.level);
      return 600 * size / (1 + ang * 4);
    }

    final first = tree.update(apparentPx, refine: targets);
    for (var frame = 1; frame <= 30; frame++) {
      final now = tree.update(apparentPx, refine: targets);
      expect(now, first,
          reason: 'frame $frame: the leaf set moved under a STILL camera — '
              'wanted flickers, and every arrival lands unwanted');
    }
    // And the island actually reaches the demanded depth over the crater.
    final deepest = targets
        .map((t) => t.level.clamp(0, tree.maxRefineLevel))
        .reduce(math.max);
    final over = first.where((k) => k.contains(focus));
    expect(over.map((k) => k.level).reduce(math.max), deepest,
        reason: 'refinement never carried the crater to its forced level');
  });

  test('craterForImpact sizes a real hole for a 9 t craft at 300 m/s', () {
    // Sanity anchor for the scenario above: the impact the tests dig is the
    // kind a player actually produces, not a degenerate pebble the "too
    // small to record" gate would drop.
    final moon = SampleWorld.realSystem().require(SampleWorld.moon);
    final c = craterForImpact(
      kineticEnergyJ: kineticEnergy(9000, 300),
      surfaceGravityMs2: moon.mu / (moon.radius * moon.radius),
      targetDensityKgM3: 1500,
    );
    expect(c, isNotNull);
    expect(c!.rimRadiusM, greaterThan(1));
  });
}
