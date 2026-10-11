// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/presenters/colony_markers.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colony markers: what can be seen from where.
void main() {
  const r = 1.7e6;
  BodySnapshot body(String id, double x, double radius) =>
      BodySnapshot(id: id, px: x, py: 0, pz: 0, qw: 1, qx: 0, qy: 0, qz: 0, radius: radius);
  final moon = body('moon', 0, r);
  const base = ColonyMarkerInput(
    id: 'c1',
    name: 'Base',
    bodyId: 'moon',
    bodyFixed: Vector3(r, 0, 0),
    status: ColonyMarkerStatus.yours,
  );

  /// Looking down −x from [eye]: screen x = world y, screen y = world z,
  /// nothing behind the eye.
  List<ColonyMark> seen(Vector3 eye, {Map<String, BodySnapshot>? bodies, List<ColonyMarkerInput>? colonies}) =>
      projectColonyMarkers(
        colonies: colonies ?? const [base],
        bodies: bodies ?? {'moon': moon},
        focus: eye,
        eyeOffset: Vector3.zero,
        project: (rel) => rel.x >= 0 ? null : (x: rel.y, y: rel.z),
      );

  test('a colony on the near side is marked, with the eye\'s distance to it', () {
    final m = seen(const Vector3(2 * r, 0, 0)).single;
    expect(m.id, 'c1');
    expect(m.distanceM, closeTo(r, 1e-6));
    expect((m.x, m.y), (0.0, 0.0));
  });

  test('a colony past its body\'s horizon is not', () {
    expect(seen(const Vector3(-2 * r, 0, 0)), isEmpty);
    // Just over the limb from a low orbit: hidden; just inside it: seen.
    final low = r * 1.05;
    expect(seen(Vector3(0, low, 0)), isEmpty, reason: 'a quarter turn away, below the horizon');
    expect(seen(Vector3(1.01 * r, low, 0)), hasLength(1), reason: 'just above its horizon plane');
    expect(seen(Vector3(0.99 * r, low, 0)), isEmpty, reason: 'just below it');
  });

  test('another body in the way hides it', () {
    final rock = body('rock', 1.5 * r, 0.1 * r);
    expect(seen(const Vector3(3 * r, 0, 0), bodies: {'moon': moon, 'rock': rock}), isEmpty);
    expect(seen(const Vector3(3 * r, 0.5 * r, 0), bodies: {'moon': moon, 'rock': rock}), hasLength(1));
  });

  test('nearly at it, or behind the eye, no marker', () {
    expect(seen(const Vector3(r + 1000, 0, 0)), isEmpty);
    expect(
        projectColonyMarkers(
          colonies: const [base],
          bodies: {'moon': moon},
          focus: const Vector3(2 * r, 0, 0),
          eyeOffset: Vector3.zero,
          project: (_) => null,
        ),
        isEmpty);
  });

  test('the open colony is marked only from far out', () {
    const open = ColonyMarkerInput(
      id: 'c1',
      name: 'Base',
      bodyId: 'moon',
      bodyFixed: Vector3(r, 0, 0),
      status: ColonyMarkerStatus.yours,
      hideWithinM: kOpenColonyMarkerNearM,
    );
    expect(seen(const Vector3(r + 20e3, 0, 0), colonies: const [open]), isEmpty);
    expect(seen(const Vector3(r + 20e3, 0, 0)), hasLength(1), reason: 'any other colony, at 20 km');
    expect(seen(const Vector3(r + 80e3, 0, 0), colonies: const [open]), hasLength(1));
  });

  test('nearest first, and a body the frame lacks marks nothing', () {
    const far = ColonyMarkerInput(
      id: 'c2',
      name: 'Far',
      bodyId: 'moon',
      bodyFixed: Vector3(0.9 * r, 0.43 * r, 0),
      status: ColonyMarkerStatus.independent,
    );
    const lost = ColonyMarkerInput(
      id: 'c3',
      name: 'Lost',
      bodyId: 'mars',
      bodyFixed: Vector3(1, 0, 0),
      status: ColonyMarkerStatus.yours,
    );
    final marks = seen(const Vector3(2 * r, 0, 0), colonies: const [far, base, lost]);
    expect([for (final m in marks) m.id], ['c1', 'c2']);
  });

  test('distances read in km, then Gm', () {
    expect(colonyMarkerDistance(4200), '4.2 km');
    expect(colonyMarkerDistance(384400e3), '384400 km');
    expect(colonyMarkerDistance(2.5e9), '2.5 Gm');
  });
}
