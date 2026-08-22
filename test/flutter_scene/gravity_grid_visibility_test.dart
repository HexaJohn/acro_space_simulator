// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/gravity_grid_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

/// The spacetime grid is a navigation aid for the body you are AT, over the
/// zoom range where a funnel reads as a funnel. Both decisions — WHICH body,
/// and WHETHER at this zoom — are pure functions, testable with no GPU.
void main() {
  BodySnapshot body(String id, {double radius = 6.371e6, double x = 0}) =>
      BodySnapshot(
          id: id,
          px: x,
          py: 0,
          pz: 0,
          qw: 1,
          qx: 0,
          qy: 0,
          qz: 0,
          radius: radius);

  BodyDescriptorSnapshot desc(String id,
          {BodyKind kind = BodyKind.rocky, double mu = 3.986e14}) =>
      BodyDescriptorSnapshot(
          id: id, kind: kind, referenceRadius: 6.371e6, mu: mu);

  VesselSnapshot vessel(String id, String bodyId) => VesselSnapshot(
      id: id,
      ownerId: 'p1',
      body: bodyId,
      px: 0,
      py: 0,
      pz: 7e6,
      vx: 0,
      vy: 0,
      vz: 0,
      throttle: 0,
      onRails: false);

  final snap = WorldSnapshot(
    tick: 0,
    bodies: {
      'earth': body('earth'),
      'moon': body('moon', radius: 1.737e6, x: 3.8e8),
      'sun': body('sun', radius: 6.96e8, x: 1.5e11),
    },
    descriptors: {
      'earth': desc('earth'),
      'moon': desc('moon', mu: 4.9e12),
      'sun': desc('sun', kind: BodyKind.star, mu: 1.327e20),
    },
    vessels: {'v1': vessel('v1', 'moon')},
  );

  group('which body', () {
    test('the focused body, and only it', () {
      expect(GravityGridNodes.targetBodyId(snap, focusBodyId: 'earth'),
          'earth');
      expect(GravityGridNodes.targetBodyId(snap, focusBodyId: 'moon'), 'moon');
    });

    test('a focused craft grids the body it orbits, not the craft', () {
      // v1 is at the Moon: the Moon's well is the one that matters, even
      // though Earth is the bigger body in the frame.
      expect(GravityGridNodes.targetBodyId(snap, focusVesselId: 'v1'), 'moon');
    });

    test('the sun never gets a funnel — it would swallow the system', () {
      expect(GravityGridNodes.targetBodyId(snap, focusBodyId: 'sun'), isNull);
      final solar = WorldSnapshot(
        tick: 0,
        bodies: snap.bodies,
        descriptors: snap.descriptors,
        vessels: {'v2': vessel('v2', 'sun')},
      );
      expect(GravityGridNodes.targetBodyId(solar, focusVesselId: 'v2'), isNull);
    });

    test('nothing focused, or an unknown/massless body, grids nothing', () {
      expect(GravityGridNodes.targetBodyId(snap), isNull);
      expect(GravityGridNodes.targetBodyId(snap, focusBodyId: 'nope'), isNull);
      final massless = WorldSnapshot(
        tick: 0,
        bodies: {'x': body('x')},
        descriptors: {'x': desc('x', mu: 0)}, // pre-mu wire producer
        vessels: const {},
      );
      expect(GravityGridNodes.targetBodyId(massless, focusBodyId: 'x'), isNull);
    });
  });

  group('zoom window', () {
    // A 1000x800 frame: shortest side 800, so the body's disc spans the
    // frame when its apparent RADIUS hits 400 px.
    const frame = 800.0;
    const e = GravityGridNodes.extentRadii;

    test('system zoom: a subpixel rim draws nothing', () {
      expect(GravityGridNodes.apparentFade(4, frame), 0);
      expect(GravityGridNodes.apparentFade(30, frame), 0);
    });

    test('fades in as the body grows past a few pixels', () {
      final near = GravityGridNodes.apparentFade(45, frame);
      final far = GravityGridNodes.apparentFade(75, frame);
      expect(near, greaterThan(0));
      expect(far, greaterThan(near));
      expect(GravityGridNodes.apparentFade(90, frame), 1.0);
    });

    test('full strength while the whole body is comfortably in frame', () {
      // Body radius 100 px in an 800 px frame: a quarter of the height.
      expect(GravityGridNodes.apparentFade(100 * e, frame), 1.0);
    });

    test('fades back out as the body outgrows the frame', () {
      // Radius 200 px = the disc owns half the frame: the last full-strength
      // frame. Past it the sheet gives way.
      expect(GravityGridNodes.apparentFade(200 * e, frame), 1.0);
      final part = GravityGridNodes.apparentFade(250 * e, frame);
      expect(part, lessThan(1.0));
      expect(part, greaterThan(0.0));
      expect(GravityGridNodes.apparentFade(350 * e, frame), lessThan(part));
      // Radius 400 px+ = the disc fills the short side: gone. Low orbit and
      // the ground are far past this.
      expect(GravityGridNodes.apparentFade(400 * e, frame), 0);
      expect(GravityGridNodes.apparentFade(5000 * e, frame), 0);
    });

    test('an unknown viewport keeps the old far-side-only behaviour', () {
      // Belt and braces: a caller with no frame size must not lose the grid.
      expect(GravityGridNodes.apparentFade(400 * e, 0), 1.0);
    });
  });
}
