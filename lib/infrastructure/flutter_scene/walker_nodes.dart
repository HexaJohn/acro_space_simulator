// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

/// The walker's body, for third-person view.
///
/// **Programmer art, deliberately.** There is no humanoid mesh in the repo —
/// the only baked figures are LM parts — so the suit is assembled from engine
/// primitives: a capsule torso, a sphere helmet, a box PLSS pack and two leg
/// cylinders. It exists so third person frames a person instead of an empty
/// patch of ground, and so the scale of everything else (a 1.7 m figure beside
/// a lander, a boulder, a habitat) can finally be judged. Swap the whole class
/// for a real model when one exists; nothing outside it knows the shape.
///
/// Driven by STATIC fields rather than the world snapshot, because the walker
/// is view state: the anchor lives in `SimulationView`, never crosses the wire,
/// and no other client needs to see it. Same idiom as the terrain material's
/// tuning knobs.
class WalkerNodes {
  WalkerNodes(this._scene);

  final fs.Scene _scene;
  fs.Node? _root;

  /// Draw the figure at all. False in first person — you are inside its head.
  static bool visible = false;

  /// EYE position, focus-relative metres. The figure hangs BELOW this: the
  /// anchor the walker integrates is the eye, not the feet.
  static Vector3 eyeRel = Vector3.zero;

  /// Local up (unit, world frame) and the heading the figure faces.
  static Vector3 up = Vector3.unitZ;
  static Vector3 forward = Vector3.unitY;

  /// Eye height above the boots, metres — the figure is built to hang from it.
  static double eyeHeightM = 1.7;

  void update() {
    if (!visible) {
      final r = _root;
      if (r != null) {
        _scene.remove(r);
        _root = null;
      }
      return;
    }
    final root = _root ??= _build();
    if (_root != null && identical(root, _root) && root.parent == null) {
      _scene.add(root);
    }

    // Orthonormal frame: +Z up, +Y forward, +X = Y cross Z. The primitives are
    // authored in that frame, so the node transform is a pure rotation.
    final u = up.normalized;
    var f = forward - u * forward.dot(u);
    f = f.length < 1e-6 ? _anyPerpendicular(u) : f.normalized;
    final r = f.cross(u).normalized;

    // Feet, not eyes: the whole figure is modelled up from the boots.
    final feet = eyeRel - u * eyeHeightM;
    final m = vm.Matrix4.identity()
      ..setColumn(0, vm.Vector4(r.x, r.y, r.z, 0))
      ..setColumn(1, vm.Vector4(f.x, f.y, f.z, 0))
      ..setColumn(2, vm.Vector4(u.x, u.y, u.z, 0));
    final origin = relToScene(feet);
    m.setColumn(3, vm.Vector4(origin.x, origin.y, origin.z, 1));
    // The primitives are built in METRES; the scene is in kRenderScale units.
    root.localTransform = m * vm.Matrix4.diagonal3Values(
        lengthToScene(1), lengthToScene(1), lengthToScene(1));
  }

  static Vector3 _anyPerpendicular(Vector3 u) {
    final a = u.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    return u.cross(a).normalized;
  }

  /// One EVA suit, metres, standing on the origin and facing +Y.
  fs.Node _build() {
    final root = fs.Node();

    fs.Node part(fs.Geometry g, fs.Material mat, vm.Vector3 at,
        {vm.Vector3? scale}) {
      final n = fs.Node(mesh: fs.Mesh(g, mat));
      n.localTransform = vm.Matrix4.compose(
        at,
        vm.Quaternion.identity(),
        scale ?? vm.Vector3(1, 1, 1),
      );
      return n;
    }

    final suit = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.88, 0.88, 0.90, 1.0)
      ..roughnessFactor = 0.75
      ..metallicFactor = 0.05;
    final gold = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.85, 0.65, 0.15, 1.0)
      ..roughnessFactor = 0.25
      ..metallicFactor = 0.9;
    final dark = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.22, 0.23, 0.25, 1.0)
      ..roughnessFactor = 0.6
      ..metallicFactor = 0.2;

    // Torso 0.75 m tall, centred at 1.05 m; helmet at 1.55 m; boots below.
    root.add(part(fs.CapsuleGeometry(radius: 0.26, height: 0.75), suit,
        vm.Vector3(0, 0, 1.05)));
    root.add(part(fs.SphereGeometry(radius: 0.20), gold,
        vm.Vector3(0, 0.02, 1.55)));
    root.add(part(fs.CuboidGeometry(vm.Vector3(0.42, 0.20, 0.52)), dark,
        vm.Vector3(0, -0.26, 1.10)));
    for (final side in [-1.0, 1.0]) {
      root.add(part(fs.CylinderGeometry(bottomRadius: 0.11, topRadius: 0.11, height: 0.68), suit,
          vm.Vector3(0.14 * side, 0, 0.34)));
      root.add(part(fs.CapsuleGeometry(radius: 0.095, height: 0.55), suit,
          vm.Vector3(0.33 * side, 0, 1.08)));
    }
    return root;
  }
}
