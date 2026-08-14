// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';

/// Orbit rails, predicted trajectories, and flown trails as camera-facing
/// [fs.PolylineGeometry] strips (screen-pixel width — same visual weight as
/// the software renderer's 2D lines at any distance).
///
/// COPY-ON-WRITE GPU DISCIPLINE. No buffer attached to a scene node is
/// ever written again: [update] only refreshes CPU-side line specs;
/// [updateForCamera] expands each strip into a FRESH PolylineGeometry,
/// swaps it onto the node, and retires the old mesh by wall clock. In-place
/// writes (including PolylineGeometry.updateForCamera on a live strip)
/// race frames in flight on the Windows GLES backend and tear — black
/// shards and broken dashes, worst under mouse-drag camera motion where
/// builds outpace paints. A settled scene (camera and content unchanged)
/// performs ZERO buffer writes per frame.
class LineNodes {
  LineNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, fs.Node> _nodes = {};

  /// Pending line content (world-relative scene points + styling).
  final Map<String, _LineSpec> _specs = {};

  /// Replaced meshes held by wall clock before the last reference drops
  /// (frame-count windows shrink under high build rates). Releasing
  /// immediately frees GPU buffers under in-flight frames.
  final List<(int, fs.Mesh)> _retired = [];
  static const int _retireAfterMs = 400;

  /// Last expansion inputs; when nothing changed, [updateForCamera] skips.
  vm.Vector3? _lastEye, _lastUp;
  ui.Size? _lastViewport;
  bool _contentDirty = false;

  // Flown-trail breadcrumbs per vessel: BOTH the absolute world position
  // and the parent-body-relative offset at capture time, so the trail can
  // render in either frame. Parent-relative (default) co-moves with the
  // body and traces the orbit as a ring; inertial (sun-relative) keeps the
  // absolute points and traces the true wavy path through space.
  // [body] is the frame the rel offset was captured in: after an SOI
  // switch (Earth -> Moon) the old crumbs' offsets are meaningless in the
  // new parent's frame — "moonPos + earthRel" painted garbage streaks — so
  // the relative trail drops them and restarts at SOI entry.
  final Map<String, List<({Vector3 abs, Vector3 rel, String body})>> _trails =
      {};
  static const int _trailCap = 240;
  static const double _trailMinStepM = 500.0;

  /// Render trails in the sun-inertial frame instead of parent-relative.
  /// Toggled from the UI / control API.
  static bool inertialTrails = false;

  /// Apparent-size window (px) for orbit rails: below the floor a rail is
  /// sub-pixel shimmer; above the ceiling the ring dwarfs the viewport and
  /// its arc is clutter. Rails belong to the zoomed-out map view.
  static const double _railMinApparentPx = 40.0;

  // Predicted paths green (focused vessel bright, others dimmed), trails
  // fading cyan.
  static final vm.Vector4 _pathColor = vm.Vector4(0.5, 0.88, 0.56, 0.9);
  static final vm.Vector4 _pathDimColor = vm.Vector4(0.5, 0.88, 0.56, 0.35);
  static final vm.Vector4 _trailColor = vm.Vector4(0.35, 0.75, 1.0, 0.9);

  /// Rail colour per body — each orbit line wears its body's identity
  /// (Mars red, Jupiter tan, the Moon grey...). Fallback: cool gray.
  static final Map<String, vm.Vector4> _railColors = {
    'mercury': vm.Vector4(0.55, 0.5, 0.45, 0.85),
    'venus': vm.Vector4(0.9, 0.8, 0.55, 0.85),
    'earth': vm.Vector4(0.35, 0.55, 0.95, 0.85),
    'moon': vm.Vector4(0.7, 0.7, 0.72, 0.85),
    'mars': vm.Vector4(0.9, 0.4, 0.25, 0.85),
    'jupiter': vm.Vector4(0.85, 0.6, 0.35, 0.85),
    'saturn': vm.Vector4(0.9, 0.8, 0.5, 0.85),
    'uranus': vm.Vector4(0.5, 0.8, 0.85, 0.85),
    'neptune': vm.Vector4(0.35, 0.5, 0.9, 0.85),
    'pluto': vm.Vector4(0.65, 0.55, 0.5, 0.85),
  };
  static final vm.Vector4 _railFallback = vm.Vector4(0.55, 0.62, 0.7, 0.85);

  /// Refresh CPU-side line specs from this frame's snapshot. GPU work
  /// happens later in [updateForCamera].
  void update(WorldSnapshot snap, FloatingOrigin origin,
      {SceneCamera? camera,
      ui.Size? viewport,
      String? focusVesselId,
      String? focusBodyId}) {
    final seen = <String>{};

    // Body orbit rails (closed rings, root-relative metres).
    for (final b in snap.bodies.values) {
      if (b.orbit.length < 6) continue;

      if (camera != null) {
        final first = Vector3(b.orbit[0], b.orbit[1], b.orbit[2]);
        var cx = 0.0, cy = 0.0, cz = 0.0;
        final n = b.orbit.length ~/ 3;
        for (var i = 0; i + 2 < b.orbit.length; i += 3) {
          cx += b.orbit[i];
          cy += b.orbit[i + 1];
          cz += b.orbit[i + 2];
        }
        final centre = Vector3(cx / n, cy / n, cz / n);
        final ringRadiusM = (first - centre).length;

        // A ring that ENCIRCLES the focus (the Moon's orbit while focused
        // on Earth/orbiter) frames the view as a closed ellipse around the
        // screen centre — always wanted, at any zoom, even from deep
        // inside it. The clutter case is a ring centred far away seen
        // edge-on from inside (other planets' rails from Earth), which
        // sweeps the sky as clipped dashes: those wait until the camera
        // clears the ring.
        final centreRel = origin.worldToRel(centre);
        // Exempt only rings CENTRED ON the focus (the Moon's orbit while
        // focused on Earth): centre within a tenth of the ring radius.
        // A naive "focus inside the ring" test also matched every OUTER
        // planet's rail (Earth sits inside Mars..Neptune's orbits), which
        // drew the whole system's rails through every close-up frame.
        final centredOnFocus = centreRel.length < 0.1 * ringRadiusM;
        if (!centredOnFocus) {
          final centreDist = (centreRel - camera.eyeOffset).length;
          if (centreDist < 1.1 * ringRadiusM) continue;
          // Other planets' rails are map-scale context: zoomed in tight on
          // a body/vessel they read as stray arcs across the sky. Require
          // the camera range to be within an order of magnitude or two of
          // the ring's own scale before they join the frame.
          if (camera.eyeOffset.length < 0.05 * ringRadiusM) continue;
        }

        final apparentPx =
            camera.radiusPx(origin.worldToRel(centre), ringRadiusM);
        final maxPx = viewport == null
            ? double.infinity
            : 2.0 * math.max(viewport.width, viewport.height);
        if (apparentPx < _railMinApparentPx || apparentPx > maxPx) continue;
      }

      final world = <Vector3>[
        for (var i = 0; i + 2 < b.orbit.length; i += 3)
          Vector3(b.orbit[i], b.orbit[i + 1], b.orbit[i + 2]),
      ];
      world.add(world.first); // close the ring
      // Leading-edge fade: rail vertex 0 IS the body (ephemeris contract)
      // and indices march forward in time, so i/m ramps from invisible
      // just ahead of the body around the loop to full right behind it.
      final m = world.length - 1;
      final frac = [for (var i = 0; i <= m; i++) i / m];
      final (pts, cols) = _fadedStrip(
          world, frac, _railColors[b.id] ?? _railFallback, origin, camera);
      _setSpec('rail/${b.id}', seen, pts, _railFallback,
          width: 2.5, perVertexColor: cols);
    }

    for (final v in snap.vessels.values) {
      final body = snap.bodies[v.body];
      if (body == null) continue;
      final bodyPos = Vector3(body.px, body.py, body.pz);

      // Predicted trajectory (body-relative metres). Foreign vessels' paths
      // (the demo fleet across the system) slice the close-up frame as
      // stray arcs: draw a path only when it's OURS (the focused vessel or
      // one orbiting the focused body) or the camera is zoomed out to the
      // path's own scale.
      final pathRelevant = v.id == focusVesselId ||
          (v.body == focusBodyId && focusBodyId != null) ||
          camera == null ||
          camera.eyeOffset.length > 0.05 * math.max(v.semiMajor, 1.0);
      if (pathRelevant && v.trajectory.length >= 9) {
        final world = <Vector3>[
          for (var i = 0; i + 2 < v.trajectory.length; i += 3)
            bodyPos +
                Vector3(
                    v.trajectory[i], v.trajectory[i + 1], v.trajectory[i + 2]),
        ];
        // Leading-edge fade anchored at the CRAFT: trajectory samples sit at
        // a fixed phase from periapsis (the craft slides along them), so
        // find its nearest vertex and ramp forward-in-time from there —
        // invisible just ahead, full alpha arriving from behind. A closed
        // ellipse wraps the ramp; an open escape path fades ahead from the
        // craft (its samples DO start at the craft).
        final craftWorld = bodyPos + Vector3(v.px, v.py, v.pz);
        // An arc truncated at a predicted SOI handoff is OPEN even when e < 1:
        // fade forward from the craft, don't wrap the ramp around a seam.
        final closed =
            !v.trajectoryOpen && v.eccentricity < 1 && v.semiMajor > 0;
        final List<double> frac;
        if (closed) {
          final m = world.length - 1; // last vertex repeats the first
          var i0 = 0;
          var best = double.infinity;
          for (var i = 0; i < m; i++) {
            final d = world[i].distanceTo(craftWorld);
            if (d < best) {
              best = d;
              i0 = i;
            }
          }
          frac = [
            for (var i = 0; i < world.length; i++) ((i - i0) % m + m) % m / m,
          ];
        } else {
          final m = world.length - 1;
          frac = [for (var i = 0; i <= m; i++) 1.0 - i / m];
        }
        final (pts, cols) = _fadedStrip(world, frac,
            v.id == focusVesselId ? _pathColor : _pathDimColor, origin, camera);
        _setSpec('path/${v.id}', seen, pts, _pathColor,
            width: 2.0, perVertexColor: cols);
      }

      // Flown trail: world breadcrumbs, faded tail -> head. PREMULTIPLIED
      // alpha (the pipeline blends premultiplied). Accumulated for every
      // vessel (history survives focus switches) but DRAWN only for the
      // focused one — software parity (TopDownSnapshot.trailPx is the
      // focus vessel's alone), and a fleet of trails reads as stray lines.
      final relPos = Vector3(v.px, v.py, v.pz);
      final world = bodyPos + relPos;
      final trail = _trails.putIfAbsent(v.id, () => []);
      if (trail.isEmpty ||
          trail.last.abs.distanceTo(world) >= _trailMinStepM) {
        trail.add((abs: world, rel: relPos, body: v.body));
        if (trail.length > _trailCap) trail.removeAt(0);
      }
      if (v.id == focusVesselId && trail.length >= 2) {
        // Relative frame: only crumbs captured in the CURRENT parent's
        // frame are renderable there (see _trails doc).
        final pts = [
          if (inertialTrails)
            for (final p in trail) origin.worldToScene(p.abs)
          else
            for (final p in trail)
              if (p.body == v.body) origin.worldToScene(bodyPos + p.rel),
        ];
        if (pts.length >= 2) {
          final colors = <vm.Vector4>[
            for (var i = 0; i < pts.length; i++)
              () {
                final a = _trailColor.w * i / (pts.length - 1);
                return vm.Vector4(_trailColor.x * a, _trailColor.y * a,
                    _trailColor.z * a, a);
              }(),
          ];
          _setSpec('trail/${v.id}', seen, pts, _trailColor,
              width: 2.0, perVertexColor: colors);
        }
      }
    }

    // Drop lines that left the frame.
    _specs.removeWhere((id, _) {
      if (seen.contains(id)) return false;
      final node = _nodes.remove(id);
      if (node != null) {
        final old = node.mesh;
        if (old != null) _retired.add((_nowMs(), old));
        _scene.remove(node);
      }
      _contentDirty = true;
      return true;
    });
    _trails.removeWhere((id, _) => !snap.vessels.containsKey(id));
  }

  // Screen-space chord densification targets: split any segment longer than
  // ~[_densifyTargetPx] on screen. Long chords otherwise interpolate their
  // endpoint screen-widths across wildly different depths (thickness swings
  // along the segment) and meet at visible miter kinks. Caps bound the cost
  // when a chord crosses the whole frame at extreme close zoom.
  static const double _densifyTargetPx = 24.0;
  static const int _densifyMaxPerSeg = 64;
  static const int _densifyMaxPts = 4096;

  /// Fade floor: the leading edge keeps this fraction of the base alpha
  /// (a fully invisible leading arc made rails hard to trace end-to-end).
  static const double _fadeFloor = 0.25;

  /// Absolute world polyline -> (scene points, premultiplied vertex colors),
  /// densified in screen space and alpha-ramped by [frac] per vertex:
  /// 0 = leading edge ([_fadeFloor] of the base alpha), 1 = trailing edge
  /// (full [base] alpha).
  (List<vm.Vector3>, List<vm.Vector4>) _fadedStrip(
    List<Vector3> world,
    List<double> frac,
    vm.Vector4 base,
    FloatingOrigin origin,
    SceneCamera? camera,
  ) {
    final pts = <vm.Vector3>[];
    final cols = <vm.Vector4>[];
    final eye = camera?.eyeOffset;
    final focal = camera?.focalPx ?? 0;
    void emit(Vector3 rel, double f) {
      pts.add(relToScene(rel));
      final a = base.w * (_fadeFloor + (1.0 - _fadeFloor) * f);
      cols.add(vm.Vector4(base.x * a, base.y * a, base.z * a, a));
    }

    // Pre-project every sample into the scene-relative frame. Densified points
    // ride a Catmull-Rom spline through these samples, so they bow onto the
    // true curve instead of cutting the chord: the craft — always ON a sample
    // — sees a smooth arc hugging it, not a polyline it pulls off of between
    // vertices. The spline passes exactly through every sample, so the coarse
    // shape is untouched; only the gaps fill in.
    final n = world.length;
    final rel = [for (final w in world) origin.worldToRel(w)];
    // Closed loop when the first and last sample coincide (rail rings append
    // their seam vertex; closed ellipse paths repeat periapsis): wrap the
    // spline's neighbour lookups across the seam; otherwise clamp at the ends.
    final closed = n > 2 && rel.first.distanceTo(rel.last) < 1.0; // metres
    final loopN = n - 1; // unique vertices when closed (last repeats first)
    Vector3 ctrl(int i) => closed
        ? rel[((i % loopN) + loopN) % loopN]
        : rel[i < 0 ? 0 : (i >= n ? n - 1 : i)];

    for (var i = 0; i < n; i++) {
      final f = frac[i];
      if (i > 0 && eye != null && pts.length < _densifyMaxPts) {
        final p1 = rel[i - 1];
        final p2 = rel[i];
        final seg = p2 - p1;
        final dist = ((p1 + seg * 0.5) - eye).length;
        if (dist > 1e-3) {
          final px = focal * seg.length / dist;
          final splits =
              math.min((px / _densifyTargetPx).floor(), _densifyMaxPerSeg);
          if (splits > 1) {
            final p0 = ctrl(i - 2);
            final p3 = ctrl(i + 1);
            final prevF = frac[i - 1];
            for (var k = 1; k < splits; k++) {
              final t = k / splits;
              emit(_catmullRom(p0, p1, p2, p3, t), prevF + (f - prevF) * t);
            }
          }
        }
      }
      emit(rel[i], f);
    }
    return (pts, cols);
  }

  /// Uniform Catmull-Rom point at parameter [t] (0..1) on the segment
  /// [p1]->[p2], with [p0]/[p3] the flanking samples that set the tangents.
  /// Interpolates (passes through p1 at t=0, p2 at t=1) and curves toward the
  /// neighbours between them.
  static Vector3 _catmullRom(
      Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    // 0.5 * (2p1 + (p2-p0)t + (2p0-5p1+4p2-p3)t^2 + (3p1-3p2+p3-p0)t^3)
    return (p1 * 2.0 +
            (p2 - p0) * t +
            (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2 +
            (p1 * 3.0 - p2 * 3.0 + p3 - p0) * t3) *
        0.5;
  }

  void _setSpec(
    String id,
    Set<String> seen,
    List<vm.Vector3> pts,
    vm.Vector4 color, {
    required double width,
    List<vm.Vector4>? perVertexColor,
  }) {
    if (pts.length < 2) return;
    seen.add(id);
    _specs[id] = _LineSpec(pts, color, width, perVertexColor);
    // The floating origin moves every tick, so points change every frame;
    // marking dirty per frame is correct. The win is the settled case:
    // paused sim + still camera = no dirt = no writes.
    _contentDirty = true;
  }

  /// Expand every strip for this frame's camera — copy-on-write. Skips
  /// entirely when camera, viewport, and content are all unchanged.
  void updateForCamera(fs.PerspectiveCamera camera, ui.Size viewport) {
    if (viewport.width <= 0 || viewport.height <= 0) return;

    final unchanged = !_contentDirty &&
        _lastViewport == viewport &&
        _lastEye != null &&
        (camera.position - _lastEye!).length2 < 1e-12 &&
        (camera.up - _lastUp!).length2 < 1e-12;
    if (unchanged) return;
    _lastEye = camera.position.clone();
    _lastUp = camera.up.clone();
    _lastViewport = viewport;
    _contentDirty = false;

    final now = _nowMs();
    _retired.removeWhere((e) => now - e.$1 > _retireAfterMs);

    for (final entry in _specs.entries) {
      final spec = entry.value;
      final geometry = fs.PolylineGeometry(
        spec.points,
        width: spec.width,
        widthMode: fs.PolylineWidthMode.screenPixels,
        perVertexColor: spec.perVertexColor,
      );
      try {
        geometry.updateForCamera(camera, viewport);
      } on ArgumentError {
        continue; // transient degenerate camera; keep last frame's mesh
      }
      // Blend + PREMULTIPLIED colour: AlphaMode.opaque (default) ignores
      // alpha, and the translucent pass blends premultiplied. Per-vertex
      // colours (already premultiplied) keep the material white.
      final c = spec.color;
      final tint = spec.perVertexColor != null
          ? vm.Vector4(1, 1, 1, 1)
          : vm.Vector4(c.x * c.w, c.y * c.w, c.z * c.w, c.w);
      final mesh = fs.Mesh(
        geometry,
        DepthSafeUnlitMaterial()
          ..baseColorFactor = tint
          ..alphaMode = fs.AlphaMode.blend,
      );
      final node = _nodes[entry.key];
      if (node == null) {
        final n = fs.Node(mesh: mesh);
        _scene.add(n);
        _nodes[entry.key] = n;
      } else {
        final old = node.mesh;
        if (old != null) _retired.add((now, old));
        node.mesh = mesh;
      }
    }
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;
}

class _LineSpec {
  _LineSpec(this.points, this.color, this.width, this.perVertexColor);

  final List<vm.Vector3> points;
  final vm.Vector4 color;
  final double width;
  final List<vm.Vector4>? perVertexColor;
}
