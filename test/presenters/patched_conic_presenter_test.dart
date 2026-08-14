// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('focused vessel escaping the Moon gets a patched-conic handoff leg', () {
    final system = SampleWorld.realSystem();
    final moon = system.require(const BodyId('moon'));
    final r = moon.radius + 200000;
    // Well above lunar escape speed -> guaranteed SOI exit into Earth's frame.
    final v = math.sqrt(2 * moon.mu / r) * 1.2;
    final escaper = Vessel(
      id: const VesselId('escaper'),
      name: 'Escaper',
      ownerId: 'test',
      state: StateVector(
        position: Vector3(r, 0, 0),
        velocity: Vector3(0, v, 0),
      ),
      dominantBody: const BodyId('moon'),
      stages: const [],
    );
    final bystander = SampleWorld.buildEarthOrbiter(altitude: 400000);
    final vessels = InMemoryVesselRepository([escaper, bystander]);
    final presenter = TopDownSnapshotPresenter(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
    );

    final snap = presenter.present(
      focus: escaper.id,
      camera: const OrthoCamera(CameraOrbit.top, 2e6),
      epoch: Epoch.zero,
    );

    final focus = snap.vessels.firstWhere((x) => x.name == 'Escaper');
    // The escape produces at least one continuation leg, in Earth's frame.
    expect(focus.patchPaths, isNotEmpty);
    expect(focus.patchLabels.first, 'Earth');
    // The leg has real projected points (top-down ortho culls nothing).
    final finite =
        focus.patchPaths.first.where((p) => p.x.isFinite && p.y.isFinite);
    expect(finite.length, greaterThan(10));
    // Patch 0 (the truncated moon-frame arc) replaced the plain path.
    expect(focus.path, isNotEmpty);

    // The prediction is focus-only: the other craft gets no patch legs even
    // though it is drawn with its ordinary path.
    final other = snap.vessels.firstWhere((x) => x.name == 'Orbiter');
    expect(other.patchPaths, isEmpty);
  });
}
