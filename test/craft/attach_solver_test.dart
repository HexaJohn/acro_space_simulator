// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/attach_solver.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_parts.dart';

/// A mate is not "put the part roughly there": the two nodes must land on the
/// same point with opposed outward normals, or the craft has a visible seam and
/// the bake puts mass in the wrong place.
void main() {
  const solver = AttachSolver.standard;

  void expectVector(Vector3 actual, Vector3 expected, {double tol = 1e-9}) {
    expect(actual.x, closeTo(expected.x, tol), reason: 'x of $actual');
    expect(actual.y, closeTo(expected.y, tol), reason: 'y of $actual');
    expect(actual.z, closeTo(expected.z, tol), reason: 'z of $actual');
  }

  group('stack mate', () {
    test('nodes coincide and their directions are anti-parallel', () {
      // Hull sitting at the origin; mate an engine under its bottom node.
      const hull = PlacedPart(def: testHull, instanceId: 'hull');
      final engine = testEngine();

      final parentNode = hull.nodeInBody('bottom')!;
      final childNode = engine.node('top')!;
      final mate = solver.solveMate(
          parentNodeInBody: parentNode, childNodeLocal: childNode);

      // Where the engine's own node ends up in the body frame.
      final childAt = mate.position + mate.rotation.rotate(childNode.position);
      expectVector(childAt, parentNode.position);

      final childDir = mate.rotation.rotate(childNode.direction);
      expect(childDir.dot(parentNode.direction), closeTo(-1, 1e-9),
          reason: 'outward normals must oppose, not merely differ');

      // Hull bottom is at z=-1, engine node is 0.5 above its origin -> z=-1.5.
      expectVector(mate.position, const Vector3(0, 0, -1.5));
      expect(mate.rotation.w, closeTo(1, 1e-9),
          reason: 'a -Z node meeting a +Z node needs no turn');
    });

    test('a node pointing sideways turns the child to match', () {
      // Synthetic parent node on the +Y skin, treated as a stack ring.
      const parent = AttachNode(
          name: 'ring', position: Vector3(0, 3, 0), direction: Vector3.unitY);
      final engine = testEngine();
      final childNode = engine.node('top')!;

      final mate = solver.solveMate(
          parentNodeInBody: parent, childNodeLocal: childNode);

      final childAt = mate.position + mate.rotation.rotate(childNode.position);
      expectVector(childAt, parent.position);
      expectVector(mate.rotation.rotate(childNode.direction),
          const Vector3(0, -1, 0));
    });

    test('roll spins the child about the mate axis without breaking the joint',
        () {
      const hull = PlacedPart(def: testHull, instanceId: 'hull');
      final engine = testEngine();
      final parentNode = hull.nodeInBody('bottom')!;
      final childNode = engine.node('top')!;

      final mate = solver.solveMate(
        parentNodeInBody: parentNode,
        childNodeLocal: childNode,
        roll: math.pi / 2,
      );

      // Joint still closed...
      final childAt = mate.position + mate.rotation.rotate(childNode.position);
      expectVector(childAt, parentNode.position);
      // ...but the part is rolled: the mate axis here is body +Z (the opposite
      // of the hull's downward node), so local +X swings round to body +Y.
      expectVector(mate.rotation.rotate(Vector3.unitX), Vector3.unitY);
    });
  });

  group('surface mate', () {
    test('the part ends up pointing outward from the skin', () {
      const hull = PlacedPart(def: testHull, instanceId: 'hull');
      final parentNode = hull.nodeInBody('skinY')!; // +Y skin, 1 m radius
      final childNode = testBlock.node('mount')!;

      final mate = solver.solveMate(
          parentNodeInBody: parentNode, childNodeLocal: childNode);

      // The block's body (local +X) faces away from the hull.
      expectVector(mate.rotation.rotate(Vector3.unitX), Vector3.unitY);
      // Its mount face presses into the skin.
      expectVector(
          mate.rotation.rotate(childNode.direction), const Vector3(0, -1, 0));
      // Origin sits 0.1 m proud of the 1 m skin.
      expectVector(mate.position, const Vector3(0, 1.1, 0));
    });

    test('a surface mate ignores the diameter class a stack mate enforces', () {
      const skin = AttachNode(
        name: 'skin',
        position: Vector3(2, 0, 0),
        direction: Vector3.unitX,
        size: 4.0,
        kind: AttachKind.surface,
      );
      final mount = testBlock.node('mount')!; // size 0.3
      expect(solver.sizesCompatible(skin, mount), isTrue,
          reason: 'a small block must be allowed to bolt to a big hull');

      final wide = testHullWide.node('top')!; // 2.5 m stack
      final narrow = testHull.node('bottom')!; // 1.25 m stack
      expect(solver.sizesCompatible(wide, narrow), isFalse);
    });
  });

  group('radial symmetry', () {
    test('4x puts copies at 90 degrees with their orientations carried round',
        () {
      const hull = PlacedPart(def: testHull, instanceId: 'hull');
      final seed = solver.solveMate(
        parentNodeInBody: hull.nodeInBody('skinX')!,
        childNodeLocal: testBlock.node('mount')!,
      );
      final copies = solver.radialCopies(
          position: seed.position, rotation: seed.rotation, count: 4);

      expect(copies.length, 4);
      const expectedOut = [
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
        Vector3(-1, 0, 0),
        Vector3(0, -1, 0),
      ];
      for (var k = 0; k < 4; k++) {
        // Each copy sits on its own quadrant of the 1.1 m radius...
        expectVector(copies[k].position, expectedOut[k] * 1.1, tol: 1e-12);
        // ...and FACES that way too, which is the whole point of carrying the
        // rotation through the spin instead of only the position.
        expectVector(copies[k].rotation.rotate(Vector3.unitX), expectedOut[k],
            tol: 1e-12);
      }
      // Four evenly spaced copies balance about the axis.
      final sum = copies.fold(Vector3.zero, (Vector3 s, c) => s + c.position);
      expect(sum.length, closeTo(0, 1e-12));
    });

    test('3x spaces copies 120 degrees apart and keeps the radius', () {
      final copies = solver.radialCopies(
        position: const Vector3(2, 0, -0.5),
        rotation: Quaternion.identity,
        count: 3,
      );
      expect(copies.length, 3);
      for (final c in copies) {
        expect(math.sqrt(c.position.x * c.position.x + c.position.y * c.position.y),
            closeTo(2, 1e-12));
        expect(c.position.z, closeTo(-0.5, 1e-12),
            reason: 'a spin about +Z must not change height');
      }
      final angle = math.atan2(copies[1].position.y, copies[1].position.x);
      expect(angle, closeTo(2 * math.pi / 3, 1e-12));
    });

    test('fewer than two copies is not symmetry', () {
      expect(
        () => solver.radialCopies(
            position: Vector3.unitX, rotation: Quaternion.identity, count: 1),
        throwsArgumentError,
      );
    });
  });

  group('mirror symmetry', () {
    test('a node reflects both its seat and its outward normal', () {
      const node = AttachNode(
        name: 'skin',
        position: Vector3(2, 0.5, 1),
        direction: Vector3(0.6, 0.8, 0),
        kind: AttachKind.surface,
      );
      final m = AttachSolver.mirrorNode(node, Vector3.unitX);
      expectVector(m.position, const Vector3(-2, 0.5, 1), tol: 1e-12);
      expectVector(m.direction, const Vector3(-0.6, 0.8, 0), tol: 1e-12);
      expect(m.kind, AttachKind.surface, reason: 'a mirror does not retype');
    });

    test('the copy stays bolted down and still points outward', () {
      const hull = PlacedPart(def: testHull, instanceId: 'hull');
      final parentNode = hull.nodeInBody('skinX')!; // +X skin
      final childNode = testBlock.node('mount')!;

      final m = solver.mirrorMate(
          parentNodeInBody: parentNode, childNodeLocal: childNode);

      // Seated on the reflected node...
      final reflectedSeat = AttachSolver.mirrorNode(parentNode, Vector3.unitX);
      final childAt = m.position + m.rotation.rotate(childNode.position);
      expectVector(childAt, reflectedSeat.position, tol: 1e-12);
      // ...and the block's body faces away from the hull, not through it. This
      // is exactly what a straight reflection of the ORIENTATION gets wrong.
      expectVector(m.rotation.rotate(Vector3.unitX), const Vector3(-1, 0, 0),
          tol: 1e-12);
      expectVector(m.position, const Vector3(-1.1, 0, 0), tol: 1e-12);
    });

    test('an off-axis mount mirrors, where a half-turn would only swing it',
        () {
      const node = AttachNode(
        name: 'wing',
        position: Vector3(2, 0.5, 1),
        direction: Vector3.unitX,
        size: 1.0,
        kind: AttachKind.surface,
      );
      final m = solver.mirrorMate(
          parentNodeInBody: node, childNodeLocal: testBlock.node('mount')!);
      // Mirrored: only X changes sign. A 180 deg spin about +Z would have
      // flipped Y too.
      expectVector(m.position, const Vector3(-2.1, 0.5, 1), tol: 1e-12);
    });

    test('a mount lying on the mirror plane is reported as un-mirrorable', () {
      const onPlane = AttachNode(
        name: 'nose',
        position: Vector3(0, 1, 0),
        direction: Vector3.unitY,
        kind: AttachKind.surface,
      );
      expect(solver.nodeLiesOnMirrorPlane(onPlane, Vector3.unitX), isTrue);
      const offPlane = AttachNode(
        name: 'skin',
        position: Vector3(1, 0, 0),
        direction: Vector3.unitX,
        kind: AttachKind.surface,
      );
      expect(solver.nodeLiesOnMirrorPlane(offPlane, Vector3.unitX), isFalse);
    });
  });

  group('findSnap', () {
    const hull = PlacedPart(def: testHull, instanceId: 'hull');

    test('finds the stack node under the cursor', () {
      final engine = testEngine();
      // Dragging the engine so its top node is 5 cm below the hull's bottom.
      final snap = solver.findSnap(
        parts: const [hull],
        def: engine,
        position: const Vector3(0, 0, -1.55),
      );
      expect(snap, isNotNull);
      expect(snap!.parentInstanceId, 'hull');
      expect(snap.parentNode, 'bottom');
      expect(snap.childNode, 'top');
      expect(snap.gap, closeTo(0.05, 1e-9));
      expectVector(snap.position, const Vector3(0, 0, -1.5));
    });

    test('returns null when nothing is in range', () {
      final snap = solver.findSnap(
        parts: const [hull],
        def: testEngine(),
        position: const Vector3(0, 0, -40),
      );
      expect(snap, isNull);
    });

    test('returns null when the kinds are incompatible', () {
      // The block only has a SURFACE node; park it right on the hull's stack
      // node so distance cannot be the reason it fails.
      final snap = solver.findSnap(
        parts: const [
          PlacedPart(def: testHullWide, instanceId: 'wide') // stack nodes only
        ],
        def: testBlock,
        position: const Vector3(0.1, 0, 1),
      );
      expect(snap, isNull);
    });

    test('returns null when the stack diameter classes disagree', () {
      final snap = solver.findSnap(
        parts: const [PlacedPart(def: testHullWide, instanceId: 'wide')],
        def: testHull, // 1.25 m nodes against 2.5 m nodes
        position: const Vector3(0, 0, 2.05),
      );
      expect(snap, isNull);
    });

    test('an occupied stack node is skipped for the next one along', () {
      // Same drag as the first case, but the bottom node is reported taken;
      // nothing else is within the snap radius, so there is no mate.
      final snap = solver.findSnap(
        parts: const [hull],
        def: testEngine(),
        position: const Vector3(0, 0, -1.55),
        isStackNodeOccupied: (id, node) => id == 'hull' && node == 'bottom',
      );
      expect(snap, isNull);
    });

    test('picks the nearer of two candidate nodes', () {
      const lower = PlacedPart(
          def: testHull, instanceId: 'lower', position: Vector3(0, 0, -4));
      final engine = testEngine();
      // Top node of `lower` is at z=-3, bottom node of `hull` at z=-1, and the
      // engine's own node lands at z=-3.1 — both are inside a 3 m radius, so
      // the answer has to come from ranking, not from range.
      final snap = solver.findSnap(
        parts: const [hull, lower],
        def: engine,
        position: const Vector3(0, 0, -3.6),
        radius: 3.0,
      );
      expect(snap, isNotNull);
      expect(snap!.parentInstanceId, 'lower');
      expect(snap.parentNode, 'top');
    });

    test('a spent node on the DRAGGED part is skipped too', () {
      // The dragged hull's top node is 5 cm under the parked hull's bottom, so
      // range and compatibility are both satisfied — but the caller reports
      // that node as already carrying something of its own, which leaves the
      // hull's out-of-range bottom node as the only other option.
      final snap = solver.findSnap(
        parts: const [hull],
        def: testHull,
        position: const Vector3(0, 0, -2.05),
        isChildNodeOccupied: (node) => node == 'top',
      );
      expect(snap, isNull);

      // Without the veto the same drag snaps, so the veto is what changed it.
      expect(
        solver.findSnap(
          parts: const [hull],
          def: testHull,
          position: const Vector3(0, 0, -2.05),
        )?.childNode,
        'top',
      );
    });

    test('excluded parts are never mated to', () {
      final snap = solver.findSnap(
        parts: const [hull],
        def: testEngine(),
        position: const Vector3(0, 0, -1.55),
        exclude: const {'hull'},
      );
      expect(snap, isNull);
    });
  });
}
