// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Silo salvos in the world (docs/plans/combat.md §7O): each shot the combat
/// phase asked for, flown as a real vessel.
///
/// A paid shot leaves its colony's Missile Silo at burnout on the Lambert arc
/// to its aimed ground, timed so the body has turned the target under it,
/// and coasts on the conic like any craft — the craft trajectory line, cut
/// at the impact. It detonates at its impact time (the tick does that: the
/// crater and the Impact event are its own), which is where it was aimed
/// however the clock is warped.
library;

import 'dart:math' as math;

import '../../domain/colony/city/city_sim.dart';
import '../../domain/combat/operation_registry.dart';
import '../../domain/combat/powers/missile.dart';
import '../../domain/dynamics/state_vector.dart';
import '../../domain/orbits/lambert.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/part.dart';
import '../../domain/vessel/stage.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';
import '../ports/world_repositories.dart';

/// The salvo's arc, planned: where it leaves (inertial), how fast, and how
/// long it flies; or why it cannot.
typedef MissilePlan = ({Vector3 r1, Vector3 v1, double tof, Vector3 siloBF, Vector3 aimBF, String? why});

class MissileFlight {
  MissileFlight({required this.vessels, required this.terrainEdits});

  final VesselRepository vessels;
  final TerrainEditsRepository terrainEdits;

  /// The salvo leaves the silo at burnout this high above it, m.
  static const double burnoutM = 100;

  /// The ground under body-fixed unit [dir], m from the centre.
  double groundAt(CelestialBody body, Vector3 dir) =>
      body.terrainFieldWith(terrainEdits.forBody(body.id))?.groundRadiusAt(dir.x, dir.y, dir.z) ?? body.radius;

  /// [colony]'s Missile Silo, body-fixed on its ground; null with none.
  Vector3? siloOf(CitySim colony, CelestialBody body) {
    final silos = [
      for (final (p, s) in colony.buildingParcels())
        if (s.type == 'silo') p
    ]..sort((a, b) => a.id.compareTo(b.id));
    if (silos.isEmpty) return null;
    final dir = colony.localToBodyFixed(silos.first.centroid, bodyRadiusM: body.radius).normalized;
    return dir * groundAt(body, dir);
  }

  /// The arc from [siloBF] to the ground at [aimDir], leaving at [epochS].
  MissilePlan plan(CelestialBody body, Vector3 siloBF, Vector3 aimDir, double epochS) {
    final aimBF = aimDir.normalized * groundAt(body, aimDir.normalized);
    final up = siloBF.normalized;
    final from = up * (siloBF.length + burnoutM);
    final cosA = (up.dot(aimBF.normalized)).clamp(-1.0, 1.0);
    final arcM = body.radius * math.acos(cosA);
    MissilePlan no(String why) => (r1: Vector3.zero, v1: Vector3.zero, tof: 0, siloBF: siloBF, aimBF: aimBF, why: why);
    if (arcM < 300) return no('too close to the silo.');
    if (arcM > kMissileMaxArcM) {
      return no('out of range: ${(arcM / 1000).round()} km away, and a silo reaches '
          '${(kMissileMaxArcM / 1000).round()} km.');
    }
    // A 45° loft over flat ground: tof = √(2s/g). Lambert bends it to the
    // sphere; on long arcs the curvature shortens the flight it needs.
    final g = body.mu / (body.radius * body.radius);
    final tof = math.max(20.0, math.sqrt(2 * arcM / g));
    final r1 = body.orientationAt(Epoch(epochS)).rotate(from);
    final r2 = body.orientationAt(Epoch(epochS + tof)).rotate(aimBF);
    final s = solveLambert(r1, r2, tof, body.mu);
    if (s == null) return no('no arc reaches it.');
    return (r1: r1, v1: s.departure, tof: tof, siloBF: siloBF, aimBF: aimBF, why: null);
  }

  /// One tick, after the combat phase: launch what is paid for, and point
  /// what flies along its flight.
  void run(OperationRegistry registry, Iterable<CitySim> cities, StarSystem system, SimulationClock clock) {
    for (final m in registry.missiles) {
      switch (m.state) {
        case MissileState.pending:
          _launch(m, cities, system, clock);
        case MissileState.flying:
          final v = vessels.byId(VesselId(m.vesselId));
          if (v == null) continue;
          v.arcEndEpochS = m.impactEpochS;
          v.updateState(v.state.copyWith(attitude: noseAlong(v.state.velocity)));
          vessels.save(v);
        case MissileState.unpaid:
        case MissileState.landed:
        case MissileState.failed:
          break;
      }
    }
  }

  void _launch(MissileShot m, Iterable<CitySim> cities, StarSystem system, SimulationClock clock) {
    CitySim? home;
    for (final c in cities) {
      if (c.id == m.homeColonyId) home = c;
    }
    final body = system.body(home?.body.id ?? BodyId(m.bodyId));
    if (home == null || body == null) {
      m
        ..state = MissileState.failed
        ..why = 'the firing colony is gone.';
      return;
    }
    if (body.id.value != m.bodyId) {
      m
        ..state = MissileState.failed
        ..why = 'a silo strikes only its own world.';
      return;
    }
    final silo = siloOf(home, body);
    if (silo == null) {
      m
        ..state = MissileState.failed
        ..why = '${home.name} has no Missile Silo.';
      return;
    }
    final t0 = clock.epoch.seconds;
    final p = plan(body, silo, m.aimDir, t0);
    if (p.why != null) {
      m
        ..state = MissileState.failed
        ..why = p.why;
      return;
    }
    final v = Vessel(
      id: VesselId(m.vesselId),
      name: 'Missile salvo',
      ownerId: 'player',
      state: StateVector(position: p.r1, velocity: p.v1, attitude: noseAlong(p.v1)),
      dominantBody: body.id,
      stages: [
        Stage(index: 0, parts: [
          Part(
            id: PartId('${m.vesselId}-salvo'),
            name: 'Missile salvo',
            dryMass: kMissileSalvoKg,
            inertiaContribution: const Vector3(800, 800, 120),
            crossSectionArea: 0.6,
          ),
        ]),
      ],
    )..arcEndEpochS = t0 + p.tof;
    vessels.save(v);
    m
      ..state = MissileState.flying
      ..launchEpochS = t0
      ..impactEpochS = t0 + p.tof
      ..siloBF = p.siloBF
      ..aimBF = p.aimBF;
  }

  /// The salvos due to land by [epochS].
  static List<MissileShot> due(OperationRegistry registry, double epochS) => [
        for (final m in registry.missiles)
          if (m.state == MissileState.flying && m.impactEpochS <= epochS) m
      ];

  /// An attitude with the nose (+Z) along [velocity].
  static Quaternion noseAlong(Vector3 velocity) {
    final l = velocity.length;
    if (l < 1e-9) return Quaternion.identity;
    final d = velocity * (1 / l);
    const z = Vector3.unitZ;
    final c = z.dot(d).clamp(-1.0, 1.0);
    if (c > 1 - 1e-12) return Quaternion.identity;
    if (c < -1 + 1e-12) return Quaternion.axisAngle(Vector3.unitX, math.pi);
    return Quaternion.axisAngle(z.cross(d).normalized, math.acos(c));
  }
}
