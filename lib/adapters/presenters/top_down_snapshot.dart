import 'dart:math' as math;

import '../../application/ports/repositories.dart';
import '../../application/ports/world_repositories.dart';
import '../../domain/orbits/trajectory_service.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/simulation/epoch.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/vessel/resource_container.dart';
import '../../domain/vessel/vessel.dart';

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

  /// Sun direction (unit, XY plane) for lit-disc shading — from this body
  /// toward the star. Stars use a zero vector (self-luminous).
  final double sunX;
  final double sunY;

  const BodyView(this.name, this.x, this.y, this.radius, this.isStar,
      {this.hasAtmosphere = false, this.sunX = 1, this.sunY = 0});
}

class VesselView {
  final String name;
  final double x; // m, relative to focus
  final double y;
  final double headingRad; // facing in the XY plane
  final bool onRails;

  /// Predicted orbit path, focus-relative XY metres. Empty when unavailable
  /// (e.g. landed). The painter draws this as a faint polyline.
  final List<({double x, double y})> path;

  const VesselView(this.name, this.x, this.y, this.headingRad, this.onRails,
      {this.path = const []});
}

/// Bare-minimum HUD readouts for the focus vessel + colony totals. Strings are
/// preformatted so the painter just draws lines of text.
class HudView {
  final List<String> lines;
  const HudView(this.lines);
}

/// What the painter draws for one frame.
class TopDownSnapshot {
  final List<BodyView> bodies;
  final List<VesselView> vessels;
  final double metresPerPixel; // current zoom
  final HudView hud;
  const TopDownSnapshot({
    required this.bodies,
    required this.vessels,
    required this.metresPerPixel,
    required this.hud,
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

  TopDownSnapshotPresenter({
    required this.vessels,
    required this.universe,
    this.colonies,
    this.trajectory = const TrajectoryService(),
  });

  TopDownSnapshot present({
    required VesselId? focus,
    required double metresPerPixel,
    Epoch epoch = Epoch.zero,
    double science = 0,
  }) {
    final system = universe.current();

    // Focus position (camera origin). Default to world origin if no focus.
    final focusVessel = focus == null ? null : vessels.byId(focus);
    final focusBody =
        focusVessel == null ? null : system.body(focusVessel.dominantBody);
    final focusPos = focusVessel?.state.position ?? Vector3.zero;

    final bodyViews = <BodyView>[];
    for (final b in system.all) {
      // Body's position in the focus body's frame: approximate by its mean
      // orbit (full impl uses propagated ephemeris). Same-frame bodies are at
      // origin relative to themselves.
      final rel = _bodyRelativeToFocus(b, focusBody, focusPos);
      // Sun direction for shading: from this body toward the star (system root
      // at the world origin). In focus-relative coords the star sits at -focus
      // of the body's own position; approximate by pointing at the screen
      // origin offset by the body's relative position.
      final sun = (-rel).normalized;
      bodyViews.add(BodyView(
        b.name, rel.x, rel.y, b.radius, b.isStar,
        hasAtmosphere: b.hasAtmosphere,
        sunX: b.isStar ? 0 : (sun.x == 0 && sun.y == 0 ? 1 : sun.x),
        sunY: b.isStar ? 0 : sun.y,
      ));
    }

    final vesselViews = <VesselView>[];
    for (final v in vessels.all()) {
      final rel = v.state.position - focusPos; // small numbers (same frame)
      final fwd = v.state.attitude.rotate(Vector3.unitZ);

      // Predicted orbit path (skip for landed vessels — they don't orbit).
      var path = const <({double x, double y})>[];
      final vBody = system.body(v.dominantBody);
      if (!v.landed && vBody != null && v.state.velocity.length > 1) {
        final pts = trajectory.predictPath(
          position: v.state.position,
          velocity: v.state.velocity,
          body: vBody,
          epoch: epoch,
          samples: 48,
        );
        path = [for (final p in pts) (x: p.x - focusPos.x, y: p.y - focusPos.y)];
      }

      vesselViews.add(VesselView(
        v.name,
        rel.x,
        rel.y,
        _headingXY(fwd),
        v.mode == PropagationMode.onRails,
        path: path,
      ));
    }

    return TopDownSnapshot(
      bodies: bodyViews,
      vessels: vesselViews,
      metresPerPixel: metresPerPixel,
      hud: _buildHud(focusVessel, focusBody, science),
    );
  }

  HudView _buildHud(Vessel? focus, CelestialBody? body, double science) {
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
      lines.add('alt ${(alt / 1000).toStringAsFixed(1)} km   '
          'vel ${speed.toStringAsFixed(0)} m/s   '
          'thr ${(focus.throttle * 100).toStringAsFixed(0)}%');

      // Hottest part temperature, if any thermal state.
      if (focus.thermal.isNotEmpty) {
        final hottest = focus.thermal
            .map((t) => t.temperature)
            .reduce((a, b) => a > b ? a : b);
        lines.add('temp ${hottest.toStringAsFixed(0)} K');
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

  Vector3 _bodyRelativeToFocus(
    CelestialBody body,
    CelestialBody? focusBody,
    Vector3 focusPos,
  ) {
    if (focusBody != null && body.id == focusBody.id) {
      // Focus body sits at the focus's negative position (vessel orbits it).
      return -focusPos;
    }
    // Mean-orbit placeholder around its parent; refined by ephemeris later.
    return Vector3(body.orbitRadius, 0, 0) - focusPos;
  }

  /// In-plane (XY) heading of the vessel's forward axis.
  double _headingXY(Vector3 forward) => math.atan2(forward.y, forward.x);
}
