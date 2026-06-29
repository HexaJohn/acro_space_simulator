import 'dart:math' as math;

import '../../application/ports/repositories.dart';
import '../../application/ports/world_repositories.dart';
import '../../domain/orbits/body_ephemeris.dart';
import '../../domain/orbits/state_vector_converter.dart';
import '../../domain/orbits/trajectory_service.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/vessel/resource_container.dart';
import '../../domain/vessel/vessel.dart';
import 'camera_view.dart';

export 'camera_view.dart';
export 'perspective_camera.dart';

/// Immutable, render-ready description of one body for the top-down painter.
/// Positions are already projected to the XY plane in *metres relative to the
/// camera focus* — small numbers, so the painter only does a metres->pixels
/// scale. Z (up) is dropped for this top-down pass.
class BodyView {
  final String name;
  final double x; // m, relative to focus (XY plane)
  final double y;
  final double radius; // m
  final bool isStar;
  final bool hasAtmosphere;

  /// Sun direction (unit, XY plane) for the flat lit-disc shading — from this
  /// body toward the star. Stars use a zero vector (self-luminous).
  final double sunX;
  final double sunY;

  /// Sun direction as a full 3D WORLD unit vector (body -> star), for the
  /// textured-sphere Lambert shading. The sphere transforms it into the camera
  /// frame itself, so lighting stays correct as the camera orbits (the 2D
  /// sunX/sunY can't encode depth and lit the night side). Zero for stars.
  final double sunWorldX;
  final double sunWorldY;
  final double sunWorldZ;

  /// How much the sun points toward the camera: +1 = sun behind the viewer
  /// (whole visible face lit), -1 = sun behind the body (face is night). Lets
  /// the 2D shaders resolve the degenerate front-on/back-on case where the
  /// projected sunX/sunY collapse to ~0.
  final double sunFacing;

  /// Texture key (e.g. 'earth') -> `assets/textures/<key>.jpg`, when this body
  /// has a surface map. Null falls back to the procedural shaded disc.
  final String? textureKey;

  /// Rotation of the body about its spin axis (+Z) at this epoch, radians. The
  /// sphere offsets the texture longitude by this so the surface visibly turns.
  final double spin;

  /// Dominant atmosphere tint as packed ARGB (the painter's Rayleigh sweep uses
  /// it for the day-side glow). Defaults to Earth blue.
  final int atmoColor;

  /// True for gas giants — the debug "exaggerate atmosphere" option thickens
  /// their haze since their real scale dwarfs the visible atmosphere band.
  final bool isGasGiant;

  /// Sphere-of-influence radius, metres (0 = none/root). The painter draws this
  /// as a dashed circle when the SOI debug overlay is on.
  final double soiRadius;

  /// The body's orbit ellipse about its parent, focus-relative XY metres
  /// (already projected for the current view). Empty for the root star. The
  /// painter draws this as a faint closed ring ("rails"). [orbitBehind] flags
  /// each point as behind the parent body so the painter occludes the far arc.
  final List<({double x, double y})> orbitPath;
  final List<bool> orbitBehind;

  /// Projected inner/outer ring-circle sample points (focus-relative XY metres),
  /// for bodies with a ring system. Empty when ringless. The painter strokes a
  /// band between them. [ringBehind] is true for samples on the far side of the
  /// body (drawn under the disc) so the planet occludes the back of the rings.
  final List<({double x, double y})> ringInnerPath;
  final List<({double x, double y})> ringOuterPath;
  final List<bool> ringBehind;

  /// Per-angle perpendicular distance (metres) from the planet's shadow cylinder
  /// axis, at the inner and outer ring edges (1e30 when sunward = never shadow).
  /// The painter shadows a band point when the interpolated value < body radius,
  /// giving a straight-chord (U-shaped) shadow rather than a radial wedge.
  final List<double> ringShadowInner;
  final List<double> ringShadowOuter;

  /// Ring material colour (packed ARGB). Defaults to Saturn tan.
  final int ringColor;

  /// Ring opacity multiplier (0..1) — gas giants are faint, Saturn brightest.
  final double ringIntensity;

  /// On-screen radius in pixels (camera already applied the projection — ortho
  /// = radius/mpp, perspective = radius/depth*focal). The painter draws this
  /// directly; [radius] (metres) is kept only for shadow/SOI world-space math.
  final double radiusPx;

  /// Body's camera-relative WORLD position (metres), so the painter can build a
  /// per-body view basis for the sphere (the eye->body direction differs from
  /// the camera forward off-axis — using forward slides the texture).
  final Vector3 worldRel;

  /// SOI radius already projected to pixels (0 = none).
  final double soiRadiusPx;

  /// Whether the painter should draw this body's name label. Cleared for
  /// unrelated bodies when zoomed inside the active body's SOI (declutter).
  final bool showLabel;

  const BodyView(this.name, this.x, this.y, this.radius, this.isStar,
      {this.hasAtmosphere = false,
      this.sunX = 1,
      this.sunY = 0,
      this.sunWorldX = 1,
      this.sunWorldY = 0,
      this.sunWorldZ = 0,
      this.sunFacing = 0,
      this.spin = 0,
      this.atmoColor = 0xFF6FB4FF,
      this.isGasGiant = false,
      this.soiRadius = 0,
      this.textureKey,
      this.orbitPath = const [],
      this.orbitBehind = const [],
      this.ringInnerPath = const [],
      this.ringOuterPath = const [],
      this.ringBehind = const [],
      this.ringShadowInner = const [],
      this.ringShadowOuter = const [],
      this.ringColor = 0xFFE3D2A8,
      this.ringIntensity = 1.0,
      this.radiusPx = 0,
      this.soiRadiusPx = 0,
      this.showLabel = true,
      this.worldRel = Vector3.zero});
}

class VesselView {
  final String name;
  final double x; // SCREEN px, relative to centre
  final double y;
  final double headingRad; // facing in the screen plane (flat-marker LOD)
  final bool onRails;

  /// Predicted orbit path, SCREEN px (a single ordered polyline). Empty when
  /// unavailable (e.g. landed). [pathBehind] flags each point behind the
  /// dominant body so the painter occludes the far arc.
  final List<({double x, double y})> path;
  final List<bool> pathBehind;

  /// 3D data for the lit-cone LOD (when the craft is big enough on screen): the
  /// vessel's camera-relative WORLD position (metres) + its nose/up world axes +
  /// the sun direction at the vessel (world unit).
  final Vector3 worldRel;
  final Vector3 forwardW;
  final Vector3 upW;
  final Vector3 sunW;

  /// Current engine throttle 0..1 (0 = coasting). Drives the exhaust flame on
  /// the cone-LOD marker.
  final double throttle;

  /// Surface-proximity cues: altitude above the dominant body's surface (m),
  /// that body's radius (m), the camera-relative WORLD position of the point on
  /// the surface directly BELOW the craft (the radial foot), and whether the
  /// craft is landed. The painter draws a drop-line + alt label when low and a
  /// contact ring when landed.
  final double altSurfaceM;
  final double bodyRadiusM;
  final Vector3 surfaceFootRel;
  final bool landed;

  const VesselView(this.name, this.x, this.y, this.headingRad, this.onRails,
      {this.path = const [],
      this.pathBehind = const [],
      this.worldRel = Vector3.zero,
      this.forwardW = Vector3.unitZ,
      this.upW = Vector3.unitY,
      this.sunW = Vector3.unitZ,
      this.throttle = 0,
      this.altSurfaceM = double.infinity,
      this.bodyRadiusM = 0,
      this.surfaceFootRel = Vector3.zero,
      this.landed = false});
}

/// Bare-minimum HUD readouts for the focus vessel + colony totals. Strings are
/// preformatted so the painter just draws lines of text.
class HudView {
  final List<String> lines;
  const HudView(this.lines);
}

/// What the painter draws for one frame. Coordinates are already in SCREEN px
/// (the camera applied the projection), so the painter draws them directly.
class TopDownSnapshot {
  final List<BodyView> bodies;
  final List<VesselView> vessels;
  final HudView hud;

  /// The focused vessel's FLOWN path (breadcrumb), in SCREEN px — the actual
  /// trajectory already travelled, distinct from each vessel's predicted orbit
  /// rail. Empty when no trail is supplied. Points the camera culled are NaN so
  /// the painter's clip drops those segments.
  final List<({double x, double y})> trailPx;

  const TopDownSnapshot({
    required this.bodies,
    required this.vessels,
    required this.hud,
    this.trailPx = const [],
  });
}

/// Builds a [TopDownSnapshot] from current simulation state, projecting onto the
/// XY plane and recentering on a focus vessel (the floating origin that keeps
/// rendered numbers small). Interface Adapter — depends inward on ports/domain,
/// knows nothing about Flutter.
class TopDownSnapshotPresenter {
  final VesselRepository vessels;
  final UniverseRepository universe;
  final ColonyRepository? colonies;
  final TrajectoryService trajectory;
  final BodyEphemeris ephemeris;

  TopDownSnapshotPresenter({
    required this.vessels,
    required this.universe,
    this.colonies,
    this.trajectory = const TrajectoryService(),
    this.ephemeris = const BodyEphemeris(),
  });

  /// Body ids that ship with a surface map under `assets/textures/<id>.jpg`.
  static const Set<String> _texturedBodies = {
    'sun', 'mercury', 'venus', 'earth', 'moon',
    'mars', 'jupiter', 'saturn', 'uranus', 'neptune',
  };

  /// Ring systems: (innerMult, outerMult, tiltRadians, colorARGB). Radii are in
  /// body radii; tilt is the ring plane's inclination to the body's equator
  /// (≈ obliquity); colour is the ring material's tone.
  ///  - Saturn: bright icy tan, tilted ~26.7°.
  ///  - Uranus: dark charcoal rings, nearly POLAR (~98°, the planet is on its
  ///    side) so they appear edge-on/vertical relative to the ecliptic.
  ///  - Neptune: dark bluish, ~28°.
  ///  - Jupiter: faint reddish dust, ~3°.
  static const Map<String, (double, double, double, int)> _rings = {
    'saturn': (1.2, 2.3, 0.466, 0xFFE3D2A8), // 26.7°, pale gold
    'uranus': (1.6, 2.1, 1.706, 0xFF6E6A74), // 97.8°, dark grey
    'neptune': (1.7, 2.4, 0.494, 0xFF5A6E86), // 28.3°, dusky blue
    'jupiter': (1.4, 1.8, 0.055, 0xFFB08A6A), // 3.1°, faint red-brown
  };

  /// Ring opacity per body. Only Saturn's rings are bright; the others are
  /// tenuous dust/ice and barely visible.
  static const Map<String, double> _ringIntensity = {
    'saturn': 0.7,
    'jupiter': 0.18,
    'uranus': 0.22,
    'neptune': 0.2,
  };

  /// Dominant atmosphere tint per body (packed ARGB). Falls back to Earth blue.
  static const Map<String, int> _atmoColors = {
    'earth': 0xFF6FB4FF, // blue
    'venus': 0xFFE8D27A, // thick sulphuric yellow
    'mars': 0xFFE2A172, // thin dusty pink-tan
    'titan': 0xFFE89A4C, // orange organic haze
    'jupiter': 0xFFD8C2A0, // banded cream/brown
    'saturn': 0xFFE6D8B0, // pale gold
    'uranus': 0xFF9FE6E0, // cyan methane
    'neptune': 0xFF5A8CFF, // deep blue methane
    'pluto': 0xFFBFC8D8, // faint bluish haze
  };

  /// Gas/ice giants — flagged so the debug option can exaggerate their haze.
  static const Set<String> _gasGiants = {
    'jupiter', 'saturn', 'uranus', 'neptune',
  };

  /// Angular samples around a ring circle (smoother ellipse + finer shadow edge).
  static const int _ringSamples = 160;

  TopDownSnapshot present({
    required VesselId? focus,
    BodyId? focusBodyId, // lock the camera onto a body instead of a vessel
    required SceneCamera camera, // ortho or perspective; owns metres->px
    Epoch epoch = Epoch.zero,
    double science = 0,
    // A tilted view culls everything but the active body + its moons when the
    // active body's apparent radius drops below this many pixels (zoomed out).
    double tiltedCullRadiusPx = 6,
    // Debug master switch: when false, never cull distant bodies (show all).
    bool cullDistant = true,
    // Hide unrelated bodies' rails + labels once the active body's SOI projects
    // larger than this (we're zoomed inside its neighbourhood).
    double declutterSoiPx = 1400,
    // The focused vessel's flown breadcrumb, as positions RELATIVE TO its
    // dominant body (the same frame as Vessel.state.position), plus that body's
    // id so we can lift them to world coords. Projected to screen px below.
    List<Vector3> flownTrail = const [],
    BodyId? flownTrailBody,
  }) {
    final system = universe.current();

    // World position (relative to the system root) of any body, via ephemeris.
    Vector3 bodyWorld(CelestialBody b) =>
        ephemeris.positionRelativeToRoot(b, system, epoch);

    // World position of a vessel = its dominant body's world pos + local state.
    Vector3 vesselWorld(Vessel v) {
      final b = system.body(v.dominantBody);
      final base = b == null ? Vector3.zero : bodyWorld(b);
      return base + v.state.position;
    }

    // Camera origin (world frame). Prefer a focused body, else a focused vessel.
    final focusVessel = focus == null ? null : vessels.byId(focus);
    final focusBodyLocked =
        focusBodyId == null ? null : system.body(focusBodyId);
    final focusBody = focusBodyLocked ??
        (focusVessel == null ? null : system.body(focusVessel.dominantBody));
    final Vector3 camWorld = focusBodyLocked != null
        ? bodyWorld(focusBodyLocked)
        : (focusVessel != null ? vesselWorld(focusVessel) : Vector3.zero);

    // Camera projects target-relative metres -> screen px. These shorthands
    // recentre on the focus before projecting/measuring depth.
    ({double x, double y})? proj(Vector3 world) =>
        camera.projectPx(world - camWorld);
    double depthOf(Vector3 world) => camera.depth(world - camWorld);
    // Projected point or NaN (so the painter's clip drops it) when culled.
    ({double x, double y}) projOrNan(Vector3 world) =>
        proj(world) ?? (x: double.nan, y: double.nan);

    // In a tilted view the whole solar system collapses onto one line of sight
    // and distant planets swamp the frame — so when the active body is small on
    // screen we show ONLY it + its moons. When it's big (zoomed in), show all.
    final activeBody = focusBody;
    final activeRadiusPx = activeBody == null
        ? double.infinity
        : camera.radiusPx(bodyWorld(activeBody) - camWorld, activeBody.radius);
    final cullActive = cullDistant &&
        camera.usesDistanceCull &&
        activeRadiusPx < tiltedCullRadiusPx;
    bool visibleInView(CelestialBody b) {
      if (camera.isTopish || activeBody == null || !cullActive) return true;
      if (b.isStar) return true; // the star is the light source — always show it
      if (b.id == activeBody.id) return true;
      return system.parentOf(b)?.id == activeBody.id; // a moon of the active body
    }

    // Declutter: once zoomed inside the active body's sphere of influence, the
    // orbit rails + name labels of unrelated bodies are just noise across the
    // frame. We treat "inside the SOI" as the active body's SOI projecting larger
    // than the [declutterSoiPx] threshold (its neighbourhood fills the view).
    // Related bodies (the active body, its parent, and its moons) keep their rail
    // + label so local context stays; everything else loses both.
    final activeSoiPx = (activeBody == null || activeBody.soiRadius <= 0)
        ? 0.0
        : camera.radiusPx(
            bodyWorld(activeBody) - camWorld, activeBody.soiRadius);
    final declutter = cullDistant && activeBody != null &&
        activeSoiPx > declutterSoiPx;
    final activeParentId = activeBody == null
        ? null
        : system.parentOf(activeBody)?.id;
    bool isRelated(CelestialBody b) {
      if (activeBody == null) return true;
      if (b.id == activeBody.id) return true;
      if (b.id == activeParentId) return true; // the body we orbit
      final p = system.parentOf(b)?.id;
      return p == activeBody.id; // a moon of the active body
    }

    final bodyViews = <BodyView>[];
    for (final b in system.all) {
      if (!visibleInView(b)) continue;
      final bw = bodyWorld(b);
      final rel = proj(bw); // screen px, or null if behind the camera
      if (rel == null) continue; // body behind the camera -> cull
      // Declutter unrelated bodies when zoomed inside the active SOI: no rail,
      // no label (the disc itself still draws so the body isn't invisible).
      final decluttered = declutter && !isRelated(b);
      // Sun (system root) direction from this body. Full 3D world unit vector
      // for sphere Lambert; also a screen-plane projection (basis dots, NOT the
      // perspective projectPx — it's a direction, not a point) for the disc.
      final toSunWorld = (-bw).normalized;
      final toSun = (x: toSunWorld.dot(camera.right), y: toSunWorld.dot(camera.up));
      // Orbit "rails": the body's ellipse about its parent. Each point flagged
      // behind the PARENT body so the painter occludes the far arc; NaN when
      // behind the camera so the clip drops it.
      final parent = system.parentOf(b);
      var orbitPath = const <({double x, double y})>[];
      var orbitBehind = const <bool>[];
      if (parent != null && !decluttered) {
        final parentWorld = bodyWorld(parent);
        final parentDepth = depthOf(parentWorld);
        final ring =
            ephemeris.orbitPathRelativeToParent(b, system, epoch: epoch);
        final pts = <({double x, double y})>[];
        final beh = <bool>[];
        for (final p in ring) {
          final world = Vector3(
              parentWorld.x + p.x, parentWorld.y + p.y, parentWorld.z + p.z);
          pts.add(projOrNan(world));
          beh.add(depthOf(world) > parentDepth);
        }
        orbitPath = pts;
        orbitBehind = beh;
      }

      final key = b.id.value;

      // Ring system: project sample points of the inner & outer ring circles
      // (lying in the body's equatorial / ecliptic-XY plane) through the camera.
      // Per sample, flag whether it's BEHIND the body so the planet occludes the
      // far half of the rings.
      var ringInnerPath = const <({double x, double y})>[];
      var ringOuterPath = const <({double x, double y})>[];
      var ringBehind = const <bool>[];
      var ringShadowInner = const <double>[];
      var ringShadowOuter = const <double>[];
      final ring = _rings[key];
      if (ring != null) {
        final bodyDepth = depthOf(bw);
        final sunDir = toSunWorld; // body -> star (unit)
        final tilt = ring.$3;
        final ct = math.cos(tilt), st = math.sin(tilt);
        // Body-local sample on a ring circle, tilted about the X axis by the
        // ring-plane inclination (Uranus is nearly polar, so its rings stand up
        // edge-on to the ecliptic).
        Vector3 localOffset(double mult, double a) {
          final cx = b.radius * mult * math.cos(a);
          final cy = b.radius * mult * math.sin(a);
          return Vector3(cx, cy * ct, cy * st); // rotate (0..cy..0) about X
        }
        Vector3 ringWorld(double mult, double a) {
          final o = localOffset(mult, a);
          return Vector3(bw.x + o.x, bw.y + o.y, bw.z + o.z);
        }
        final inner = <({double x, double y})>[];
        final outer = <({double x, double y})>[];
        final behind = <bool>[];
        // Shadow: signed perpendicular distance to the planet's shadow cylinder,
        // at the inner/outer ring edges (huge when sunward = never shadowed).
        final shadowInner = <double>[];
        final shadowOuter = <double>[];
        double shadowPerp(double mult, double a) {
          final off = localOffset(mult, a);
          final along = off.dot(sunDir);
          if (along >= 0) return 1e30; // sunward -> never shadowed
          return (off - sunDir * along).length; // perp distance to sun-line
        }
        for (var i = 0; i <= _ringSamples; i++) {
          final a = i / _ringSamples * 2 * math.pi;
          inner.add(projOrNan(ringWorld(ring.$1, a)));
          final outW = ringWorld(ring.$2, a);
          outer.add(projOrNan(outW));
          behind.add(depthOf(outW) > bodyDepth);
          shadowInner.add(shadowPerp(ring.$1, a));
          shadowOuter.add(shadowPerp(ring.$2, a));
        }
        ringInnerPath = inner;
        ringOuterPath = outer;
        ringBehind = behind;
        ringShadowInner = shadowInner;
        ringShadowOuter = shadowOuter;
      }

      bodyViews.add(BodyView(
        b.name, rel.x, rel.y, b.radius, b.isStar,
        // Visual atmosphere: any body we have a tint for (gas giants included,
        // even though they carry no physics AtmosphereModel) gets the glow.
        hasAtmosphere: b.hasAtmosphere || _atmoColors.containsKey(key),
        sunX: b.isStar ? 0 : (toSun.x == 0 && toSun.y == 0 ? 1 : toSun.x),
        sunY: b.isStar ? 0 : toSun.y,
        sunWorldX: toSunWorld.x,
        sunWorldY: toSunWorld.y,
        sunWorldZ: toSunWorld.z,
        sunFacing: toSunWorld.dot(camera.forward * -1),
        spin: b.angularVelocity * epoch.seconds,
        // True-ish haze colour from the body's real gas composition (Rayleigh +
        // absorption blend); falls back to the hand-tuned table, then blue.
        atmoColor: b.composition?.scatterColorArgb ??
            _atmoColors[key] ??
            0xFF6FB4FF,
        isGasGiant: _gasGiants.contains(key),
        soiRadius: b.soiRadius,
        // Untextured bodies fall back to the Moon surface map so every body
        // renders as a real lit sphere (no flat blue disc fallback).
        textureKey: _texturedBodies.contains(key) ? key : 'moon',
        orbitPath: orbitPath,
        orbitBehind: orbitBehind,
        ringInnerPath: ringInnerPath,
        ringOuterPath: ringOuterPath,
        ringBehind: ringBehind,
        ringShadowInner: ringShadowInner,
        ringShadowOuter: ringShadowOuter,
        ringColor: ring?.$4 ?? 0xFFE3D2A8,
        ringIntensity: _ringIntensity[key] ?? 1.0,
        radiusPx: camera.radiusPx(bw - camWorld, b.radius),
        soiRadiusPx: b.soiRadius > 0
            ? camera.radiusPx(bw - camWorld, b.soiRadius)
            : 0,
        showLabel: !decluttered,
        worldRel: bw - camWorld,
      ));
    }

    final vesselViews = <VesselView>[];
    for (final v in vessels.all()) {
      final vWorld = vesselWorld(v);
      final rel = proj(vWorld);
      if (rel == null) continue; // behind the camera -> cull
      final fwd = v.state.attitude.rotate(Vector3.unitZ);
      final upV = v.state.attitude.rotate(Vector3.unitY);

      // Predicted orbit path (skip for landed vessels — they don't orbit).
      var path = const <({double x, double y})>[];
      var pathBehind = const <bool>[];
      final vBody = system.body(v.dominantBody);
      if (!v.landed && vBody != null && v.state.velocity.length > 1) {
        final bodyOrigin = bodyWorld(vBody);
        final bodyDepth = depthOf(bodyOrigin);
        final bodyR = vBody.radius;
        // Projected body centre + radius, so we can test occlusion against the
        // SILHOUETTE (limb) rather than the centre plane.
        final bodyCentrePx = camera.projectPx(bodyOrigin - camWorld);
        final bodyRadiusPx = camera.radiusPx(bodyOrigin - camWorld, bodyR);
        // Lift a body-centred path point to world and project to screen px (null
        // when culled) — the adaptive sampler bisects against this on-screen.
        Vector3 toWorld(Vector3 p) =>
            Vector3(bodyOrigin.x + p.x, bodyOrigin.y + p.y, bodyOrigin.z + p.z);
        // Adaptive screen-space sampling: dense near the craft + at sharp
        // turning points, sparse on far/straight arcs.
        final pts = trajectory.predictPathAdaptive(
          position: v.state.position,
          velocity: v.state.velocity,
          body: vBody,
          epoch: epoch,
          projectPx: (p) => camera.projectPx(toWorld(p) - camWorld),
        );
        final pp = <({double x, double y})>[];
        final beh = <bool>[];
        for (final p in pts) {
          // Suborbital / impacting arc: a point BELOW the surface is underground,
          // so break the line there (NaN) instead of looping through the centre.
          if (p.length < bodyR) {
            pp.add((x: double.nan, y: double.nan));
            beh.add(false);
            continue;
          }
          final world = toWorld(p);
          final sp = projOrNan(world);
          pp.add(sp);
          // Occluded only when BEHIND the centre plane AND inside the projected
          // limb disc — i.e. the planet's silhouette actually covers it. A point
          // behind the centre but outside the limb (e.g. just past the horizon on
          // a low pass) stays visible.
          var behind = depthOf(world) > bodyDepth;
          if (behind && bodyCentrePx != null && !sp.x.isNaN) {
            final dx = sp.x - bodyCentrePx.x, dy = sp.y - bodyCentrePx.y;
            behind = (dx * dx + dy * dy) < bodyRadiusPx * bodyRadiusPx;
          }
          beh.add(behind);
        }
        path = pp;
        pathBehind = beh;
      }

      // Sun direction at the vessel (world unit), for cone-mesh lighting.
      final sunW =
          vWorld.length < 1 ? Vector3.unitZ : (-vWorld).normalized;

      // Surface-proximity cues. The radial foot is the point on the body's
      // surface directly below the craft; altitude is the craft's height over it.
      final vBodyForAlt = system.body(v.dominantBody);
      var altSurface = double.infinity;
      var bodyRadius = 0.0;
      var footRel = Vector3.zero;
      if (vBodyForAlt != null) {
        bodyRadius = vBodyForAlt.radius;
        final rLocal = v.state.position; // body-centred
        final rMag = rLocal.length;
        altSurface = rMag - bodyRadius;
        final dir = rMag < 1e-6 ? Vector3.unitZ : rLocal * (1 / rMag);
        final footWorld = bodyWorld(vBodyForAlt) + dir * bodyRadius;
        footRel = footWorld - camWorld;
      }

      vesselViews.add(VesselView(
        v.name,
        rel.x,
        rel.y,
        _headingXY(fwd),
        v.mode == PropagationMode.onRails,
        path: path,
        pathBehind: pathBehind,
        worldRel: vWorld - camWorld,
        forwardW: fwd,
        upW: upV,
        sunW: sunW,
        throttle: v.mode == PropagationMode.onRails ? 0.0 : v.throttle,
        altSurfaceM: altSurface,
        bodyRadiusM: bodyRadius,
        surfaceFootRel: footRel,
        landed: v.landed,
      ));
    }

    // Flown breadcrumb -> screen px. Lift each body-relative point to world via
    // its dominant body, then project through the same camera as everything else
    // (NaN where culled so the painter drops that segment).
    final trailPx = <({double x, double y})>[];
    if (flownTrail.isNotEmpty) {
      final tb = flownTrailBody == null ? null : system.body(flownTrailBody);
      final tbWorld = tb == null ? Vector3.zero : bodyWorld(tb);
      for (final p in flownTrail) {
        trailPx.add(projOrNan(tbWorld + p));
      }
    }

    return TopDownSnapshot(
      bodies: bodyViews,
      vessels: vesselViews,
      hud: _buildHud(focusVessel, focusBody, science, epoch),
      trailPx: trailPx,
    );
  }

  /// Altitude string: metres below 10 km (surface precision), km above.
  static String _altStr(double m) => m.abs() < 10000
      ? '${m.toStringAsFixed(0)} m'
      : '${(m / 1000).toStringAsFixed(2)} km';

  HudView _buildHud(
      Vessel? focus, CelestialBody? body, double science, Epoch epoch) {
    final lines = <String>[];
    if (science > 0) lines.add('SCIENCE ${science.toStringAsFixed(0)}');
    if (focus != null) {
      final speed = focus.state.velocity.length;
      final alt = body == null ? 0.0 : body.altitudeOf(focus.state.position);
      lines.add('VESSEL ${focus.name}');
      lines.add('body ${focus.dominantBody.value}   '
          '${focus.mode == PropagationMode.onRails ? "ON-RAILS" : "PHYSICS"}'
          '${focus.landed ? "  LANDED" : ""}'
          '   ${focus.hasCommLink ? "LINK" : "NO SIGNAL"}');
      lines.add('alt ${_altStr(alt)}   '
          'vel ${speed.toStringAsFixed(0)} m/s   '
          'thr ${(focus.throttle * 100).toStringAsFixed(0)}%');

      // Apoapsis / periapsis altitudes (Keplerian solve from the current state).
      if (body != null) {
        final orbit = const StateVectorOrbitConverter().toOrbit(
          position: focus.state.position,
          velocity: focus.state.velocity,
          body: body,
          epoch: epoch,
        );
        final apStr = (orbit.apoapsis.isInfinite || orbit.apoapsis < 0)
            ? '∞ (escape)'
            : _altStr(orbit.apoapsis - body.radius);
        lines.add('AP $apStr   PE ${_altStr(orbit.periapsis - body.radius)}');
      }

      // Hottest part temperature + a heat fraction vs its limit; an OVERHEAT
      // warning when it nears the destruction threshold.
      if (focus.thermal.isNotEmpty) {
        var frac = 0.0, hottest = 0.0, limit = 0.0;
        for (final t in focus.thermal) {
          final f = t.maxTemperature > 0 ? t.temperature / t.maxTemperature : 0.0;
          if (f > frac) {
            frac = f;
            hottest = t.temperature;
            limit = t.maxTemperature;
          }
        }
        lines.add('temp ${hottest.toStringAsFixed(0)} K'
            '${limit > 0 ? " (${(frac * 100).toStringAsFixed(0)}% of ${limit.toStringAsFixed(0)})" : ""}');
        if (frac > 0.85) lines.add('⚠ OVERHEATING — shed speed / pull up');
      }
      // Fuel + ore fractions.
      final fuel = _resourceTotal(focus, ResourceType.liquidFuel);
      final ore = _resourceTotal(focus, ResourceType.ore);
      if (fuel != null) lines.add('fuel ${fuel.toStringAsFixed(0)}');
      if (ore != null) lines.add('ore ${ore.toStringAsFixed(0)}');
      final dv = focus.deltaVCapacity();
      if (dv > 0) lines.add('dv ${dv.toStringAsFixed(0)} m/s');

      // Dynamic pressure (max-Q) when in atmosphere — warns of overstress.
      if (body != null && body.hasAtmosphere) {
        final alt = body.altitudeOf(focus.state.position);
        if (body.atmosphere!.hasAtmosphere(alt)) {
          final rho = body.atmosphere!.sampleAt(alt).density;
          final q = 0.5 * rho * speed * speed;
          lines.add('Q ${(q / 1000).toStringAsFixed(1)} kPa');
        }
      }
    }

    final cols = colonies?.all() ?? const [];
    for (final c in cols) {
      final water = c.stockpile[ResourceType.water]?.amount ?? 0;
      lines.add('COLONY ${c.name}  pop ${c.population}/${c.housingCapacity}  '
          'water ${water.toStringAsFixed(0)}');
    }
    return HudView(lines);
  }

  double? _resourceTotal(Vessel v, ResourceType type) {
    double total = 0;
    var found = false;
    for (final p in v.allParts) {
      for (final r in p.resources) {
        if (r.type == type) {
          total += r.amount;
          found = true;
        }
      }
    }
    return found ? total : null;
  }

  /// In-plane (XY) heading of the vessel's forward axis.
  double _headingXY(Vector3 forward) => math.atan2(forward.y, forward.x);
}
