// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';
import 'dart:math' as math;

import '../../domain/colony/building.dart';
import '../../domain/colony/city/city_building_spec.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/city_terrain_shaper.dart';
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
import 'city_patch_columns.dart';
import 'city_traffic_frame.dart';
import 'traffic_capture.dart';

// The patch classes live in their own file (the columns are a fair amount of
// code) but are part of the frame's vocabulary, so they come with it.
export 'city_patch_columns.dart'
    show CityPatchSnapshot, CityPatchColumns, CityPatchColumnsBuilder;
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
/// Road-drape ground sampling stride, in units of the 6 m spline samples,
/// for a road that is not a plain graded corridor: one that follows the
/// land, or the ground under a deck. Not the corridor's knots — `sample`
/// rounds each span up to whole steps, so the two spacings drift apart —
/// which is why a graded road is draped from its corridor instead
/// ([_drapeRoad], [CityTerrainShaper.corridorGround]).
const int _roadGroundStride = 4;

/// The corridor a graded road was cut to, read back for its drape. The
/// shaper the world tick grades with (`AdvanceSimulationTick.cityShaper`),
/// at its defaults.
const CityTerrainShaper _roadCorridor = CityTerrainShaper();

/// How far (m) a graded road's drawn line may leave its corridor between
/// two of its points before a point is drawn between them
/// ([_followCorridor]) — well inside the ribbon's lift over the ground.
const double _drapeChordTolM = 0.03;

/// Where along a span [_followCorridor] asks the corridor whether the
/// straight line between its ends holds: a quarter, half and three quarters
/// along. The middle alone missed a ledge off it — a two-lane's ground
/// 0.16 m over the line a quarter of the way along a span whose middle
/// was on it.
const List<double> _drapeProbeFractions = [0.25, 0.5, 0.75];

/// How many times [_followCorridor] may halve a span: a 6 m span down to
/// 0.19 m. A ledge's bend grows with the grade into it (about half the
/// grade per metre, per metre), and a street climbing off a levelled lot's
/// step at 100% or more needs spans of a few tenths of a metre to stay
/// within [_drapeChordTolM] of it.
const int _drapeBisections = 5;

/// Points [_followCorridor] may add to a road, per 6 m point it was given,
/// its knots aside: what a road cut through relief may cost to draw. The
/// worst spans are split first.
const int _drapePointsPerSample = 4;

/// A road's drape: its points — [samples], its 6 m points, and for a plain
/// graded corridor as many between them as the corridor's bends need
/// ([_followCorridor]) — and the ground radius under each, asked of the
/// ground through [groundFor] (held by key) as few times as it can be.
/// [dirOf] is the unit body-fixed direction [groundFor] asks along; [edits]
/// the body's edit store.
///
/// Never a ground query per point. A query on a colony site marches
/// radially through every brush covering the point, and in a built city
/// that was 8 ms EACH; the drape asking for one every 6 m of every road was
/// 43 s of the 46 s a four-block colony (435 roads once alleys and elevated
/// lines are counted) took to generate, all of it after the progress bar
/// had finished.
///
/// Its `dirs` are the directions of the points, 3 per point, for a road
/// whose drape depends on which brushes can reach them (a corridor already
/// cut: see below) — what a brush laid later is checked against to know
/// whether this drape still holds — or null for one that depends only on
/// its keys.
({List<Vec2> pts, Float64List radii, Float64List? dirs}) _drapeRoad(
    CitySim city,
    RoadSpline road,
    List<Vec2> samples,
    TerrainEdits? edits,
    double corridorScale,
    Vector3 Function(Vec2 local) dirOf,
    double Function(String key, Vec2 local) groundFor) {
  WorldSnapshot.roadDrapesComputed++;
  final laid = road.graded && road.deck == null
      ? road.sample(stepM: CityTerrainShaper.corridorStepM)
      : const <Vec2>[];
  // The corridor's knots where the shaper laid them, in this frame's
  // plane. The shaper places a local point on the tangent plane at the
  // body's DATUM radius (the `bodyRadiusM` its callers hand it) and this
  // frame on the plane at the site's ground: the same metres east and north
  // are two directions, and on a site kilometres above its datum they are
  // metres apart a few kilometres out — a trunk road's corridor 1.9 m
  // further out than the frame took it, 4 km from the site. Carried across
  // by [corridorScale], the ratio of the two planes' radii.
  final knots = corridorScale == 1.0
      ? laid
      : [for (final k in laid) k * corridorScale];
  if (knots.length >= 2) {
    // A plain graded corridor. The ground under it IS the corridor the
    // shaper cut — a straight grade per segment between its knots, eased
    // into the next — so it is read back by the corridor's own rules, from
    // the datums each segment was cut to ([CitySim.corridorDatums]).
    // Not from the ground at the knots once cut: on a curve the next
    // segment's easing reaches back over a knot and pulls it off its own
    // segment's line. Nor from every fourth 6 m point: `sample` rounds each
    // span up to whole steps, so a 64.5 m road is graded every 21.5 m and
    // drawn every 5.9 m, and that drew a re-laid street metres in and out
    // of the hill it was graded through.
    final m = knots.length - 1;
    final hw = road.halfWidth.toStringAsFixed(2);
    final datumStart = Float64List(m), datumEnd = Float64List(m);
    var cut = true;
    // Whether any segment was cut to be meshed finer than the colony's
    // ground, by the shaper's own judgement ([CitySim.fineCorridors]): that
    // ground shows the corridor's bends, and the road must follow them
    // ([_followCorridor]). Those segments were cut with a square start
    // (`TerrainBrush.squareStart`). Not by the voxel they asked for: a
    // shaper whose colony voxel is set finer (the city studio's slider)
    // cuts every street at it, and those streets are not fine.
    var fine = false;
    final square = List<bool>.filled(m, false);
    for (var j = 0; j < m; j++) {
      // The shaper's own key for the segment (`CityTerrainShaper.pending`).
      final key = 'road:${road.id}:$hw:${j + 1}';
      final datums = city.corridorDatums[key];
      if (datums != null) {
        datumStart[j] = datums.$1;
        datumEnd[j] = datums.$2;
        if (city.fineCorridors.contains(key)) square[j] = fine = true;
      } else {
        assert(
            !city.shapedTerrain.contains(key),
            '$key is recorded as shaped but not the datums it was cut to: '
            'record what CityTerrainShaper.pending returns with '
            'CityTerrainShaper.markShaped, not shapedTerrain.add');
        // Not cut yet: the ground at its knots, which is what the shaper
        // will measure when it cuts it — the road is drawn where its
        // corridor is about to be.
        cut = false;
        datumStart[j] = groundFor('road:${road.id}:k$j', knots[j]);
        datumEnd[j] = groundFor('road:${road.id}:k${j + 1}', knots[j + 1]);
      }
    }
    if (!cut && city.shapedTerrain.isNotEmpty) {
      // Nor whether the shaper will cut it fine — which it judges on the
      // ground as it stands, so the same judgement here draws the road on
      // the corridor it is about to be cut to: a fine one starts each
      // segment square, and drawn round the frame it was laid a re-laid
      // one-way stood 1.55 m off the ground it was cut to the frame after.
      // Asked of the ground only for a road laid into a colony already
      // graded: one founded in one call is judged on pristine ground, where
      // its streets are never fine, and a town of them is not asked five
      // points a segment before its first grading.
      for (final i in _roadCorridor.fineSegmentsAhead(
          city,
          road,
          (p) => groundFor(
              'road:${road.id}:f${p.e.toStringAsFixed(3)},'
              '${p.n.toStringAsFixed(3)}',
              p * corridorScale))) {
        square[i - 1] = fine = true;
      }
    }
    final fineSegs = fine ? square : null;
    // The vertical curve each segment cut fine meets the one before it with
    // (`TerrainBrush.curveHalfM`): as its brush was cut, or as the shaper
    // will cut it.
    List<(double, double)?>? curves;
    if (fine) {
      curves = List<(double, double)?>.filled(m, null);
      for (var j = 1; j < m; j++) {
        if (!square[j]) continue;
        final key = 'road:${road.id}:$hw:${j + 1}';
        if (city.corridorDatums.containsKey(key)) {
          curves[j] = city.corridorCurves[key];
          continue;
        }
        final c = _roadCorridor.corridorCurve(
            knots[j - 1],
            knots[j],
            knots[j + 1],
            datumStart[j - 1],
            datumEnd[j - 1],
            datumStart[j],
            datumEnd[j],
            road.halfWidth);
        if (c != null) curves[j] = (c.inGrade, c.halfM);
      }
    }
    final pts = fine
        ? _followCorridor(samples, knots, datumStart, datumEnd,
            road.halfWidth, square, curves)
        : samples;
    final last = pts.length - 1;
    final radii = Float64List(pts.length);
    _roadCorridor.corridorGround(
        pts, knots, datumStart, datumEnd, road.halfWidth, radii,
        fine: fineSegs, curves: curves);
    if (!cut || edits == null) return (pts: pts, radii: radii, dirs: null);
    // Once cut, the corridor is exact where nothing has been laid over it
    // since, and the ground is asked, point by point, only where something
    // has: a crossing or joining road's corridor recorded after this one
    // — every road is split where another meets it, so theirs eases over
    // the end of this one, a local step of up to a metre that no line
    // between knots follows — a crater, a drill's quantum, a lot's pad.
    final dirs = Float64List(3 * pts.length);
    final at = List<Vector3>.generate(pts.length, (i) {
      final d = dirOf(pts[i]);
      dirs[3 * i] = d.x;
      dirs[3 * i + 1] = d.y;
      dirs[3 * i + 2] = d.z;
      return d;
    });
    final over = _laidOver(road, knots.map(dirOf).toList(), datumStart,
        datumEnd, fineSegs, at, edits);
    if (over.isEmpty) return (pts: pts, radii: radii, dirs: dirs);
    final asked = List<bool>.filled(pts.length, false);
    for (final b in over) {
      for (var i = 0; i <= last; i++) {
        if (asked[i] || !b.canMoveGroundAlong(at[i])) continue;
        asked[i] = true;
        radii[i] = groundFor('road:${road.id}:p$i', pts[i]);
      }
    }
    return (pts: pts, radii: radii, dirs: dirs);
  }
  // Natural ground (a road that follows the land), or the ground under a
  // raised or sunk road, which is drawn at its deck by the lifts over this
  // drape: sampled every [_roadGroundStride] points and interpolated
  // between.
  final pts = samples;
  final last = pts.length - 1;
  final radii = Float64List(pts.length);
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
  return (pts: pts, radii: radii, dirs: null);
}

/// [pts], a graded road's 6 m points in order, with the knots either side
/// of each segment cut fine among them ([_withKnots]), and a point added
/// halfway along each span where the corridor leaves the straight line
/// between its ends by more than [_drapeChordTolM] at any of
/// [_drapeProbeFractions] — and again in each half so split,
/// [_drapeBisections] times at most, worst first, within
/// [_drapePointsPerSample] added per point given.
///
/// The knots because the grade turns there: where a segment cut fine starts
/// level (`TerrainBrush.squareStart` with no vertical curve — where the road
/// bends), the one before it meets the knot level and the ground leaves it
/// at the next grade, a corner no line between points either side of it
/// follows — a curved one-way was drawn 1.37 m in its own ground across
/// one. Where it starts in a vertical curve the knot is the curve's middle.
///
/// The road is drawn as straight lines between its points, and its
/// corridor is not straight between them: where a road climbs into a knot
/// the next segment's end cap holds the knot's datum flat for its half
/// width before it and eases in over the falloff, a ledge the grade runs
/// into. Drawn every 6 m the line cut under it — a re-laid one-way rising
/// 23% was drawn 0.95 m in its own ground, grass across it for five metres
/// though every point sat on the ground within centimetres.
///
/// Only for a corridor cut to be meshed finer than the colony's ground
/// (`CityTerrainShaper.corridorReliefTolM`): at the colony's voxel the
/// ground cannot show a ledge a few metres long — the starter streets cut
/// 0.26 m under theirs every 6 m and read clean — and every other street
/// keeps its 6 m points, and so the tiles it is drawn in. [fine]: which of
/// its segments were cut fine (`CityTerrainShaper.corridorGround`).
List<Vec2> _followCorridor(
    List<Vec2> pts,
    List<Vec2> knots,
    Float64List datumStart,
    Float64List datumEnd,
    double halfWidthM,
    List<bool> fine,
    List<(double, double)?>? curves) {
  var cur = _withKnots(pts, knots, fine);
  final budget = cur.length + _drapePointsPerSample * pts.length;
  const probes = _drapeProbeFractions;
  // Whether the span from cur[i] to cur[i + 1] is still to be tested, and
  // how many times it has been halved.
  var open = List<bool>.filled(math.max(0, cur.length - 1), true);
  var depth = List<int>.filled(open.length, 0);
  while (true) {
    // Every point, in order — the corridor finds each point's segment by
    // searching on from the last one's — each followed by the probes of
    // its span if that is still to be tested.
    final q = <Vec2>[];
    final at = List<int>.filled(cur.length, 0);
    for (var i = 0; i < cur.length; i++) {
      at[i] = q.length;
      q.add(cur[i]);
      if (i < open.length && open[i]) {
        final a = cur[i], run = cur[i + 1] - cur[i];
        for (final f in probes) {
          q.add(a + run * f);
        }
      }
    }
    if (q.length == cur.length) break;
    final r = Float64List(q.length);
    _roadCorridor.corridorGround(
        q, knots, datumStart, datumEnd, halfWidthM, r,
        fine: fine, curves: curves);
    // The spans whose corridor leaves their line, by how far.
    final off = <(int, double)>[];
    for (var i = 0; i < open.length; i++) {
      if (!open[i] || depth[i] >= _drapeBisections) continue;
      final ra = r[at[i]], rb = r[at[i + 1]];
      var worst = 0.0;
      for (var k = 0; k < probes.length; k++) {
        worst = math.max(
            worst, (r[at[i] + 1 + k] - (ra + (rb - ra) * probes[k])).abs());
      }
      if (worst > _drapeChordTolM) off.add((i, worst));
    }
    if (off.isEmpty || cur.length >= budget) break;
    off.sort((x, y) => y.$2.compareTo(x.$2));
    final split = {
      for (final (i, _) in off.take(budget - cur.length)) i,
    };
    final next = <Vec2>[];
    final nextOpen = <bool>[];
    final nextDepth = <int>[];
    for (var i = 0; i < cur.length; i++) {
      next.add(cur[i]);
      if (i == cur.length - 1) break;
      if (split.contains(i)) {
        // Halved: both halves are tested again.
        next.add((cur[i] + cur[i + 1]) * 0.5);
        nextOpen
          ..add(true)
          ..add(true);
        nextDepth
          ..add(depth[i] + 1)
          ..add(depth[i] + 1);
      } else {
        nextOpen.add(false);
        nextDepth.add(depth[i]);
      }
    }
    cur = next;
    open = nextOpen;
    depth = nextDepth;
  }
  return cur;
}

/// [pts], a road's points in order, with each interior knot of [knots]
/// either side of which a segment was cut fine ([fine]) put in among them
/// where it falls along the road: after the point whose span to the next
/// it lies along (the nearest, searched on from the last knot's — the
/// knots are in order too). A knot within 5 cm of a point is left out: that
/// point is it, near enough.
///
/// The knots lie on the road's own line — `road.sample` at the corridor's
/// step — carried into the frame's plane ([_drapeRoad]'s corridorScale),
/// millimetres off it for a road the player lays near the site.
List<Vec2> _withKnots(List<Vec2> pts, List<Vec2> knots, List<bool> fine) {
  final m = knots.length - 1;
  if (pts.length < 2 || m < 2) return pts;
  // Squared distance from [p] to span [s], and where along it.
  (double, double) along(Vec2 p, int s) {
    final a = pts[s], run = pts[s + 1] - pts[s];
    final len2 = run.e * run.e + run.n * run.n;
    var t = len2 <= 1e-12
        ? 0.0
        : ((p.e - a.e) * run.e + (p.n - a.n) * run.n) / len2;
    t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    final ce = a.e + run.e * t - p.e, cn = a.n + run.n * t - p.n;
    return (ce * ce + cn * cn, t);
  }

  // The knots to put in, by the span they fall along.
  final bySpan = <int, List<Vec2>>{};
  var s = 0;
  for (var k = 1; k < m; k++) {
    if (!fine[k - 1] && !fine[k]) continue;
    final p = knots[k];
    while (s < pts.length - 2 && along(p, s + 1).$1 <= along(p, s).$1) {
      s++;
    }
    final (_, t) = along(p, s);
    final len = pts[s].distanceTo(pts[s + 1]);
    if (t * len < 0.05 || (1 - t) * len < 0.05) continue;
    (bySpan[s] ??= []).add(p);
  }
  if (bySpan.isEmpty) return pts;
  return [
    for (var i = 0; i < pts.length; i++) ...[
      pts[i],
      ...?bySpan[i],
    ],
  ];
}

/// The brushes laid over a road's cut corridor since it was cut: each brush
/// in [edits] that the index finds along one of the road's points ([at],
/// unit directions) and that stands, in the order the brushes compose, after
/// the first of the corridor's own.
///
/// Its own are its segments' cut-and-fills, known by their width (a
/// segment cut fine — [fine] — is levelled wider:
/// `CityTerrainShaper.fineCoreM`), the datums the shaper cut them to
/// ([datumStart], [datumEnd], segment j from knot j to knot j + 1) and where
/// they end ([knotDirs]). What came before them does not show on the road:
/// its own segment levels the ground under its centreline outright. Where
/// none of its own is found — its brushes are not in this store — every
/// brush found is taken as laid over it.
List<TerrainBrush> _laidOver(
    RoadSpline road,
    List<Vector3> knotDirs,
    Float64List datumStart,
    Float64List datumEnd,
    List<bool>? fine,
    List<Vector3> at,
    TerrainEdits edits) {
  final fineCore = _roadCorridor.fineCoreM(road.halfWidth);
  bool own(TerrainBrush b) {
    if (b.kind != TerrainBrushKind.cutFill) return false;
    final end = b.endBF;
    if (end == null) return false;
    for (var j = 0; j < datumStart.length; j++) {
      if (b.datumRadiusM != datumStart[j] || b.datumRadiusEndM != datumEnd[j]) {
        continue;
      }
      if (b.radiusM !=
          (fine != null && fine[j] ? fineCore : road.halfWidth)) {
        continue;
      }
      // The same datums on another road (two levelled to one pad) are told
      // apart by where the brush ends: at this segment's far knot.
      final off = end - knotDirs[j + 1] * end.dot(knotDirs[j + 1]);
      if (off.lengthSquared < 1.0) return true;
    }
    return false;
  }

  final ords = edits.ordinalsAt(at);
  var firstOwn = -1;
  final others = <int>[];
  for (final o in ords) {
    if (own(edits.brushAt(o))) {
      if (firstOwn < 0) firstOwn = o;
    } else {
      others.add(o);
    }
  }
  return [
    for (final o in others)
      if (o > firstOwn) edits.brushAt(o),
  ];
}

/// How far from its site, in metres across the ground, a colony keeps
/// anything the snapshot holds the ground under — a road, a lot, a
/// junction — with [_colonyReachMarginM] for a road's width, its
/// corridor's easing and a spline's swing past its controls.
double _colonyReachM(CitySim city) {
  var r2 = 0.0;
  void see(Vec2 p) {
    final d = p.e * p.e + p.n * p.n;
    if (d > r2) r2 = d;
  }

  for (final road in city.layout.roads) {
    for (final c in road.controls) {
      see(c);
    }
  }
  for (final parcel in city.layout.parcels) {
    for (final v in parcel.polygon) {
      see(v);
    }
  }
  for (final o in city.junctionOverrides.values) {
    see(o.at);
  }
  return math.sqrt(r2) + _colonyReachMarginM;
}

const double _colonyReachMarginM = 100;

/// Whether [brush] can move the ground anywhere within [reachRad] (radians,
/// seen from the body's centre) of a colony's site direction [siteDirBF].
///
/// A ground query marches out along a ray from the body's centre, and a
/// brush changes nothing outside its bounding sphere: a sphere centred at
/// `c` meets a ray at angle θ from `c` only where `|c|·sin θ` is within its
/// radius (and never past a right angle — the ray runs away from it).
bool _brushReachesColony(
    TerrainBrush brush, Vector3 siteDirBF, double reachRad) {
  final c = brush.centreBF;
  final cLen = c.length;
  if (cLen <= 1e-9) return true;
  final cosA = (c.dot(siteDirBF) / cLen).clamp(-1.0, 1.0);
  final off = math.acos(cosA) - reachRad;
  if (off <= 0) return true;
  if (off >= math.pi / 2) return false;
  return cLen * math.sin(off) <= brush.boundingRadiusM + 1;
}

/// Forget what [brush], newly laid within a colony's reach, can move: each
/// ground height [city] holds along a ray the brush can move the ground on
/// ([TerrainBrush.canMoveGroundAlong]), the drape of any road that height
/// was asked for, and the drape of any road whose points it can reach —
/// a corridor already cut asks the ground only at the points something
/// was laid over, and the brush is now one. Everything else holds.
void _forgetGroundUnder(CitySim city, TerrainBrush brush) {
  final lost = <String>[
    for (final e in city.groundCache.entries)
      if (brush.canMoveGroundAlong(e.value.dir)) e.key,
  ];
  for (final key in lost) {
    city.groundCache.remove(key);
    // 'road:<id>:…' — road ids hold no colon.
    if (key.startsWith('road:')) {
      final end = key.indexOf(':', 5);
      city.drapeCache.remove(end < 0 ? key.substring(5) : key.substring(5, end));
    }
  }
  city.drapeCache.removeWhere((_, drape) {
    final dirs = drape.dirs;
    if (dirs == null) return false;
    for (var k = 0; k + 2 < dirs.length; k += 3) {
      if (brush.canMoveGroundAlong(Vector3(dirs[k], dirs[k + 1], dirs[k + 2]))) {
        return true;
      }
    }
    return false;
  });
}

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

  /// The road's id in its colony's layout: what the road tool's overlays
  /// and the renderer's instant edited-road path map a drawn road back to.
  /// Travels on the frame, never into the tile columns (a string per road
  /// would cost every tile's pack).
  final String? id;

  /// `RoadDecoration.index`: decorative grass or trees (0 = plain).
  final int decoration;

  /// Deck above the drape, metres, one per point: the road tool's raised
  /// and sunk roads. EMPTY for a road that follows the ground. Below
  /// `-RoadElevation.tunnelCoverM` the road is in a tunnel.
  final List<double> lifts;

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
    this.id,
    this.decoration = 0,
    this.lifts = const [],
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
        if (id != null) 'id': id,
        if (decoration != 0) 'deco': decoration,
        if (lifts.isNotEmpty) 'lift': lifts,
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
        id: j['id'] as String?,
        decoration: (j['deco'] as num?)?.toInt() ?? 0,
        lifts: Float64List.fromList([
          for (final v in (j['lift'] as List?) ?? const []) (v as num).toDouble()
        ]),
      );
}

/// A player's override of one junction, flattened for the wire: the
/// junction's place on the ground, body-fixed, and what the player said.
///
/// Keyed by PLACE, as the domain's `JunctionOverride` is — road ids change
/// every time a road is split, a junction's place does not — so a renderer
/// matches it to the junction its road ends make within
/// `JunctionOverride.matchM` of [px], [py], [pz]. A stop leg is named by a
/// point [stopReachM] out along it rather than by the domain's heading: a
/// heading is measured in the colony's local frame, which the frame does
/// not carry, and a point on the leg is what a renderer holding road ends
/// can compare with.
class JunctionSnapshot {
  const JunctionSnapshot({
    required this.colonyId,
    required this.body,
    required this.px,
    required this.py,
    required this.pz,
    this.lights = -1,
    this.stopPoints = const [],
    this.stopsSet = false,
  });

  final String colonyId;
  final String body;

  /// The junction on the ground, body-fixed metres.
  final double px, py, pz;

  /// Lights forced on (1), forced off (0), or left to the warrant (-1).
  final int lights;

  /// Flattened x,y,z triples, body-fixed: a point [stopReachM] out along
  /// each leg the player made stop, at the junction's own ground height.
  final List<double> stopPoints;

  /// Whether the player chose the stop legs at all. Clear, the junction
  /// keeps the warrant's default stop legs; set with no [stopPoints], no
  /// leg stops — which an empty list alone could not say.
  final bool stopsSet;

  /// How far out along a leg its stop point is: past the junction's own
  /// spread (its ends meet within a few metres), well inside the block.
  static const double stopReachM = 12.0;

  Map<String, dynamic> toJson() => {
        'colony': colonyId,
        'body': body,
        'p': [px, py, pz],
        if (lights != -1) 'lights': lights,
        // Present — even empty — exactly when the player chose the stops.
        if (stopsSet) 'stops': stopPoints,
      };

  factory JunctionSnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List?) ?? const [];
    double at(int i) => i < p.length ? (p[i] as num).toDouble() : 0.0;
    final stops = j['stops'] as List?;
    return JunctionSnapshot(
      colonyId: j['colony'] as String? ?? '',
      body: j['body'] as String? ?? '',
      px: at(0),
      py: at(1),
      pz: at(2),
      lights: (j['lights'] as num?)?.toInt() ?? -1,
      stopPoints: Float64List.fromList([
        for (final v in stops ?? const []) (v as num).toDouble()
      ]),
      stopsSet: stops != null,
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
    this.squareStart = false,
    this.curveInGrade = 0,
    this.curveHalf = 0,
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

  /// Whether a corridor brush ends square behind its start
  /// ([TerrainBrush.squareStart]) — the shape of the ground, so carried like
  /// the datums, or the renderer meshes a different corridor from the one
  /// the road is draped on.
  final bool squareStart;

  /// The vertical curve a square-started corridor meets the grade before it
  /// with ([TerrainBrush.curveInGrade], [TerrainBrush.curveHalfM]; a half
  /// length of 0 is none) — the shape of the ground, carried like
  /// [squareStart].
  final double curveInGrade, curveHalf;

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
        squareStart: b.squareStart,
        curveInGrade: b.curveInGrade,
        curveHalf: b.curveHalfM,
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
        squareStart: squareStart,
        curveInGrade: curveInGrade,
        curveHalfM: curveHalf,
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
        if (squareStart) 'sq': true,
        if (curveHalf != 0) 'vc': [curveInGrade, curveHalf],
        if (ex != null) 'e': [ex, ey, ez],
        if (polygon.isNotEmpty) 'poly': polygon,
      };

  factory TerrainEditSnapshot.fromJson(Map<String, dynamic> j) {
    final c = (j['c'] as List?) ?? const [0, 0, 0];
    final a = (j['a'] as List?) ?? const [0, 0, 1];
    final e = j['e'] as List?;
    final vc = j['vc'] as List?;
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
      squareStart: j['sq'] == true,
      curveInGrade: vc == null ? 0 : (vc[0] as num).toDouble(),
      curveHalf: vc == null ? 0 : (vc[1] as num).toDouble(),
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
  /// Work [WorldSnapshot.capture] does for a colony's ground, counted for
  /// tests and profiling: ground queries made — each a march through every
  /// brush at the point, milliseconds in a built colony — and road drapes
  /// worked out. A frame in which nothing changed adds to neither.
  static int groundQueries = 0;
  static int roadDrapesComputed = 0;

  final int tick;
  final double epoch;
  final Map<String, BodySnapshot> bodies;
  final Map<String, VesselSnapshot> vessels;
  final Map<String, BuildingSnapshot> buildings;

  /// Colony roads. A separate list rather than a field on the colony because
  /// the renderer consumes them on their own — road ribbons and street lamps
  /// are drawn from these without any building being involved.
  final List<RoadSnapshot> roads;

  /// Ground patches: roads, zoned lots, support platforms. Columns, not a
  /// list of objects: on a big colony they outnumber everything else in the
  /// frame put together, and as objects they were the bulk of what every
  /// old-generation collection had to walk (see `city_patch_columns.dart`).
  /// Iterable, so a reader that wants patches as objects still gets them —
  /// transiently.
  final CityPatchColumns patches;

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

  /// Per colony id, how often its road network's CONTENT has changed (see
  /// `CitySim.roadsRevision`): a road laid, split, upgraded, reversed,
  /// renamed or re-routed, a junction overridden. What a renderer keys its
  /// road work on — an in-place edit keeps every count the frame has, and a
  /// renderer that re-cut its tiles only when a count moved went on drawing
  /// an upgraded road as what it had been.
  final Map<String, int> roadsRevision;

  /// The players' junction overrides, every colony's (see
  /// [JunctionSnapshot]).
  final List<JunctionSnapshot> junctions;

  /// Every agent colony's traffic (docs/plans/agent-traffic.md §13.1): its
  /// vehicles' latest columns and the geometry they are drawn on, all by
  /// reference. Empty for a colony without agents, and in every frame not
  /// captured from a ticking colony — the studios', the wire codec's.
  /// Transient: not serialised, since a JSON frame is not a save.
  final List<CityTrafficFrame> cityTraffic;

  // Not const: the empty patch columns are typed lists, which have no const
  // form, and nothing constructs a frame as a constant.
  WorldSnapshot({
    required this.tick,
    required this.vessels,
    this.epoch = 0,
    this.bodies = const {},
    this.buildings = const {},
    this.roads = const [],
    CityPatchColumns? patches,
    this.descriptors = const {},
    this.events = const [],
    this.terrainEdits = const [],
    this.megastructures = const [],
    this.roadsRevision = const {},
    this.junctions = const [],
    this.cityTraffic = const [],
  }) : patches = patches ?? CityPatchColumns.empty;

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
        roadsRevision: roadsRevision,
        junctions: junctions,
        cityTraffic: cityTraffic,
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
    final cityTraffic = <CityTrafficFrame>[];
    final junctions = <JunctionSnapshot>[];
    final roadsRevision = <String, int>{};
    final patches = CityPatchColumnsBuilder();
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
        final edits = terrainEdits?.forBody(body.id);
        final field = body.terrainFieldWith(edits);

        // The ground under the colony changed? The shaper settling
        // something may have moved it anywhere, and so may a store replaced
        // or cut back (a load, a replicated rebuild): every cached height is
        // stale. Otherwise a brush laid on the body since forgets only what
        // it can move. Any brush anywhere — a crater on the far side of the
        // body, a quarry's pit elsewhere — cleared the whole cache, and so
        // did one that did reach the colony: a hand drill's quantum on a
        // street, 0.25 m of ground, cost a generated colony's next frame
        // 1,578 ground queries and two seconds.
        final editCount = edits?.length ?? 0;
        final groundStale =
            city.groundCacheShaped != city.shapedTerrain.length ||
                !identical(city.groundCacheEditStore, edits) ||
                editCount < city.groundCacheEditCount;
        if (groundStale) {
          city.groundCache.clear();
          city.drapeCache.clear();
        } else if (edits != null && editCount > city.groundCacheEditCount) {
          final reachRad = _colonyReachM(city) / body.radius;
          for (var i = city.groundCacheEditCount; i < editCount; i++) {
            final brush = edits.brushAt(i);
            if (_brushReachesColony(brush, siteDirBF, reachRad)) {
              _forgetGroundUnder(city, brush);
            }
          }
        }
        city.groundCacheShaped = city.shapedTerrain.length;
        city.groundCacheEditStore = edits;
        city.groundCacheEditCount = editCount;
        // A road laid, split, upgraded or re-laid: its drape is worked out
        // again, and a road that is gone forgets its own.
        if (city.drapeCacheRevision != city.roadsRevision) {
          city.drapeCache.clear();
          city.drapeCacheRevision = city.roadsRevision;
        }

        // Held with the rest of the colony's ground: asked every frame it was
        // a march through every brush at the site, 3-4 ms of a built
        // colony's frame.
        final siteRadius = field == null
            ? body.radius
            : city.groundCache.putIfAbsent('site', () {
                groundQueries++;
                return (
                  radius: field.groundRadiusAt(
                      siteDirBF.x, siteDirBF.y, siteDirBF.z),
                  dir: siteDirBF,
                );
              }).radius;

        /// The unit body-fixed direction under a local point — what the
        /// ground is asked along there.
        Vector3 dirOf(Vec2 local) =>
            city.localToBodyFixed(local, bodyRadiusM: siteRadius).normalized;

        /// Ground radius under a parcel-city feature, cached by key. Sampled
        /// WITH the terrain edits, so geometry reads the pad that was levelled
        /// for it — sampling the pristine field would re-open the exact gap
        /// the shaper closed.
        double groundFor(String key, Vec2 local) {
          if (field == null) return siteRadius;
          return city.groundCache.putIfAbsent(key, () {
            groundQueries++;
            final dir = dirOf(local);
            return (
              radius: field.groundRadiusAt(dir.x, dir.y, dir.z),
              dir: dir,
            );
          }).radius;
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
          // Worked out once per change to the road or to the ground under
          // the colony, and held ([CitySim.drapeCache]): the capture runs
          // every frame, and re-sampling and re-modelling every graded
          // road's corridor every frame was a quarter of a colony's frame
          // budget.
          var drape = city.drapeCache[road.id];
          if (drape == null || !identical(drape.road, road)) {
            final samples = road.sample(stepM: 6);
            final d = samples.length < 2
                ? (
                    pts: samples,
                    radii: Float64List(samples.length),
                    dirs: null
                  )
                : _drapeRoad(city, road, samples, edits,
                    siteRadius / body.radius, dirOf, groundFor);
            drape = (road: road, pts: d.pts, dirs: d.dirs, radii: d.radii);
            city.drapeCache[road.id] = drape;
          }
          final pts = drape.pts;
          if (pts.length < 2) continue;
          final radii = drape.radii;
          final last = pts.length - 1;
          // Arc along the capture's OWN samples, in plan, for the roads that
          // need one: a raised or sunk road's deck is read against it, and a
          // reversed road's bridges are mirrored across it.
          final deck = road.deck;
          final reversed = road.reversed;
          Float64List? arc;
          if (deck != null || reversed) {
            arc = Float64List(pts.length);
            for (var i = 1; i <= last; i++) {
              arc[i] = arc[i - 1] + pts[i].distanceTo(pts[i - 1]);
            }
          }
          final lengthM = arc == null ? 0.0 : arc[last];
          // The deck above the drape, per point: arithmetic over the drape
          // radii just sampled, never a ground query of its own — the
          // capture runs every frame, and a ground query in a built city is
          // milliseconds. A deck's heights are above the body DATUM and the
          // drape's radii are from the body's centre, so the datum goes back
          // in.
          Float64List? lifts;
          if (deck != null) {
            lifts = Float64List(pts.length);
            for (var i = 0; i <= last; i++) {
              lifts[i] =
                  body.radius + deck.heightAt(arc![i], lengthM) - radii[i];
            }
          }
          // A reversed one-way road goes out FLIPPED — points and lifts last
          // to first, its bridges mirrored, its tapers swapped — so the
          // renderer's one rule, that traffic runs first point to last,
          // holds without it ever learning that a road can be reversed.
          //
          // Typed, not a growable list of boxed doubles: fifty thousand
          // roads' points were 5.8 million heap objects for the collector
          // to mark on every old-generation pass, and the pauses that
          // marking finished with landed in the frame. A Float64List IS a
          // List<double> to every reader.
          final flat = Float64List(3 * pts.length);
          for (var k = 0; k <= last; k++) {
            final i = reversed ? last - k : k;
            final bf = city.localToBodyFixed(pts[i], bodyRadiusM: radii[i]);
            flat[3 * k] = bf.x;
            flat[3 * k + 1] = bf.y;
            flat[3 * k + 2] = bf.z;
          }
          if (reversed && lifts != null) {
            for (var a = 0, b = last; a < b; a++, b--) {
              final t = lifts[a];
              lifts[a] = lifts[b];
              lifts[b] = t;
            }
          }
          roads.add(RoadSnapshot(
            colonyId: city.id,
            body: body.id.value,
            points: flat,
            halfWidthM: road.halfWidth,
            roadClassIndex: road.roadClass.index,
            sealed: road.sealed,
            soundWalls: road.soundWalls,
            collector: road.collector,
            bridges: Float64List.fromList(reversed
                ? [
                    for (final (a, b) in road.bridges.reversed)
                      ...[lengthM - b, lengthM - a]
                  ]
                : [
                    for (final (a, b) in road.bridges) ...[a, b]
                  ]),
            startHalfWidthM:
                reversed ? road.endHalfWidthM : road.startHalfWidthM,
            endHalfWidthM: reversed ? road.startHalfWidthM : road.endHalfWidthM,
            id: road.id,
            decoration: road.decoration.index,
            lifts: lifts ?? const <double>[],
          ));
        }
        // The players' junction overrides, each on the ground at its own
        // point — one cached sample per override, keyed like the rest — and
        // each stop leg as a point out along it at that same height, so a
        // renderer can match both against the road ends it holds.
        for (final o in city.junctionOverrides.values) {
          if (o.isEmpty) continue;
          final radius = groundFor('junction:${o.key}', o.at);
          final at = city.localToBodyFixed(o.at, bodyRadiusM: radius);
          final headings = o.stopHeadings;
          final stops = Float64List(3 * (headings?.length ?? 0));
          if (headings != null) {
            for (var k = 0; k < headings.length; k++) {
              // Headings run from north toward east (see Vec2.heading).
              final h = headings[k];
              final p = city.localToBodyFixed(
                  o.at +
                      Vec2(math.sin(h), math.cos(h)) *
                          JunctionSnapshot.stopReachM,
                  bodyRadiusM: radius);
              stops[3 * k] = p.x;
              stops[3 * k + 1] = p.y;
              stops[3 * k + 2] = p.z;
            }
          }
          junctions.add(JunctionSnapshot(
            colonyId: city.id,
            body: body.id.value,
            px: at.x,
            py: at.y,
            pz: at.z,
            lights: switch (o.lights) { null => -1, true => 1, false => 0 },
            stopPoints: stops,
            stopsSet: headings != null,
          ));
        }
        roadsRevision[city.id] = city.roadsRevision;
        if (city.agents.enabled) {
          cityTraffic.add(TrafficCapture.frameFor(city, body.id.value, roads));
        }
        // Roads, zoned-but-unbuilt lots and support platforms. These are what
        // the player has actually placed a moment after founding, so leaving
        // them out is what made a new colony look like nothing happened.
        //
        // Straight into the columns, with the two names this colony's
        // patches all share interned once. The parcel list is materialised
        // here too — `layout.parcels` builds a fresh list per call — and
        // together with the cell sets gives the columns an upper bound to
        // size themselves by (a built lot yields at most four strips), so
        // on a colony this size they grow once rather than doubling twenty
        // times over.
        final parcels = city.layout.parcels;
        final colonyIx = patches.internString(city.id);
        final bodyIx = patches.internString(body.id.value);
        patches.reserve(city.roads.length +
            city.support.length +
            city.zones.length +
            parcels.length);
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
          patches.addInterned(
            colony: colonyIx,
            body: bodyIx,
            px: t.position.x,
            py: t.position.y,
            pz: t.position.z,
            qw: t.orientation.w,
            qx: t.orientation.x,
            qy: t.orientation.y,
            qz: t.orientation.z,
            sizeM: CitySim.cellM,
            depthM: CitySim.cellM,
            kind: kind,
          );
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
        for (final parcel in parcels) {
          // ONE patch per lot, whole-lot, flagged with whether anything
          // stands on it. What that patch is FOR is a view decision, taken by
          // the renderer: a plat is worth seeing while the ground is empty and
          // worth seeing on demand once it is not, and the frame's job is to
          // carry the plat rather than to decide when it is painted.
          //
          // This replaced a ring of four strips drawn around each building in
          // the lot's zone colour. It was drawn that way to avoid painting
          // ground under a building and z-fighting it — but setback and
          // coverage leave a low-density lot only ~72% covered, so what the
          // ring actually painted was a wide opaque skirt around everything:
          // a green apron around a house, and a grey one 60 m deep around a
          // 900 m spaceport pad. A built lot is now not painted at all unless
          // the overlay asks for it, which is both the fix and the feature.
          final builtSpec = city.parcelBuildings[parcel.id] ??
              city.parcelGrownSpec(parcel.id, parcel.use);
          final t = _parcelTransform(
              city, parcel, groundFor('lot:${parcel.id}', parcel.centroid));
          final extent = parcel.buildableExtent;
          patches.addInterned(
            colony: colonyIx,
            body: bodyIx,
            px: t.position.x,
            py: t.position.y,
            pz: t.position.z,
            qw: t.orientation.w,
            qx: t.orientation.x,
            qy: t.orientation.y,
            qz: t.orientation.z,
            sizeM: extent.width,
            depthM: extent.depth,
            kind: CityPatchSnapshot.packKind(
              switch (parcel.use) {
                ParcelUse.commercial => CityPatchSnapshot.kindCommercial,
                ParcelUse.industrial => CityPatchSnapshot.kindIndustrial,
                ParcelUse.residential => CityPatchSnapshot.kindResidential,
                _ => CityPatchSnapshot.kindSupport,
              },
              built: builtSpec != null,
              unzoned: parcel.use == ParcelUse.unzoned,
              lot: true,
            ),
          );
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
      roadsRevision: roadsRevision,
      junctions: junctions,
      cityTraffic: cityTraffic,
      patches: patches.build(),
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
        if (roadsRevision.isNotEmpty) 'roadsRev': roadsRevision,
        if (junctions.isNotEmpty)
          'junctions': [for (final x in junctions) x.toJson()],
        'patches': patches.toJsonList(),
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
      // Both optional, and both skip what they cannot read: a frame from
      // before the road tool had neither.
      roadsRevision: {
        for (final e
            in ((j['roadsRev'] as Map?) ?? const <String, dynamic>{}).entries)
          if (e.value is num) '${e.key}': (e.value as num).toInt(),
      },
      junctions: [
        for (final x in (j['junctions'] as List?) ?? const [])
          if (x is Map) JunctionSnapshot.fromJson(x.cast<String, dynamic>()),
      ],
      patches: CityPatchColumns.fromJsonList(patchList),
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
