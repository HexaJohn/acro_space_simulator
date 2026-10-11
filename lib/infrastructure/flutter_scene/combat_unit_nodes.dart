// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The joined battle's soldiers and tracers (docs/plans/combat.md §7G).
///
/// Programmer art, as the walker is: a soldier is three boxes in its side's
/// colour, an emplacement a squat nest with a barrel, a tracer a thin bright
/// box from muzzle to impact. Fed by static [CombatUnitState] the host writes
/// each frame, body-fixed, as the walker's body is: the bubble is view state
/// and never crosses the wire.
///
/// **Batched and cached** (Spike S item 4, found live): one node per box cost
/// 10.8 ms of frame at 48 soldiers and 64 tracers, a draw call each; one mesh
/// per side rebuilt every frame still cost 6 ms of CPU. Now the meshes are
/// built in body-fixed metres about an anchor and placed by one node
/// transform (the body's spin, the floating origin), so units standing still
/// are built once per change of who stands where; only the moving ones and
/// the tracers are rebuilt each frame, in plain doubles.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

class CombatUnitMark {
  const CombatUnitMark(this.key, this.bodyId, this.feetBF,
      {required this.attacker, this.emplacement = false, this.moving = false});

  /// Stable while the unit lives: `<formation>:<member>`.
  final String key;
  final String bodyId;
  final Vector3 feetBF;
  final bool attacker;
  final bool emplacement;

  /// Walking this frame: drawn from the per-frame batch.
  final bool moving;
}

class CombatTracerMark {
  const CombatTracerMark(this.bodyId, this.fromBF, this.toBF, {required this.attacker});
  final String bodyId;
  final Vector3 fromBF, toBF;
  final bool attacker;
}

abstract final class CombatUnitState {
  static List<CombatUnitMark> units = const [];
  static List<CombatTracerMark> tracers = const [];

  /// What the last update cost, ms (Spike S item 4).
  static double lastUpdateMs = 0;

  static void clear() {
    units = const [];
    tracers = const [];
  }
}

/// Boxes gathered into one mesh, in metres × the render scale about an
/// anchor, axes body-fixed. Both windings, so no face is lost to the culling
/// whichever way the image is mirrored (coord_convert.dart).
class _BoxBatch {
  final List<double> pos = [];
  final List<double> nrm = [];
  final List<int> idx = [];

  bool get isEmpty => idx.isEmpty;

  /// A box centred at [c] (relative to the anchor, metres) with unit axes
  /// [x], [y], [z] and half-extents in metres.
  void box(double cx, double cy, double cz, List<double> x, List<double> y, List<double> z, double hx, double hy,
      double hz) {
    const k = kRenderScale;
    void face(List<double> n, double hn, List<double> a, double ha, List<double> b, double hb) {
      final base = pos.length ~/ 3;
      final fx = cx + n[0] * hn, fy = cy + n[1] * hn, fz = cz + n[2] * hn;
      for (var v = 0; v < 4; v++) {
        final sa = (v == 1 || v == 2) ? ha : -ha;
        final sb = v >= 2 ? hb : -hb;
        pos
          ..add((fx + a[0] * sa + b[0] * sb) * k)
          ..add((fy + a[1] * sa + b[1] * sb) * k)
          ..add((fz + a[2] * sa + b[2] * sb) * k);
        nrm
          ..add(n[0])
          ..add(n[1])
          ..add(n[2]);
      }
      idx
        ..addAll([base, base + 1, base + 2, base, base + 2, base + 3])
        ..addAll([base, base + 2, base + 1, base, base + 3, base + 2]);
    }

    final nx = [-x[0], -x[1], -x[2]], ny = [-y[0], -y[1], -y[2]], nz = [-z[0], -z[1], -z[2]];
    face(z, hz, x, hx, y, hy);
    face(nz, hz, y, hy, x, hx);
    face(x, hx, y, hy, z, hz);
    face(nx, hx, z, hz, y, hy);
    face(y, hy, z, hz, x, hx);
    face(ny, hy, x, hx, z, hz);
  }

  fs.MeshGeometry geometry() => fs.MeshGeometry.fromArrays(
        positions: Float32List.fromList(pos),
        normals: Float32List.fromList(nrm),
        indices: idx,
      );
}

class CombatUnitNodes {
  CombatUnitNodes(this._scene);

  final fs.Scene _scene;

  /// Tracers drawn at most.
  static const int maxTracers = 64;

  static final _attacker = fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.30, 0.55, 0.95, 1)
    ..roughnessFactor = 0.7;
  static final _defender = fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.85, 0.35, 0.25, 1)
    ..roughnessFactor = 0.7;
  static final _tracerAtt = fs.UnlitMaterial()..baseColorFactor = vm.Vector4(1.0, 0.95, 0.6, 1);
  static final _tracerDef = fs.UnlitMaterial()..baseColorFactor = vm.Vector4(1.0, 0.45, 0.3, 1);

  /// The anchor every mesh is built about, and the body it is on.
  Vector3? _anchor;
  String? _bodyId;

  /// Standing units' meshes, cached until who stands where changes.
  String _staticKey = '';
  final List<fs.Node> _static = [];
  final List<fs.Node> _dynamic = [];

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    final sw = Stopwatch()..start();
    for (final n in _dynamic) {
      _scene.remove(n);
    }
    _dynamic.clear();
    final units = CombatUnitState.units, tracers = CombatUnitState.tracers;
    if (units.isEmpty && tracers.isEmpty) {
      _dropStatic();
      CombatUnitState.lastUpdateMs = sw.elapsedMicroseconds / 1000;
      return;
    }
    final bodyId = units.isNotEmpty ? units.first.bodyId : tracers.first.bodyId;
    final body = snap.bodies[bodyId];
    if (body == null) return;
    if (bodyId != _bodyId || _anchor == null) {
      _bodyId = bodyId;
      _anchor = units.isNotEmpty ? units.first.feetBF : tracers.first.fromBF;
      _dropStatic();
    }
    final anchor = _anchor!;
    final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
    final transform = vm.Matrix4.compose(
      origin.worldToScene(Vector3(body.px, body.py, body.pz) + q.rotate(anchor)),
      quatToScene(q),
      vm.Vector3.all(1),
    );

    // The standing: rebuilt only when the set or a place changes.
    final buf = StringBuffer();
    for (final u in units) {
      if (u.moving || u.bodyId != bodyId) continue;
      buf
        ..write(u.key)
        ..write('@')
        ..write((u.feetBF.x * 4).round())
        ..write(',')
        ..write((u.feetBF.y * 4).round())
        ..write(';');
    }
    final key = buf.toString();
    if (key != _staticKey) {
      _dropStatic();
      _staticKey = key;
      final att = _BoxBatch(), def = _BoxBatch();
      for (final u in units) {
        if (u.moving || u.bodyId != bodyId) continue;
        _figure(u.attacker ? att : def, u, anchor);
      }
      _static.addAll(_nodes([(att, _attacker), (def, _defender)]));
    }
    for (final n in _static) {
      n.localTransform = transform;
    }

    // The moving, and the tracers: every frame.
    final att = _BoxBatch(), def = _BoxBatch(), tAtt = _BoxBatch(), tDef = _BoxBatch();
    for (final u in units) {
      if (!u.moving || u.bodyId != bodyId) continue;
      _figure(u.attacker ? att : def, u, anchor);
    }
    var drawn = 0;
    for (final t in tracers) {
      if (t.bodyId != bodyId) continue;
      if (drawn++ >= maxTracers) break;
      final ax = t.fromBF.x - anchor.x, ay = t.fromBF.y - anchor.y, az = t.fromBF.z - anchor.z;
      final dx = t.toBF.x - t.fromBF.x, dy = t.toBF.y - t.fromBF.y, dz = t.toBF.z - t.fromBF.z;
      final len = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (len < 1e-9) continue;
      final z = [dx / len, dy / len, dz / len];
      final (x, y) = _basis(z);
      (t.attacker ? tAtt : tDef).box(ax + dx / 2, ay + dy / 2, az + dz / 2, x, y, z, 0.03, 0.03, len / 2);
    }
    final made = _nodes([(att, _attacker), (def, _defender), (tAtt, _tracerAtt), (tDef, _tracerDef)]);
    for (final n in made) {
      n.localTransform = transform;
    }
    _dynamic.addAll(made);
    CombatUnitState.lastUpdateMs = sw.elapsedMicroseconds / 1000;
  }

  List<fs.Node> _nodes(List<(_BoxBatch, fs.Material)> batches) {
    final out = <fs.Node>[];
    for (final (b, mat) in batches) {
      if (b.isEmpty) continue;
      final node = fs.Node(mesh: fs.Mesh(b.geometry(), mat));
      _scene.add(node);
      out.add(node);
    }
    return out;
  }

  void _dropStatic() {
    for (final n in _static) {
      _scene.remove(n);
    }
    _static.clear();
    _staticKey = '';
  }

  /// A unit vector's two companions.
  static (List<double>, List<double>) _basis(List<double> z) {
    final ref = z[2].abs() < 0.9 ? const [0.0, 0.0, 1.0] : const [1.0, 0.0, 0.0];
    var x = [ref[1] * z[2] - ref[2] * z[1], ref[2] * z[0] - ref[0] * z[2], ref[0] * z[1] - ref[1] * z[0]];
    final xl = math.sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2]);
    x = [x[0] / xl, x[1] / xl, x[2] / xl];
    final y = [z[1] * x[2] - z[2] * x[1], z[2] * x[0] - z[0] * x[2], z[0] * x[1] - z[1] * x[0]];
    return (x, y);
  }

  /// One figure, standing on its feet along the local vertical.
  static void _figure(_BoxBatch b, CombatUnitMark u, Vector3 anchor) {
    final fx = u.feetBF.x - anchor.x, fy = u.feetBF.y - anchor.y, fz = u.feetBF.z - anchor.z;
    final l = u.feetBF.length;
    final z = [u.feetBF.x / l, u.feetBF.y / l, u.feetBF.z / l];
    final (x, y) = _basis(z);
    void at(double h, double hx, double hy, double hz, {double fwd = 0}) =>
        b.box(fx + z[0] * h + y[0] * fwd, fy + z[1] * h + y[1] * fwd, fz + z[2] * h + y[2] * fwd, x, y, z, hx, hy, hz);
    if (u.emplacement) {
      at(0.45, 0.8, 0.8, 0.45);
      at(1.05, 0.35, 0.35, 0.18);
      at(1.1, 0.06, 0.6, 0.06, fwd: 0.7);
    } else {
      at(0.4, 0.18, 0.12, 0.4);
      at(1.15, 0.25, 0.15, 0.35);
      at(1.65, 0.13, 0.13, 0.14);
    }
  }
}
