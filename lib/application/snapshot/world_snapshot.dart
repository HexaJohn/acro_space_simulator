import 'dart:math' as math;

import '../../domain/colony/building.dart';
import '../../domain/colony/colony.dart';
import '../../domain/colony/surface_placement.dart';
import '../../domain/comms/comms_service.dart';
import '../../domain/orbits/body_ephemeris.dart';
import '../../domain/orbits/state_vector_converter.dart';
import '../../domain/orbits/trajectory_service.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/domain_event.dart';
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

/// An aggregated resource gauge: the craft's total [amount]/[capacity] of one
/// [type] (e.g. liquidFuel), summed across all its parts.
class ResourceSnapshot {
  final String type;
  final double amount;
  final double capacity;

  const ResourceSnapshot({
    required this.type,
    required this.amount,
    required this.capacity,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'amount': amount,
        'capacity': capacity,
      };

  factory ResourceSnapshot.fromJson(Map<String, dynamic> j) => ResourceSnapshot(
        type: j['type'] as String,
        amount: (j['amount'] as num).toDouble(),
        capacity: (j['capacity'] as num).toDouble(),
      );
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
  // Telemetry / gauges.
  final double mass; // kg
  final int crew;
  final List<ResourceSnapshot> resources;
  final double maxTemp; // hottest part temperature, K
  final double tempLimit; // that part's destruction temperature, K
  // Orbit about the dominant body. Radii in metres; -1 = escape/none.
  final double apoapsis, periapsis, period;
  final double eccentricity, inclination, semiMajor;
  // Predicted orbit-line points, flattened x,y,z triples (body-relative metres).
  final List<double> trajectory;
  // Comms.
  final bool connected;
  final double commDelay; // one-way light-time, s

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
    this.mass = 0,
    this.crew = 0,
    this.resources = const [],
    this.maxTemp = 0,
    this.tempLimit = 0,
    this.apoapsis = -1,
    this.periapsis = -1,
    this.period = -1,
    this.eccentricity = 0,
    this.inclination = 0,
    this.semiMajor = 0,
    this.trajectory = const [],
    this.connected = true,
    this.commDelay = 0,
  });

  factory VesselSnapshot.of(Vessel v,
      {StarSystem? system, Epoch epoch = Epoch.zero}) {
    // Aggregate resources across parts by type, and find the hottest part.
    final amounts = <String, double>{};
    final capacities = <String, double>{};
    for (final p in v.allParts) {
      for (final r in p.resources) {
        final k = r.type.name;
        amounts[k] = (amounts[k] ?? 0) + r.amount;
        capacities[k] = (capacities[k] ?? 0) + r.capacity;
      }
    }
    var maxTemp = 0.0, tempLimit = 0.0;
    for (final t in v.thermal) {
      if (t.temperature > maxTemp) {
        maxTemp = t.temperature;
        tempLimit = t.maxTemperature;
      }
    }

    // Orbit / trajectory / comms — need the dominant body + current epoch.
    var apoapsis = -1.0, periapsis = -1.0, period = -1.0;
    var eccentricity = 0.0, inclination = 0.0, semiMajor = 0.0;
    var trajectory = const <double>[];
    var commDelay = 0.0;
    final body = system?.body(v.dominantBody);
    if (body != null) {
      commDelay = const CommsService()
          .signalDelaySeconds(v.state.position, Vector3(body.radius, 0, 0));
      if (!v.landed && v.state.velocity.length > 1) {
        double fin(double x) => x.isFinite ? x : -1.0;
        final orbit = const StateVectorOrbitConverter().toOrbit(
          position: v.state.position,
          velocity: v.state.velocity,
          body: body,
          epoch: epoch,
        );
        apoapsis = fin(orbit.apoapsis);
        periapsis = fin(orbit.periapsis);
        period = fin(orbit.period);
        semiMajor = fin(orbit.elements.semiMajorAxis);
        eccentricity = orbit.elements.eccentricity;
        inclination = orbit.elements.inclination;
        final path = const TrajectoryService().predictPath(
          position: v.state.position,
          velocity: v.state.velocity,
          body: body,
          epoch: epoch,
          samples: 48,
        );
        trajectory = [for (final p in path) ...[p.x, p.y, p.z]];
      }
    }

    return VesselSnapshot(
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
      mass: v.mass,
      crew: v.crew?.count ?? 0,
      resources: [
        for (final k in amounts.keys)
          ResourceSnapshot(
            type: k,
            amount: amounts[k]!,
            capacity: capacities[k] ?? 0,
          ),
      ],
      maxTemp: maxTemp,
      tempLimit: tempLimit,
      apoapsis: apoapsis,
      periapsis: periapsis,
      period: period,
      eccentricity: eccentricity,
      inclination: inclination,
      semiMajor: semiMajor,
      trajectory: trajectory,
      connected: v.hasCommLink,
      commDelay: commDelay,
    );
  }

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
        'mass': mass,
        'crew': crew,
        'resources': [for (final r in resources) r.toJson()],
        'maxTemp': maxTemp,
        'tempLimit': tempLimit,
        'apoapsis': apoapsis,
        'periapsis': periapsis,
        'period': period,
        'eccentricity': eccentricity,
        'inclination': inclination,
        'semiMajor': semiMajor,
        'traj': trajectory,
        'connected': connected,
        'commDelay': commDelay,
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
      mass: (j['mass'] as num?)?.toDouble() ?? 0,
      crew: (j['crew'] as num?)?.toInt() ?? 0,
      resources: [
        for (final r in (j['resources'] as List?) ?? const [])
          ResourceSnapshot.fromJson(r as Map<String, dynamic>),
      ],
      maxTemp: (j['maxTemp'] as num?)?.toDouble() ?? 0,
      tempLimit: (j['tempLimit'] as num?)?.toDouble() ?? 0,
      apoapsis: (j['apoapsis'] as num?)?.toDouble() ?? -1,
      periapsis: (j['periapsis'] as num?)?.toDouble() ?? -1,
      period: (j['period'] as num?)?.toDouble() ?? -1,
      eccentricity: (j['eccentricity'] as num?)?.toDouble() ?? 0,
      inclination: (j['inclination'] as num?)?.toDouble() ?? 0,
      semiMajor: (j['semiMajor'] as num?)?.toDouble() ?? 0,
      trajectory: [
        for (final n in (j['traj'] as List?) ?? const []) (n as num).toDouble(),
      ],
      connected: (j['connected'] as bool?) ?? true,
      commDelay: (j['commDelay'] as num?)?.toDouble() ?? 0,
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
  // The body's closed orbit ring about its parent, flattened x,y,z triples in
  // system-root-relative metres (SAME frame as px..pz). Empty for root bodies.
  // Lets a renderer draw the orbit line without re-deriving ephemerides.
  final List<double> orbit;

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
    this.orbit = const [],
  });

  factory BodySnapshot.of(
    CelestialBody body,
    StarSystem system,
    BodyEphemeris ephemeris,
    Epoch epoch, {
    // Orbit-ring resolution. The wire uses a coarse ring (the whole ring is ~90%
    // of a WorldFrame; a full-res ring per body per tick bloats the frame to
    // ~85 KB, which the engine bridge struggles to reassemble). The on-screen
    // painter passes the default 96 for smooth ellipses.
    int orbitSamples = 96,
  }) {
    final pos = ephemeris.positionRelativeToRoot(body, system, epoch);
    // Spin about the body's +Z axis; angularVelocity = 2*pi / siderealPeriod.
    final spin = Quaternion.axisAngle(Vector3.unitZ, body.angularVelocity * epoch.seconds);
    // Obliquity tilts the spin axis off world +Z (about +X). Zero for bodies
    // with no axialTilt set, so the orientation is then pure spin.
    final tilt = Quaternion.axisAngle(Vector3.unitX, body.axialTilt);
    final q = (tilt * spin).normalized;
    // Orbit ring: sampled about the parent, then shifted into root-relative
    // space by the parent's current position so it sits in the SAME frame as
    // pos (the engine rebases it onto the focus origin exactly like pos).
    final orbit = <double>[];
    final parent = system.parentOf(body);
    if (parent != null && body.orbitRadius != 0) {
      final parentRoot = ephemeris.positionRelativeToRoot(parent, system, epoch);
      for (final p in ephemeris.orbitPathRelativeToParent(body, system,
          epoch: epoch, samples: orbitSamples)) {
        orbit
          ..add(parentRoot.x + p.x)
          ..add(parentRoot.y + p.y)
          ..add(parentRoot.z + p.z);
      }
    }
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
      orbit: orbit,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'p': [px, py, pz],
        'q': [qw, qx, qy, qz],
        'r': radius,
        if (orbit.isNotEmpty) 'orbit': orbit,
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
      orbit: [
        for (final n in (j['orbit'] as List?) ?? const []) (n as num).toDouble(),
      ],
    );
  }
}

/// Coarse render classification of a body, mirrored on the wire as a ubyte.
/// Values MUST match `enum BodyKind` in wire/sim.fbs.
enum BodyKind { rocky, star, gasGiant, moon, ice }

/// One gas in a body's atmosphere: [gas] is the AtmosphereGas enum INDEX (the
/// wire ubyte; see lib/domain/planetary/atmospheric_composition.dart) and
/// [fraction] its mole (volume) fraction, 0..1.
class GasFractionSnapshot {
  final int gas;
  final double fraction;
  const GasFractionSnapshot({required this.gas, required this.fraction});

  Map<String, dynamic> toJson() => {'g': gas, 'f': fraction};

  factory GasFractionSnapshot.fromJson(Map<String, dynamic> j) =>
      GasFractionSnapshot(
        gas: (j['g'] as num).toInt(),
        fraction: (j['f'] as num).toDouble(),
      );
}

/// STATIC per-body render descriptor — the texture/heightmap/atmosphere mapping
/// an external engine binds ONCE and caches, joined to [BodySnapshot] by [id].
/// Unlike [BodySnapshot] (dynamic transform, every tick) this is config.
///
/// The sim only ships what it authoritatively owns: the [kind] classification,
/// the [referenceRadius] datum, and the atmosphere's physical numbers (it owns
/// the air model). The asset [albedoKey]/[heightKey]/[materialKey] are forward
/// hooks — empty means "the engine derives the asset from [id]". Render-only:
/// never part of the determinism fingerprint.
class BodyDescriptorSnapshot {
  final String id;
  final BodyKind kind;
  final double referenceRadius; // m, datum a heightmap perturbs (== BodySnapshot.radius)
  final String albedoKey;
  final String heightKey;
  final String materialKey;
  final double heightScale; // m of relief at a full-white height sample
  final bool atmoPresent;
  final double atmoScaleHeight; // m
  final double atmoThickness; // m
  final double atmoSeaLevelPressure; // Pa
  final double atmoSeaLevelDensity; // kg/m^3
  final double atmoSeaLevelTemperature; // K
  // Chemical composition (from the body's AtmosphericComposition). Empty/zero
  // when the body has no composition model.
  final double atmoMeanMolecularWeight; // kg/mol, mole-fraction-weighted
  final int atmoScatterColorArgb; // packed 0xAARRGGBB haze tint from the gas mix
  final List<GasFractionSnapshot> atmoGases; // per-species mole fractions

  const BodyDescriptorSnapshot({
    required this.id,
    this.kind = BodyKind.rocky,
    required this.referenceRadius,
    this.albedoKey = '',
    this.heightKey = '',
    this.materialKey = '',
    this.heightScale = 0,
    this.atmoPresent = false,
    this.atmoScaleHeight = 0,
    this.atmoThickness = 0,
    this.atmoSeaLevelPressure = 0,
    this.atmoSeaLevelDensity = 0,
    this.atmoSeaLevelTemperature = 0,
    this.atmoMeanMolecularWeight = 0,
    this.atmoScatterColorArgb = 0,
    this.atmoGases = const [],
  });

  factory BodyDescriptorSnapshot.of(CelestialBody body, StarSystem system) {
    final atmo = body.atmosphere;
    final comp = body.composition;
    return BodyDescriptorSnapshot(
      id: body.id.value,
      kind: _classify(body, system),
      referenceRadius: body.radius,
      // Keys left empty: the sim does not own art assets — the engine derives
      // them from id. They exist so the sim CAN override per body later.
      atmoPresent: atmo != null,
      atmoScaleHeight: atmo?.scaleHeight ?? 0,
      atmoThickness: atmo?.atmosphereHeight ?? 0,
      atmoSeaLevelPressure: atmo?.seaLevelPressure ?? 0,
      atmoSeaLevelDensity: atmo?.seaLevelDensity ?? 0,
      atmoSeaLevelTemperature: atmo?.seaLevelTemperature ?? 0,
      atmoMeanMolecularWeight: comp?.meanMolecularWeight ?? 0,
      atmoScatterColorArgb: comp?.scatterColorArgb ?? 0,
      atmoGases: comp == null
          ? const []
          : [
              for (final e in comp.fractions.entries)
                GasFractionSnapshot(gas: e.key.index, fraction: e.value),
            ],
    );
  }

  static BodyKind _classify(CelestialBody body, StarSystem system) {
    if (body.isStar) return BodyKind.star;
    if (body.isGasGiant) return BodyKind.gasGiant;
    // A body whose parent is itself not a star (i.e. it orbits a planet) is a
    // moon; one orbiting the star directly is a rocky planet.
    final parent = body.parent == null ? null : system.body(body.parent!);
    if (parent != null && !parent.isStar) return BodyKind.moon;
    return BodyKind.rocky;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.index,
        'r': referenceRadius,
        if (albedoKey.isNotEmpty) 'albedo': albedoKey,
        if (heightKey.isNotEmpty) 'height': heightKey,
        if (materialKey.isNotEmpty) 'material': materialKey,
        if (heightScale != 0) 'heightScale': heightScale,
        'atmo': atmoPresent,
        if (atmoPresent) ...{
          'atmoH': atmoScaleHeight,
          'atmoTop': atmoThickness,
          'atmoP': atmoSeaLevelPressure,
          'atmoRho': atmoSeaLevelDensity,
          'atmoT': atmoSeaLevelTemperature,
          if (atmoMeanMolecularWeight != 0) 'atmoMmw': atmoMeanMolecularWeight,
          if (atmoScatterColorArgb != 0) 'atmoTint': atmoScatterColorArgb,
          if (atmoGases.isNotEmpty)
            'atmoGases': [for (final g in atmoGases) g.toJson()],
        },
      };

  factory BodyDescriptorSnapshot.fromJson(Map<String, dynamic> j) {
    final ki = (j['kind'] as num?)?.toInt() ?? 0;
    return BodyDescriptorSnapshot(
      id: j['id'] as String,
      kind: BodyKind.values[ki.clamp(0, BodyKind.values.length - 1)],
      referenceRadius: (j['r'] as num?)?.toDouble() ?? 0,
      albedoKey: (j['albedo'] as String?) ?? '',
      heightKey: (j['height'] as String?) ?? '',
      materialKey: (j['material'] as String?) ?? '',
      heightScale: (j['heightScale'] as num?)?.toDouble() ?? 0,
      atmoPresent: (j['atmo'] as bool?) ?? false,
      atmoScaleHeight: (j['atmoH'] as num?)?.toDouble() ?? 0,
      atmoThickness: (j['atmoTop'] as num?)?.toDouble() ?? 0,
      atmoSeaLevelPressure: (j['atmoP'] as num?)?.toDouble() ?? 0,
      atmoSeaLevelDensity: (j['atmoRho'] as num?)?.toDouble() ?? 0,
      atmoSeaLevelTemperature: (j['atmoT'] as num?)?.toDouble() ?? 0,
      atmoMeanMolecularWeight: (j['atmoMmw'] as num?)?.toDouble() ?? 0,
      atmoScatterColorArgb: (j['atmoTint'] as num?)?.toInt() ?? 0,
      atmoGases: [
        for (final g in (j['atmoGases'] as List?) ?? const [])
          GasFractionSnapshot.fromJson(g as Map<String, dynamic>),
      ],
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

/// A discrete sim event that fired this tick, flattened for the wire. The
/// renderer switches on [kind] and looks up [subject] in the frame for FX.
///   subject   = primary asset id (usually the vessel)
///   target    = secondary id (body / 2nd vessel / part / deposit), else ''
///   magnitude = numeric payload (speed/temp/dose/stage index/Pa), else 0
///   info      = text payload (reason/cause/situation/message), else ''
class EventSnapshot {
  final String kind;
  final String subject;
  final String target;
  final double magnitude;
  final String info;

  const EventSnapshot({
    required this.kind,
    this.subject = '',
    this.target = '',
    this.magnitude = 0,
    this.info = '',
  });

  /// Flatten a [DomainEvent] to the wire shape. Unknown types fall back to the
  /// runtime type name so the renderer at least sees that something happened.
  factory EventSnapshot.of(DomainEvent e) {
    switch (e) {
      case SoiTransition x:
        return EventSnapshot(
            kind: 'SoiTransition', subject: x.vessel.value, target: x.to.value, info: x.from.value);
      case StageSeparation x:
        return EventSnapshot(
            kind: 'StageSeparation', subject: x.vessel.value, magnitude: x.stageIndex.toDouble());
      case ApoapsisReached x:
        return EventSnapshot(kind: 'ApoapsisReached', subject: x.vessel.value);
      case AtmosphericEntry x:
        return EventSnapshot(kind: 'AtmosphericEntry', subject: x.vessel.value, target: x.body.value);
      case Impact x:
        return EventSnapshot(
            kind: 'Impact', subject: x.vessel.value, target: x.body.value, magnitude: x.speed);
      case DockingCompleted x:
        return EventSnapshot(kind: 'DockingCompleted', subject: x.a.value, target: x.b.value);
      case PartOverheated x:
        return EventSnapshot(
            kind: 'PartOverheated', subject: x.vessel.value, target: x.part.value, magnitude: x.temperature);
      case ResourceMined x:
        return EventSnapshot(
            kind: 'ResourceMined', subject: x.vessel.value, target: x.depositId, magnitude: x.amount);
      case PlanAborted x:
        return EventSnapshot(kind: 'PlanAborted', subject: x.vessel.value, info: x.reason);
      case CrewLost x:
        return EventSnapshot(kind: 'CrewLost', subject: x.vessel.value, info: x.cause);
      case CrewIrradiated x:
        return EventSnapshot(kind: 'CrewIrradiated', subject: x.vessel.value, magnitude: x.doseSv);
      case MegastructureMilestone x:
        return EventSnapshot(
            kind: 'MegastructureMilestone',
            subject: x.structureId,
            info: x.message,
            magnitude: x.completed ? 1 : 0);
      case SituationEntered x:
        return EventSnapshot(kind: 'SituationEntered', subject: x.vessel.value, info: x.situation);
      case StructuralFailure x:
        return EventSnapshot(
            kind: 'StructuralFailure', subject: x.vessel.value, magnitude: x.dynamicPressure);
      default:
        return EventSnapshot(kind: e.runtimeType.toString());
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'subject': subject,
        'target': target,
        'magnitude': magnitude,
        'info': info,
      };

  factory EventSnapshot.fromJson(Map<String, dynamic> j) => EventSnapshot(
        kind: j['kind'] as String,
        subject: (j['subject'] as String?) ?? '',
        target: (j['target'] as String?) ?? '',
        magnitude: (j['magnitude'] as num?)?.toDouble() ?? 0,
        info: (j['info'] as String?) ?? '',
      );
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

  /// STATIC per-body render config (texture/heightmap/atmosphere mapping), keyed
  /// by body id — joins to [bodies]. Render-only; excluded from [fingerprint].
  /// Shipped every frame (tiny + stateless) so a late-joining engine client
  /// always receives the catalog without a separate handshake.
  final Map<String, BodyDescriptorSnapshot> descriptors;

  /// Discrete events that fired this tick (transient; not keyed). Best-effort:
  /// a renderer that skips frames may miss some — fine for cosmetic FX/UI.
  final List<EventSnapshot> events;

  const WorldSnapshot({
    required this.tick,
    required this.vessels,
    this.epoch = 0,
    this.bodies = const {},
    this.buildings = const {},
    this.descriptors = const {},
    this.events = const [],
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
    List<EventSnapshot> events = const [],
    // Body descriptors (static render config: kind/atmosphere/composition) are
    // STICKY on the engine side — it caches + joins by id — so a publisher can
    // omit them on most frames and re-send only ~1 Hz. Pass false to skip them.
    bool includeDescriptors = true,
    // Orbit-ring resolution per body. The engine bridge passes a coarse value to
    // keep the WorldFrame small enough to reassemble; the in-app painter uses 96.
    int orbitSamples = 96,
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
                b.id.value:
                    BodySnapshot.of(b, system, ephemeris, epoch, orbitSamples: orbitSamples),
            },
      descriptors: (system == null || !includeDescriptors)
          ? const {}
          : {
              for (final b in system.all)
                b.id.value: BodyDescriptorSnapshot.of(b, system),
            },
      vessels: {
        for (final v in vessels.all())
          v.id.value: VesselSnapshot.of(v, system: system, epoch: epoch),
      },
      buildings: buildings,
      events: events,
    );
  }

  Map<String, dynamic> toJson() => {
        'tick': tick,
        'epoch': epoch,
        'bodies': [for (final b in bodies.values) b.toJson()],
        'descriptors': [for (final d in descriptors.values) d.toJson()],
        'vessels': [for (final v in vessels.values) v.toJson()],
        'buildings': [for (final b in buildings.values) b.toJson()],
        'events': [for (final e in events) e.toJson()],
      };

  factory WorldSnapshot.fromJson(Map<String, dynamic> j) {
    final bodyList = (j['bodies'] as List?) ?? const [];
    final descriptorList = (j['descriptors'] as List?) ?? const [];
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
      descriptors: {
        for (final d in descriptorList)
          (d as Map<String, dynamic>)['id'] as String:
              BodyDescriptorSnapshot.fromJson(d),
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
      events: [
        for (final e in (j['events'] as List?) ?? const [])
          EventSnapshot.fromJson(e as Map<String, dynamic>),
      ],
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
