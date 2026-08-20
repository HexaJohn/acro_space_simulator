// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The walker's drill. What is pinned here is the two things that make hand
// digging affordable rather than ruinous:
//   * brushes are earned in QUANTA — a held trigger at 60 fps must not append
//     60 brushes a second to a list the snapshot ships every tick;
//   * each brush SWALLOWS the last (same centre, larger ball), so the composed
//     surface only ever shows the newest and the superseded ones are dead
//     weight bounded by the bore's own size cap.
// Plus the aiming rule: the drill bites the first ground along the ray, so
// pointing at a cliff face digs the face.
import 'package:acro_space_simulator/domain/mining/hand_drill.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const drill = HandDrill();
  const groundR = 1.0e6;
  double flat(Vector3 _) => groundR;
  final standing = Vector3(0, 0, groundR + 1.7);

  ({DrillBore? bore, List<TerrainBrush> brushes, double dug}) hold(
    double seconds, {
    Vector3? aim,
    DrillBore? from,
    double dt = 1 / 60,
  }) {
    var bore = from;
    final all = <TerrainBrush>[];
    var dug = 0.0;
    final target = aim ?? Vector3(0, 1, groundR);
    for (var t = 0.0; t < seconds; t += dt) {
      final r = drill.drill(bore: bore, aimBF: target, dt: dt, tick: 1);
      bore = r.bore;
      all.addAll(r.brushes);
      dug += r.excavatedM3;
    }
    return (bore: bore, brushes: all, dug: dug);
  }

  test('a held trigger earns brushes in quanta, not one per frame', () {
    final r = hold(2.0); // 120 frames
    expect(r.brushes.length, lessThan(10),
        reason: 'a brush per frame would be 120 of them');
    expect(r.brushes, isNotEmpty, reason: 'but the ground must actually move');
    expect(r.dug, closeTo(drill.removalRateM3PerS * 2.0, 0.05));
  });

  test('every brush is a bigger ball on the same centre — each swallows the last',
      () {
    final r = hold(3.0);
    expect(r.brushes.length, greaterThan(1));
    for (var i = 1; i < r.brushes.length; i++) {
      expect(r.brushes[i].radiusM, greaterThan(r.brushes[i - 1].radiusM));
      expect(r.brushes[i].centreBF.x, r.brushes[i - 1].centreBF.x);
      expect(r.brushes[i].centreBF.y, r.brushes[i - 1].centreBF.y);
      expect(r.brushes[i].centreBF.z, r.brushes[i - 1].centreBF.z);
    }
    expect(r.brushes.every((b) => b.kind == TerrainBrushKind.sphere), isTrue);
  });

  test('a worked-out bore stops growing and stops emitting', () {
    // Far longer than it takes to reach maxRadiusM.
    final r = hold(600.0);
    expect(r.bore!.radiusM, closeTo(drill.maxRadiusM, 1e-6));
    expect(r.brushes.length, lessThanOrEqualTo(drill.maxBrushesPerBore));
    final more = hold(60.0, from: r.bore);
    expect(more.brushes, isEmpty, reason: 'nothing left to earn');
  });

  test('drifting the aim starts a new hole instead of resuming the old one',
      () {
    final first = hold(2.0, aim: Vector3(0, 1, groundR));
    final moved = drill.drill(
      bore: first.bore,
      aimBF: Vector3(0, 1 + drill.newBoreDistanceM * 2, groundR),
      dt: 1 / 60,
      tick: 2,
    );
    expect(moved.bore, isNot(same(first.bore)));
    expect(moved.bore!.carvedSteps, 0);
    expect(moved.bore!.volumeM3, lessThan(first.bore!.volumeM3));
  });

  test('a small aim wobble keeps working the same hole', () {
    final first = hold(2.0, aim: Vector3(0, 1, groundR));
    final same0 = drill.drill(
      bore: first.bore,
      aimBF: Vector3(0, 1 + drill.newBoreDistanceM * 0.5, groundR),
      dt: 1 / 60,
      tick: 2,
    );
    expect(identical(same0.bore, first.bore), isTrue);
  });

  test('the bite is the first ground along the ray, not the aim point', () {
    // Looking down-forward from standing height at flat ground.
    final hit = drill.contact(
      eyeBF: standing,
      aimDirBF: Vector3(0, 0.7, -0.7),
      groundRadiusAt: flat,
    );
    expect(hit, isNotNull);
    expect(hit!.length, lessThanOrEqualTo(groundR + 1e-6),
        reason: 'the bite is at or under the surface');
    expect(hit.y, greaterThan(0), reason: 'and out in front of the operator');
  });

  test('aiming at the sky bites nothing', () {
    expect(
        drill.contact(
            eyeBF: standing,
            aimDirBF: Vector3(0, 0.2, 1),
            groundRadiusAt: flat),
        isNull);
  });

  test('aiming across a gap beyond reach bites nothing', () {
    // Ground 50 m below the feet: nothing within arm's length.
    double pit(Vector3 _) => groundR - 50;
    expect(
        drill.contact(
            eyeBF: standing,
            aimDirBF: Vector3(0, 0.3, -1),
            groundRadiusAt: pit),
        isNull);
  });

  test('a saved bore restores to the size it was worked to', () {
    final r = hold(4.0);
    final restored = drill.restoreBrush(r.bore!, tick: 9);
    expect(restored.radiusM, r.brushes.last.radiusM);
    expect(restored.centreBF.z, r.bore!.centreBF.z);
  });
}
