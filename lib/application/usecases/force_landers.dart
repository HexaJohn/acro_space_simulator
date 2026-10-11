// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Troop landers in the world (docs/plans/combat.md §7B): the operation's
/// lander records flown as real vessels.
///
/// The same machinery as the colony supply shuttles — the same factory, the
/// same landing guidance, the same snapped attitude — onto a point by the
/// landing zone rather than a pad. A record spawns its vessel once the
/// operation has mustered; the guidance re-arms from the record every tick,
/// so a load resumes a descent; touchdown and loss go back to the operation,
/// which lands or loses the squads aboard. After the operation ends, a landed
/// lander lifts off and is recovered past 4 km, as a shuttle is.
library;

import 'dart:math' as math;

import '../../domain/autonomy/landing_guidance.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/parcel.dart';
import '../../domain/colony/city/shuttle_run.dart';
import '../../domain/combat/lander.dart';
import '../../domain/combat/operation.dart';
import '../../domain/combat/operation_registry.dart';
import '../../domain/dynamics/state_vector.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';
import '../ports/world_repositories.dart';

class ForceLanderFlight {
  ForceLanderFlight({required this.vessels, required this.terrainEdits});

  final VesselRepository vessels;
  final TerrainEditsRepository terrainEdits;

  static const LandingGuidance _guidance = LandingGuidance();
  static const ColonyShuttleFactory _factory = ColonyShuttleFactory();

  /// Above this height a departing lander is recovered.
  static const double recoverAltM = 4000;

  /// Each lander's touchdown point, body-fixed: sampled once (a terrain query
  /// is not free), re-sampled after a load. Not saved.
  final Map<String, Vector3> _touchdownBF = {};

  /// Whether a lander is in the air, or about to be: what holds warp at 1×,
  /// since above 4× a craft is on rails and its guidance does nothing.
  static bool aloft(OperationRegistry registry) {
    for (final op in registry.operations) {
      for (final l in op.landers) {
        if (l.state == LanderState.descending) return true;
        if (l.state == LanderState.pending &&
            !op.resolved &&
            op.phase != OperationPhase.mustering) {
          return true;
        }
      }
    }
    return false;
  }

  /// One tick, after motion: spawn, fly, land or lose, recover.
  void run(OperationRegistry registry, Iterable<CitySim> cities, StarSystem system,
      SimulationClock clock) {
    for (final op in registry.operations) {
      if (op.landers.isEmpty) continue;
      CitySim? city;
      for (final c in cities) {
        if (c.id == op.targetColonyId) city = c;
      }
      final body = city == null ? null : system.body(city.body.id);
      final lz = op.graph.byId(op.lzId);
      for (final l in op.landers) {
        if (city == null || body == null || lz == null) {
          // Nowhere to land: whoever is aboard never arrives.
          if (l.state == LanderState.pending) l.state = LanderState.departed;
          if (l.state == LanderState.descending) op.landerLost(l.vesselId);
          continue;
        }
        _fly(op, l, city, body, lz.e, lz.n, clock);
      }
    }
  }

  void _fly(Operation op, LanderRecord l, CitySim city, CelestialBody body, double lzE,
      double lzN, SimulationClock clock) {
    final orientation = body.orientationAt(clock.epoch);
    Vector3 touchdown() => _touchdownBF[l.vesselId] ??=
        _groundBF(city, Vec2(lzE + l.offE, lzN + l.offN), body);
    switch (l.state) {
      case LanderState.pending:
        if (op.phase == OperationPhase.mustering) return;
        if (op.resolved) {
          l.state = LanderState.departed; // it never flew
          return;
        }
        vessels.save(_factory.build(
          id: l.vesselId,
          body: body,
          padBF: touchdown(),
          bodyOrientation: orientation,
          name: 'Troop Lander',
          withCargo: false,
        ));
        l.state = LanderState.descending;
      case LanderState.descending:
        final v = vessels.byId(VesselId(l.vesselId));
        if (v == null) {
          op.landerLost(l.vesselId);
          _touchdownBF.remove(l.vesselId);
          return;
        }
        if (v.landed) {
          v.setThrottle(0);
          vessels.save(v);
          op.landerDown(l.vesselId);
          return;
        }
        final posBF = orientation.conjugate.rotate(v.state.position);
        final period = body.siderealRotationPeriod;
        final omega =
            period.abs() < 1 ? Vector3.zero : Vector3(0, 0, 2 * math.pi / period);
        final velBF = orientation.conjugate.rotate(v.state.velocity) - omega.cross(posBF);
        final cmd = _guidance.command(
          posBF: posBF,
          velBF: velBF,
          padBF: touchdown(),
          mu: body.mu,
          mass: v.mass,
          maxThrust: ColonyShuttleFactory.maxThrust,
        );
        v.setThrottle(cmd.throttle);
        _point(v, orientation.rotate(cmd.facing));
        vessels.save(v);
      case LanderState.landed:
        if (!op.resolved) return;
        final v = vessels.byId(VesselId(l.vesselId));
        if (v == null) {
          l.state = LanderState.departed;
          return;
        }
        final posBF = orientation.conjugate.rotate(v.state.position);
        v.setThrottle(1);
        _point(v, orientation.rotate(posBF.normalized));
        if (posBF.length - touchdown().length > recoverAltM) {
          vessels.remove(v.id);
          l.state = LanderState.departed;
          _touchdownBF.remove(l.vesselId);
        } else {
          vessels.save(v);
        }
      case LanderState.lost:
      case LanderState.departed:
        return;
    }
  }

  /// Body-fixed point on the real ground under colony-local [local].
  Vector3 _groundBF(CitySim city, Vec2 local, CelestialBody body) {
    final dir = city.localToBodyFixed(local, bodyRadiusM: body.radius).normalized;
    final field = body.terrainFieldWith(terrainEdits.forBody(body.id));
    final ground = field == null ? body.radius : field.groundRadiusAt(dir.x, dir.y, dir.z);
    return dir * ground;
  }

  /// Snaps the thrust axis (+Z) onto [dir], as the shuttles do.
  static void _point(Vessel vessel, Vector3 dir) {
    final d = dir.normalized;
    final axis = Vector3.unitZ.cross(d);
    final sin = axis.length;
    final cos = Vector3.unitZ.dot(d);
    final att = sin < 1e-9
        ? (cos > 0 ? Quaternion.identity : Quaternion.axisAngle(Vector3.unitX, math.pi))
        : Quaternion.axisAngle(axis.normalized, math.atan2(sin, cos));
    vessel.updateState(StateVector(
      position: vessel.state.position,
      velocity: vessel.state.velocity,
      attitude: att,
    ));
    vessel.targetFacing = d;
  }
}
