// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final system = RealSolarSystem.build();
  final vessels = InMemoryVesselRepository(const []);

  Megastructure ring() => Megastructure.haloRing(
        id: 'halo-earth',
        radius: 5.0e6,
        site: const MegastructureSite(
          parentBodyId: 'earth',
          orbitRadiusM: 1.5e7,
          orbitPhaseRad: 0.25,
        ),
      );

  test('a sited halo ring crosses the snapshot with pose + recipe + progress',
      () {
    final m = ring();
    // Finish phase 1, half-fill phase 2.
    m.phases[0].contributedMass = m.phases[0].requiredMass;
    m.phases[0].contributedEnergy = m.phases[0].requiredEnergy;
    m.phases[1].contributedMass = m.phases[1].requiredMass * 0.5;
    m.phases[1].contributedEnergy = m.phases[1].requiredEnergy * 0.5;

    final snap = WorldSnapshot.capture(
      1,
      vessels,
      system: system,
      epoch: const Epoch(1000),
      megastructures: InMemoryMegastructureRepository([m]),
    );

    expect(snap.megastructures, hasLength(1));
    final s = snap.megastructures.single;
    expect(s.id, 'halo-earth');
    expect(s.type, MegastructureType.haloRing.index);
    expect(s.completedPhases, 1);
    expect(s.stageFraction, closeTo(0.5, 1e-9));
    expect(s.ringRadiusM, 5.0e6);
    expect(s.spinPeriodS, greaterThan(0));

    // Pose: the ring orbits EARTH — its root-relative position must sit at
    // the site's orbit radius from Earth's root-relative position.
    final earth = snap.bodies['earth']!;
    final dx = s.px - earth.px, dy = s.py - earth.py, dz = s.pz - earth.pz;
    expect(math.sqrt(dx * dx + dy * dy + dz * dz), closeTo(1.5e7, 1));

    // Orientation: unit quaternion, spin about +Z only.
    final n = s.qw * s.qw + s.qx * s.qx + s.qy * s.qy + s.qz * s.qz;
    expect(n, closeTo(1, 1e-9));
    expect(s.qx, 0);
    expect(s.qy, 0);
  });

  test('unsited projects stay sim-side', () {
    final snap = WorldSnapshot.capture(
      1,
      vessels,
      system: system,
      megastructures: InMemoryMegastructureRepository(
          [Megastructure.haloRing(id: 'toy', radius: 1e5)]),
    );
    expect(snap.megastructures, isEmpty);
  });

  test('json round trip preserves the megastructure entry', () {
    final snap = WorldSnapshot.capture(
      1,
      vessels,
      system: system,
      epoch: const Epoch(5),
      megastructures: InMemoryMegastructureRepository([ring()]),
    );
    final back = WorldSnapshot.fromJson(snap.toJson());
    expect(back.megastructures, hasLength(1));
    final a = snap.megastructures.single, b = back.megastructures.single;
    expect(b.id, a.id);
    expect(b.px, a.px);
    expect(b.qw, a.qw);
    expect(b.ringRadiusM, a.ringRadiusM);
    expect(b.bandWidthM, a.bandWidthM);
    expect(b.seed, a.seed);
    expect(b.completedPhases, a.completedPhases);
    // Recipe survives intact enough to rebuild the identical field.
    expect(b.toRingSpec().field().heightAt(1.2, 300),
        a.toRingSpec().field().heightAt(1.2, 300));
  });

  test('spin period rides the override through the wire recipe', () {
    final m = ring();
    final snap = WorldSnapshot.capture(1, vessels,
        system: system,
        megastructures: InMemoryMegastructureRepository([m]));
    final spec = snap.megastructures.single.toRingSpec();
    // Snapshot stores the RESOLVED period; rebuilding must not re-derive a
    // different one.
    expect(spec.spinPeriodS, m.ringSpec!.spinPeriodS);
  });
}
