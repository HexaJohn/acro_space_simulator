// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../dynamics/state_vector.dart';
import '../planetary/planet_surface.dart';
import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../simulation/epoch.dart';
import '../universe/celestial_body.dart';
import '../universe/star_system.dart';
import 'body_ephemeris.dart';

/// Where a [SpawnPreset] puts a craft: the body it belongs to, its body-centred
/// INERTIAL state, and whether it starts resting on (or floating on) the
/// surface. Exactly the three fields a caller writes onto a vessel.
class SpawnPlacement {
  const SpawnPlacement({
    required this.body,
    required this.state,
    required this.landed,
  });

  final BodyId body;
  final StateVector state;
  final bool landed;
}

/// Named "drop the craft here" scenarios — the handful of places worth putting
/// eyes on a render or a flight model without flying there first.
enum SpawnPreset {
  earthSurface('Earth surface', BodyId('earth')),
  earthOcean('Earth ocean', BodyId('earth')),
  lowEarthOrbit('Low Earth orbit', BodyId('earth')),
  moonSurface('Landed — Moon', BodyId('moon')),
  lowLunarOrbit('Low lunar orbit', BodyId('moon')),
  saturnRings('Inside Saturn rings', BodyId('saturn'));

  const SpawnPreset(this.label, this.bodyId);

  /// Menu text.
  final String label;

  /// Body the placement is relative to (the vessel's new dominant body).
  final BodyId bodyId;
}

/// Resolves a [SpawnPreset] into a concrete placement against the live system.
///
/// Pure and deterministic: the same system + epoch always yield the same spot,
/// so a preset is reproducible across sessions. Surface presets SEARCH for a
/// site rather than hard-coding a lat/lon — the terrain and the biome map are
/// both noise fields, so "somewhere on land" / "somewhere at sea" can only be
/// answered by sampling them.
class SpawnPresets {
  const SpawnPresets({this.ephemeris = const BodyEphemeris()});

  final BodyEphemeris ephemeris;

  /// Circular-orbit altitude above the datum (m). LEO clears Earth's 140 km
  /// modelled atmosphere with room to spare, so the craft doesn't decay while
  /// you look at it.
  static const double leoAltitude = 400000;
  static const double lloAltitude = 100000;

  /// ISS-like inclination (51.6°) for LEO: an inclined orbit reads AS an orbit
  /// on screen, where an equatorial one hides its own plane edge-on.
  static const double leoInclination = 0.9006;

  /// Ring-plane orbit radius in body radii. 1.55 R sits in Saturn's B ring,
  /// well inside the 1.2R–2.3R sheet the renderer draws, and exactly in-plane
  /// so the particle field surrounds the craft.
  static const double saturnRingRadii = 1.55;

  /// Candidate surface directions sampled when hunting for a site.
  static const int _samples = 512;

  /// Skip anything poleward of this |sin(lat)| — polar sites light badly and
  /// read as ice caps on every body with a surface map.
  static const double _polarCutoff = 0.75;

  /// The placement for [preset], or null when the body isn't in [system].
  SpawnPlacement? resolve(
    SpawnPreset preset, {
    required StarSystem system,
    required Epoch epoch,
  }) {
    final body = system.body(preset.bodyId);
    if (body == null) return null;
    return switch (preset) {
      SpawnPreset.earthSurface => _surface(body, system, epoch, onWater: false),
      SpawnPreset.earthOcean => _surface(body, system, epoch, onWater: true),
      SpawnPreset.moonSurface => _surface(body, system, epoch, onWater: false),
      SpawnPreset.lowEarthOrbit => _circular(body,
          radius: body.radius + leoAltitude, inclination: leoInclination),
      SpawnPreset.lowLunarOrbit =>
        _circular(body, radius: body.radius + lloAltitude, inclination: 0),
      SpawnPreset.saturnRings =>
        _circular(body, radius: body.radius * saturnRingRadii, inclination: 0),
    };
  }

  /// A circular orbit of [radius] (from the centre) whose plane is [inclination]
  /// off the body's EQUATOR — which is also its ring plane, so an inclination of
  /// 0 puts the craft in among the rings rather than above them.
  SpawnPlacement _circular(
    CelestialBody body, {
    required double radius,
    required double inclination,
  }) {
    final axis = body.spinAxisInertial; // unit, = tilt·(+Z)
    // Ascending node: any unit vector in the equatorial plane. Pick the
    // reference off the axis so the cross product never degenerates.
    final ref = axis.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final node = axis.cross(ref).normalized;
    final along = axis.cross(node); // unit, prograde (with the body's spin)
    final speed = math.sqrt(body.mu / radius);
    final position = node * radius;
    // At the node, inclining tips the velocity out of the equator toward the
    // pole; the orbit stays circular either way.
    final velocity =
        (along * math.cos(inclination) + axis * math.sin(inclination)) * speed;
    return SpawnPlacement(
      body: body.id,
      state: StateVector(
        position: position,
        velocity: velocity,
        attitude: _prograde(position, velocity),
      ),
      landed: false,
    );
  }

  /// A landed (or floating) placement on [body]: upright, co-rotating with the
  /// ground, at a site that matches [onWater].
  SpawnPlacement _surface(
    CelestialBody body,
    StarSystem system,
    Epoch epoch, {
    required bool onWater,
  }) {
    final dir = _pickSite(body, system, epoch, onWater: onWater);
    final groundR = body.terrainGroundRadius(dir, epoch);
    final seaR = body.terrainField?.seaRadius ?? body.radius;
    // On water the craft floats at the sea datum; on land it rests exactly on
    // the terrain — the same radius the tick's touchdown clamps a lander to.
    final position = dir * (onWater ? math.max(seaR, groundR) : groundR);

    // Upright: nose (+Z) radially out, +Y toward the pole, +X east.
    final up = dir;
    final axis = body.spinAxisInertial;
    var north = axis - up * up.dot(axis);
    if (north.lengthSquared < 1e-12) {
      north = Vector3.unitX - up * up.dot(Vector3.unitX); // standing on a pole
    }
    north = north.normalized;
    final east = north.cross(up);

    return SpawnPlacement(
      body: body.id,
      state: StateVector(
        position: position,
        // Matches the velocity the landed branch of the tick maintains, so the
        // craft doesn't jolt on its first step.
        velocity: body.surfaceVelocityAt(position),
        attitude: Quaternion.fromBasis(east, north, up),
      ),
      landed: true,
    );
  }

  /// Hunt for a surface direction (unit, INERTIAL) that is land or water as
  /// asked, preferring daylight. Scored rather than filtered so a body missing
  /// terrain or a biome map still yields a sane site instead of nothing.
  Vector3 _pickSite(
    CelestialBody body,
    StarSystem system,
    Epoch epoch, {
    required bool onWater,
  }) {
    final field = body.terrainField;
    final surface = body.surface;
    final seaR = field?.seaRadius ?? body.radius;
    final toSun = _sunDirection(body, system, epoch);

    var best = Vector3.unitX;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < _samples; i++) {
      final dir = _spherePoint(i, _samples);
      if (dir.z.abs() > _polarCutoff) continue;
      var score = 0.0;
      if (field != null) {
        // Relief decides the LOOK: a basin is the sea floor, high ground is
        // dry land. Margins keep the craft off the shoreline either way.
        final ground = body.terrainGroundRadius(dir, epoch);
        final wet = ground < seaR - 200;
        final dry = ground > seaR + 50;
        if (onWater ? wet : dry) score += 2;
      }
      if (surface != null) {
        // Biome decides the PHYSICS (splashdown vs hard landing). Lat/lon come
        // off the inertial direction because that's what the tick's touchdown
        // check uses — matching it means the sim reads the same biome we chose.
        final lat = math.asin(dir.z.clamp(-1.0, 1.0));
        final lon = math.atan2(dir.y, dir.x);
        final isOcean =
            surface.biomeAt(latitude: lat, longitude: lon) == Biome.ocean;
        if (onWater == isOcean) score += 2;
      }
      if (toSun != null && dir.dot(toSun) > 0.25) score += 1; // sunlit
      if (score > bestScore) {
        bestScore = score;
        best = dir;
      }
    }
    return best;
  }

  /// Unit vector from [body] toward the system's star, or null at the root.
  Vector3? _sunDirection(CelestialBody body, StarSystem system, Epoch epoch) {
    final fromStar = ephemeris.positionRelativeToRoot(body, system, epoch);
    if (fromStar.lengthSquared < 1) return null; // the body IS the star
    return (-fromStar).normalized;
  }

  /// Attitude with the nose (+Z) on the velocity and the craft's up (+Y)
  /// radially out — the way a craft flies an orbit, not a random roll.
  static Quaternion _prograde(Vector3 position, Vector3 velocity) {
    final nose = velocity.normalized;
    var up = position.normalized;
    up = up - nose * nose.dot(up); // orthogonalise against the nose
    if (up.lengthSquared < 1e-12) return Quaternion.identity; // purely radial
    up = up.normalized;
    return Quaternion.fromBasis(up.cross(nose), up, nose);
  }

  /// Point [i] of [n] on a Fibonacci sphere — an even, deterministic spread, so
  /// the site search covers the globe without clustering at the poles.
  static Vector3 _spherePoint(int i, int n) {
    const goldenAngle = math.pi * (3 - 2.23606797749979); // pi*(3 - sqrt(5))
    final z = 1 - 2 * (i + 0.5) / n;
    final r = math.sqrt(math.max(0.0, 1 - z * z));
    final theta = i * goldenAngle;
    return Vector3(r * math.cos(theta), r * math.sin(theta), z);
  }
}
