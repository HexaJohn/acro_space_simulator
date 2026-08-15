// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Scatter render-frame maths: node transform composed with an instance
// transform must land a prop at worldToScene of its true world position, at
// its true scene scale.
//
// This is the gate the double-scale bug slipped past: instance offsets and
// billboard centres are written in SCENE units, and the shared node transform
// once multiplied lengthToScene on top — every prop mesh collapsed to
// millimetres (only billboards ever rendered) and the imposter cards crushed
// onto the quantised anchor point, floating well off the ground. No test
// composed the two halves, so both halves looked individually plausible.

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/scatter/prop_catalog.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_instance.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scatter/scatter_nodes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  test('node x instance transform lands a prop at worldToScene(its position)',
      () {
    // A spinning moon-sized body away from the origin, numbers chosen ugly on
    // purpose. The FOCUS sits a few hundred metres from the prop — the real
    // flight configuration (the floating origin follows the camera), and a
    // requirement of the assertion tolerances: this vector_math variant
    // stores matrices and vectors in FLOAT32, so translations quantise at
    // ~1e-7 of their magnitude. Near the focus that is nanometres; put the
    // focus thousands of kilometres away (as an earlier draft of this test
    // did) and the quantisation alone reads as a phantom 3% scale error.
    final bodyWorld = Vector3(3.84e8, -1.2e7, 5.5e6);
    final bodyQuat =
        Quaternion.axisAngle(Vector3(0.1, 0.2, 0.97).normalized, 1.37);

    // A prop on the surface, anchored to a quantised point ~200 m away.
    final positionBF = Vector3(9.1e5, 1.2e6, 8.2e5).normalized * 1.7374e6;
    final anchorBF = Vector3(
      (positionBF.x / 256).roundToDouble() * 256,
      (positionBF.y / 256).roundToDouble() * 256,
      (positionBF.z / 256).roundToDouble() * 256,
    );
    final origin = FloatingOrigin()
      ..focusWorld = bodyWorld +
          bodyQuat.rotate(positionBF) +
          Vector3(120.0, -80.0, 45.0);
    final instance = ScatterInstance(
      kind: PropKind.boulder,
      seed: 7,
      positionBF: positionBF,
      upBF: positionBF.normalized,
      yaw: 0.8,
      scale: 1.4,
    );

    final composed =
        ScatterNodes.batchTransform(origin, bodyWorld, bodyQuat, anchorBF) *
            ScatterNodes.instanceTransform(instance, anchorBF) as vm.Matrix4;

    // Where the prop's origin must land: the scene-space image of its true
    // world position.
    final world = bodyWorld + bodyQuat.rotate(positionBF);
    final want = origin.worldToScene(world);
    final got = composed.transform3(vm.Vector3.zero());
    expect((got - want).length, lessThan(1e-3),
        reason: 'prop origin off by ${(got - want).length} scene units '
            '(${((got - want).length / kRenderScale).toStringAsFixed(1)} m)');

    // And the composed scale must be lengthToScene(scale) ONCE — the
    // double-scale collapse was exactly this assertion failing by x1000.
    final unitZ = composed.transform3(vm.Vector3(0, 0, 1)) - got;
    // Tolerance sized for float32 matrix storage, far below the x1000 the
    // double-scale bug produced.
    expect(unitZ.length, closeTo(lengthToScene(instance.scale), 1e-7),
        reason: 'prop scale is ${unitZ.length} scene units per model unit, '
            'want ${lengthToScene(instance.scale)}');

    // The prop's local +Z (grown-along axis) must map to the body-frame up
    // rotated into the world — standing on the surface normal, co-rotating.
    final upWorld = bodyQuat.rotate(instance.upBF);
    final upScene = vm.Vector3(upWorld.x, upWorld.y, upWorld.z);
    final err = math.acos(
        (unitZ.normalized().dot(upScene)).clamp(-1.0, 1.0));
    // Float32 rotation entries cost ~0.01 deg; a real frame bug costs degrees.
    expect(err, lessThan(1e-3),
        reason: 'prop up axis tilted ${err * 180 / math.pi} deg off the '
            'surface normal');
  });

  test('zoom gate retriggers LOD selection when the eye genuinely moves', () {
    // The first build must always fire...
    expect(ScatterNodes.zoomInvalidates(double.nan, 50), isTrue);
    // ...a sub-threshold drift must not (per-frame instance churn)...
    expect(ScatterNodes.zoomInvalidates(100, 105), isFalse);
    // ...and crossing 10% either way must. Without this the levels picked at
    // the spawn camera (150 m out -> all billboards) froze forever: walking
    // up to a rock never promoted it to a mesh.
    expect(ScatterNodes.zoomInvalidates(100, 80), isTrue);
    expect(ScatterNodes.zoomInvalidates(100, 130), isTrue);
  });
}
