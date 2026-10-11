// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The combat phase's view of the flying world at a tick's end
/// (docs/plans/combat.md §7E): vessels and body spin, behind [CombatSky], so
/// the combat code never imports a vessel.
library;

import 'dart:math' as math;

import '../../domain/colony/city/city_sim.dart';
import '../../domain/combat/formation.dart';
import '../../domain/combat/powers/sky.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';

class TickSky implements CombatSky {
  TickSky(this.vessels, this.system, this.epoch, this.cities);

  final VesselRepository vessels;
  final StarSystem system;
  final Epoch epoch;
  final Iterable<CitySim> cities;

  /// How close to a pad's centre a craft must stand to be armed there: the
  /// shuttle cargo service's own reach.
  static const double padRadiusM = 60;

  Vessel? _v(String id) => vessels.byId(VesselId(id));

  @override
  Vector3? positionAbout(String vesselId, String bodyId) {
    final v = _v(vesselId);
    if (v == null || v.landed || v.dominantBody.value != bodyId) return null;
    return v.state.position;
  }

  @override
  Vector3 toInertial(String bodyId, Vector3 bf) =>
      system.body(BodyId(bodyId))?.orientationAt(epoch).rotate(bf) ?? bf;

  @override
  String? nameOf(String vesselId) => _v(vesselId)?.name;

  @override
  bool isPlayers(String vesselId) => Factions.ownerIsPlayer(_v(vesselId)?.ownerId);

  @override
  bool landedAtPad(String vesselId, String colonyId) {
    final v = _v(vesselId);
    if (v == null || !v.landed) return false;
    CitySim? city;
    for (final c in cities) {
      if (c.id == colonyId) city = c;
    }
    if (city == null || v.dominantBody != city.body.id) return false;
    final body = system.body(city.body.id);
    if (body == null) return false;
    final dir = body.orientationAt(epoch).conjugate.rotate(v.state.position).normalized;
    for (final (parcel, _) in city.landingPads()) {
      final pad = city.localToBodyFixed(parcel.centroid, bodyRadiusM: body.radius).normalized;
      final arc = math.acos(dir.dot(pad).clamp(-1.0, 1.0)) * body.radius;
      if (arc <= padRadiusM) return true;
    }
    return false;
  }
}
