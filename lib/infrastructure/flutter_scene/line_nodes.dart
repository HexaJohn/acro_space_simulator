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
/// Line points are world positions rebased against the floating origin, so
/// every polyline is rebuilt each frame (the origin moves with the focus).
/// Point counts are small (tens to hundreds); the rebuild is cheap relative
/// to the per-frame camera update PolylineGeometry does internally anyway.
class LineNodes {
  LineNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, fs.Node> _nodes = {};
  // Live polyline geometries: each needs updateForCamera every frame (the
  // strip is a collapsed placeholder until then — SceneView does NOT call
  // it; that is the caller's job per the PolylineGeometry contract).
  final Map<String, fs.PolylineGeometry> _lines = {};

  // DEFERRED RETIREMENT: replaced meshes are held here for a few frames
  // before their last reference drops. Releasing immediately lets the GPU
  // buffers free while a previous frame still reads them (use-after-free:
  // broken dashes / garbage shards, worse the faster the camera moves).
  final List<(int, fs.Mesh)> _retired = [];
  int _frame = 0;
  static const int _retireAfterFrames = 6;

  // Flown-trail breadcrumbs per vessel, absolute world metres (doubles).
  final Map<String, List<Vector3>> _trails = {};
  static const int _trailCap = 240;
  static const double _trailMinStepM = 500.0; // drop denser samples

  // Parity with the software painter: rails cool gray, predicted paths the
  // painter's green, trails fading cyan. Rails run brighter than the
  // painter's: at system zoom they compete with the Milky Way backdrop.
  static final vm.Vector4 _railColor = vm.Vector4(0.55, 0.62, 0.7, 0.85);
  static final vm.Vector4 _pathColor = vm.Vector4(0.5, 0.88, 0.56, 0.9);
  static final vm.Vector4 _trailColor = vm.Vector4(0.35, 0.75, 1.0, 0.9);

  /// Apparent-size window (px) for orbit rails. Below the floor a rail is
  /// sub-pixel shimmer; above the ceiling the ring dwarfs the viewport and
  /// its arc is just a clutter line through the frame (the "zoomed way in"
  /// case) — rails belong to the zoomed-out map view.
  static const double _railMinApparentPx = 40.0;

  void update(WorldSnapshot snap, FloatingOrigin origin,
      {SceneCamera? camera, ui.Size? viewport}) {
    _frame++;
    _retired.removeWhere((e) => _frame - e.$1 > _retireAfterFrames);
    final seen = <String>{};

    // Body orbit rails (closed rings, root-relative metres).
    for (final b in snap.bodies.values) {
      if (b.orbit.length < 6) continue;

      if (camera != null) {
        // Apparent ring size: the orbit's radius about its parent projected
        // at the ring centre's distance. Rails draw only when the ring is
        // both resolvable and roughly frameable.
        final first =
            Vector3(b.orbit[0], b.orbit[1], b.orbit[2]);
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
        // the sky as near-plane-clipped dashes — pure clutter (the Moon's
        // rail seen from Earth orbit, Earth's own rail at close zoom).
        // CAMERA distance, not focus distance: zooming way out moves the
        // eye far outside these rings, and the rails come back for the
        // system map.
        final centreDist =
            (origin.worldToRel(centre) - camera.eyeOffset).length;
        if (centreDist < 2.0 * ringRadiusM) continue;

        final apparentPx = camera.radiusPx(origin.worldToRel(centre), ringRadiusM);
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
      _upsert('rail/${b.id}', seen, pts, _railColor, width: 2.5);
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
              Vector3(v.trajectory[i], v.trajectory[i + 1],
                  v.trajectory[i + 2])));
        }
        _upsert('path/${v.id}', seen, pts, _pathColor, width: 2.0);
      }

      // Flown trail: accumulate world breadcrumbs, faded tail -> head.
      final world = bodyPos + Vector3(v.px, v.py, v.pz);
      final trail = _trails.putIfAbsent(v.id, () => []);
      if (trail.isEmpty ||
          trail.last.distanceTo(world) >= _trailMinStepM) {
        trail.add(world);
        if (trail.length > _trailCap) trail.removeAt(0);
      }
      if (trail.length >= 2) {
        final pts = [for (final p in trail) origin.worldToScene(p)];
        // PREMULTIPLIED alpha: the pipeline blends premultiplied colors, so
        // a fading tail must scale RGB by alpha too — straight-alpha vertex
        // colors render as dark boxes where alpha approaches zero.
        final colors = <vm.Vector4>[
          for (var i = 0; i < pts.length; i++)
            () {
              final a = _trailColor.w * i / (pts.length - 1);
              return vm.Vector4(_trailColor.x * a, _trailColor.y * a,
                  _trailColor.z * a, a);
            }(),
        ];
        _upsert('trail/${v.id}', seen, pts, _trailColor,
            width: 2.0, perVertexColor: colors);
      }
    }

    _nodes.removeWhere((id, node) {
      if (seen.contains(id)) return false;
      _scene.remove(node);
      _lines.remove(id);
      return true;
    });
    _trails.removeWhere((id, _) => !snap.vessels.containsKey(id));
  }

  /// Regenerate every camera-facing strip for this frame's camera. Must run
  /// after [update] and before the scene renders.
  ///
  /// Defensive per-line: a transient degenerate camera (e.g. mid camera-mode
  /// switch, zero-size viewport) makes the view-projection singular and
  /// PolylineGeometry's screen-space expansion throws — skip that line for
  /// one frame rather than killing the render.
  void updateForCamera(fs.Camera camera, ui.Size viewport) {
    if (viewport.width <= 0 || viewport.height <= 0) return;
    for (final line in _lines.values) {
      try {
        line.updateForCamera(camera, viewport);
      } on ArgumentError {
        // Singular matrix this frame; the strip keeps last frame's shape.
      }
    }
  }

  void _upsert(
    String id,
    Set<String> seen,
    List<vm.Vector3> pts,
    vm.Vector4 color, {
    required double width,
    List<vm.Vector4>? perVertexColor,
  }) {
    if (pts.length < 2) return;
    seen.add(id);
    final geometry = fs.PolylineGeometry(
      pts,
      width: width,
      widthMode: fs.PolylineWidthMode.screenPixels,
      perVertexColor: perVertexColor,
    );
    _lines[id] = geometry;
    // Blend + PREMULTIPLIED colour: AlphaMode.opaque (default) ignores
    // alpha entirely, and the translucent pass blends premultiplied — a
    // straight-alpha tint darkens the line against bright surfaces. When
    // per-vertex colours (already premultiplied) carry the shading, the
    // material stays white so the tint isn't applied twice.
    final tint = perVertexColor != null
        ? vm.Vector4(1, 1, 1, 1)
        : vm.Vector4(
            color.x * color.w, color.y * color.w, color.z * color.w, color.w);
    final mesh = fs.Mesh(
      geometry,
      fs.UnlitMaterial()
        ..baseColorFactor = tint
        ..alphaMode = fs.AlphaMode.blend,
    );
    final node = _nodes[id];
    if (node == null) {
      final n = fs.Node(mesh: mesh);
      _scene.add(n);
      _nodes[id] = n;
    } else {
      final old = node.mesh;
      if (old != null) _retired.add((_frame, old));
      node.mesh = mesh;
    }
  }
}
