// Diagnostic: the user's scenario (Earth orbiter at 3000 km, the in-app default)
// under time warp 50 for ~15 s, LOOK-AT once at t0 then let the orbit carry the
// planet toward the disk edge, viewed through the chase cam with the real Earth
// texture. Writes release/screenshots/scenario_*.png.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/texture_cache.dart';
import 'package:acro_space_simulator/infrastructure/flutter/top_down_painter.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Chase camera: inverts the camera basis so it looks down the craft's nose
// (matches SimulationView._onFrame).
PerspectiveCamera _chaseCam(Quaternion attitude, double range, double viewportH) {
  final nose = attitude.rotate(Vector3.unitZ);
  final craftUp = attitude.rotate(Vector3.unitY);
  final elevation = math.asin((-nose.z).clamp(-1.0, 1.0));
  final azimuth = math.atan2(nose.x, nose.y);
  final ca = math.cos(azimuth), sa = math.sin(azimuth);
  final rightBase = Vector3(ca, -sa, 0);
  final upBase = rightBase.cross(nose).normalized;
  final roll = math.atan2(-craftUp.dot(rightBase), craftUp.dot(upBase));
  return PerspectiveCamera(
    azimuth: azimuth,
    elevation: elevation.clamp(-math.pi / 2 + 0.02, math.pi / 2 - 0.02),
    roll: roll,
    range: range,
    fovY: 50 * math.pi / 180,
    viewportH: viewportH,
  );
}

Quaternion _lookAt(Vector3 position) {
  final dir = (position * -1).normalized;
  final dot = Vector3.unitZ.dot(dir).clamp(-1.0, 1.0);
  if (dot > 0.9999) return Quaternion.identity;
  if (dot < -0.9999) return Quaternion.axisAngle(Vector3.unitX, math.pi);
  return Quaternion.axisAngle(
      Vector3.unitZ.cross(dir), math.acos(dot)).normalized;
}

Future<ui.Image> _decodeFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

Future<void> _capture(
    TopDownSnapshot snap, SceneCamera cam, TextureCache tex, String path,
    {Size size = const Size(1280, 720)}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  TopDownPainter(snap, view: cam, textures: tex).paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  test('scenario: warp 50, ~15 s, LOOK-AT, planet drifts to disk edge', () async {
    final system = RealSolarSystem.build();
    final orbiter = SampleWorld.buildEarthOrbiter(altitude: 3000000); // in-app
    // LOOK AT the planet ONCE at t0 (nose points at Earth centre); afterwards the
    // attitude holds while the orbit carries the craft, so Earth slides toward
    // the edge of the view.
    orbiter.updateState(
        orbiter.state.copyWith(attitude: _lookAt(orbiter.state.position)));

    final vessels = InMemoryVesselRepository([orbiter]);
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
    // In-app clock: warp 50, fixed step 0.02 s. 15 s real * 50 = 750 s sim.
    final clock = SimulationClock(warpFactor: 50, fixedStep: 0.02);
    final presenter = TopDownSnapshotPresenter(
        vessels: vessels, universe: StaticUniverseRepository(system));
    final tex = TextureCache();
    tex.seed('earth', await _decodeFile('assets/textures/earth.jpg'));

    // Close chase range (150 m): big craft in foreground, planet limb behind.
    // Render at several wall-clock times @ warp 50.
    const range = 150.0;
    const secsReal = [26.0];
    var simElapsed = 0.0;
    for (final tReal in secsReal) {
      final targetSim = tReal * clock.warpFactor;
      while (simElapsed < targetSim) {
        tick.execute(clock);
        simElapsed += clock.simStep;
      }
      final live = vessels.byId(orbiter.id)!;
      final cam = _chaseCam(live.state.attitude, range, 720);
      final snap = presenter.present(
          focus: orbiter.id, camera: cam, epoch: clock.epoch);
      final tag = tReal.toInt();
      await _capture(
          snap, cam, tex, 'release/screenshots/scenario_${tag}s_close.png');
      expect(File('release/screenshots/scenario_${tag}s_close.png').existsSync(),
          isTrue);
    }
  });
}
