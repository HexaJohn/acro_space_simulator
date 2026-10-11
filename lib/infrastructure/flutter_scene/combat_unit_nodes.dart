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
/// **Batched** (Spike S item 4, found live): one node per box cost 10.8 ms of
/// frame at 48 soldiers and 64 tracers, a draw call each. Now every soldier
/// of a side is one mesh and every tracer of a side another — four draws in
/// all — rebuilt each frame from the marks, in scene units about the
/// floating origin.
library;

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

class CombatUnitMark {
  const CombatUnitMark(this.key, this.bodyId, this.feetBF, {required this.attacker, this.emplacement = false});

  /// Stable while the unit lives: `<formation>:<member>`.
  final String key;
  final String bodyId;
  final Vector3 feetBF;
  final bool attacker;
  final bool emplacement;
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

/// Boxes gathered into one mesh: centre, three axes (unit, scene frame) and
/// half-extents in scene units, emitted with both windings so no face is lost
/// to the culling whichever way the image is mirrored (coord_convert.dart).
class _BoxBatch {
  final List<double> pos = [];
  final List<double> nrm = [];
  final List<int> idx = [];

  bool get isEmpty => idx.isEmpty;

  void box(vm.Vector3 c, vm.Vector3 x, vm.Vector3 y, vm.Vector3 z, double hx, double hy, double hz) {
    void face(vm.Vector3 n, double hn, vm.Vector3 a, double ha, vm.Vector3 b, double hb) {
      final base = pos.length ~/ 3;
      final fc = c + n * hn;
      for (final (sa, sb) in const [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]) {
        final p = fc + a * (sa * ha) + b * (sb * hb);
        pos.addAll([p.x, p.y, p.z]);
        nrm.addAll([n.x, n.y, n.z]);
      }
      idx.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
      idx.addAll([base, base + 2, base + 1, base, base + 3, base + 2]);
    }

    face(z, hz, x, hx, y, hy);
    face(-z, hz, y, hy, x, hx);
    face(x, hx, y, hy, z, hz);
    face(-x, hx, z, hz, y, hy);
    face(y, hy, z, hz, x, hx);
    face(-y, hy, x, hx, z, hz);
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
  final List<fs.Node> _shown = [];

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

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    final sw = Stopwatch()..start();
    for (final n in _shown) {
      _scene.remove(n);
    }
    _shown.clear();
    if (CombatUnitState.units.isEmpty && CombatUnitState.tracers.isEmpty) {
      CombatUnitState.lastUpdateMs = sw.elapsedMicroseconds / 1000;
      return;
    }
    final att = _BoxBatch(), def = _BoxBatch(), tAtt = _BoxBatch(), tDef = _BoxBatch();
    final m = lengthToScene(1);
    for (final u in CombatUnitState.units) {
      final body = snap.bodies[u.bodyId];
      if (body == null) continue;
      final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final feet = origin.worldToScene(Vector3(body.px, body.py, body.pz) + q.rotate(u.feetBF));
      final up = q.rotate(u.feetBF.normalized);
      final ref = up.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
      final r = ref.cross(up).normalized;
      final f = up.cross(r);
      final z = vm.Vector3(up.x, up.y, up.z), x = vm.Vector3(r.x, r.y, r.z), y = vm.Vector3(f.x, f.y, f.z);
      final b = u.attacker ? att : def;
      vm.Vector3 at(double h) => feet + z * (h * m);
      if (u.emplacement) {
        b.box(at(0.45), x, y, z, 0.8 * m, 0.8 * m, 0.45 * m);
        b.box(at(1.05), x, y, z, 0.35 * m, 0.35 * m, 0.18 * m);
        b.box(at(1.1) + y * (0.7 * m), x, y, z, 0.06 * m, 0.6 * m, 0.06 * m);
      } else {
        b.box(at(0.4), x, y, z, 0.18 * m, 0.12 * m, 0.4 * m);
        b.box(at(1.15), x, y, z, 0.25 * m, 0.15 * m, 0.35 * m);
        b.box(at(1.65), x, y, z, 0.13 * m, 0.13 * m, 0.14 * m);
      }
    }
    var drawn = 0;
    for (final t in CombatUnitState.tracers) {
      if (drawn++ >= maxTracers) break;
      final body = snap.bodies[t.bodyId];
      if (body == null) continue;
      final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final at = Vector3(body.px, body.py, body.pz);
      final a = origin.worldToScene(at + q.rotate(t.fromBF));
      final bb = origin.worldToScene(at + q.rotate(t.toBF));
      final d = bb - a;
      final len = d.length;
      if (len < 1e-9) continue;
      final z = d / len;
      final ref = z.z.abs() < 0.9 ? vm.Vector3(0, 0, 1) : vm.Vector3(1, 0, 0);
      final x = ref.cross(z)..normalize();
      final y = z.cross(x);
      (t.attacker ? tAtt : tDef).box(a + d * 0.5, x, y, z, 0.03 * m, 0.03 * m, len / 2);
    }
    for (final (batch, mat) in [(att, _attacker), (def, _defender), (tAtt, _tracerAtt), (tDef, _tracerDef)]) {
      if (batch.isEmpty) continue;
      final node = fs.Node(mesh: fs.Mesh(batch.geometry(), mat));
      _scene.add(node);
      _shown.add(node);
    }
    CombatUnitState.lastUpdateMs = sw.elapsedMicroseconds / 1000;
  }
}
