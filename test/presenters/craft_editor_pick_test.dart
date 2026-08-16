// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:acro_space_simulator/adapters/presenters/craft_editor_camera.dart';
import 'package:acro_space_simulator/adapters/presenters/craft_editor_pick.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';

const Size kWide = Size(1280, 720);
const Offset kCentre = Offset(640, 360);

/// Azimuth 0 / elevation 0 makes the basis exactly `forward +Y, right +X,
/// up +Z`, so a test can place a marker at a chosen PIXEL offset and a chosen
/// VIEW DEPTH by closed form and reason about the ranking directly.
CraftEditorCamera _cam({double distanceM = 30.0}) => CraftEditorCamera(
      azimuth: 0,
      elevation: 0,
      distanceM: distanceM,
      pivot: Vector3.zero,
      viewport: kWide,
    );

typedef _Node = ({String name, Vector3 pos, Vector3 dir, double size});

TargetMarker _markerOf(_Node n) =>
    (position: n.pos, direction: n.dir, size: n.size);

/// A candidate that projects [dxPx]/[dyPx] from the screen centre at view depth
/// [depthM]. [facingAway] points the outward normal back into the screen, which
/// is what a node on the far side of a hull looks like.
_Node _node(
  CraftEditorCamera cam,
  String name, {
  required double depthM,
  double dxPx = 0,
  double dyPx = 0,
  double size = 1.25,
  bool facingAway = false,
}) {
  final f = cam.focalPx;
  return (
    name: name,
    pos: Vector3(
        dxPx * depthM / f, depthM - cam.distanceM, -dyPx * depthM / f),
    dir: facingAway ? const Vector3(0, 1, 0) : const Vector3(0, -1, 0),
    size: size,
  );
}

PickedTarget<_Node>? _pick(
  CraftEditorCamera cam,
  List<_Node> nodes, {
  Offset cursor = kCentre,
  bool touch = false,
  int cycle = 0,
}) =>
    CraftEditorPick.pickTarget<_Node>(cam, nodes, cursor,
        markerOf: _markerOf, touch: touch, cycle: cycle);

PartDef _box(String id, Vector3 size) => PartDef(
      id: id,
      name: id,
      category: PartCategory.structural,
      dryMass: 100,
      size: size,
      modelRotation: Quaternion.identity,
    );

void main() {
  group('the test rig itself', () {
    test('a node lands where the closed form says it does', () {
      // Everything below reasons in pixels, so the placement helper is load
      // bearing: if it were wrong, every ranking assertion would be testing the
      // wrong geometry and still passing.
      final cam = _cam();
      final n = _node(cam, 'probe', depthM: 12, dxPx: 40, dyPx: -25);
      expect(cam.depthOf(n.pos), closeTo(12, 1e-9));
      final s = cam.project(n.pos)!;
      expect(s.dx, closeTo(kCentre.dx + 40, 1e-9));
      expect(s.dy, closeTo(kCentre.dy - 25, 1e-9));
    });
  });

  group('ring ranking (R1: projection picking is occlusion-blind)', () {
    test('inside one ring the NEAREST TO CAMERA wins, not the nearest pixel',
        () {
      // The whole point of ranking in rings. A pure min(dPx) hands the click to
      // the node on the FAR side of a tank whenever it happens to project one
      // pixel closer, which reads as the editor ignoring where you clicked.
      final cam = _cam();
      final far = _node(cam, 'far', depthM: 60, dxPx: 1);
      final near = _node(cam, 'near', depthM: 20, dxPx: 7);
      expect(_pick(cam, [far, near])!.pairing.name, 'near');
      expect(_pick(cam, [near, far])!.pairing.name, 'near',
          reason: 'ranking must not depend on input order');
    });

    test('a closer ring beats a nearer depth', () {
      // Rings are the primary key. A marker 20 px away sitting right under the
      // camera must not steal a click aimed at one 3 px away.
      final cam = _cam();
      final onCursor = _node(cam, 'onCursor', depthM: 50, dxPx: 3);
      final offCursor = _node(cam, 'offCursor', depthM: 5, dxPx: 20);
      expect(_pick(cam, [offCursor, onCursor])!.pairing.name, 'onCursor');
    });

    test('two markers 5 px apart resolve to the near one', () {
      final cam = _cam();
      final behind = _node(cam, 'behind', depthM: 40);
      final front = _node(cam, 'front', depthM: 12, dxPx: 5);
      final got = _pick(cam, [behind, front])!;
      expect(got.pairing.name, 'front');
      expect(got.alternatives, 2, reason: 'both were in range — offer the cycle');
    });
  });

  group('the facing test', () {
    test('a back-facing marker loses to a front-facing one at equal distance',
        () {
      // Demoted two full rings rather than removed, so orbiting a little brings
      // it back rather than making it unreachable.
      final cam = _cam();
      final away = _node(cam, 'away', depthM: 12, dxPx: -5, facingAway: true);
      final toward = _node(cam, 'toward', depthM: 12, dxPx: 5);
      expect(_pick(cam, [away, toward])!.pairing.name, 'toward');
    });

    test('a back-facing marker still wins when it is the only candidate', () {
      final cam = _cam();
      final away = _node(cam, 'away', depthM: 12, dxPx: 4, facingAway: true);
      expect(_pick(cam, [away])!.pairing.name, 'away');
    });

    test('two demoted rings is a real demotion, not a disqualification', () {
      // A back-facing marker on the cursor lands in ring 0 + 2 == 2, the same
      // ring as a front-facing one 20 px off, and then wins on depth. It is
      // pushed back exactly two rings, not thrown away.
      final cam = _cam();
      final away = _node(cam, 'away', depthM: 10, facingAway: true);
      final toward = _node(cam, 'toward', depthM: 12, dxPx: 20);
      expect(_pick(cam, [toward, away])!.pairing.name, 'away');
      expect(_pick(cam, [away, toward])!.pairing.name, 'away');
      expect(_pick(cam, [toward, away])!.alternatives, 2);

      // One ring further out and the demotion decides it: ring 1 + 2 == 3
      // loses to ring 2 even though the back-facing marker is nearer.
      final away1 = _node(cam, 'away1', depthM: 10, dxPx: 9, facingAway: true);
      expect(_pick(cam, [away1, toward])!.pairing.name, 'toward');
    });
  });

  group('accept radius', () {
    test('a marker beyond the mouse grab radius is not a candidate', () {
      final cam = _cam();
      final far = _node(cam, 'far', depthM: 12, dxPx: 30);
      expect(_pick(cam, [far]), isNull);
    });

    test('a thumb reaches further than a mouse', () {
      // 25 px is outside the 22 px mouse radius and inside the 30 px touch one.
      // The rule is in PIXELS precisely because a thumb is a screen-space
      // object, not a world-space one.
      final cam = _cam();
      final n = _node(cam, 'n', depthM: 12, dxPx: 25);
      expect(_pick(cam, [n]), isNull);
      expect(_pick(cam, [n], touch: true)!.pairing.name, 'n');
    });

    test('the world cap takes over from the pixel rule at the predicted zoom',
        () {
      // acceptPx = min(grab, 1.5 * max(size, 0.25) * pxPerMetre). For a 0.25 m
      // node the two rules cross where 0.375 * focalPx / depth == 22, i.e.
      // depth ~= 14.8 m. Below that the pixel rule governs and a 15 px miss is
      // forgiven; above it the world cap governs and the same 15 px miss is
      // not, so a zoomed-out view cannot snap across the whole vehicle.
      final cam = _cam(distanceM: 60);
      final crossover = 0.375 * cam.focalPx / CraftEditorPick.grabPxMouse;
      expect(crossover, closeTo(14.8, 0.2));

      final close = _node(cam, 'close', depthM: 8, dxPx: 15, size: 0.25);
      final distant = _node(cam, 'distant', depthM: 40, dxPx: 15, size: 0.25);
      expect(_pick(cam, [close])!.pairing.name, 'close');
      expect(_pick(cam, [distant]), isNull);
    });

    test('a big mating ring is no easier to hit than the grab radius allows',
        () {
      // The world rule is a CAP, never a boost: a 4.2 m node must not become a
      // 200 px target just because it is close.
      final cam = _cam(distanceM: 12);
      final huge = _node(cam, 'huge', depthM: 6, dxPx: 40, size: 4.2);
      expect(_pick(cam, [huge]), isNull);
    });

    test('nothing in range returns null, and an empty list is not a crash', () {
      final cam = _cam();
      expect(_pick(cam, const []), isNull);
      expect(_pick(cam, [_node(cam, 'n', depthM: 12, dxPx: 400)]), isNull);
    });
  });

  group('cycling', () {
    test('cycle walks the survivors in ranked order and wraps', () {
      final cam = _cam();
      final a = _node(cam, 'a', depthM: 10, dxPx: 2);
      final b = _node(cam, 'b', depthM: 20, dxPx: 4);
      final c = _node(cam, 'c', depthM: 30, dxPx: 6);
      final order = [
        for (var i = 0; i < 5; i++)
          _pick(cam, [c, a, b], cycle: i)!.pairing.name
      ];
      expect(order, ['a', 'b', 'c', 'a', 'b']);
      expect(_pick(cam, [c, a, b])!.alternatives, 3);
    });

    test('a negative cycle index still lands on a real candidate', () {
      // Dart's % is non-negative for a positive divisor; this pins that the
      // cycle counter can be decremented (Shift+Tab) without going out of range.
      final cam = _cam();
      final a = _node(cam, 'a', depthM: 10);
      final b = _node(cam, 'b', depthM: 20, dxPx: 4);
      expect(_pick(cam, [a, b], cycle: -1)!.pairing.name, 'b');
    });

    test('alternatives counts only what was actually in range', () {
      final cam = _cam();
      final inRange = _node(cam, 'in', depthM: 12, dxPx: 4);
      final outOfRange = _node(cam, 'out', depthM: 12, dxPx: 300);
      final got = _pick(cam, [inRange, outOfRange])!;
      expect(got.alternatives, 1);
    });
  });

  group('near plane', () {
    test('a marker at or behind the near plane is never a candidate', () {
      // The overlay must not offer a target the renderer has already clipped.
      final cam = _cam(distanceM: 30); // nearM == 1.5 m
      final behind = _node(cam, 'behind', depthM: 0.5);
      expect(cam.project(behind.pos), isNull);
      expect(_pick(cam, [behind]), isNull);
    });
  });

  group('pickPart', () {
    test('overlapping parts resolve to the nearer one', () {
      final cam = _cam(distanceM: 30);
      final design = CraftDesign(name: 'overlap');
      // Camera eye is at -Y, so a smaller y is nearer.
      design.addPart(
          def: _box('back', const Vector3(2, 2, 2)),
          instanceId: 'back',
          position: const Vector3(0, 8, 0));
      design.addPart(
          def: _box('front', const Vector3(2, 2, 2)),
          instanceId: 'front',
          position: const Vector3(0, -8, 0));
      expect(CraftEditorPick.pickPart(cam, design, kCentre), 'front');
    });

    test('a click off the silhouette hits nothing', () {
      final cam = _cam(distanceM: 30);
      final design = CraftDesign(name: 'miss');
      design.addPart(def: _box('a', const Vector3(2, 2, 2)), instanceId: 'a');
      expect(CraftEditorPick.pickPart(cam, design, const Offset(1200, 80)),
          isNull);
      expect(CraftEditorPick.pickPart(cam, design, kCentre), 'a');
    });

    test('the OBB follows the part rotation, not an axis-aligned box', () {
      // A 6 m x 0.4 m x 0.4 m spar laid along +X and then spun 90 degrees about
      // +Z lies along +Y — straight down the view axis — so its silhouette
      // collapses and a click 100 px to the side must miss. An axis-aligned box
      // would still be 6 m wide on screen and would wrongly hit.
      final cam = _cam(distanceM: 30);
      final spar = _box('spar', const Vector3(6, 0.4, 0.4));
      final flat = CraftDesign(name: 'flat')
        ..addPart(def: spar, instanceId: 's');
      final spun = CraftDesign(name: 'spun')
        ..addPart(
            def: spar,
            instanceId: 's',
            rotation: Quaternion.axisAngle(Vector3.unitZ, 1.5707963267948966));
      const off = Offset(640 + 60, 360);
      expect(CraftEditorPick.pickPart(cam, flat, off), 's');
      expect(CraftEditorPick.pickPart(cam, spun, off), isNull);
    });

    test('a 0.15 m thruster is only reachable through the centre rescue', () {
      // eagle-rcs-solo is 0.15 m: at working range its projected box is a few
      // pixels across and is not a click target at all. The rescue is what makes
      // the part selectable, so this pins that the box path really does fail and
      // the rescue really does carry it.
      final cam = _cam(distanceM: 40);
      final design = CraftDesign(name: 'thin');
      design.addPart(
          def: _box('solo', const Vector3(0.15, 0.15, 0.15)),
          instanceId: 'solo');
      final depth = cam.depthOf(Vector3.zero);
      final halfBoxPx = cam.pxPerMetreAt(depth) * 0.075;
      expect(halfBoxPx, lessThan(5),
          reason: 'premise: the box really is too small to click');

      // Beyond the inflated box, inside the 10 px rescue.
      expect(CraftEditorPick.pickPart(cam, design, const Offset(648, 360)),
          'solo');
      // Beyond both.
      expect(CraftEditorPick.pickPart(cam, design, const Offset(654, 360)),
          isNull);
    });

    test('a part behind the near plane is not pickable', () {
      final cam = _cam(distanceM: 30);
      final design = CraftDesign(name: 'behind');
      design.addPart(
          def: _box('a', const Vector3(2, 2, 2)),
          instanceId: 'a',
          position: const Vector3(0, -31, 0));
      expect(cam.depthOf(const Vector3(0, -31, 0)), lessThan(cam.nearM));
      expect(CraftEditorPick.pickPart(cam, design, kCentre), isNull);
    });

    test('an empty design picks nothing', () {
      expect(
          CraftEditorPick.pickPart(_cam(), CraftDesign(name: 'e'), kCentre),
          isNull);
    });
  });
}
