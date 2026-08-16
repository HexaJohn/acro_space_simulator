// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_parts.dart';

/// The design aggregate is what a 3D editor drives, so it has to hold its
/// invariants against whatever order the player does things in — and it has to
/// keep the tree and the geometry telling the same story.
void main() {
  void expectVector(Vector3 actual, Vector3 expected, {double tol = 1e-9}) {
    expect(actual.x, closeTo(expected.x, tol), reason: 'x of $actual');
    expect(actual.y, closeTo(expected.y, tol), reason: 'y of $actual');
    expect(actual.z, closeTo(expected.z, tol), reason: 'z of $actual');
  }

  /// pod -> hull -> engine, a plain three-part stack down the +Z axis.
  CraftDesign stack() {
    final d = CraftDesign(name: 'Stack');
    d.addPart(def: testPod, instanceId: 'pod');
    d.attachPart(
      def: testHull,
      instanceId: 'hull',
      toInstanceId: 'pod',
      parentNode: 'bottom',
      childNode: 'top',
    );
    d.attachPart(
      def: testEngine(),
      instanceId: 'engine',
      toInstanceId: 'hull',
      parentNode: 'bottom',
      childNode: 'top',
    );
    return d;
  }

  group('placement', () {
    test('a mated part lands exactly where the two nodes coincide', () {
      final d = stack();
      // Pod bottom node z=-0.7; hull top node is 1 m above its origin.
      expectVector(d.partById('hull')!.position, const Vector3(0, 0, -1.7));
      // Hull bottom node z=-2.7; engine top node is 0.5 m above its origin.
      expectVector(d.partById('engine')!.position, const Vector3(0, 0, -3.2));
      for (final id in ['hull', 'engine']) {
        expect(d.partById(id)!.rotation.w, closeTo(1, 1e-12),
            reason: 'an axial stack needs no turn');
      }
    });

    test('a mated part inherits its parent\'s stage unless told otherwise', () {
      final d = CraftDesign(name: 'S');
      d.addPart(def: testPod, instanceId: 'pod', stage: 3);
      d.attachPart(
        def: testHull,
        instanceId: 'hull',
        toInstanceId: 'pod',
        parentNode: 'bottom',
        childNode: 'top',
      );
      expect(d.partById('hull')!.stage, 3);
    });

    test('duplicate instance ids are refused', () {
      final d = stack();
      expect(
        () => d.addPart(def: testHull, instanceId: 'hull'),
        throwsA(isA<StateError>()),
      );
    });

    test('a stack node carries at most one part', () {
      final d = stack();
      expect(
        () => d.attachPart(
          def: testEngine(),
          instanceId: 'engine2',
          toInstanceId: 'hull',
          parentNode: 'bottom',
          childNode: 'top',
        ),
        throwsA(isA<StateError>()),
      );
      // ...but a surface node hosts as many as you like.
      d.attachPart(
        def: testBlock,
        instanceId: 'blockX',
        toInstanceId: 'hull',
        parentNode: 'skinX',
        childNode: 'mount',
      );
      d.attachPart(
        def: testBlock,
        instanceId: 'blockY',
        toInstanceId: 'hull',
        parentNode: 'skinY',
        childNode: 'mount',
      );
      expect(d.partCount, 5);
    });

    test('a node spent holding a part on cannot take a second mate', () {
      final d = CraftDesign(name: 'S');
      d.addPart(def: testPod, instanceId: 'pod');
      d.attachPart(
        def: testHull,
        instanceId: 'hull',
        toInstanceId: 'pod',
        parentNode: 'bottom',
        childNode: 'top',
      );
      // The hull's top ring is spent holding the hull onto the pod. Nothing
      // else fits there — an engine mated to it would sit inside the pod.
      expect(
        () => d.attachPart(
          def: testEngine(),
          instanceId: 'engine',
          toInstanceId: 'hull',
          parentNode: 'top',
          childNode: 'top',
        ),
        throwsA(isA<StateError>()),
      );
      expect(d.partCount, 2, reason: 'a refused mate must leave no debris');
      expect(d.isStackNodeOccupied('hull', 'top'), isTrue);
    });

    test('re-mating onto a node the target hangs from is refused', () {
      final d = stack();
      d.addPart(
        def: testEngine(),
        instanceId: 'spare',
        position: const Vector3(0, 0, -8),
      );
      // Same trap through mate() rather than attachPart(): hull.top is the
      // node holding the hull onto the pod.
      expect(
        () => d.mate(
          instanceId: 'spare',
          toInstanceId: 'hull',
          parentNode: 'top',
          childNode: 'top',
        ),
        throwsA(isA<StateError>()),
      );
      expect(d.partById('spare')!.attachment, isNull);
    });

    test('a part cannot be re-mated through a node its own child holds', () {
      final d = stack();
      d.detach('hull');
      // hull.bottom carries the engine; seating the hull on the pod through
      // that same ring would put the engine and the pod in one place.
      expect(
        () => d.mate(
          instanceId: 'hull',
          toInstanceId: 'pod',
          parentNode: 'bottom',
          childNode: 'bottom',
        ),
        throwsA(isA<StateError>()),
      );
      // Its free top node is still a legal way back onto the pod.
      d.mate(
        instanceId: 'hull',
        toInstanceId: 'pod',
        parentNode: 'bottom',
        childNode: 'top',
      );
      expect(d.partById('hull')!.attachment!.parentInstanceId, 'pod');
    });

    test('mismatched kinds and diameters are refused', () {
      final d = CraftDesign(name: 'S');
      d.addPart(def: testHull, instanceId: 'hull');
      expect(
        () => d.attachPart(
          def: testBlock, // surface-only mount
          instanceId: 'b',
          toInstanceId: 'hull',
          parentNode: 'bottom', // stack node
          childNode: 'mount',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => d.attachPart(
          def: testHullWide, // 2.5 m stack nodes
          instanceId: 'w',
          toInstanceId: 'hull',
          parentNode: 'bottom',
          childNode: 'top',
        ),
        throwsA(isA<StateError>()),
      );
      expect(d.partCount, 1, reason: 'a refused mate must leave no debris');
    });

    test('an unknown node name is refused', () {
      final d = stack();
      expect(
        () => d.attachPart(
          def: testEngine(),
          instanceId: 'e2',
          toInstanceId: 'hull',
          parentNode: 'nope',
          childNode: 'top',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('tree', () {
    test('removing a parent takes its whole subtree with it', () {
      final d = stack();
      d.attachPart(
        def: testBlock,
        instanceId: 'block',
        toInstanceId: 'hull',
        parentNode: 'skinX',
        childNode: 'mount',
      );
      expect(d.partCount, 4);

      final gone = d.remove('hull');
      expect(gone.toSet(), {'hull', 'engine', 'block'});
      expect(d.partCount, 1);
      expect(d.partById('pod'), isNotNull);
      expect(d.partById('engine'), isNull,
          reason: 'an orphaned engine would keep contributing mass to the bake');
    });

    test('detach keeps the branch, in place, as a free part', () {
      final d = stack();
      final before = d.partById('engine')!.position;
      d.detach('hull');

      expect(d.partCount, 3);
      expect(d.partById('hull')!.attachment, isNull);
      expect(d.partById('engine')!.attachment, isNotNull,
          reason: 'only the named joint breaks');
      expectVector(d.partById('engine')!.position, before);
      expect(d.roots.map((p) => p.instanceId), containsAll(['pod', 'hull']));
    });

    test('a part cannot be mated into its own subtree', () {
      final d = stack();
      expect(
        () => d.mate(
          instanceId: 'hull',
          toInstanceId: 'engine',
          parentNode: 'top',
          childNode: 'bottom',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => d.mate(
          instanceId: 'hull',
          toInstanceId: 'hull',
          parentNode: 'top',
          childNode: 'bottom',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('re-mating an existing part carries its subtree rigidly', () {
      final d = stack();
      // Separation between hull and engine before the move.
      final gap = d.partById('engine')!.position - d.partById('hull')!.position;

      d.detach('hull');
      // Bolt the hull onto the pod's +X skin instead: the hull turns 90 deg,
      // and the engine hanging off it must follow through the same turn.
      d.mate(
        instanceId: 'hull',
        toInstanceId: 'pod',
        parentNode: 'skin',
        childNode: 'skinX',
      );

      final hull = d.partById('hull')!;
      final engine = d.partById('engine')!;
      // Rigid: the engine's offset expressed in the HULL's own frame is
      // untouched, which is the only statement that survives the hull turning.
      final movedGap = engine.position - hull.position;
      expectVector(hull.rotation.conjugate.rotate(movedGap), gap);
      // The hull did actually turn (its skinX node now faces -X, into the pod).
      expectVector(hull.rotation.rotate(Vector3.unitX), const Vector3(-1, 0, 0));
      expectVector(hull.position, const Vector3(1.6, 0, 0));
      expect(engine.attachment!.parentInstanceId, 'hull');
    });

    test('fromParts rejects a tree that is not a forest', () {
      final good = stack();
      // Hand-build the same parts but point the pod at the engine, closing the
      // loop pod -> hull -> engine -> pod.
      final parts = [
        for (final p in good.parts)
          p.instanceId == 'pod'
              ? p.copyWith(
                  attachment: const PartAttachment(
                  parentInstanceId: 'engine',
                  parentNode: 'top',
                  childNode: 'bottom',
                ))
              : p
      ];
      expect(
        () => CraftDesign.fromParts(name: 'Loop', parts: parts),
        throwsA(isA<StateError>()),
      );
    });

    test('fromParts rejects a mate to a part that is not there', () {
      expect(
        () => CraftDesign.fromParts(name: 'Orphan', parts: [
          const PlacedPart(
            def: testHull,
            instanceId: 'hull',
            attachment: PartAttachment(
                parentInstanceId: 'ghost', parentNode: 'bottom', childNode: 'top'),
          ),
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('fromParts rejects a stack node claimed from both directions', () {
      // pod -> hull, and then an engine bolted to the SAME hull node that
      // holds the hull onto the pod. Nothing in the child-side view of the
      // tree is doubled up, so only a two-ended check catches it.
      final parts = [
        const PlacedPart(def: testPod, instanceId: 'pod'),
        const PlacedPart(
          def: testHull,
          instanceId: 'hull',
          position: Vector3(0, 0, -1.7),
          attachment: PartAttachment(
              parentInstanceId: 'pod', parentNode: 'bottom', childNode: 'top'),
        ),
        PlacedPart(
          def: testEngine(),
          instanceId: 'engine',
          position: const Vector3(0, 0, -0.2),
          attachment: const PartAttachment(
              parentInstanceId: 'hull', parentNode: 'top', childNode: 'top'),
        ),
      ];
      expect(
        () => CraftDesign.fromParts(name: 'Doubled', parts: parts),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('occupancy bookkeeping', () {
    /// A part whose one downward stack node is called [nodeName].
    PartDef host(String nodeName) => PartDef(
          id: 'sep-host-$nodeName',
          name: 'Separator Host',
          category: PartCategory.structural,
          dryMass: 10,
          attachNodes: [
            AttachNode(
                name: nodeName,
                position: const Vector3(0, 0, -1),
                direction: const Vector3(0, 0, -1)),
          ],
        );

    const cap = PartDef(
      id: 'sep-cap',
      name: 'Separator Cap',
      category: PartCategory.structural,
      dryMass: 5,
      attachNodes: [AttachNode(name: 'top', position: Vector3(0, 0, 1))],
    );

    test('two distinct (part, node) pairs never share an occupancy slot', () {
      // Instance ids and node names are opaque strings that arrive off disk,
      // so occupancy has to be keyed on the PAIR. Joining the two names into
      // one string leaves the split ambiguous for ANY separator S: the pair
      // ('a', 'b' + S + 'c') and the pair ('a' + S + 'b', 'c') encode to the
      // same text, and a perfectly legal design is rejected as double-booked.
      // Every plausible S is exercised, including the empty string a tool that
      // strips control characters would leave behind.
      const separators = ['\u0000', '', '/', ':', '|', '.', '#', ' '];
      for (final s in separators) {
        final d = CraftDesign.fromParts(name: 'Separators', parts: [
          PlacedPart(def: host('b${s}c'), instanceId: 'a'),
          PlacedPart(def: host('c'), instanceId: 'a${s}b'),
          PlacedPart(
            def: cap,
            instanceId: 'cap-a',
            attachment: PartAttachment(
                parentInstanceId: 'a', parentNode: 'b${s}c', childNode: 'top'),
          ),
          PlacedPart(
            def: cap,
            instanceId: 'cap-b',
            attachment: PartAttachment(
                parentInstanceId: 'a${s}b', parentNode: 'c', childNode: 'top'),
          ),
        ]);
        expect(d.partCount, 4, reason: 'separator ${s.codeUnits}');
        expect(d.isStackNodeOccupied('a', 'b${s}c'), isTrue);
        expect(d.isStackNodeOccupied('a${s}b', 'c'), isTrue);
      }
    });

    test('the craft-design sources are plain text, so repo search sees them',
        () {
      // A raw control byte anywhere in a source file makes ripgrep classify it
      // as binary and drop it from every content search, hiding the whole
      // aggregate from the tool most likely to be used to look for it.
      for (final path in const [
        'lib/domain/craft/craft_design.dart',
        'lib/domain/craft/attach_solver.dart',
      ]) {
        final control = File(path)
            .readAsBytesSync()
            .where((b) =>
                (b < 0x20 && b != 0x09 && b != 0x0a && b != 0x0d) || b == 0x7f)
            .map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
            .toSet();
        expect(control, isEmpty, reason: path);
      }
    });
  });

  group('moving', () {
    test('moving a free part carries its subtree', () {
      final d = stack();
      final engineBefore = d.partById('engine')!.position;
      d.moveTo('pod', const Vector3(0, 0, 10));
      expectVector(d.partById('pod')!.position, const Vector3(0, 0, 10));
      expectVector(
          d.partById('engine')!.position, engineBefore + const Vector3(0, 0, 10));
    });

    test('rotating a free part swings its subtree about that part', () {
      final d = stack();
      d.rotateTo('pod', Quaternion.axisAngle(Vector3.unitY, math.pi / 2));
      // A +90 deg pitch about +Y sends the stack from -Z out along +X.
      expectVector(d.partById('hull')!.position, const Vector3(-1.7, 0, 0));
      expectVector(d.partById('engine')!.position, const Vector3(-3.2, 0, 0));
      expectVector(
          d.partById('engine')!.rotation.rotate(Vector3.unitZ), Vector3.unitX);
    });

    test('a mated part refuses to be nudged out of its joint', () {
      final d = stack();
      expect(() => d.moveTo('hull', Vector3.zero), throwsA(isA<StateError>()));
      expect(() => d.rotateTo('hull', Quaternion.identity),
          throwsA(isA<StateError>()));
    });
  });

  group('root', () {
    test('the first part added is the root, and removal re-picks one', () {
      final d = stack();
      expect(d.rootId, 'pod');
      d.remove('pod');
      expect(d.partCount, 0);
      expect(d.rootId, isNull);
    });

    test('the root must be unmated', () {
      final d = stack();
      expect(() => d.setRoot('hull'), throwsA(isA<StateError>()));
      d.detach('hull');
      d.setRoot('hull');
      expect(d.rootId, 'hull');
    });
  });

  group('staging', () {
    test('a stage can be assigned to a whole branch at once', () {
      final d = stack();
      d.assignStage('hull', 2, withSubtree: true);
      expect(d.partById('pod')!.stage, 0);
      expect(d.partById('hull')!.stage, 2);
      expect(d.partById('engine')!.stage, 2);
    });

    test('renumbering squeezes out the holes and keeps the order', () {
      final d = stack();
      d.assignStage('pod', 7);
      d.assignStage('hull', 3);
      d.assignStage('engine', 0);
      expect(d.stages, [0, 3, 7]);

      d.renumberStages();
      expect(d.stages, [0, 1, 2]);
      expect(d.partById('engine')!.stage, 0);
      expect(d.partById('hull')!.stage, 1);
      expect(d.partById('pod')!.stage, 2);
    });
  });

  group('symmetry', () {
    test('4x radial gives four blocks 90 degrees apart, all facing outward',
        () {
      final d = CraftDesign(name: 'Quad');
      d.addPart(def: testHull, instanceId: 'hull');
      final quads = d.attachRadial(
        def: testBlock,
        instanceIdPrefix: 'rcs',
        toInstanceId: 'hull',
        parentNode: 'skinX',
        childNode: 'mount',
        count: 4,
      );

      expect(quads.map((p) => p.instanceId).toList(),
          ['rcs-0', 'rcs-1', 'rcs-2', 'rcs-3']);
      const outward = [
        Vector3(1, 0, 0),
        Vector3(0, 1, 0),
        Vector3(-1, 0, 0),
        Vector3(0, -1, 0),
      ];
      for (var k = 0; k < 4; k++) {
        expectVector(quads[k].position, outward[k] * 1.1, tol: 1e-12);
        expectVector(quads[k].rotation.rotate(Vector3.unitX), outward[k],
            tol: 1e-12);
        expect(quads[k].attachment!.parentInstanceId, 'hull');
        expect(quads[k].attachment!.parentNode, 'skinX');
      }
      // All four hang off the hull, so deleting it takes them with it.
      expect(d.remove('hull').length, 5);
    });

    test('radial symmetry is refused on a stack node', () {
      final d = CraftDesign(name: 'S');
      d.addPart(def: testHull, instanceId: 'hull');
      expect(
        () => d.attachRadial(
          def: testEngine(),
          instanceIdPrefix: 'e',
          toInstanceId: 'hull',
          parentNode: 'bottom',
          childNode: 'top',
          count: 4,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('mirror symmetry gives the handed pair', () {
      final d = CraftDesign(name: 'Wings');
      d.addPart(def: testHull, instanceId: 'hull');
      final pair = d.attachMirrored(
        def: testBlock,
        instanceIdPrefix: 'wing',
        toInstanceId: 'hull',
        parentNode: 'skinX',
        childNode: 'mount',
      );
      expect(pair.length, 2);
      expectVector(pair[0].position, const Vector3(1.1, 0, 0), tol: 1e-12);
      expectVector(pair[1].position, const Vector3(-1.1, 0, 0), tol: 1e-12);
      expectVector(pair[1].rotation.rotate(Vector3.unitX),
          const Vector3(-1, 0, 0), tol: 1e-12);
    });
  });

  group('snapping through the design', () {
    test('an occupied stack node does not snap, a free one does', () {
      final d = stack();
      // The hull's bottom node is taken by the engine.
      expect(
        d.findSnap(def: testEngine(), position: const Vector3(0, 0, -3.25)),
        isNull,
      );
      // Its top node is taken by the pod mate as well; the pod's own bottom is
      // taken too — so mate onto the engine-free lower end of the stack.
      d.remove('engine');
      final snap =
          d.findSnap(def: testEngine(), position: const Vector3(0, 0, -3.25));
      expect(snap, isNotNull);
      expect(snap!.parentInstanceId, 'hull');
      expect(snap.parentNode, 'bottom');
    });

    test('a dragged part cannot snap to its own subtree', () {
      final d = stack();
      d.detach('hull');
      // Sitting right on the joint it just left, but excluded from itself.
      final snap = d.findSnap(
        def: testHull,
        position: d.partById('hull')!.position,
        movingInstanceId: 'hull',
      );
      // The engine's free top node is right there, but it is inside the moving
      // branch — the only legal answer is the pod it came off.
      expect(snap, isNotNull);
      expect(snap!.parentInstanceId, 'pod');
    });

    test('a drag will not snap through a node the dragged branch holds', () {
      final d = stack();
      d.detach('hull');
      // At this drag position the hull's BOTTOM node is 0.02 m off the pod's
      // bottom and nothing else is within the snap radius — but that node is
      // spent carrying the engine, so offering the mate would hand the editor
      // a snap that mate() has to refuse.
      const drag = Vector3(0, 0, 0.32);
      expect(
        d.findSnap(def: testHull, position: drag, movingInstanceId: 'hull'),
        isNull,
      );
      // Drop the engine and the same drag snaps.
      d.remove('engine');
      final snap =
          d.findSnap(def: testHull, position: drag, movingInstanceId: 'hull');
      expect(snap, isNotNull);
      expect(snap!.parentNode, 'bottom');
      expect(snap.childNode, 'bottom');
    });
  });

  test('a craft must have a name', () {
    expect(() => CraftDesign(name: '  '), throwsA(isA<ArgumentError>()));
  });
}
