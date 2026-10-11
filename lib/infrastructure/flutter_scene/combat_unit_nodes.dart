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
library;

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

class CombatUnitNodes {
  CombatUnitNodes(this._scene);

  final fs.Scene _scene;
  final Map<String, fs.Node> _units = {};
  final List<String> _order = [];
  final List<fs.Node> _tracers = [];
  int _tracersShown = 0;

  static const int maxTracers = 64;

  static final _attacker = fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.30, 0.55, 0.95, 1)
    ..roughnessFactor = 0.7;
  static final _defender = fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.85, 0.35, 0.25, 1)
    ..roughnessFactor = 0.7;
  static final _dark = fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.18, 0.18, 0.2, 1)
    ..roughnessFactor = 0.6;
  static final _tracerAtt = fs.UnlitMaterial()..baseColorFactor = vm.Vector4(1.0, 0.95, 0.6, 1);
  static final _tracerDef = fs.UnlitMaterial()..baseColorFactor = vm.Vector4(1.0, 0.45, 0.3, 1);
  static final _box = fs.CuboidGeometry(vm.Vector3(1, 1, 1));

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    final sw = Stopwatch()..start();
    final seen = <String>[];
    for (final m in CombatUnitState.units) {
      final body = snap.bodies[m.bodyId];
      if (body == null) continue;
      seen.add(m.key);
      var node = _units[m.key];
      if (node == null) {
        node = _build(m);
        _units[m.key] = node;
        _order.add(m.key);
        _scene.add(node);
      }
      final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final up = q.rotate(m.feetBF.normalized);
      final world = Vector3(body.px, body.py, body.pz) + q.rotate(m.feetBF);
      node.localTransform = _frame(origin.worldToScene(world), up);
    }
    final gone = [for (final k in _order) if (!seen.contains(k)) k];
    for (final k in gone) {
      _scene.remove(_units.remove(k)!);
      _order.remove(k);
    }

    // Tracers from a fixed pool: shown, placed, and the rest taken out.
    final want = CombatUnitState.tracers.length < maxTracers ? CombatUnitState.tracers.length : maxTracers;
    while (_tracers.length < want) {
      _tracers.add(fs.Node(mesh: fs.Mesh(_box, _tracerAtt)));
    }
    for (var i = 0; i < want; i++) {
      final t = CombatUnitState.tracers[i];
      final body = snap.bodies[t.bodyId];
      final node = _tracers[i];
      if (i >= _tracersShown) _scene.add(node);
      if (body == null) continue;
      final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final at = Vector3(body.px, body.py, body.pz);
      final a = origin.worldToScene(at + q.rotate(t.fromBF));
      final b = origin.worldToScene(at + q.rotate(t.toBF));
      node.mesh = fs.Mesh(_box, t.attacker ? _tracerAtt : _tracerDef);
      node.localTransform = _segment(a, b, lengthToScene(0.05));
    }
    for (var i = want; i < _tracersShown; i++) {
      _scene.remove(_tracers[i]);
    }
    _tracersShown = want;
    CombatUnitState.lastUpdateMs = sw.elapsedMicroseconds / 1000;
  }

  /// A figure's frame: boots at [at], standing along [up], in metres.
  static vm.Matrix4 _frame(vm.Vector3 at, Vector3 up) {
    final u = up.normalized;
    final ref = u.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final r = ref.cross(u).normalized;
    final f = u.cross(r);
    // The scene keeps the domain's axes (coord_convert.dart): directions go
    // straight across, lengths in scene units.
    final s = lengthToScene(1);
    return vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(r.x * s, r.y * s, r.z * s, 0))
      ..setColumn(1, vm.Vector4(f.x * s, f.y * s, f.z * s, 0))
      ..setColumn(2, vm.Vector4(u.x * s, u.y * s, u.z * s, 0))
      ..setColumn(3, vm.Vector4(at.x, at.y, at.z, 1));
  }

  /// A unit box stretched from [a] to [b], [w] thick (scene units).
  static vm.Matrix4 _segment(vm.Vector3 a, vm.Vector3 b, double w) {
    final d = b - a;
    final len = d.length;
    final z = len < 1e-9 ? vm.Vector3(0, 1, 0) : d / len;
    final ref = z.z.abs() < 0.9 ? vm.Vector3(0, 0, 1) : vm.Vector3(1, 0, 0);
    final x = ref.cross(z)..normalize();
    final y = z.cross(x);
    final mid = a + d * 0.5;
    return vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(x.x * w, x.y * w, x.z * w, 0))
      ..setColumn(1, vm.Vector4(y.x * w, y.y * w, y.z * w, 0))
      ..setColumn(2, vm.Vector4(z.x * len, z.y * len, z.z * len, 0))
      ..setColumn(3, vm.Vector4(mid.x, mid.y, mid.z, 1));
  }

  fs.Node _build(CombatUnitMark m) {
    final root = fs.Node();
    final mat = m.attacker ? _attacker : _defender;
    fs.Node part(fs.Material mat, vm.Vector3 at, vm.Vector3 size) =>
        fs.Node(mesh: fs.Mesh(_box, mat))..localTransform = vm.Matrix4.compose(at, vm.Quaternion.identity(), size);
    if (m.emplacement) {
      root.add(part(_dark, vm.Vector3(0, 0, 0.45), vm.Vector3(1.6, 1.6, 0.9)));
      root.add(part(mat, vm.Vector3(0, 0, 1.05), vm.Vector3(0.7, 0.7, 0.35)));
      root.add(part(_dark, vm.Vector3(0, 0.7, 1.1), vm.Vector3(0.12, 1.2, 0.12)));
      return root;
    }
    root.add(part(_dark, vm.Vector3(0, 0, 0.4), vm.Vector3(0.36, 0.24, 0.8)));
    root.add(part(mat, vm.Vector3(0, 0, 1.15), vm.Vector3(0.5, 0.3, 0.7)));
    root.add(part(mat, vm.Vector3(0, 0, 1.65), vm.Vector3(0.26, 0.26, 0.28)));
    return root;
  }
}
