import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

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

  // Flown-trail breadcrumbs per vessel, absolute world metres (doubles).
  final Map<String, List<Vector3>> _trails = {};
  static const int _trailCap = 240;
  static const double _trailMinStepM = 500.0;

  /// Apparent-size window (px) for orbit rails: below the floor a rail is
  /// sub-pixel shimmer; above the ceiling the ring dwarfs the viewport and
  /// its arc is clutter. Rails belong to the zoomed-out map view.
  static const double _railMinApparentPx = 40.0;

  // Parity with the software painter: rails cool gray (brighter than the
  // painter's — at system zoom they compete with the Milky Way), predicted
  // paths the painter's green, trails fading cyan.
  static final vm.Vector4 _railColor = vm.Vector4(0.55, 0.62, 0.7, 0.85);
  static final vm.Vector4 _pathColor = vm.Vector4(0.5, 0.88, 0.56, 0.9);
  static final vm.Vector4 _trailColor = vm.Vector4(0.35, 0.75, 1.0, 0.9);

  /// Refresh CPU-side line specs from this frame's snapshot. GPU work
  /// happens later in [updateForCamera].
  void update(WorldSnapshot snap, FloatingOrigin origin,
      {SceneCamera? camera, ui.Size? viewport}) {
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

        // Camera inside (or near) the ring: an edge-on giant ring sweeps
        // the sky as near-plane-clipped dashes. CAMERA distance, not focus
        // distance, so zooming way out brings the system rails back.
        final centreDist =
            (origin.worldToRel(centre) - camera.eyeOffset).length;
        if (centreDist < 2.0 * ringRadiusM) continue;

        final apparentPx =
            camera.radiusPx(origin.worldToRel(centre), ringRadiusM);
        final maxPx = viewport == null
            ? double.infinity
            : 2.0 * math.max(viewport.width, viewport.height);
        if (apparentPx < _railMinApparentPx || apparentPx > maxPx) continue;
      }

      final pts = <vm.Vector3>[];
      for (var i = 0; i + 2 < b.orbit.length; i += 3) {
        pts.add(origin.worldToScene(
            Vector3(b.orbit[i], b.orbit[i + 1], b.orbit[i + 2])));
      }
      pts.add(pts.first); // close the ring
      _setSpec('rail/${b.id}', seen, pts, _railColor, width: 2.5);
    }

    for (final v in snap.vessels.values) {
      final body = snap.bodies[v.body];
      if (body == null) continue;
      final bodyPos = Vector3(body.px, body.py, body.pz);

      // Predicted trajectory (body-relative metres).
      if (v.trajectory.length >= 6) {
        final pts = <vm.Vector3>[];
        for (var i = 0; i + 2 < v.trajectory.length; i += 3) {
          pts.add(origin.worldToScene(bodyPos +
              Vector3(
                  v.trajectory[i], v.trajectory[i + 1], v.trajectory[i + 2])));
        }
        _setSpec('path/${v.id}', seen, pts, _pathColor, width: 2.0);
      }

      // Flown trail: world breadcrumbs, faded tail -> head. PREMULTIPLIED
      // alpha (the pipeline blends premultiplied).
      final world = bodyPos + Vector3(v.px, v.py, v.pz);
      final trail = _trails.putIfAbsent(v.id, () => []);
      if (trail.isEmpty || trail.last.distanceTo(world) >= _trailMinStepM) {
        trail.add(world);
        if (trail.length > _trailCap) trail.removeAt(0);
      }
      if (trail.length >= 2) {
        final pts = [for (final p in trail) origin.worldToScene(p)];
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
        fs.UnlitMaterial()
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
