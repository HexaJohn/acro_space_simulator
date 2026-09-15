// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mask functions over the kerb-cut form (docs/plans/site-access.md
/// §5.5): the asymmetric `blocked`, kerb parking by program, and stations
/// moved out of drawn cuts. The agents' kerb slots and the baked kerb cars
/// both read these, so their exact bounds are pinned here.
void main() {
  /// One entry: kerb [side], centre [c], half [h], travel sign [sigma], [kind].
  Float64List entry(int side, double c, double h, int sigma, int kind) =>
      Float64List.fromList(
          [side.toDouble(), c, h, sigma.toDouble(), kind.toDouble()]);

  const eps = 1e-9;

  group('blocked: −(h + up) < σ·(s − c) < h + down', () {
    test('forward travel: upstream is behind the cut', () {
      final e = entry(1, 100, 4, 1, KerbCuts.kindDropped);
      bool at(double s) =>
          KerbCuts.blocked(e, 1, s, upstreamM: 12, downstreamM: 3);
      expect(at(100 - 16 + eps), isTrue);
      expect(at(100 - 16), isFalse, reason: 'open bound');
      expect(at(100 + 7 - eps), isTrue);
      expect(at(100 + 7), isFalse, reason: 'open bound');
      expect(KerbCuts.blocked(e, 0, 100, upstreamM: 12, downstreamM: 3),
          isFalse, reason: 'the other kerb');
    });

    test('backward travel flips which side is upstream', () {
      final e = entry(0, 100, 4, -1, KerbCuts.kindDropped);
      bool at(double s) =>
          KerbCuts.blocked(e, 0, s, upstreamM: 12, downstreamM: 3);
      expect(at(100 + 16 - eps), isTrue);
      expect(at(100 + 16), isFalse);
      expect(at(100 - 7 + eps), isTrue);
      expect(at(100 - 7), isFalse);
    });

    test('equal extents are the symmetric |s − c| < h + x', () {
      final e = entry(1, 50, 2, -1, KerbCuts.kindDropped);
      for (final s in [45.0, 45.0 + eps, 50.0, 55.0 - eps, 55.0]) {
        expect(KerbCuts.blocked(e, 1, s, upstreamM: 3, downstreamM: 3),
            (s - 50).abs() < 5, reason: 's $s');
      }
    });

    test('drawnOnly leaves out far-swing masks; null entries block nothing',
        () {
      final e = entry(0, 10, 4, -1, KerbCuts.kindHomeFarSwing);
      expect(KerbCuts.blocked(e, 0, 10, upstreamM: 0, downstreamM: 0), isTrue);
      expect(
          KerbCuts.blocked(e, 0, 10,
              upstreamM: 0, downstreamM: 0, drawnOnly: true),
          isFalse);
      expect(KerbCuts.blocked(null, 0, 10, upstreamM: 9, downstreamM: 9),
          isFalse);
    });
  });

  group('parkingBlocked by program', () {
    test('a home cut masks (T − 12 − h, T + 3 + h) in travel terms', () {
      final e = entry(1, 200, kHomeCutHalfM, 1, KerbCuts.kindHomeLot);
      expect(kHomeSwingUpM, 12);
      expect(kHomeSwingDownM, 3);
      expect(KerbCuts.parkingBlocked(e, 1, 200 - 16 + eps), isTrue);
      expect(KerbCuts.parkingBlocked(e, 1, 200 - 16), isFalse);
      expect(KerbCuts.parkingBlocked(e, 1, 200 + 7 - eps), isTrue);
      expect(KerbCuts.parkingBlocked(e, 1, 200 + 7), isFalse);
    });

    test('the far-swing kerb of a home join masks with the home extents', () {
      // Side 0 of a two-way road travels backward: upstream is larger arc.
      final e = entry(0, 200, 4, -1, KerbCuts.kindHomeFarSwing);
      expect(KerbCuts.parkingBlocked(e, 0, 200 + 16 - eps), isTrue);
      expect(KerbCuts.parkingBlocked(e, 0, 200 + 16), isFalse);
      expect(KerbCuts.parkingBlocked(e, 0, 200 - 7 + eps), isTrue);
      expect(KerbCuts.parkingBlocked(e, 0, 200 - 7), isFalse);
    });

    test('any other cut masks the symmetric 3.25 m beyond its half', () {
      final e = entry(1, 80, 3, 1, KerbCuts.kindDropped);
      expect(kKerbMaskM, 3.25);
      expect(KerbCuts.parkingBlocked(e, 1, 80 - 6.25 + eps), isTrue);
      expect(KerbCuts.parkingBlocked(e, 1, 80 - 6.25), isFalse);
      expect(KerbCuts.parkingBlocked(e, 1, 80 + 6.25 - eps), isTrue);
      expect(KerbCuts.parkingBlocked(e, 1, 80 + 6.25), isFalse);
    });

    test('a slot beside a home cut: no kerb-car body reaches the swing', () {
      // A slot centre just outside the mask, its car's half length 3.7 m,
      // stays clear of [T − 12, T + 3].
      const t = 300.0, h = kHomeCutHalfM, halfCar = 3.7;
      final e = entry(1, t, h, 1, KerbCuts.kindHomeLot);
      const upEdge = t - h - kHomeSwingUpM, downEdge = t + h + kHomeSwingDownM;
      expect(KerbCuts.parkingBlocked(e, 1, upEdge), isFalse);
      expect(upEdge + halfCar, lessThanOrEqualTo(t - 12));
      expect(KerbCuts.parkingBlocked(e, 1, downEdge), isFalse);
      expect(downEdge - halfCar, greaterThanOrEqualTo(t + 3));
    });

    test('masks agree in either frame: canonical and drawn (reversed road)',
        () {
      // A cut on a two-way road of index length 400 drawn 404 m long and
      // sent reversed: the drawn copy masks the mirrored, rescaled slots.
      final canon = entry(1, 120, 4, 1, KerbCuts.kindHomeLot);
      final drawn = KerbCuts.toDrawn(canon,
          indexLengthM: 400, drawnLengthM: 404, reversed: true);
      for (var s = 90.0; s <= 140; s += 0.5) {
        final mirrored = 404 - s * 404 / 400;
        expect(KerbCuts.parkingBlocked(drawn, 0, mirrored),
            KerbCuts.parkingBlocked(canon, 1, s),
            reason: 'canonical $s, drawn $mirrored');
      }
    });
  });

  group('shiftOut', () {
    test('a station in a drawn cut moves to the nearer end plus 1 m', () {
      final e = entry(1, 50, 4, 1, KerbCuts.kindDropped);
      expect(KerbCuts.shiftOut(e, 1, 48), 50 - 4 - kKerbShiftOutM);
      expect(KerbCuts.shiftOut(e, 1, 52), 50 + 4 + kKerbShiftOutM);
      expect(KerbCuts.shiftOut(e, 1, 54), 54, reason: 'at the edge: stays');
      expect(KerbCuts.shiftOut(e, 0, 50), 50, reason: 'the other kerb');
      expect(KerbCuts.shiftOut(null, 1, 50), 50);
    });

    test('out of one cut into its neighbour: moved again; far swings never',
        () {
      final both = Float64List.fromList([
        ...entry(1, 50, 4, 1, KerbCuts.kindDropped),
        ...entry(1, 58, 4, 1, KerbCuts.kindDropped),
        ...entry(1, 70, 4, 1, KerbCuts.kindHomeFarSwing),
      ]);
      // 53 → 55 (end of the first + 1) lies in the second (54..62) → 63.
      expect(KerbCuts.shiftOut(both, 1, 53), 63);
      expect(KerbCuts.shiftOut(both, 1, 70), 70);
    });
  });
}
