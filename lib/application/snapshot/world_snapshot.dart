import 'dart:math' as math;

import '../../domain/colony/building.dart';
import '../../domain/colony/colony.dart';
import '../../domain/colony/surface_placement.dart';
import '../../domain/orbits/body_ephemeris.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/universe/terrain_heights.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';
import '../ports/world_repositories.dart';

/// One part of a craft for asset binding: [type] is the asset key (the sim's
/// part name) and [ox]/[oy]/[oz] is the local offset in the vessel body frame
/// (metres). Parts have no own orientation — they inherit the craft attitude.
class PartSnapshot {
  final String id;
  final String type;
  final double ox, oy, oz;

  const PartSnapshot({
    required this.id,
    required this.type,
    required this.ox,
    required this.oy,
    required this.oz,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'o': [ox, oy, oz],
      };

  factory PartSnapshot.fromJson(Map<String, dynamic> j) {
    final o = (j['o'] as List).cast<num>();
    return PartSnapshot(
      id: j['id'] as String,
      type: j['type'] as String,
      ox: o[0].toDouble(),
      oy: o[1].toDouble(),
      oz: o[2].toDouble(),
    );
  }
}

/// Serializable per-vessel state for network sync, save/load, determinism
/// checks, and external renderers (e.g. a game engine consuming the snapshot
/// over the wire). Plain numbers only — no domain objects — so it round-trips
/// trivially.
///
/// Frame: position/velocity are metres / metres-per-second in the dominant
/// body's inertial frame (right-handed, Z up). [qw]..[qz] is the body attitude
/// quaternion in Hamilton convention with the scalar FIRST (w, x, y, z);
/// identity is (1, 0, 0, 0). A consumer using a scalar-LAST convention
/// (glTF/Unity/Unreal) must reorder.
class VesselSnapshot {
  final String id;
  final String ownerId;
  final String body;
  final double px, py, pz;
  final double vx, vy, vz;
  // Attitude quaternion (Hamilton, scalar-first: w, x, y, z).
  final double qw, qx, qy, qz;
  // Angular velocity (rad/s, body frame).
  final double wx, wy, wz;
  final double throttle;
  final bool onRails;
  final bool landed;
  final List<PartSnapshot> parts;

  const VesselSnapshot({
    required this.id,
    required this.ownerId,
    required this.body,
    required this.px,
    required this.py,
    required this.pz,
    required this.vx,
    required this.vy,
    required this.vz,
    this.qw = 1,
    this.qx = 0,
    this.qy = 0,
    this.qz = 0,
    this.wx = 0,
    this.wy = 0,
    this.wz = 0,
    required this.throttle,
    required this.onRails,
    this.landed = false,
    this.parts = const [],
  });

  factory VesselSnapshot.of(Vessel v) => VesselSnapshot(
        id: v.id.value,
        ownerId: v.ownerId,
        body: v.dominantBody.value,
        px: v.state.position.x,
        py: v.state.position.y,
        pz: v.state.position.z,
        vx: v.state.velocity.x,
        vy: v.state.velocity.y,
        vz: v.state.velocity.z,
        qw: v.state.attitude.w,
        qx: v.state.attitude.x,
        qy: v.state.attitude.y,
        qz: v.state.attitude.z,
        wx: v.state.angularVelocity.x,
        wy: v.state.angularVelocity.y,
        wz: v.state.angularVelocity.z,
        throttle: v.throttle,
        onRails: v.mode == PropagationMode.onRails,
        landed: v.landed,
        parts: [
          for (final p in v.allParts)
            PartSnapshot(
              id: p.id.value,
              type: p.name,
              ox: p.positionInVessel.x,
              oy: p.positionInVessel.y,
              oz: p.positionInVessel.z,
            ),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'ownerId': ownerId,
        'body': body,
        'p': [px, py, pz],
        'v': [vx, vy, vz],
        'q': [qw, qx, qy, qz],
        'w': [wx, wy, wz],
        'throttle': throttle,
        'onRails': onRails,
        'landed': landed,
        'parts': [for (final p in parts) p.toJson()],
      };

  /// Tolerant of older payloads that lack attitude / angularVelocity / landed:
  /// missing quaternion decodes to identity, missing spin to zero.
  factory VesselSnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    final v = (j['v'] as List).cast<num>();
    final q = (j['q'] as List?)?.cast<num>() ?? const [1, 0, 0, 0];
    final w = (j['w'] as List?)?.cast<num>() ?? const [0, 0, 0];
    return VesselSnapshot(
      id: j['id'] as String,
      ownerId: j['ownerId'] as String,
      body: j['body'] as String,
      px: p[0].toDouble(),
      py: p[1].toDouble(),
      pz: p[2].toDouble(),
      vx: v[0].toDouble(),
      vy: v[1].toDouble(),
      vz: v[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
      wx: w[0].toDouble(),
      wy: w[1].toDouble(),
      wz: w[2].toDouble(),
      throttle: (j['throttle'] as num).toDouble(),
      onRails: j['onRails'] as bool,
      landed: (j['landed'] as bool?) ?? false,
      parts: [
        for (final p in (j['parts'] as List?) ?? const [])
          PartSnapshot.fromJson(p as Map<String, dynamic>),
      ],
    );
  }
}

/// Serializable celestial-body world transform for one tick. Lets an external
/// renderer place and orient planets/moons without re-deriving ephemerides.
///
/// [px]..[pz] is the body's position relative to the system root (metres).
/// [qw]..[qz] is its orientation (Hamilton, scalar-first): spin about the body
/// +Z axis composed with the axial tilt. [radius] is the equatorial radius (m)
/// so the renderer can scale the sphere.
class BodySnapshot {
  final String id;
  final double px, py, pz;
  final double qw, qx, qy, qz;
  final double radius;

  const BodySnapshot({
    required this.id,
    required this.px,
    required this.py,
    required this.pz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.radius,
  });

  factory BodySnapshot.of(
    CelestialBody body,
    StarSystem system,
    BodyEphemeris ephemeris,
    Epoch epoch,
  ) {
    final pos = ephemeris.positionRelativeToRoot(body, system, epoch);
    // Spin about the body's +Z axis; angularVelocity = 2*pi / siderealPeriod.
    final spin = Quaternion.axisAngle(Vector3.unitZ, body.angularVelocity * epoch.seconds);
    // Obliquity tilts the spin axis off world +Z (about +X). Zero for bodies
    // with no axialTilt set, so the orientation is then pure spin.
    final tilt = Quaternion.axisAngle(Vector3.unitX, body.axialTilt);
    final q = (tilt * spin).normalized;
    return BodySnapshot(
      id: body.id.value,
      px: pos.x,
      py: pos.y,
      pz: pos.z,
      qw: q.w,
      qx: q.x,
      qy: q.y,
      qz: q.z,
      radius: body.radius,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'p': [px, py, pz],
        'q': [qw, qx, qy, qz],
        'r': radius,
      };

  factory BodySnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    final q = (j['q'] as List).cast<num>();
    return BodySnapshot(
      id: j['id'] as String,
      px: p[0].toDouble(),
      py: p[1].toDouble(),
      pz: p[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
      radius: (j['r'] as num).toDouble(),
    );
  }
}

/// A colony building, placed BODY-FIXED so it rotates with the planet. [px..pz]
/// and the quaternion [qw..qz] are in the body frame (local +Z radial-up, +Y
/// north); [lat]/[lon] (radians) is the surface point the renderer can ray-cast
/// against its own terrain and report a height back. [type] is the asset key
/// (the building spec type). [px..pz] already includes any reported elevation.
class BuildingSnapshot {
  final String id;
  final String type;
  final String colonyId;
  final String body;
  final double px, py, pz;
  final double qw, qx, qy, qz;
  final double lat, lon;

  const BuildingSnapshot({
    required this.id,
    required this.type,
    required this.colonyId,
    required this.body,
    required this.px,
    required this.py,
    required this.pz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.lat,
    required this.lon,
  });

  factory BuildingSnapshot.of(
    Colony colony,
    Building b,
    CelestialBody body,
    SurfacePlacement placement,
    TerrainHeights terrain,
  ) {
    // Place the cell on the tangent plane, then recover its TRUE spherical
    // lat/lon from the resulting surface direction. Keying terrain off the
    // actual placed point (rather than a first-order lat/lon approximation)
    // keeps the cache cell correct at high latitude and over the poles, and
    // keeps lat in [-pi/2, pi/2] / wraps lon — the renderer echoes these exact
    // values back via ReportTerrainHeight so both sides hit the same cell.
    final base = placement.building(
      radius: body.radius,
      lat: colony.latitude,
      lon: colony.longitude,
      gridX: b.gridX,
      gridY: b.gridY,
    );
    final dir = base.position.normalized;
    final lat = math.asin(dir.z.clamp(-1.0, 1.0));
    final lon = math.atan2(dir.y, dir.x);
    final elevation = terrain.heightAt(colony.body, lat, lon);
    final t = placement.building(
      radius: body.radius,
      lat: colony.latitude,
      lon: colony.longitude,
      gridX: b.gridX,
      gridY: b.gridY,
      elevation: elevation,
    );
    return BuildingSnapshot(
      id: b.id,
      type: b.spec.type,
      colonyId: colony.id,
      body: colony.body.value,
      px: t.position.x,
      py: t.position.y,
      pz: t.position.z,
      qw: t.orientation.w,
      qx: t.orientation.x,
      qy: t.orientation.y,
      qz: t.orientation.z,
      lat: lat,
      lon: lon,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'colony': colonyId,
        'body': body,
        'p': [px, py, pz],
        'q': [qw, qx, qy, qz],
        'lat': lat,
        'lon': lon,
      };

  factory BuildingSnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    final q = (j['q'] as List).cast<num>();
    return BuildingSnapshot(
      id: j['id'] as String,
      type: j['type'] as String,
      colonyId: j['colony'] as String,
      body: j['body'] as String,
      px: p[0].toDouble(),
      py: p[1].toDouble(),
      pz: p[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
    );
  }
}

/// Full authoritative world state for one tick: a complete render frame.
/// Sent to clients for reconciliation, compared between runs to verify
/// deterministic simulation, and consumed by external renderers.
///
/// [epoch] is sim time in seconds. [bodies] is empty when captured without a
/// [StarSystem] (vessel-only sync, e.g. legacy determinism checks).
class WorldSnapshot {
  final int tick;
  final double epoch;
  final Map<String, BodySnapshot> bodies;
  final Map<String, VesselSnapshot> vessels;
  final Map<String, BuildingSnapshot> buildings;

  const WorldSnapshot({
    required this.tick,
    required this.vessels,
    this.epoch = 0,
    this.bodies = const {},
    this.buildings = const {},
  });

  /// Capture the world. Pass [system] (+ [ephemeris] and [epoch]) to include
  /// celestial-body transforms; pass [colonies] (with [system]) to include
  /// body-fixed building transforms, folding in any reported [terrain].
  factory WorldSnapshot.capture(
    int tick,
    VesselRepository vessels, {
    StarSystem? system,
    BodyEphemeris ephemeris = const BodyEphemeris(),
    Epoch epoch = Epoch.zero,
    ColonyRepository? colonies,
    TerrainHeights? terrain,
    SurfacePlacement placement = const SurfacePlacement(),
  }) {
    final heights = terrain ?? TerrainHeights();
    final buildings = <String, BuildingSnapshot>{};
    if (system != null && colonies != null) {
      for (final colony in colonies.all()) {
        final body = system.body(colony.body);
        if (body == null) continue;
        for (final b in colony.buildings) {
          // Building ids are only colony-scoped — namespace the map key so two
          // colonies sharing an id (e.g. each a 'hab-1') don't clobber.
          buildings['${colony.id}/${b.id}'] =
              BuildingSnapshot.of(colony, b, body, placement, heights);
        }
      }
    }
    return WorldSnapshot(
      tick: tick,
      epoch: epoch.seconds,
      bodies: system == null
          ? const {}
          : {
              for (final b in system.all)
                b.id.value: BodySnapshot.of(b, system, ephemeris, epoch),
            },
      vessels: {
        for (final v in vessels.all()) v.id.value: VesselSnapshot.of(v),
      },
      buildings: buildings,
    );
  }

  Map<String, dynamic> toJson() => {
        'tick': tick,
        'epoch': epoch,
        'bodies': [for (final b in bodies.values) b.toJson()],
        'vessels': [for (final v in vessels.values) v.toJson()],
        'buildings': [for (final b in buildings.values) b.toJson()],
      };

  factory WorldSnapshot.fromJson(Map<String, dynamic> j) {
    final bodyList = (j['bodies'] as List?) ?? const [];
    final vesselList = (j['vessels'] as List?) ?? const [];
    final buildingList = (j['buildings'] as List?) ?? const [];
    return WorldSnapshot(
      tick: (j['tick'] as num).toInt(),
      epoch: (j['epoch'] as num?)?.toDouble() ?? 0,
      bodies: {
        for (final b in bodyList)
          (b as Map<String, dynamic>)['id'] as String:
              BodySnapshot.fromJson(b),
      },
      vessels: {
        for (final v in vesselList)
          (v as Map<String, dynamic>)['id'] as String:
              VesselSnapshot.fromJson(v),
      },
      buildings: {
        for (final b in buildingList)
          '${(b as Map<String, dynamic>)['colony']}/${b['id']}':
              BuildingSnapshot.fromJson(b),
      },
    );
  }

  /// A stable hash of the world state. Two deterministic runs fed identical
  /// commands must yield the same fingerprint. Rounds floats to a tolerance so
  /// the check is robust to non-meaningful ULP noise while still catching real
  /// divergence — including rotational divergence (attitude and angular
  /// velocity are both included).
  String get fingerprint {
    final ids = vessels.keys.toList()..sort();
    final buf = StringBuffer();
    for (final id in ids) {
      final s = vessels[id]!;
      buf
        ..write(id)
        ..write(':')
        ..write(s.body)
        ..write(':')
        ..write(_q(s.px))
        ..write(',')
        ..write(_q(s.py))
        ..write(',')
        ..write(_q(s.pz))
        ..write('|')
        ..write(_q(s.vx))
        ..write(',')
        ..write(_q(s.vy))
        ..write(',')
        ..write(_q(s.vz))
        ..write('@')
        ..write(_q(s.throttle))
        ..write('~')
        ..write(_q(s.qw))
        ..write(',')
        ..write(_q(s.qx))
        ..write(',')
        ..write(_q(s.qy))
        ..write(',')
        ..write(_q(s.qz))
        ..write('%')
        ..write(_q(s.wx))
        ..write(',')
        ..write(_q(s.wy))
        ..write(',')
        ..write(_q(s.wz))
        ..write(';');
    }
    return buf.toString();
  }

  // Quantize to 1e-3 to ignore meaningless float noise across runs. Canonicalize
  // signed zero (-0.0 -> "0") so two numerically identical runs that differ only
  // in a zero's sign bit still hash equal; NaN maps to a fixed token.
  String _q(double x) {
    if (x.isNaN) return 'nan';
    final v = (x * 1000).roundToDouble();
    return (v == 0.0 ? 0.0 : v).toStringAsFixed(0);
  }
}
