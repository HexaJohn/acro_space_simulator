// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_textures.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// The render-FX side of a hard impact: the Impact event must carry the
/// BODY-FIXED contact point (the anchor terrain dust/debris FX co-rotate
/// around), it must survive the EventSnapshot wire flattening, and the
/// CPU-side albedo copy must sample the equirect map the way the terrain
/// shader does.
void main() {
  registerBakedDemsForTest();

  test('Impact event carries the body-fixed contact, matching the crater', () {
    final system = SampleWorld.realSystem();
    final moon = system.require(SampleWorld.moon);
    final ground =
        moon.terrainGroundRadius(Vector3(moon.radius, 0, 0), Epoch.zero);
    final vessels = InMemoryVesselRepository([
      Vessel(
        id: const VesselId('faller'),
        name: 'Faller',
        ownerId: 'p',
        state: StateVector(
          position: Vector3(ground + 5, 0, 0),
          velocity: Vector3(-300, 0, 0),
        ),
        dominantBody: SampleWorld.moon,
        stages: [
          Stage(index: 0, parts: [
            Part(
              id: const PartId('hull-0'),
              name: 'Hull',
              dryMass: 9000,
              crossSectionArea: 4,
            ),
          ]),
        ],
      ),
    ]);
    final edits = InMemoryTerrainEditsRepository();
    final bus = InMemoryEventBus();
    Impact? impact;
    bus.subscribe((e) {
      if (e is Impact) impact = e;
    });
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: bus,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      terrainEdits: edits,
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 12; i++) {
      tick.execute(clock);
    }

    expect(impact, isNotNull, reason: 'the fall must end in a raised Impact');
    expect(impact!.contactBF, isNot(Vector3.zero));
    // Same body-fixed point the crater brush was cut at — FX and hole agree.
    final crater = edits.forBody(SampleWorld.moon)!.all.single;
    expect(impact!.contactBF, crater.centreBF);

    // And the flattened event keeps it, through JSON and back.
    final snap = EventSnapshot.of(impact!);
    expect(snap.kind, 'Impact');
    expect(snap.px, impact!.contactBF.x);
    expect(snap.py, impact!.contactBF.y);
    expect(snap.pz, impact!.contactBF.z);
    final round = EventSnapshot.fromJson(snap.toJson());
    expect((round.px, round.py, round.pz), (snap.px, snap.py, snap.pz));
  });

  test('events without a site keep the compact wire shape', () {
    final j = EventSnapshot.of(ApoapsisReached(const VesselId('v'))).toJson();
    expect(j.containsKey('px'), isFalse);
    final round = EventSnapshot.fromJson(j);
    expect((round.px, round.py, round.pz), (0.0, 0.0, 0.0));
  });

  group('CpuAlbedo', () {
    // A 4x2 equirect map with a distinct color per texel column/row.
    // Row 0 = northern half, row 1 = southern; column 0 starts at lon -180.
    CpuAlbedo tiny() {
      final rgb = <int>[
        // north row: red, green, blue, white
        255, 0, 0, /**/ 0, 255, 0, /**/ 0, 0, 255, /**/ 255, 255, 255,
        // south row: 4 shades of grey
        10, 10, 10, /**/ 60, 60, 60, /**/ 120, 120, 120, /**/ 200, 200, 200,
      ];
      return CpuAlbedo.downsample(Uint8List.fromList(rgb), 0, 4, 2);
    }

    test('samples the shader\'s equirect mapping', () {
      final m = tiny();
      expect(m.width, 4);
      expect(m.height, 2);
      // lon 0 (+X), slightly north → u=0.5 → column 2, row 0 → blue.
      final north = m.sample(0.9, 0.0, 0.4);
      expect((north.r, north.g), (0.0, 0.0));
      expect(north.b, closeTo(1.0, 1e-9));
      // Same longitude, south → row 1, grey 120.
      final south = m.sample(0.9, 0.0, -0.4);
      expect(south.r, closeTo(120 / 255, 1e-9));
      // lon just past the -180 seam → column 0 → red.
      final seam = m.sample(-0.9, -0.01, 0.4);
      expect(seam.r, closeTo(1.0, 1e-9));
      expect(seam.g, 0.0);
    });

    test('box-downsample averages blocks', () {
      // 1024 wide forces a step of 2 against the 512 cap: each output texel
      // averages a 2x2 block.
      final w = 1024, h = 2;
      final rgb = List<int>.filled(w * h * 3, 0);
      // First 2x2 block: values 10,30 on row 0 and 50,110 on row 1 → mean 50.
      void set(int x, int y, int v) {
        final i = (y * w + x) * 3;
        rgb[i] = v;
        rgb[i + 1] = v;
        rgb[i + 2] = v;
      }

      set(0, 0, 10);
      set(1, 0, 30);
      set(0, 1, 50);
      set(1, 1, 110);
      final m = CpuAlbedo.downsample(Uint8List.fromList(rgb), 0, w, h);
      expect(m.width, 512);
      expect(m.height, 1);
      expect(m.rgb[0], 50);
    });
  });
}
