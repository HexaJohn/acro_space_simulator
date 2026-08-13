// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic unit directions — seeded so a failure is always reproducible.
List<Vector3> _sampleDirections(int n, {int seed = 0xC0FFEE}) {
  final rng = math.Random(seed);
  return [
    for (var i = 0; i < n; i++)
      () {
        // Uniform on the sphere: z uniform in [-1,1], azimuth uniform.
        final z = rng.nextDouble() * 2 - 1;
        final a = rng.nextDouble() * 2 * math.pi;
        final r = math.sqrt(1 - z * z);
        return Vector3(r * math.cos(a), r * math.sin(a), z);
      }(),
  ];
}

void main() {
  group('face basis', () {
    test('every face frame is orthonormal and right-handed', () {
      for (final f in CubeFace.values) {
        final b = basisOf(f);
        expect(b.forward.length, closeTo(1, 1e-12), reason: '$f forward');
        expect(b.right.length, closeTo(1, 1e-12), reason: '$f right');
        expect(b.up.length, closeTo(1, 1e-12), reason: '$f up');
        expect(b.forward.dot(b.right), closeTo(0, 1e-12), reason: '$f f.r');
        expect(b.forward.dot(b.up), closeTo(0, 1e-12), reason: '$f f.u');
        expect(b.right.dot(b.up), closeTo(0, 1e-12), reason: '$f r.u');
        // right x up == forward
        final cross = Vector3(
          b.right.y * b.up.z - b.right.z * b.up.y,
          b.right.z * b.up.x - b.right.x * b.up.z,
          b.right.x * b.up.y - b.right.y * b.up.x,
        );
        expect((cross - b.forward).length, closeTo(0, 1e-12),
            reason: '$f is left-handed');
      }
    });

    test('the six forward axes are distinct', () {
      final seen = <String>{};
      for (final f in CubeFace.values) {
        seen.add(basisOf(f).forward.toString());
      }
      expect(seen.length, 6);
    });
  });

  group('direction <-> (face, s, t) round-trip', () {
    test('projects and unprojects to the same direction', () {
      for (final d in _sampleDirections(500)) {
        final face = faceOfDirection(d);
        final st = faceST(face, d);
        expect(st.s, inInclusiveRange(-1.0000001, 1.0000001));
        expect(st.t, inInclusiveRange(-1.0000001, 1.0000001));
        final back = directionOf(face, st.s, st.t);
        expect((back - d).length, lessThan(1e-12), reason: 'dir $d face $face');
      }
    });

    test('faceOfDirection agrees with the dominant axis', () {
      expect(faceOfDirection(const Vector3(0.9, 0.1, 0.2)), CubeFace.posX);
      expect(faceOfDirection(const Vector3(-0.9, 0.1, 0.2)), CubeFace.negX);
      expect(faceOfDirection(const Vector3(0.1, 0.9, 0.2)), CubeFace.posY);
      expect(faceOfDirection(const Vector3(0.1, -0.9, 0.2)), CubeFace.negY);
      expect(faceOfDirection(const Vector3(0.1, 0.2, 0.9)), CubeFace.posZ);
      expect(faceOfDirection(const Vector3(0.1, 0.2, -0.9)), CubeFace.negZ);
    });
  });

  group('chunk coverage', () {
    test('roots partition the sphere: exactly one contains each direction', () {
      final roots = ChunkKey.roots;
      expect(roots.length, 6);
      for (final d in _sampleDirections(500)) {
        final hits = roots.where((k) => k.contains(d)).length;
        expect(hits, 1, reason: 'dir $d covered by $hits roots');
      }
    });

    test('chunkAt returns a cell that contains the direction', () {
      for (final level in [0, 1, 2, 4, 6]) {
        for (final d in _sampleDirections(200, seed: 7 + level)) {
          final k = chunkAt(d, level);
          expect(k.level, level);
          expect(k.u, inInclusiveRange(0, k.cellsPerSide - 1));
          expect(k.v, inInclusiveRange(0, k.cellsPerSide - 1));
          expect(k.contains(d), isTrue, reason: 'level $level dir $d -> $k');
        }
      }
    });

    test('children tile their parent exactly once', () {
      for (final d in _sampleDirections(300, seed: 99)) {
        final parent = chunkAt(d, 3);
        final hits = parent.children.where((c) => c.contains(d)).length;
        expect(hits, 1, reason: '$parent children covered $d $hits times');
        for (final c in parent.children) {
          expect(c.parent, parent);
          expect(c.level, parent.level + 1);
        }
      }
    });

    test('ancestors walk up to the root', () {
      final k = chunkAt(const Vector3(0.3, -0.8, 0.5).normalized, 5);
      final chain = k.ancestors;
      expect(chain.length, 5);
      expect(chain.last.level, 0);
      expect(chain.last.face, k.face);
      for (final a in chain) {
        expect(a.contains(k.centreDirection), isTrue,
            reason: '$a should contain $k');
      }
    });
  });

  group('neighbours', () {
    test('four distinct neighbours, none equal to self', () {
      for (final level in [0, 1, 3, 5]) {
        for (final d in _sampleDirections(80, seed: 21 + level)) {
          final k = chunkAt(d, level);
          final ns = {for (final e in ChunkEdge.values) k.neighbour(e)};
          expect(ns.contains(k), isFalse, reason: '$k is its own neighbour');
          // At level 0 a face has 4 distinct neighbours; deeper too.
          expect(ns.length, 4, reason: '$k gave $ns');
          for (final n in ns) {
            expect(n.level, level);
            expect(n.u, inInclusiveRange(0, n.cellsPerSide - 1));
            expect(n.v, inInclusiveRange(0, n.cellsPerSide - 1));
          }
        }
      }
    });

    test('reciprocal: a neighbour lists the original back', () {
      // Across a seam the return trip is NOT via the opposite edge (the faces'
      // axes meet rotated), so assert membership rather than a fixed edge.
      for (final level in [0, 1, 2, 3, 5]) {
        for (final d in _sampleDirections(80, seed: 55 + level)) {
          final k = chunkAt(d, level);
          for (final e in ChunkEdge.values) {
            final n = k.neighbour(e);
            final back = {for (final e2 in ChunkEdge.values) n.neighbour(e2)};
            expect(back.contains(k), isTrue,
                reason: '$k --$e--> $n did not point back (got $back)');
          }
        }
      }
    });

    test('neighbours are geometrically adjacent', () {
      // Centre-to-centre angle must be about one cell wide, never a jump
      // across the body. Generous bound: cells are non-uniform under plain
      // normalisation, and face-corner cells are the small ones.
      for (final level in [1, 2, 3, 4, 6]) {
        final cellAngle = (math.pi / 2) / (1 << level);
        for (final d in _sampleDirections(60, seed: 300 + level)) {
          final k = chunkAt(d, level);
          for (final e in ChunkEdge.values) {
            final n = k.neighbour(e);
            final cos =
                k.centreDirection.dot(n.centreDirection).clamp(-1.0, 1.0);
            final ang = math.acos(cos);
            expect(ang, lessThan(cellAngle * 2.0),
                reason: '$k --$e--> $n is $ang rad away (cell $cellAngle)');
            expect(ang, greaterThan(cellAngle * 0.25),
                reason: '$k --$e--> $n is suspiciously close');
          }
        }
      }
    });

    test('crossing every face seam stays on a face sharing that edge', () {
      // A seam crossing must land on a face whose forward axis is perpendicular
      // to the origin face's — never the same face, never the antipode.
      for (final level in [0, 1, 2, 4]) {
        final n = 1 << level;
        for (final f in CubeFace.values) {
          for (var u = 0; u < n; u++) {
            for (var v = 0; v < n; v++) {
              final k = ChunkKey(f, level, u, v);
              for (final e in ChunkEdge.values) {
                final nb = k.neighbour(e);
                if (nb.face == f) continue; // interior step
                final a = basisOf(f).forward, b = basisOf(nb.face).forward;
                expect(a.dot(b).abs(), closeTo(0, 1e-12),
                    reason: '$k --$e--> $nb crossed to a non-adjacent face');
              }
            }
          }
        }
      }
    });

    test('face-corner cells resolve unambiguously', () {
      // The case a naive "step and re-project" gets wrong: the four corner
      // cells of every face at several levels must produce valid, reciprocal
      // neighbours.
      for (final level in [1, 2, 3, 4, 5]) {
        final n = 1 << level;
        for (final f in CubeFace.values) {
          for (final corner in [
            [0, 0],
            [n - 1, 0],
            [0, n - 1],
            [n - 1, n - 1],
          ]) {
            final k = ChunkKey(f, level, corner[0], corner[1]);
            final ns = {for (final e in ChunkEdge.values) k.neighbour(e)};
            expect(ns.length, 4, reason: 'corner $k gave $ns');
            for (final nb in ns) {
              final back = {
                for (final e2 in ChunkEdge.values) nb.neighbour(e2)
              };
              expect(back.contains(k), isTrue,
                  reason: 'corner $k -> $nb did not point back');
            }
          }
        }
      }
    });
  });

  group('cell geometry', () {
    test('circumradius shrinks per level, converging on half', () {
      // Coarse cells cover a strongly curved patch, so the first splits do not
      // halve cleanly; once cells are small enough to be near-planar the ratio
      // settles at 1/2.
      const r = 1.7374e6;
      final d = const Vector3(0.4, 0.5, 0.76).normalized;
      var prev = chunkAt(d, 0).circumradiusM(r);
      for (var level = 1; level <= 10; level++) {
        final cur = chunkAt(d, level).circumradiusM(r);
        final ratio = cur / prev;
        expect(ratio, inInclusiveRange(0.3, 0.75),
            reason: 'level $level ratio $ratio');
        if (level >= 5) {
          expect(ratio, inInclusiveRange(0.47, 0.53),
              reason: 'level $level should be near-planar, ratio $ratio');
        }
        prev = cur;
      }
    });

    test('circumradius covers the cell corners', () {
      const r = 1.7374e6;
      for (final level in [0, 2, 5]) {
        for (final d in _sampleDirections(40, seed: 900 + level)) {
          final k = chunkAt(d, level);
          final rad = k.circumradiusM(r);
          final centre = k.centreDirection * r;
          for (final c in k.cornerDirections) {
            expect((c * r - centre).length, lessThanOrEqualTo(rad * 1.0000001),
                reason: '$k corner outside circumradius');
          }
        }
      }
    });
  });

  group('field agreement', () {
    test('chunk centres land within the field relief band', () {
      // Plan §8: chunk-centre -> ground-radius agreement with TerrainField.
      final field = TerrainField(
        radius: 1.7374e6,
        amplitude: 4000,
        featureScale: 60000,
        seed: 0x11A00,
      );
      for (final level in [0, 3, 6]) {
        for (final d in _sampleDirections(60, seed: 1200 + level)) {
          final k = chunkAt(d, level);
          final c = k.centreDirection;
          final gr = field.groundRadiusAt(c.x, c.y, c.z);
          expect(gr, inInclusiveRange(field.radius - field.amplitude,
              field.radius + field.amplitude));
          // The density field must vanish on that surface point.
          final p = c * gr;
          expect(field.density(p.x, p.y, p.z).abs(), lessThan(1e-3),
              reason: '$k centre is not on the isosurface');
        }
      }
    });

    test('addressing is deterministic: same direction, same key', () {
      for (final d in _sampleDirections(200, seed: 4242)) {
        for (final level in [0, 4, 9]) {
          expect(chunkAt(d, level), chunkAt(d, level));
          expect(chunkAt(d, level).hashCode, chunkAt(d, level).hashCode);
        }
      }
    });
  });
}
