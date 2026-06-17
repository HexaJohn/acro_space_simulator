// Renders the TopDownPainter to PNG files for the release/promo materials.
// Run with: flutter test test/screenshots/capture_screenshots_test.dart
//
// Not a behavioural test — it drives a sample simulation forward, builds a
// snapshot, paints it to an off-screen canvas, and writes release/screenshots/*.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/top_down_painter.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _capture(TopDownSnapshot snap, String path,
    {Size size = const Size(1280, 720), double mpp = 25000}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  TopDownPainter(snap, view: OrthoCamera(CameraOrbit.top, mpp)).paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  test('capture: low-Kerbin-orbit overview', () async {
    final system = SampleWorld.buildSystem();
    final vessel = SampleWorld.buildVessel(altitude: 120000);
    final miner = SampleWorld.buildMiner();
    final freighter = SampleWorld.buildFreighter();
    final vessels = InMemoryVesselRepository([vessel, miner, freighter]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository([SampleWorld.buildColony()]),
      deposits: InMemoryDepositRepository([SampleWorld.buildDeposit()]),
      weather: const NullWeatherRepository(),
    );
    final clock = SimulationClock(warpFactor: 30, fixedStep: 1.0);
    for (var i = 0; i < 200; i++) {
      tick.execute(clock);
    }
    final presenter = TopDownSnapshotPresenter(
        vessels: vessels, universe: StaticUniverseRepository(system));
    final snap = presenter.present(
        focus: vessel.id,
        camera: OrthoCamera(CameraOrbit.top, 3500),
        epoch: clock.epoch,
        science: 42);
    await _capture(snap, 'release/screenshots/01_orbit_overview.png', mpp: 3500);
    expect(File('release/screenshots/01_orbit_overview.png').existsSync(), isTrue);
  });

  test('capture: real solar system (Earth + Moon, lit + atmosphere)', () async {
    final system = RealSolarSystem.build();
    final earth = system.require(const BodyId('earth'));
    final r = earth.radius + 600000;
    final v = SampleWorld.buildVessel(); // reuse a generic craft
    final orbiter = Vessel(
      id: const VesselId('iss'),
      name: 'Station',
      ownerId: 'p',
      state: v.state.copyWith(),
      dominantBody: const BodyId('earth'),
      stages: const [],
    );
    final vessels = InMemoryVesselRepository([orbiter]);
    final presenter = TopDownSnapshotPresenter(
        vessels: vessels, universe: StaticUniverseRepository(system));
    final snap = presenter.present(
        focus: orbiter.id,
        camera: OrthoCamera(CameraOrbit.top, 60000),
        epoch: Epoch.zero,
        science: 0);
    await _capture(snap, 'release/screenshots/02_real_earth.png', mpp: 60000);
    expect(r, greaterThan(0));
    expect(File('release/screenshots/02_real_earth.png').existsSync(), isTrue);
  });

  test('capture: vessel close-up with trajectory trail', () async {
    final system = SampleWorld.buildSystem();
    final vessel = SampleWorld.buildVessel(altitude: 90000);
    final vessels = InMemoryVesselRepository([vessel]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 60; i++) {
      tick.execute(clock);
    }
    final presenter = TopDownSnapshotPresenter(
        vessels: vessels, universe: StaticUniverseRepository(system));
    final snap = presenter.present(
        focus: vessel.id,
        camera: OrthoCamera(CameraOrbit.top, 1500),
        epoch: clock.epoch,
        science: 88);
    await _capture(snap, 'release/screenshots/03_vessel_closeup.png', mpp: 1500);
    expect(File('release/screenshots/03_vessel_closeup.png').existsSync(), isTrue);
  });
}
