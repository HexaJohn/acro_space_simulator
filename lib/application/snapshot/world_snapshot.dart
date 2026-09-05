// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';
import 'dart:math' as math;

import '../../domain/colony/building.dart';
import '../../domain/colony/city/city_building_spec.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/parcel.dart';
import '../../domain/colony/colony.dart';
import '../../domain/colony/surface_placement.dart';
import '../../domain/comms/comms_service.dart';
import '../../domain/megastructure/halo_ring.dart';
import '../../domain/megastructure/megastructure.dart';
import '../../domain/orbits/body_ephemeris.dart';
import '../../domain/orbits/patched_conic_service.dart';
import '../../domain/orbits/state_vector_converter.dart';
import '../../domain/orbits/trajectory_service.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/domain_event.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/terrain/dem_pyramid.dart';
import '../../domain/terrain/dem_registry.dart';
import '../../domain/terrain/terrain_brush.dart';
import '../../domain/terrain/terrain_edits.dart';
import '../../domain/terrain/terrain_feature.dart';
import '../../domain/terrain/terrain_field.dart';
import '../../domain/terrain/terrain_profile.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/universe/terrain_heights.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';
import '../ports/world_repositories.dart';

/// One part of a craft for asset binding: [type] is the asset key (the catalog
/// [PartDef] id, so it survives a display-name change) and [ox]/[oy]/[oz] is
/// the local offset in the vessel body frame (metres, Z-up).
///
/// [qw]..[qz] is the part's own orientation WITHIN that body frame (Hamilton,
/// scalar-first; identity = (1,0,0,0)), composed under the craft attitude by
/// the renderer. Radial parts — RCS blocks, legs, side boosters — are turned by
/// this rather than by a separately baked mesh per facing.
class PartSnapshot {
  final String id;
  final String type;
  final double ox, oy, oz;
  final double qw, qx, qy, qz;

  const PartSnapshot({
    required this.id,
    required this.type,
    required this.ox,
    required this.oy,
    required this.oz,
    this.qw = 1,
    this.qx = 0,
    this.qy = 0,
    this.qz = 0,
  });

  /// True when the part sits the way it was authored. Lets the wire skip the
  /// quaternion for the overwhelmingly common case.
  bool get isUnrotated => qw == 1 && qx == 0 && qy == 0 && qz == 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'o': [ox, oy, oz],
        if (!isUnrotated) 'q': [qw, qx, qy, qz],
      };

  /// Tolerant of payloads written before parts had an orientation: a missing
  /// 'q' decodes to identity, which is exactly what those parts meant.
  factory PartSnapshot.fromJson(Map<String, dynamic> j) {
    final o = (j['o'] as List).cast<num>();
    final q = (j['q'] as List?)?.cast<num>() ?? const [1, 0, 0, 0];
    return PartSnapshot(
      id: j['id'] as String,
      type: j['type'] as String,
      ox: o[0].toDouble(),
      oy: o[1].toDouble(),
      oz: o[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
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
  // True when [trajectory] is an OPEN arc truncated at a predicted SOI
  // handoff (patched conics) rather than the full closed ellipse — renderers
  // must not treat first/last as a seam or wrap fades around it.
  final bool trajectoryOpen;
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
    this.trajectoryOpen = false,
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
    var trajectoryOpen = false;
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
        // Patched conics: when the current conic runs into an SOI handoff,
        // the drawn line must STOP at the boundary (the continuation legs are
        // rendered from the presenter's patch paths) instead of tracing the
        // stale full ellipse through space the craft will never fly.
        final patches = const PatchedConicService().predict(
          position: v.state.position,
          velocity: v.state.velocity,
          body: body,
          system: system!,
          epoch: epoch,
          pointsPerPatch: 256,
        );
        if (patches.length > 1) {
          trajectory = [
            for (final p in patches.first.points) ...[p.x, p.y, p.z]
          ];
          trajectoryOpen = true;
        } else {
          final path = const TrajectoryService().predictPath(
            position: v.state.position,
            velocity: v.state.velocity,
            body: body,
            epoch: epoch,
            // 48 faceted visibly (7.5° kink per joint on the line you stare
            // at while flying); 256 keeps joints under 1.5°.
            samples: 256,
          );
          trajectory = [for (final p in path) ...[p.x, p.y, p.z]];
        }
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
            // The catalog id, not the display name — see [Part.assetKey].
            type: p.assetKey,
            ox: p.positionInVessel.x,
            oy: p.positionInVessel.y,
            oz: p.positionInVessel.z,
            qw: p.rotationInVessel.w,
            qx: p.rotationInVessel.x,
            qy: p.rotationInVessel.y,
            qz: p.rotationInVessel.z,
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
      trajectoryOpen: trajectoryOpen,
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
        'trajOpen': trajectoryOpen,
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
      trajectoryOpen: (j['trajOpen'] as bool?) ?? false,
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
    Epoch epoch,
  ) {
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
      for (final p in ephemeris.orbitPathRelativeToParent(body, system, epoch: epoch)) {
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

/// One physically-sited megastructure for the renderer: world pose + the ring
/// recipe + build progress. Only projects with a [Megastructure.site] AND a
/// physical shape cross — pure economy projects stay sim-side.
///
/// The pose is derived, not stored: a circular orbit about the parent in the
/// root frame, and spin about the structure's +Z at the spec's rate. The
/// renderer rebuilds the terrain field from the spec (same seed => same
/// surface), mirroring how `BodyDescriptorSnapshot.buildTerrainField` works
/// for planets.
class MegastructureSnapshot {
  final String id;
  final int type; // MegastructureType enum index
  final String parentBodyId;
  final double px, py, pz; // root-relative metres
  final double qw, qx, qy, qz; // Hamilton, scalar-first

  /// Build progress: completed phase count + fraction of the current phase.
  /// Together they reconstruct `HaloRingBuildState` renderer-side.
  final int completedPhases;
  final double stageFraction;

  // HaloRingSpec, flattened for the wire.
  final double ringRadiusM;
  final double bandWidthM;
  final double shellThicknessM;
  final double wallHeightM;
  final double wallThicknessM;
  final double terrainAmplitudeM;
  final double terrainFeatureScaleM;
  final int terrainOctaves;
  final int seed;
  final double spinPeriodS;

  const MegastructureSnapshot({
    required this.id,
    required this.type,
    required this.parentBodyId,
    required this.px,
    required this.py,
    required this.pz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.completedPhases,
    required this.stageFraction,
    required this.ringRadiusM,
    required this.bandWidthM,
    required this.shellThicknessM,
    required this.wallHeightM,
    required this.wallThicknessM,
    required this.terrainAmplitudeM,
    required this.terrainFeatureScaleM,
    required this.terrainOctaves,
    required this.seed,
    required this.spinPeriodS,
  });

  /// Null when the structure has no site or no physical shape yet.
  static MegastructureSnapshot? of(
    Megastructure m,
    StarSystem system,
    BodyEphemeris ephemeris,
    Epoch epoch,
  ) {
    final site = m.site;
    final spec = m.ringSpec;
    if (site == null || spec == null) return null;
    final parent = system.body(BodyId(site.parentBodyId));
    if (parent == null) return null;
    final parentRoot =
        ephemeris.positionRelativeToRoot(parent, system, epoch);
    // Circular orbit in the root XY plane. Mean motion from the parent's mu —
    // the ring is a station, not a Keplerian body, so this stays out of the
    // patched-conic machinery entirely.
    final n = math.sqrt(parent.mu /
        (site.orbitRadiusM * site.orbitRadiusM * site.orbitRadiusM));
    final theta = site.orbitPhaseRad + n * epoch.seconds;
    final pos = Vector3(
      parentRoot.x + math.cos(theta) * site.orbitRadiusM,
      parentRoot.y + math.sin(theta) * site.orbitRadiusM,
      parentRoot.z,
    );
    // Spin about the structure's +Z from t=0, tilted by the site (tilt*spin,
    // the CelestialBody convention). The skeleton "already rotating" is
    // accepted so the orientation needs no spin-start bookkeeping;
    // construction in spin reads fine at these angular rates (~1 h period).
    final spin = Quaternion.axisAngle(
        Vector3.unitZ, spec.spinAngularVelocity * epoch.seconds);
    final tilt = Quaternion.axisAngle(Vector3.unitX, site.tiltRad);
    final q = (tilt * spin).normalized;
    return MegastructureSnapshot(
      id: m.id,
      type: m.type.index,
      parentBodyId: site.parentBodyId,
      px: pos.x,
      py: pos.y,
      pz: pos.z,
      qw: q.w,
      qx: q.x,
      qy: q.y,
      qz: q.z,
      completedPhases: m.completedPhases,
      stageFraction: m.currentPhase?.fraction ?? 1.0,
      ringRadiusM: spec.radiusM,
      bandWidthM: spec.bandWidthM,
      shellThicknessM: spec.shellThicknessM,
      wallHeightM: spec.wallHeightM,
      wallThicknessM: spec.wallThicknessM,
      terrainAmplitudeM: spec.terrainAmplitudeM,
      terrainFeatureScaleM: spec.terrainFeatureScaleM,
      terrainOctaves: spec.terrainOctaves,
      seed: spec.seed,
      spinPeriodS: spec.spinPeriodS,
    );
  }

  /// The ring recipe this snapshot carries, ready to build a field.
  HaloRingSpec toRingSpec() => HaloRingSpec(
        radiusM: ringRadiusM,
        bandWidthM: bandWidthM,
        shellThicknessM: shellThicknessM,
        wallHeightM: wallHeightM,
        wallThicknessM: wallThicknessM,
        terrainAmplitudeM: terrainAmplitudeM,
        terrainFeatureScaleM: terrainFeatureScaleM,
        terrainOctaves: terrainOctaves,
        seed: seed,
        spinPeriodOverrideS: spinPeriodS,
      );

  /// Per-layer arc coverage for the construction visuals.
  HaloRingBuildState buildState() =>
      HaloRingBuildState.of(completedPhases, stageFraction);

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'parent': parentBodyId,
        'p': [px, py, pz],
        'q': [qw, qx, qy, qz],
        'phases': completedPhases,
        'frac': stageFraction,
        'ring': [
          ringRadiusM,
          bandWidthM,
          shellThicknessM,
          wallHeightM,
          wallThicknessM,
          terrainAmplitudeM,
          terrainFeatureScaleM,
        ],
        'octaves': terrainOctaves,
        'seed': seed,
        'spin': spinPeriodS,
      };

  factory MegastructureSnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    final q = (j['q'] as List).cast<num>();
    final ring = (j['ring'] as List).cast<num>();
    return MegastructureSnapshot(
      id: j['id'] as String,
      type: (j['type'] as num).toInt(),
      parentBodyId: j['parent'] as String,
      px: p[0].toDouble(),
      py: p[1].toDouble(),
      pz: p[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
      completedPhases: (j['phases'] as num).toInt(),
      stageFraction: (j['frac'] as num).toDouble(),
      ringRadiusM: ring[0].toDouble(),
      bandWidthM: ring[1].toDouble(),
      shellThicknessM: ring[2].toDouble(),
      wallHeightM: ring[3].toDouble(),
      wallThicknessM: ring[4].toDouble(),
      terrainAmplitudeM: ring[5].toDouble(),
      terrainFeatureScaleM: ring[6].toDouble(),
      terrainOctaves: (j['octaves'] as num).toInt(),
      seed: (j['seed'] as num).toInt(),
      spinPeriodS: (j['spin'] as num).toDouble(),
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

  /// Standard gravitational parameter mu = G*M (m^3/s^2), straight from the
  /// domain body. Render-side gravity effects (the spacetime grid keys its
  /// bow depth and opacity on surface gravity) derive g = mu/r^2 from this;
  /// 0 when a wire producer predates the field.
  final double mu;
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

  // Voxel terrain (render-only; the renderer rebuilds the same deterministic
  // field from these). [hasTerrain] false = a perfect sphere at referenceRadius.
  final bool hasTerrain;
  final int terrainSeed;
  final double terrainAmplitude; // m relief
  final double terrainFeatureScale; // m feature wavelength
  final double terrainSeaLevel; // m above datum
  final int terrainOctaves;
  final double terrainGrassAmount; // 0..1 vegetation cover
  final double terrainSandAmount; // 0..1 desert cover
  // Night-side ambient floor override; null = renderer derives it from the
  // atmosphere (see TerrainConfig.ambient).
  final double? terrainAmbient;

  /// Whether the body uses the erosion-aware detail layer.
  final bool terrainErodedDetail;

  /// The body's landform recipe.
  ///
  /// This has to travel. `TerrainField` is reconstructed independently on the
  /// render side, and the seed and amplitude alone do not determine the
  /// surface any more — the profile decides which features run at all. Ship
  /// only the scalars and the renderer draws plain fBm while collision resolves
  /// against eroded, cratered ground: a craft then sinks straight through the
  /// terrain on screen, chasing a surface that is drawn nowhere.
  final TerrainProfile? terrainProfile;

  /// Body id of the baked DEM replacing the procedural base relief, or null.
  /// Travels for the same reason [terrainProfile] does: the renderer rebuilds
  /// the field independently, and without this it would mesh procedural
  /// ground while collision resolves against the real map.
  final String? terrainDemBodyId;

  /// The DEM pyramid this descriptor references, from the registry (throws
  /// unregistered — the same contract as `TerrainConfig.fieldFor`).
  DemPyramid? resolveDem() =>
      terrainDemBodyId == null ? null : DemRegistry.require(terrainDemBodyId!);

  /// The composed detail layer this descriptor describes, or null for a body
  /// on the original single-fBm relief.
  ///
  /// Somewhat costly to assemble (a feature stack) — render-side callers cache
  /// it per body and hand it back through [buildTerrainField].
  TerrainDetail? buildTerrainDetail() {
    if (!terrainErodedDetail) return null;
    final dem = resolveDem();
    return (terrainProfile ?? TerrainProfile.barren).detailFor(
      seed: terrainSeed,
      radiusM: referenceRadius,
      amplitudeM: terrainAmplitude,
      featureScaleM: terrainFeatureScale,
      octaves: terrainOctaves + 1,
      control: dem == null ? null : DemDerivedControl(dem),
    );
  }

  /// The render-side [TerrainField] for this body — THE one way to rebuild it
  /// from a descriptor.
  ///
  /// MUST produce the field `CelestialBody.terrainFieldWith` builds on the sim
  /// side (test/terrain/render_sim_agreement_test.dart is the gate). Every
  /// render consumer (terrain mesher, scatter, previews) goes through here:
  /// scatter once rebuilt the field by hand, omitted [buildTerrainDetail], and
  /// seated every prop on ground the mesher never drew.
  ///
  /// Null when the body has no terrain. [detail] takes a caller's cached
  /// layer; omitted, it is built fresh.
  TerrainField? buildTerrainField({TerrainEdits? edits, TerrainDetail? detail}) {
    if (!hasTerrain) return null;
    return TerrainField(
      radius: referenceRadius,
      amplitude: terrainAmplitude,
      featureScale: terrainFeatureScale,
      seaLevel: terrainSeaLevel,
      seed: terrainSeed,
      octaves: terrainOctaves,
      edits: edits,
      dem: resolveDem(),
      detail: detail ?? buildTerrainDetail(),
    );
  }

  const BodyDescriptorSnapshot({
    required this.id,
    this.kind = BodyKind.rocky,
    required this.referenceRadius,
    this.mu = 0,
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
    this.hasTerrain = false,
    this.terrainSeed = 0,
    this.terrainAmplitude = 0,
    this.terrainFeatureScale = 0,
    this.terrainSeaLevel = 0,
    this.terrainOctaves = 5,
    this.terrainGrassAmount = 0,
    this.terrainSandAmount = 0,
    this.terrainAmbient,
    this.terrainErodedDetail = false,
    this.terrainProfile,
    this.terrainDemBodyId,
  });

  factory BodyDescriptorSnapshot.of(CelestialBody body, StarSystem system) {
    final atmo = body.atmosphere;
    final comp = body.composition;
    return BodyDescriptorSnapshot(
      id: body.id.value,
      kind: _classify(body, system),
      referenceRadius: body.radius,
      mu: body.mu,
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
      hasTerrain: body.terrain != null,
      terrainSeed: body.terrain?.seed ?? 0,
      terrainAmplitude: body.terrain?.amplitude ?? 0,
      terrainFeatureScale: body.terrain?.featureScale ?? 0,
      terrainSeaLevel: body.terrain?.seaLevel ?? 0,
      terrainOctaves: body.terrain?.octaves ?? 5,
      terrainGrassAmount: body.terrain?.grassAmount ?? 0,
      terrainSandAmount: body.terrain?.sandAmount ?? 0,
      terrainAmbient: body.terrain?.ambient,
      terrainErodedDetail: body.terrain?.erodedDetail ?? false,
      terrainProfile: body.terrain?.profile,
      terrainDemBodyId: body.terrain?.demBodyId,
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
        if (mu != 0) 'mu': mu,
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
        if (hasTerrain)
          'terrain': {
            'seed': terrainSeed,
            'amp': terrainAmplitude,
            'feat': terrainFeatureScale,
            'sea': terrainSeaLevel,
            'oct': terrainOctaves,
            'grass': terrainGrassAmount,
            'sand': terrainSandAmount,
            if (terrainAmbient != null) 'amb': terrainAmbient,
            // The generator recipe, not just its scale. Without this the
            // renderer rebuilds a DIFFERENT surface from the one physics
            // collides against — see [terrainProfile].
            if (terrainErodedDetail) 'eroded': true,
            if (terrainProfile != null) 'profile': terrainProfile!.toJson(),
            if (terrainDemBodyId != null) 'dem': terrainDemBodyId,
          },
      };

  factory BodyDescriptorSnapshot.fromJson(Map<String, dynamic> j) {
    final ki = (j['kind'] as num?)?.toInt() ?? 0;
    return BodyDescriptorSnapshot(
      id: j['id'] as String,
      kind: BodyKind.values[ki.clamp(0, BodyKind.values.length - 1)],
      referenceRadius: (j['r'] as num?)?.toDouble() ?? 0,
      mu: (j['mu'] as num?)?.toDouble() ?? 0,
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
      hasTerrain: j['terrain'] != null,
      terrainSeed: (((j['terrain'] as Map?)?['seed']) as num?)?.toInt() ?? 0,
      terrainAmplitude:
          (((j['terrain'] as Map?)?['amp']) as num?)?.toDouble() ?? 0,
      terrainFeatureScale:
          (((j['terrain'] as Map?)?['feat']) as num?)?.toDouble() ?? 0,
      terrainSeaLevel:
          (((j['terrain'] as Map?)?['sea']) as num?)?.toDouble() ?? 0,
      terrainOctaves: (((j['terrain'] as Map?)?['oct']) as num?)?.toInt() ?? 5,
      terrainGrassAmount:
          (((j['terrain'] as Map?)?['grass']) as num?)?.toDouble() ?? 0,
      terrainSandAmount:
          (((j['terrain'] as Map?)?['sand']) as num?)?.toDouble() ?? 0,
      terrainAmbient: (((j['terrain'] as Map?)?['amb']) as num?)?.toDouble(),
      terrainErodedDetail:
          (((j['terrain'] as Map?)?['eroded']) as bool?) ?? false,
      terrainProfile: ((j['terrain'] as Map?)?['profile']) == null
          ? null
          : TerrainProfile.fromJson(
              ((j['terrain'] as Map)['profile'] as Map).cast<String, dynamic>()),
      terrainDemBodyId: ((j['terrain'] as Map?)?['dem']) as String?,
    );
  }
}

/// The four strips of zoned ground left visible around a building.
///
/// A [CityPatchSnapshot] is one quad, so a ring is four of them: two spanning
/// the full width front and back, two filling the sides between. Strips of
/// zero extent are skipped, which is what happens when a building genuinely
/// does fill its plot.
void _emitYardRing(
  List<CityPatchSnapshot> out,
  CitySim city,
  Parcel parcel,
  CityBuildingSpec spec,
  CelestialBody body,
  ({Vector3 position, Quaternion orientation}) t,
  ({double width, double depth}) extent,
) {
  final foot = buildingFootprint(parcel, spec);
  final kind = switch (parcel.use) {
    ParcelUse.commercial => CityPatchSnapshot.kindCommercial,
    ParcelUse.industrial => CityPatchSnapshot.kindIndustrial,
    ParcelUse.residential => CityPatchSnapshot.kindResidential,
    _ => CityPatchSnapshot.kindSupport,
  };
  final hw = extent.width / 2, hd = extent.depth / 2;
  final fw = foot.width / 2, fd = foot.depth / 2;
  final sideW = hw - fw, endD = hd - fd;
  if (sideW <= 0.05 && endD <= 0.05) return;

  // Local offsets from the lot centre, in the lot's own east/north axes; the
  // parcel transform already carries the spin onto its street.
  final strips = <({double e, double n, double w, double d})>[
    if (endD > 0.05) (e: 0, n: -(fd + endD / 2), w: extent.width, d: endD),
    if (endD > 0.05) (e: 0, n: fd + endD / 2, w: extent.width, d: endD),
    if (sideW > 0.05)
      (e: -(fw + sideW / 2), n: 0, w: sideW, d: foot.depth),
    if (sideW > 0.05) (e: fw + sideW / 2, n: 0, w: sideW, d: foot.depth),
  ];
  for (final s in strips) {
    // Offset in the lot's frame, then back out to body-fixed.
    final off = t.orientation.rotate(Vector3(s.e, s.n, 0));
    final p = t.position + off;
    out.add(CityPatchSnapshot(
      colonyId: city.id,
      body: body.id.value,
      px: p.x,
      py: p.y,
      pz: p.z,
      qw: t.orientation.w,
      qx: t.orientation.x,
      qy: t.orientation.y,
      qz: t.orientation.z,
      sizeM: s.w,
      depthM: s.d,
      kind: kind,
    ));
  }
}

/// The footprint a building takes on [parcel], metres.
///
/// One rule, because two things need the same answer: the building itself, and
/// the ring of ZONED GROUND drawn around it. Compute them separately and the
/// yard either overlaps the walls or leaves a gap of bare terrain.
({double width, double depth}) buildingFootprint(
    Parcel parcel, CityBuildingSpec spec) {
  final extent = parcel.inscribedExtent;
  final back = lotSetbackFor(spec);
  final cover = lotCoverageFor(spec);
  final lotW = math.max((extent.width - 2 * back) * cover, extent.width * 0.35);
  final lotD = math.max((extent.depth - 2 * back) * cover, extent.depth * 0.35);
  return (
    width: spec.siteWidthM > 0 ? math.min(lotW, spec.siteWidthM) : lotW,
    depth: spec.siteDepthM > 0 ? math.min(lotD, spec.siteDepthM) : lotD,
  );
}

/// Smallest setback from a lot line, metres.
///
/// Wider than `CityTerrainShaper.padEdgeM`, which is what makes it work: the
/// pad is flat right out to the lot line and eases off over that edge, so a
/// building inset past the ease-off stands wholly on level ground. Nothing may
/// be inset less than this or it starts straddling the step to the terrace
/// next door.
/// Road-drape ground sampling stride, in units of the 6 m spline samples.
///
/// Four steps is 24 m, which is `CityTerrainShaper`'s own corridor grading
/// spacing — see the drape loop for why matching it exactly is the point.
const int _roadGroundStride = 4;

const double kLotSetbackM = 1.2;

/// Setback for [spec], metres.
///
/// Density decides how much of its plot a building takes. A tower downtown
/// meets the pavement and leaves no slack; a low-density house sits back
/// behind a garden. Every building used the SAME setback before, so a dense
/// street had the same gaps as a suburban one and the whole colony read at one
/// density however it was zoned.
///
/// Intensity — residents plus workers per building — is the density signal a
/// spec actually carries; `Density` itself does not survive onto the spec.
double lotSetbackFor(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  if (intensity >= 90) return kLotSetbackM; // towers meet the street
  if (intensity >= 30) return 2.2;
  return 4.0; // detached, with room around it
}

/// Share of its plot [spec] covers, once set back.
///
/// The other half of the same idea: a dense block fills what it is given, a
/// low-density one leaves garden around the footprint.
double lotCoverageFor(CityBuildingSpec spec) {
  final intensity = spec.housing + spec.jobs;
  if (intensity >= 90) return 0.96;
  if (intensity >= 30) return 0.86;
  return 0.72;
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

  /// Real site size in metres, and what kind of site it is.
  ///
  /// Carried on the WIRE rather than looked up client-side because a renderer
  /// must be able to build a colony from a frame alone — it has no access to
  /// the authoritative `CitySim`, and a networked client never will.
  final double siteWidthM, siteDepthM;
  final int siteKindIndex;

  /// This building stands on a CORNER — its lot touches a second street.
  ///
  /// On the frame rather than derived at the renderer because the plat is the
  /// only place that knows it: by the time a building reaches the frame it is
  /// a position and a footprint, and which of its walls faces a street is
  /// unrecoverable from those. A corner building is a genuinely different
  /// building — two public faces, no blank flank, entrance on the chamfer —
  /// so this also has to reach the archetype key.
  final bool corner;

  /// Palette colour, so a client tints facades without a spec table.
  final int colorArgb;

  const BuildingSnapshot({
    this.corner = false,
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
    this.siteWidthM = 24,
    this.siteDepthM = 24,
    this.siteKindIndex = 0,
    this.colorArgb = 0xFF9E9E9E,
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

  /// Place a building on a PARCEL.
  ///
  /// The lot supplies everything: where it stands, how big it is, and which
  /// way it faces. Facing is a rotation about the local up by the parcel's
  /// heading, so the building turns to its street rather than to the grid's
  /// idea of north.
  factory BuildingSnapshot.ofParcel(
    CitySim city,
    Parcel parcel,
    CityBuildingSpec spec,
    CelestialBody body, {
    required double siteRadiusM,
  }) {
    final t = _parcelTransform(city, parcel, siteRadiusM);
    final dir = t.position.normalized;
    // Stand the building INSIDE its own terrace.
    //
    // The shaper levels each lot to its own datum and stops at the lot line,
    // because abutting lots at different heights cannot both be flat and blend
    // into one another — the ground steps at the boundary, the way a graded
    // hillside does. A building filling its lot edge to edge therefore
    // straddles that step: flush at the centre, hanging 6 m in the air at the
    // corner nearest the lower neighbour. A setback wider than the terrace
    // edge puts every corner on its own flat ground.
    // ...and capped by the building's own DECLARED site, where it has one. A
    // lot is a plot of land, not a size: a structure dropped on a generous lot
    // was drawn to fill it, so buildings that state their own extent came out
    // far larger than they are. Specs that state nothing keep taking the lot,
    // which is the parcel-native sizing the grid never allowed.
    final foot = buildingFootprint(parcel, spec);
    final w = foot.width, d = foot.depth;
    return BuildingSnapshot(
      id: parcel.id,
      type: spec.type,
      colonyId: city.id,
      body: body.id.value,
      px: t.position.x,
      py: t.position.y,
      pz: t.position.z,
      qw: t.orientation.w,
      qx: t.orientation.x,
      qy: t.orientation.y,
      qz: t.orientation.z,
      lat: math.asin(dir.z.clamp(-1.0, 1.0)),
      lon: math.atan2(dir.y, dir.x),
      siteWidthM: w,
      siteDepthM: d,
      siteKindIndex: spec.siteKind.index,
      colorArgb: spec.colorArgb,
      corner: parcel.isCorner,
    );
  }

  /// Place one CITY-BUILDER cell. The city's grid is centred on the colony
  /// site, so cell offsets are measured from the middle of the map — without
  /// the recentre the whole city would sit off to the north-east of the lat/lon
  /// it was founded at, and the lander (hub) would not be under the pad.
  factory BuildingSnapshot.ofCityCell(
    CitySim city,
    int cell,
    CityBuildingSpec spec,
    CelestialBody body,
    SurfacePlacement placement,
    TerrainHeights terrain, {
    /// Ground radius under the colony. Defaults to the body's datum for the
    /// callers that have no terrain field to sample.
    double? siteRadiusM,
  }) {
    final radius = siteRadiusM ?? body.radius;
    final half = city.grid / 2.0;
    final gx = (cell % city.grid) - half;
    final gy = (cell ~/ city.grid) - half;
    final lat = city.cityLat * math.pi / 180.0;
    final lon = city.cityLon * math.pi / 180.0;
    final base = placement.building(
      radius: radius,
      lat: lat,
      lon: lon,
      gridX: gx.round(),
      gridY: gy.round(),
      cell: CitySim.cellM,
    );
    // Recover the TRUE spherical lat/lon of the placed point so the terrain
    // cache is keyed off where the building actually is (see the colony path).
    final dir = base.position.normalized;
    final trueLat = math.asin(dir.z.clamp(-1.0, 1.0));
    final trueLon = math.atan2(dir.y, dir.x);
    final elevation = terrain.heightAt(body.id, trueLat, trueLon);
    final t = placement.building(
      radius: radius,
      lat: lat,
      lon: lon,
      gridX: gx.round(),
      gridY: gy.round(),
      cell: CitySim.cellM,
      elevation: elevation,
    );
    return BuildingSnapshot(
      id: '$cell',
      type: spec.type,
      colonyId: city.id,
      body: body.id.value,
      px: t.position.x,
      py: t.position.y,
      pz: t.position.z,
      qw: t.orientation.w,
      qx: t.orientation.x,
      qy: t.orientation.y,
      qz: t.orientation.z,
      lat: trueLat,
      lon: trueLon,
      siteWidthM: spec.siteMetres(cellM: CitySim.cellM).width,
      siteDepthM: spec.siteMetres(cellM: CitySim.cellM).depth,
      siteKindIndex: spec.siteKind.index,
      colorArgb: spec.colorArgb,
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
        'sw': siteWidthM,
        'sd': siteDepthM,
        'sk': siteKindIndex,
        'c': colorArgb,
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
      siteWidthM: (j['sw'] as num?)?.toDouble() ?? 24,
      siteDepthM: (j['sd'] as num?)?.toDouble() ?? 24,
      siteKindIndex: (j['sk'] as num?)?.toInt() ?? 0,
      colorArgb: (j['c'] as num?)?.toInt() ?? 0xFF9E9E9E,
    );
  }
}

/// Surface transform of a parcel: its centroid, turned to face its street.
({Vector3 position, Quaternion orientation}) _parcelTransform(
  CitySim city,
  Parcel parcel,
  double siteRadiusM, [
  SurfacePlacement placement = const SurfacePlacement(),
]) {
  final c = parcel.centroid;
  final base = placement.place(
    radius: siteRadiusM,
    lat: city.cityLat * math.pi / 180.0,
    lon: city.cityLon * math.pi / 180.0,
    east: c.e,
    north: c.n,
  );
  // place() gives local +X east, +Y north, +Z up. A parcel's heading is
  // measured from north toward east, and a building is authored facing +Y, so
  // the spin about up is the NEGATIVE of that heading.
  final spin = Quaternion.axisAngle(Vector3.unitZ, -parcel.heading);
  return (position: base.position, orientation: base.orientation * spin);
}

/// A flat patch of colony ground: a road tile, a zoned-but-not-yet-built lot,
/// or a support platform.
///
/// Without these a freshly zoned colony renders as empty ground — the frame
/// only ever carried BUILDINGS, and a zone holds nothing until it grows. From
/// the cockpit that reads as the editor being broken rather than as a city
/// waiting to be built.
class CityPatchSnapshot {
  /// What the patch is. Index into the renderer's ground palette, so a client
  /// needs no spec table to colour it.
  static const int kindRoad = 0;
  static const int kindResidential = 1;
  static const int kindCommercial = 2;
  static const int kindIndustrial = 3;
  static const int kindSupport = 4;

  final String colonyId;
  final String body;
  final double px, py, pz;
  final double qw, qx, qy, qz;

  /// Extent in metres, along the patch's own east (width) and north (depth)
  /// axes. Grid cells are square; parcels are not.
  final double sizeM;
  final double depthM;
  final int kind;

  const CityPatchSnapshot({
    required this.colonyId,
    required this.body,
    required this.px,
    required this.py,
    required this.pz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.sizeM,
    required this.kind,
    double? depthM,
  }) : depthM = depthM ?? sizeM;

  Map<String, dynamic> toJson() => {
        'colony': colonyId,
        'body': body,
        'p': [px, py, pz],
        'q': [qw, qx, qy, qz],
        's': sizeM,
        'd': depthM,
        'k': kind,
      };

  factory CityPatchSnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    final q = (j['q'] as List).cast<num>();
    return CityPatchSnapshot(
      colonyId: j['colony'] as String,
      body: j['body'] as String,
      px: p[0].toDouble(),
      py: p[1].toDouble(),
      pz: p[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
      sizeM: (j['s'] as num).toDouble(),
      depthM: (j['d'] as num?)?.toDouble(),
      kind: (j['k'] as num).toInt(),
    );
  }
}

/// A colony road, flattened for the wire.
///
/// Sampled centreline points in BODY-FIXED metres rather than the spline's
/// control points: the client would otherwise have to re-run the same
/// Catmull-Rom to know where the tarmac is, and any difference between the two
/// implementations would put the road somewhere the buildings are not.
class RoadSnapshot {
  final String colonyId;
  final String body;

  /// Flattened x,y,z triples, body-fixed metres.
  final List<double> points;

  /// Carriageway half-width, metres.
  final double halfWidthM;

  /// Index into RoadClass.values — drives lamp spacing and column height.
  final int roadClassIndex;

  /// Built in unbreathable air: pedestrians travel in a sealed pressurised
  /// tube along the verge instead of on an open pavement.
  final bool sealed;

  /// Built with sound barriers along both edges.
  final bool soundWalls;

  /// A subdivision's collector: where two meet, the crossing is a
  /// roundabout.
  final bool collector;

  /// Flattened start,end pairs of arc length along the road that ride a
  /// bridge, and the half width at either end where the road tapers (null:
  /// its class's own).
  final List<double> bridges;
  final double? startHalfWidthM;
  final double? endHalfWidthM;

  const RoadSnapshot({
    required this.colonyId,
    required this.body,
    required this.points,
    required this.halfWidthM,
    required this.roadClassIndex,
    this.sealed = false,
    this.soundWalls = false,
    this.collector = false,
    this.bridges = const [],
    this.startHalfWidthM,
    this.endHalfWidthM,
  });

  Map<String, dynamic> toJson() => {
        'colony': colonyId,
        'body': body,
        'pts': points,
        'hw': halfWidthM,
        'cls': roadClassIndex,
        if (sealed) 'sealed': true,
        if (soundWalls) 'walls': true,
        if (collector) 'collector': true,
        if (bridges.isNotEmpty) 'br': bridges,
        if (startHalfWidthM != null) 'hw0': startHalfWidthM,
        if (endHalfWidthM != null) 'hw1': endHalfWidthM,
      };

  factory RoadSnapshot.fromJson(Map<String, dynamic> j) => RoadSnapshot(
        colonyId: j['colony'] as String,
        body: j['body'] as String,
        points: Float64List.fromList([
          for (final n in (j['pts'] as List?) ?? const []) (n as num).toDouble()
        ]),
        halfWidthM: (j['hw'] as num).toDouble(),
        roadClassIndex: (j['cls'] as num?)?.toInt() ?? 0,
        sealed: j['sealed'] == true,
        soundWalls: j['walls'] == true,
        collector: j['collector'] == true,
        bridges: Float64List.fromList([
          for (final v in (j['br'] as List?) ?? const []) (v as num).toDouble()
        ]),
        startHalfWidthM: (j['hw0'] as num?)?.toDouble(),
        endHalfWidthM: (j['hw1'] as num?)?.toDouble(),
      );
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

  /// Event site, when the event has one (all zero otherwise). For 'Impact'
  /// this is the BODY-FIXED contact point in metres from [target]'s centre —
  /// the frame terrain edits live in — so FX anchored here co-rotate with the
  /// planet.
  final double px, py, pz;

  /// Spatial extent of the event site in metres, 0 when the event has none.
  /// For 'Impact' this is the crater rim radius, so FX scale with the hole.
  final double size;

  const EventSnapshot({
    required this.kind,
    this.subject = '',
    this.target = '',
    this.magnitude = 0,
    this.info = '',
    this.px = 0,
    this.py = 0,
    this.pz = 0,
    this.size = 0,
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
            kind: 'Impact',
            subject: x.vessel.value,
            target: x.body.value,
            magnitude: x.speed,
            px: x.contactBF.x,
            py: x.contactBF.y,
            pz: x.contactBF.z,
            size: x.craterRadiusM);
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
        if (px != 0 || py != 0 || pz != 0) ...{'px': px, 'py': py, 'pz': pz},
        if (size != 0) 'size': size,
      };

  factory EventSnapshot.fromJson(Map<String, dynamic> j) => EventSnapshot(
        kind: j['kind'] as String,
        subject: (j['subject'] as String?) ?? '',
        target: (j['target'] as String?) ?? '',
        magnitude: (j['magnitude'] as num?)?.toDouble() ?? 0,
        info: (j['info'] as String?) ?? '',
        px: (j['px'] as num?)?.toDouble() ?? 0,
        py: (j['py'] as num?)?.toDouble() ?? 0,
        pz: (j['pz'] as num?)?.toDouble() ?? 0,
        size: (j['size'] as num?)?.toDouble() ?? 0,
      );
}

/// One terrain deformation, in the body-fixed frame.
///
/// Contrast [BodyDescriptorSnapshot], which is static render config excluded
/// from the fingerprint: these edits MOVE THE COLLISION SURFACE, so they are
/// authoritative simulation state. They are replicated in application order and
/// hashed into [WorldSnapshot.fingerprint] — a client whose edit list has
/// drifted would otherwise land craft on ground the server does not have.
class TerrainEditSnapshot {
  const TerrainEditSnapshot({
    required this.body,
    required this.kind,
    required this.cx,
    required this.cy,
    required this.cz,
    required this.ax,
    required this.ay,
    required this.az,
    required this.radius,
    this.depth = 0,
    this.rimHeight = 0,
    this.tick = 0,
    this.datumRadius = 0,
    this.datumRadiusEnd = 0,
    this.falloff = 0,
    this.benches = 1,
    this.ex,
    this.ey,
    this.ez,
    this.polygon = const [],
    this.minVoxel = 0,
  });

  /// Body id — joins to [WorldSnapshot.bodies].
  final String body;

  /// Index into [TerrainBrushKind.values].
  final int kind;

  /// Body-fixed centre (m).
  final double cx, cy, cz;

  /// Body-fixed orientation axis (surface normal at contact).
  final double ax, ay, az;

  final double radius;
  final double depth;
  final double rimHeight;
  final int tick;

  // ---- Levelling brushes (pad / steppedPit / cutFill) -------------------
  //
  // These arrived after this snapshot did, and it was never widened for them,
  // so every one of their defining fields was dropped in transit. The physics
  // reads brushes straight from the edit store and saw them intact; the
  // RENDERER rebuilds them from here and did not. A pad reached the mesher
  // with a target radius of zero and a road with no far end at all — which
  // `cutFill` answers by doing nothing — so the drawn ground kept its raw
  // relief while everything standing on it was placed at the levelled height.
  // That is the floating/clipping: two different surfaces, both "correct".

  /// Target surface radius the brush levels to (m from the body centre).
  final double datumRadius;

  /// Target radius at the FAR end of a graded corridor.
  final double datumRadiusEnd;

  /// Width of the ring easing the edit back into natural ground (m).
  final double falloff;

  /// Terrace count for a stepped pit.
  final int benches;

  /// Body-fixed far end of a corridor brush; null for the radial kinds.
  final double? ex, ey, ez;

  /// Footprint outline of a polygon pad, flattened x,y,z per vertex. Empty for
  /// every other kind. A lot is a polygon, so its pad has to be one too, and a
  /// pad that reaches the mesher without its outline levels nothing.
  final List<double> polygon;

  /// Coarsest voxel (m) the brush is content to be meshed at; 0 derives it
  /// from the radius. Render config, not surface state — the analytic field
  /// is identical at any resolution — so it is deliberately NOT hashed into
  /// [WorldSnapshot.fingerprint].
  final double minVoxel;

  static TerrainEditSnapshot of(BodyId body, TerrainBrush b) =>
      TerrainEditSnapshot(
        body: body.value,
        kind: b.kind.index,
        cx: b.centreBF.x,
        cy: b.centreBF.y,
        cz: b.centreBF.z,
        ax: b.axisBF.x,
        ay: b.axisBF.y,
        az: b.axisBF.z,
        radius: b.radiusM,
        depth: b.depthM,
        rimHeight: b.rimHeightM,
        tick: b.tick,
        datumRadius: b.datumRadiusM,
        datumRadiusEnd: b.datumRadiusEndM,
        falloff: b.falloffM,
        benches: b.benches,
        minVoxel: b.minVoxelM,
        ex: b.endBF?.x,
        ey: b.endBF?.y,
        ez: b.endBF?.z,
        polygon: [
          for (final v in b.polygonBF) ...[v.x, v.y, v.z]
        ],
      );

  /// Rebuild the domain brush. Round-trips [of] exactly — INCLUDING the
  /// levelling fields, without which a pad or a graded corridor arrives inert.
  TerrainBrush toBrush() => TerrainBrush(
        kind:
            TerrainBrushKind.values[kind.clamp(0, TerrainBrushKind.values.length - 1)],
        centreBF: Vector3(cx, cy, cz),
        axisBF: Vector3(ax, ay, az),
        radiusM: radius,
        depthM: depth,
        rimHeightM: rimHeight,
        tick: tick,
        datumRadiusM: datumRadius,
        datumRadiusEndM: datumRadiusEnd,
        falloffM: falloff,
        benches: benches,
        minVoxelM: minVoxel,
        endBF: ex == null || ey == null || ez == null
            ? null
            : Vector3(ex!, ey!, ez!),
        polygonBF: [
          for (var i = 0; i + 2 < polygon.length; i += 3)
            Vector3(polygon[i], polygon[i + 1], polygon[i + 2])
        ],
      );

  Map<String, dynamic> toJson() => {
        'body': body,
        'kind': kind,
        'c': [cx, cy, cz],
        'a': [ax, ay, az],
        'r': radius,
        if (depth != 0) 'd': depth,
        if (rimHeight != 0) 'rim': rimHeight,
        'tick': tick,
        if (datumRadius != 0) 'dr': datumRadius,
        if (datumRadiusEnd != 0) 'dre': datumRadiusEnd,
        if (falloff != 0) 'f': falloff,
        if (benches != 1) 'b': benches,
        if (minVoxel != 0) 'mv': minVoxel,
        if (ex != null) 'e': [ex, ey, ez],
        if (polygon.isNotEmpty) 'poly': polygon,
      };

  factory TerrainEditSnapshot.fromJson(Map<String, dynamic> j) {
    final c = (j['c'] as List?) ?? const [0, 0, 0];
    final a = (j['a'] as List?) ?? const [0, 0, 1];
    final e = j['e'] as List?;
    return TerrainEditSnapshot(
      body: j['body'] as String,
      kind: (j['kind'] as num?)?.toInt() ?? 0,
      cx: (c[0] as num).toDouble(),
      cy: (c[1] as num).toDouble(),
      cz: (c[2] as num).toDouble(),
      ax: (a[0] as num).toDouble(),
      ay: (a[1] as num).toDouble(),
      az: (a[2] as num).toDouble(),
      radius: (j['r'] as num?)?.toDouble() ?? 0,
      depth: (j['d'] as num?)?.toDouble() ?? 0,
      rimHeight: (j['rim'] as num?)?.toDouble() ?? 0,
      tick: (j['tick'] as num?)?.toInt() ?? 0,
      datumRadius: (j['dr'] as num?)?.toDouble() ?? 0,
      datumRadiusEnd: (j['dre'] as num?)?.toDouble() ?? 0,
      falloff: (j['f'] as num?)?.toDouble() ?? 0,
      benches: (j['b'] as num?)?.toInt() ?? 1,
      minVoxel: (j['mv'] as num?)?.toDouble() ?? 0,
      ex: e == null ? null : (e[0] as num).toDouble(),
      ey: e == null ? null : (e[1] as num).toDouble(),
      ez: e == null ? null : (e[2] as num).toDouble(),
      polygon: [
        for (final v in (j['poly'] as List?) ?? const []) (v as num).toDouble()
      ],
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

  /// Colony roads. A separate list rather than a field on the colony because
  /// the renderer consumes them on their own — road ribbons and street lamps
  /// are drawn from these without any building being involved.
  final List<RoadSnapshot> roads;

  /// Ground patches: roads, zoned lots, support platforms.
  final List<CityPatchSnapshot> patches;

  /// STATIC per-body render config (texture/heightmap/atmosphere mapping), keyed
  /// by body id — joins to [bodies]. Render-only; excluded from [fingerprint].
  /// Shipped every frame (tiny + stateless) so a late-joining engine client
  /// always receives the catalog without a separate handshake.
  final Map<String, BodyDescriptorSnapshot> descriptors;

  /// Discrete events that fired this tick (transient; not keyed). Best-effort:
  /// a renderer that skips frames may miss some — fine for cosmetic FX/UI.
  final List<EventSnapshot> events;

  /// Terrain deformations, in application order. Authoritative state, NOT
  /// render config: they move the collision surface, so they are hashed into
  /// [fingerprint] and a client must replay them in exactly this order.
  ///
  /// Sent in full every frame while the list is short. Once bodies accumulate
  /// real history this wants an incremental channel keyed on the store's
  /// version rather than a full resend.
  final List<TerrainEditSnapshot> terrainEdits;

  /// Physically-sited megastructures (halo rings, so far): world pose + build
  /// progress + shape recipe. NOT in [bodies] on purpose — a near-massless
  /// ring must never enter the patched-conic machinery (SOI scans, rails
  /// conversion) or be drawn as a textured sphere.
  final List<MegastructureSnapshot> megastructures;


  const WorldSnapshot({
    required this.tick,
    required this.vessels,
    this.epoch = 0,
    this.bodies = const {},
    this.buildings = const {},
    this.roads = const [],
    this.patches = const [],
    this.descriptors = const {},
    this.events = const [],
    this.terrainEdits = const [],
    this.megastructures = const [],
  });

  /// The same frame at a different sim time.
  ///
  /// For a viewer that wants a STATIC world to keep moving — the city studio
  /// holds one captured colony and advances only the clock, so the traffic
  /// pass (which derives vehicle positions from [epoch]) animates without the
  /// cost of re-capturing a frame that has not changed. The collections are
  /// shared, not copied.
  WorldSnapshot copyWithEpoch(double newEpoch) => WorldSnapshot(
        tick: tick,
        vessels: vessels,
        epoch: newEpoch,
        bodies: bodies,
        buildings: buildings,
        roads: roads,
        patches: patches,
        descriptors: descriptors,
        events: events,
        terrainEdits: terrainEdits,
        megastructures: megastructures,
      );

  /// The deformations for [bodyId], rebuilt as a domain store ready to hand to
  /// `CelestialBody.terrainFieldWith`. Null when the body is pristine, which
  /// keeps the untouched path on the analytic fast path.
  TerrainEdits? editsForBody(String bodyId) {
    List<TerrainBrush>? brushes;
    for (final e in terrainEdits) {
      if (e.body == bodyId) (brushes ??= []).add(e.toBrush());
    }
    return brushes == null ? null : TerrainEdits.of(brushes);
  }

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
    CityRepository? cities,
    TerrainHeights? terrain,
    TerrainEditsRepository? terrainEdits,
    MegastructureRepository? megastructures,
    SurfacePlacement placement = const SurfacePlacement(),
    List<EventSnapshot> events = const [],
    // Body descriptors (static render config: kind/atmosphere/composition) are
    // STICKY on the engine side — it caches + joins by id — so a publisher can
    // omit them on most frames and re-send only ~1 Hz. Pass false to skip them.
    bool includeDescriptors = true,
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
    final roads = <RoadSnapshot>[];
    final patches = <CityPatchSnapshot>[];
    // City-builder colonies. Their cells are placed on the same tangent grid as
    // the legacy colonies, but centred on the colony site rather than running
    // out from it, so the lander (the hub, at the middle cell) sits on the
    // configured lat/lon instead of a corner of the map.
    if (system != null && cities != null) {
      for (final city in cities.all()) {
        final body = system.body(city.body.id);
        if (body == null) continue;
        // Radius of the REAL ground at the colony site, not the datum sphere.
        // On a body with kilometres of relief the datum is underground as
        // often as not, and a colony placed on it disappears into the hill it
        // was built on. One sample for the whole site is right rather than
        // merely cheap: the terrain shaper LEVELS the site to this radius, so
        // every pad in the colony really is at this height.
        final siteDirBF = () {
          final lat = city.cityLat * math.pi / 180.0;
          final lon = city.cityLon * math.pi / 180.0;
          return Vector3(math.cos(lat) * math.cos(lon),
              math.cos(lat) * math.sin(lon), math.sin(lat));
        }();
        final field = body.terrainFieldWith(terrainEdits?.forBody(body.id));
        final siteRadius = field == null
            ? body.radius
            : field.groundRadiusAt(siteDirBF.x, siteDirBF.y, siteDirBF.z);

        // The shaper just changed the ground? Every cached height is stale.
        if (city.groundCacheStamp != city.shapedTerrain.length) {
          city.groundCache.clear();
          city.groundCacheStamp = city.shapedTerrain.length;
        }

        /// Ground radius under a parcel-city feature, cached by key. Sampled
        /// WITH the terrain edits, so geometry reads the pad that was levelled
        /// for it — sampling the pristine field would re-open the exact gap
        /// the shaper closed.
        double groundFor(String key, Vec2 local) {
          if (field == null) return siteRadius;
          return city.groundCache.putIfAbsent(key, () {
            final dir = city
                .localToBodyFixed(local, bodyRadiusM: siteRadius)
                .normalized;
            return field.groundRadiusAt(dir.x, dir.y, dir.z);
          });
        }

        /// Ground radius under one CELL, so the colony drapes over the
        /// landscape instead of hovering on a disc cut at the site's own
        /// height. Cached on the colony: the shaper levels each pad to the
        /// first value sampled here, and re-sampling afterwards would read
        /// back the pad it just cut.
        double radiusOf(int cell) {
          if (field == null) return siteRadius;
          return city.cellGroundRadius.putIfAbsent(cell, () {
            final half = city.grid / 2.0;
            final probe = placement.building(
              radius: siteRadius,
              lat: city.cityLat * math.pi / 180.0,
              lon: city.cityLon * math.pi / 180.0,
              gridX: ((cell % city.grid) - half).round(),
              gridY: ((cell ~/ city.grid) - half).round(),
              cell: CitySim.cellM,
            );
            final d = probe.position.normalized;
            return field.groundRadiusAt(d.x, d.y, d.z);
          });
        }
        for (final road in city.layout.roads) {
          final pts = road.sample(stepM: 6);
          if (pts.length < 2) continue;
          // Each point at ITS OWN ground: a road crossing a slope follows the
          // corridor graded for it, instead of holding the site's height and
          // floating off (or tunnelling into) the hillside.
          //
          // The ground is sampled every [_roadGroundStride] points — 24 m,
          // which is EXACTLY the spacing `CityTerrainShaper` grades a corridor
          // at — and interpolated between. That is not an approximation: the
          // shaper lays one cut-fill brush per 24 m and the graded ground
          // under a road is therefore piecewise-linear at that spacing
          // already, so sampling it finer resolves nothing that is there.
          //
          // It matters a great deal. A ground query on a colony site marches
          // radially through every brush covering the point, and in a built
          // city that is 8 ms EACH; the drape was asking for one every 6 m of
          // every road. On a four-block colony — 435 roads once alleys and
          // elevated lines are counted — that was 43 s of the 46 s a generate
          // took, all of it after the progress bar had finished.
          final radii = List<double>.filled(pts.length, 0);
          final last = pts.length - 1;
          for (var i = 0; i <= last; i += _roadGroundStride) {
            radii[i] = groundFor('road:${road.id}:$i', pts[i]);
          }
          if (last % _roadGroundStride != 0) {
            radii[last] = groundFor('road:${road.id}:$last', pts[last]);
          }
          for (var i = 1; i < last; i++) {
            if (i % _roadGroundStride == 0) continue;
            final a = (i ~/ _roadGroundStride) * _roadGroundStride;
            final b = math.min(a + _roadGroundStride, last);
            radii[i] = b == a
                ? radii[a]
                : radii[a] + (radii[b] - radii[a]) * ((i - a) / (b - a));
          }
          final flat = <double>[];
          for (var i = 0; i <= last; i++) {
            final bf = city.localToBodyFixed(pts[i], bodyRadiusM: radii[i]);
            flat.addAll([bf.x, bf.y, bf.z]);
          }
          // Typed, not a growable list of boxed doubles: fifty thousand
          // roads' points were 5.8 million heap objects for the collector
          // to mark on every old-generation pass, and the pauses that
          // marking finished with landed in the frame. A Float64List IS a
          // List<double> to every reader.
          roads.add(RoadSnapshot(
            colonyId: city.id,
            body: body.id.value,
            points: Float64List.fromList(flat),
            halfWidthM: road.halfWidth,
            roadClassIndex: road.roadClass.index,
            sealed: road.sealed,
            soundWalls: road.soundWalls,
            collector: road.collector,
            bridges: Float64List.fromList([
              for (final (a, b) in road.bridges) ...[a, b]
            ]),
            startHalfWidthM: road.startHalfWidthM,
            endHalfWidthM: road.endHalfWidthM,
          ));
        }
        // Roads, zoned-but-unbuilt lots and support platforms. These are what
        // the player has actually placed a moment after founding, so leaving
        // them out is what made a new colony look like nothing happened.
        void patch(int cell, int kind) {
          final half = city.grid / 2.0;
          final t = placement.building(
            radius: radiusOf(cell),
            lat: city.cityLat * math.pi / 180.0,
            lon: city.cityLon * math.pi / 180.0,
            gridX: ((cell % city.grid) - half).round(),
            gridY: ((cell ~/ city.grid) - half).round(),
            cell: CitySim.cellM,
          );
          patches.add(CityPatchSnapshot(
            colonyId: city.id,
            body: body.id.value,
            px: t.position.x,
            py: t.position.y,
            pz: t.position.z,
            qw: t.orientation.w,
            qx: t.orientation.x,
            qy: t.orientation.y,
            qz: t.orientation.z,
            sizeM: CitySim.cellM,
            kind: kind,
          ));
        }

        for (final cell in city.roads) {
          patch(cell, CityPatchSnapshot.kindRoad);
        }
        for (final cell in city.support) {
          patch(cell, CityPatchSnapshot.kindSupport);
        }
        for (final e in city.zones.entries) {
          // A grown lot is drawn as a building instead.
          if (city.grown.contains(e.key)) continue;
          patch(
            e.key,
            switch (e.value.kind) {
              'commercial' => CityPatchSnapshot.kindCommercial,
              'industrial' => CityPatchSnapshot.kindIndustrial,
              _ => CityPatchSnapshot.kindResidential,
            },
          );
        }
        // Buildings placed on PARCELS. Position, facing and size all come from
        // the lot, so a building on a subdivided street lot stands at that
        // lot's real width and turns to face its road — which is the whole
        // reason parcels exist.
        for (final (parcel, spec) in city.parcelBuiltLots()) {
          buildings['${city.id}/${parcel.id}'] = BuildingSnapshot.ofParcel(
            city,
            parcel,
            spec,
            body,
            siteRadiusM:
                groundFor('lot:${parcel.id}', parcel.centroid),
          );
        }
        // Empty lots, drawn so the subdivision is visible before anything is
        // built on it.
        for (final parcel in city.layout.parcels) {
          // A built lot draws its zone as a RING around the building, not as
          // a quad under it.
          //
          // Setback and coverage scale with density, so a building covers only
          // the middle of its plot and the yard around it was bare terrain
          // whatever the lot was zoned — no gardens, no forecourts, no works
          // aprons. A full-lot patch would fix that and z-fight the building
          // against its own ground, which is what the old guard prevented; a
          // ring paints exactly the visible part and never goes underneath.
          final builtSpec = city.parcelBuildings[parcel.id] ??
              city.parcelGrownSpec(parcel.id, parcel.use);
          final t = _parcelTransform(
              city, parcel, groundFor('lot:${parcel.id}', parcel.centroid));
          final extent = parcel.buildableExtent;
          if (builtSpec != null) {
            _emitYardRing(patches, city, parcel, builtSpec, body, t, extent);
            continue;
          }
          patches.add(CityPatchSnapshot(
            colonyId: city.id,
            body: body.id.value,
            px: t.position.x,
            py: t.position.y,
            pz: t.position.z,
            qw: t.orientation.w,
            qx: t.orientation.x,
            qy: t.orientation.y,
            qz: t.orientation.z,
            sizeM: extent.width,
            depthM: extent.depth,
            kind: switch (parcel.use) {
              ParcelUse.commercial => CityPatchSnapshot.kindCommercial,
              ParcelUse.industrial => CityPatchSnapshot.kindIndustrial,
              ParcelUse.residential => CityPatchSnapshot.kindResidential,
              _ => CityPatchSnapshot.kindSupport,
            },
          ));
        }
        for (final e in city.occupiedCells()) {
          buildings['${city.id}/${e.key}'] = BuildingSnapshot.ofCityCell(
            city,
            e.key,
            e.value,
            body,
            placement,
            heights,
            siteRadiusM: radiusOf(e.key),
          );
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
      roads: roads,
      patches: patches,
      events: events,
      terrainEdits: terrainEdits == null
          ? const []
          : [
              // Bodies in a stable order, each body's edits in application
              // order — the snapshot has to be reproducible for the
              // fingerprint to mean anything.
              for (final entry in terrainEdits.all().toList()
                ..sort((x, y) => x.key.value.compareTo(y.key.value)))
                for (final b in entry.value.all)
                  TerrainEditSnapshot.of(entry.key, b),
            ],
      megastructures: (megastructures == null || system == null)
          ? const []
          : [
              for (final m in megastructures.all())
                ?MegastructureSnapshot.of(m, system, ephemeris, epoch),
            ],
    );
  }

  Map<String, dynamic> toJson() => {
        'tick': tick,
        'epoch': epoch,
        'bodies': [for (final b in bodies.values) b.toJson()],
        'descriptors': [for (final d in descriptors.values) d.toJson()],
        'vessels': [for (final v in vessels.values) v.toJson()],
        'buildings': [for (final b in buildings.values) b.toJson()],
        'roads': [for (final r in roads) r.toJson()],
        'patches': [for (final p in patches) p.toJson()],
        'events': [for (final e in events) e.toJson()],
        if (terrainEdits.isNotEmpty)
          'terrainEdits': [for (final e in terrainEdits) e.toJson()],
        if (megastructures.isNotEmpty)
          'megastructures': [for (final m in megastructures) m.toJson()],
      };

  factory WorldSnapshot.fromJson(Map<String, dynamic> j) {
    final bodyList = (j['bodies'] as List?) ?? const [];
    final descriptorList = (j['descriptors'] as List?) ?? const [];
    final vesselList = (j['vessels'] as List?) ?? const [];
    final buildingList = (j['buildings'] as List?) ?? const [];
    final roadList = (j['roads'] as List?) ?? const [];
    final patchList = (j['patches'] as List?) ?? const [];
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
      roads: [
        for (final r in roadList)
          RoadSnapshot.fromJson(r as Map<String, dynamic>),
      ],
      patches: [
        for (final p in patchList)
          CityPatchSnapshot.fromJson(p as Map<String, dynamic>),
      ],
      buildings: {
        for (final b in buildingList)
          '${(b as Map<String, dynamic>)['colony']}/${b['id']}':
              BuildingSnapshot.fromJson(b),
      },
      events: [
        for (final e in (j['events'] as List?) ?? const [])
          EventSnapshot.fromJson(e as Map<String, dynamic>),
      ],
      terrainEdits: [
        for (final e in (j['terrainEdits'] as List?) ?? const [])
          TerrainEditSnapshot.fromJson(e as Map<String, dynamic>),
      ],
      megastructures: [
        for (final m in (j['megastructures'] as List?) ?? const [])
          MegastructureSnapshot.fromJson(m as Map<String, dynamic>),
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
    // Terrain deformation. Unlike the render descriptors, these MOVE THE
    // COLLISION SURFACE — two runs that disagree about a crater will disagree
    // about where a craft touches down — so divergence has to be caught here.
    // Hashed in application order, because the brushes compose by SDF min/max
    // and a reordered list is a different surface, not the same one shuffled.
    if (terrainEdits.isNotEmpty) {
      buf.write('#');
      for (final e in terrainEdits) {
        buf
          ..write(e.body)
          ..write(':')
          ..write(e.kind)
          ..write(':')
          ..write(_q(e.cx))
          ..write(',')
          ..write(_q(e.cy))
          ..write(',')
          ..write(_q(e.cz))
          ..write('|')
          ..write(_q(e.radius))
          ..write(',')
          ..write(_q(e.depth))
          ..write(',')
          ..write(_q(e.rimHeight))
          ..write(';');
      }
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
