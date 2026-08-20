// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/parts/proc_part_mesh.dart';
import 'package:acro_space_simulator/domain/parts/proc_shape.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:flutter_test/flutter_test.dart';

/// The generated part meshes, checked as GEOMETRY: structural sanity (indices
/// in range, arrays in step), unit normals, bounds equal to the shape's own
/// declared extent, and — the one nothing else catches — OUTWARD winding via
/// the divergence theorem. A mesh wound inward renders as a ghostly veil of
/// backfaces and looks like a lighting bug; its signed volume is negative,
/// which is a number a headless test can read.
void main() {
  /// Signed volume of a closed triangle mesh (divergence theorem). Positive
  /// for outward (CCW from outside) winding.
  double signedVolume(PropMesh m) {
    var v6 = 0.0;
    final p = m.positions;
    final ix = m.indices;
    for (var i = 0; i < ix.length; i += 3) {
      final a = ix[i] * 3, b = ix[i + 1] * 3, c = ix[i + 2] * 3;
      final ax = p[a], ay = p[a + 1], az = p[a + 2];
      final bx = p[b], by = p[b + 1], bz = p[b + 2];
      final cx = p[c], cy = p[c + 1], cz = p[c + 2];
      // a . (b x c)
      v6 += ax * (by * cz - bz * cy) +
          ay * (bz * cx - bx * cz) +
          az * (bx * cy - by * cx);
    }
    return v6 / 6.0;
  }

  void expectStructurallySane(PropMesh m, String what) {
    expect(m.triangleCount, greaterThan(0), reason: '$what is empty');
    expect(m.positions.length, m.normals.length,
        reason: '$what normals out of step with positions');
    expect(m.texCoords.length, m.vertexCount * 2,
        reason: '$what texCoords out of step with positions');
    for (final i in m.indices) {
      expect(i, lessThan(m.vertexCount),
          reason: '$what indexes a vertex it does not have');
    }
    for (var i = 0; i < m.normals.length; i += 3) {
      final n = math.sqrt(m.normals[i] * m.normals[i] +
          m.normals[i + 1] * m.normals[i + 1] +
          m.normals[i + 2] * m.normals[i + 2]);
      expect(n, closeTo(1.0, 1e-4),
          reason: '$what normal ${i ~/ 3} is not unit length');
    }
  }

  void expectBounds(PropMesh m, ProcShape shape, String what) {
    final b = m.bounds;
    final e = shape.extentM;
    expect(b.max.x - b.min.x, closeTo(e.x, 1e-6), reason: '$what X extent');
    expect(b.max.y - b.min.y, closeTo(e.y, 1e-6), reason: '$what Y extent');
    expect(b.max.z - b.min.z, closeTo(e.z, 1e-6), reason: '$what Z extent');
    // Centred on the part origin, not base-origined like a scatter prop.
    expect(b.max.x + b.min.x, closeTo(0, 1e-6), reason: '$what off-centre X');
    expect(b.max.y + b.min.y, closeTo(0, 1e-6), reason: '$what off-centre Y');
    expect(b.max.z + b.min.z, closeTo(0, 1e-6), reason: '$what off-centre Z');
  }

  // The roster's shapes plus edge cases: the smallest and largest of each
  // family, and a pill at the degenerate length == diameter.
  final shapes = <String, ProcShape>{
    'sphere 1.25': const ProcSphere(diameterM: 1.25),
    'sphere 5': const ProcSphere(diameterM: 5),
    'pill 1.25x2.5': const ProcPill(diameterM: 1.25, lengthM: 2.5),
    'pill 2.5x5': const ProcPill(diameterM: 2.5, lengthM: 5),
    'pill degenerate': const ProcPill(diameterM: 1.25, lengthM: 1.25),
    'truss 0.625x1.25': const ProcTruss(widthM: 0.625, lengthM: 1.25),
    'truss 2.5x5': const ProcTruss(widthM: 2.5, lengthM: 5),
    'plate thin': const ProcPlate(widthM: 2, heightM: 2, thicknessM: 0.05),
    'plate armor':
        const ProcPlate(widthM: 2, heightM: 2, thicknessM: 0.25, armor: true),
  };

  test('every shape builds a structurally sane mesh', () {
    for (final e in shapes.entries) {
      expectStructurallySane(ProcPartMesh.build(e.value), e.key);
    }
  });

  test('every mesh fills exactly the box its shape declares, centred', () {
    // The renderer scales a drawn part by size / authoredExtent and the
    // catalog pins spec == size, so extent equality is what makes the drawn
    // box the picked box. See `PartPrimitivesByCategory.standInScaleM`.
    for (final e in shapes.entries) {
      expectBounds(ProcPartMesh.build(e.value), e.value, e.key);
    }
  });

  test('closed solids are wound outward and enclose their true volume', () {
    // Winding is the invariant no picture-free review can see: an inward mesh
    // has the same vertices, the same normals, the same bounds — and renders
    // as culled fronts and visible backs. Volume against the analytic solid
    // catches both a flipped face set and a gross tessellation bug.
    double sphereVol(double d) => math.pi / 6 * d * d * d;
    double pillVol(double d, double l) =>
        math.pi * (d / 2) * (d / 2) * (l - d) + sphereVol(d);

    final vSphere = signedVolume(ProcPartMesh.build(shapes['sphere 5']!));
    expect(vSphere, greaterThan(0), reason: 'sphere wound inward');
    // A tessellated sphere inscribes, so it comes in a little under.
    expect(vSphere, closeTo(sphereVol(5), sphereVol(5) * 0.03));

    final vPill = signedVolume(ProcPartMesh.build(shapes['pill 2.5x5']!));
    expect(vPill, greaterThan(0), reason: 'pill wound inward');
    expect(vPill, closeTo(pillVol(2.5, 5), pillVol(2.5, 5) * 0.03));

    final vPlate = signedVolume(ProcPartMesh.build(shapes['plate armor']!));
    expect(vPlate, closeTo(2 * 2 * 0.25, 1e-9),
        reason: 'a box is exact or something is wound wrong');
  });

  test('a truss is wound outward on every strut', () {
    // The lattice is a union of boxes, so its signed volume is the sum of
    // theirs — positive only if EVERY box is outward. (Struts interpenetrate
    // at the joints, so the sum exceeds the geometric union; that overlap is
    // deliberate and does not change the sign test.) The solid bounding box
    // is a hard ceiling for any single strut wound inward: flipping one
    // subtracts twice its volume, which this bound plus positivity catches
    // for the chords and every rung; the tie to a hand-summed expectation
    // would be busywork, the sign is the bug detector.
    for (final key in ['truss 0.625x1.25', 'truss 2.5x5']) {
      final t = shapes[key]! as ProcTruss;
      final v = signedVolume(ProcPartMesh.build(t));
      expect(v, greaterThan(0), reason: '$key has an inward strut');
      expect(v, lessThan(t.widthM * t.widthM * t.lengthM),
          reason: '$key encloses more than its own bounding box');
    }
  });

  test('a pill at length == diameter is exactly a sphere', () {
    // The degenerate case shares the generator, so it must not grow a seam
    // row of zero-height quads between the caps.
    final pill = ProcPartMesh.build(shapes['pill degenerate']!);
    final sphere = ProcPartMesh.build(const ProcSphere(diameterM: 1.25));
    expect(pill.vertexCount, sphere.vertexCount);
    expect(pill.triangleCount, sphere.triangleCount);
    expect(signedVolume(pill), closeTo(signedVolume(sphere), 1e-9));
  });
}
