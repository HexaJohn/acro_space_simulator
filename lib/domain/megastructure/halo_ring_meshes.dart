// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Procedural BACKING meshes for the halo ring — the smooth structural
/// geometry the voxel terrain sits in. Voxels earn their cost only where the
/// surface is editable; the hull skin, truss skeleton, rim walls and the
/// far-LOD terrain strip are analytic sweeps, so they are built here as plain
/// indexed triangle meshes (ring body-fixed metres, ring centre at origin).
///
/// Every builder takes an [arcCoverage] fraction 0..1 and emits geometry for
/// the arc [0, arcCoverage * 2pi) measured from +X — that is how construction
/// stages read as geometry: the truss reaches around the circle as phase 1
/// fills, the hull skins over it during phase 2, terrain pours during phase 3.
///
/// Float32 vertex precision at a 5e6 m ring radius quantises to ~0.5 m; these
/// meshes are the FAR representation (the near view is anchored voxel cells),
/// so that is acceptable. All output is deterministic.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../shared/vector3.dart';
import '../terrain/surface_nets.dart';
import 'halo_ring.dart';

/// How far the far-LOD terrain strip sinks below the true terrain surface so
/// near voxel cells (which mesh the exact surface) never z-fight it.
const double haloStripSinkM = 8.0;

class _MeshSink {
  final positions = <double>[];
  final normals = <double>[];
  final indices = <int>[];

  int get vertexCount => positions.length ~/ 3;

  int vertex(Vector3 p, Vector3 n) {
    positions.addAll([p.x, p.y, p.z]);
    normals.addAll([n.x, n.y, n.z]);
    return vertexCount - 1;
  }

  void quad(int a, int b, int c, int d) {
    indices.addAll([a, b, c, a, c, d]);
  }

  SurfaceMesh build() => SurfaceMesh(
        positions: Float32List.fromList(positions),
        normals: Float32List.fromList(normals),
        indices: Uint32List.fromList(indices),
        normalMode: NormalMode.faceAveraged,
      );
}

Vector3 _rho(double phi) => Vector3(math.cos(phi), math.sin(phi), 0);
Vector3 _pt(double phi, double rho, double z) =>
    Vector3(math.cos(phi) * rho, math.sin(phi) * rho, z);

/// Sweep one cross-section segment (a line in the (rho, z) half-plane with a
/// constant cross-section normal) around the arc.
void _sweep(
  _MeshSink sink,
  double rho0,
  double z0,
  double rho1,
  double z1,
  double nRho,
  double nZ, {
  required int segments,
  required double arcStart,
  required double arcEnd,
}) {
  if (segments < 1 || arcEnd <= arcStart) return;
  int? prevA, prevB;
  for (var s = 0; s <= segments; s++) {
    final phi = arcStart + (arcEnd - arcStart) * s / segments;
    final r = _rho(phi);
    final n = Vector3(r.x * nRho, r.y * nRho, nZ);
    final a = sink.vertex(_pt(phi, rho0, z0), n);
    final b = sink.vertex(_pt(phi, rho1, z1), n);
    if (prevA != null) sink.quad(prevA, a, b, prevB!);
    prevA = a;
    prevB = b;
  }
}

int _arcSegments(int fullSegments, double coverage) =>
    (fullSegments * coverage).ceil().clamp(0, fullSegments);

/// The closed structural band: outer hull skin, band edge faces, rim walls
/// (inner faces + crests) and the bare metal deck. [arcCoverage] grows the
/// whole cross-section around the ring; [deckArcStart] withholds the deck
/// below that fraction — during the terraform stage the poured terrain
/// REPLACES the deck arc by arc, so the soil front visibly advances across
/// bare metal.
SurfaceMesh hullBandMesh(
  HaloRingSpec spec, {
  double arcCoverage = 1,
  double deckArcStart = 0,
  int radialSegments = 384,
}) {
  final sink = _MeshSink();
  final segs = _arcSegments(radialSegments, arcCoverage);
  if (segs == 0) return sink.build();
  final arcEnd = 2 * math.pi * arcCoverage;
  final r = spec.radiusM;
  final outer = spec.outerRadiusM;
  final crest = spec.crestRadiusM;
  final hw = spec.halfWidthM;
  final ihw = spec.halfWidthM - spec.wallThicknessM;

  void seg(double rho0, double z0, double rho1, double z1, double nRho,
          double nZ) =>
      _sweep(sink, rho0, z0, rho1, z1, nRho, nZ,
          segments: segs, arcStart: 0, arcEnd: arcEnd);

  // Cross-section, both rim walls + outer skin. Normals face the habitable
  // void or space; materials render double-sided, so winding is free.
  seg(crest, ihw, r, ihw, 0, -1); // north wall inner face
  seg(crest, ihw, crest, hw, -1, 0); // north crest top
  seg(crest, hw, outer, hw, 0, 1); // north band edge
  seg(outer, hw, outer, -hw, 1, 0); // outer hull skin
  seg(outer, -hw, crest, -hw, 0, -1); // south band edge
  seg(crest, -hw, crest, -ihw, -1, 0); // south crest top
  seg(r, -ihw, crest, -ihw, 0, 1); // south wall inner face

  // Bare deck between the wall feet, withheld where terrain has poured.
  final deckStart = (deckArcStart.clamp(0.0, 1.0)) * 2 * math.pi;
  if (deckStart < arcEnd) {
    final deckSegs =
        _arcSegments(radialSegments, arcCoverage - deckArcStart.clamp(0.0, 1.0));
    _sweep(sink, r, -ihw, r, ihw, -1, 0,
        segments: deckSegs, arcStart: deckStart, arcEnd: arcEnd);
  }
  return sink.build();
}

/// An axis-aligned-free box strut between [a] and [b] with square cross
/// section [halfM]: 4 side faces, flat normals, no caps (they are buried in
/// joints).
void _strut(_MeshSink sink, Vector3 a, Vector3 b, double halfM) {
  final d = (b - a).normalized;
  // Any stable perpendicular.
  final ref = d.z.abs() < 0.9 ? Vector3(0, 0, 1) : Vector3(1, 0, 0);
  final u = d.cross(ref).normalized * halfM;
  final v = d.cross(u).normalized * halfM;
  for (final (s0, s1) in [(u, v), (v, -u), (-u, -v), (-v, u)]) {
    final n = (s0 + s1).normalized;
    final i0 = sink.vertex(a + s0, n);
    final i1 = sink.vertex(b + s0, n);
    final i2 = sink.vertex(b + s1, n);
    final i3 = sink.vertex(a + s1, n);
    sink.quad(i0, i1, i2, i3);
  }
}

/// Construction skeleton: four chord rails at the corners of the (future)
/// hull cross-section, tied by a rectangular frame at every station, with one
/// face diagonal per bay so it reads as truss-work rather than a wireframe
/// box. Chunky struts on purpose — a 5,000 km ring's skeleton has to be
/// visible from orbit.
SurfaceMesh trussMesh(
  HaloRingSpec spec, {
  double arcCoverage = 1,
  int stations = 192,
  double strutHalfM = 150,
}) {
  final sink = _MeshSink();
  final count = _arcSegments(stations, arcCoverage);
  if (count == 0) return sink.build();
  final corners = [
    (spec.outerRadiusM, spec.halfWidthM),
    (spec.outerRadiusM, -spec.halfWidthM),
    (spec.crestRadiusM, -spec.halfWidthM),
    (spec.crestRadiusM, spec.halfWidthM),
  ];
  Vector3 at(int station, int corner) {
    final phi = 2 * math.pi * station / stations;
    final (rho, z) = corners[corner];
    return _pt(phi, rho, z);
  }

  for (var s = 0; s < count; s++) {
    // Station frame.
    for (var c = 0; c < 4; c++) {
      _strut(sink, at(s, c), at(s, (c + 1) % 4), strutHalfM);
    }
    // Rails to the next station.
    for (var c = 0; c < 4; c++) {
      _strut(sink, at(s, c), at(s + 1, c), strutHalfM);
    }
    // One diagonal across the outer face per bay, alternating direction.
    final flip = s.isOdd;
    _strut(sink, at(s, flip ? 1 : 0), at(s + 1, flip ? 0 : 1), strutHalfM);
  }
  // Closing frame at the leading edge of an incomplete arc.
  if (count < stations) {
    for (var c = 0; c < 4; c++) {
      _strut(sink, at(count, c), at(count, (c + 1) % 4), strutHalfM);
    }
  }
  return sink.build();
}

/// Far-LOD terrain: the floor height field sampled on a coarse (phi, z) grid,
/// sunk [haloStripSinkM] below the true surface so near voxel cells draw over
/// it. Normals from central differences of the same height field, so lighting
/// matches what the voxel cells will show up close.
SurfaceMesh terrainStripMesh(
  HaloRingField field, {
  double arcCoverage = 1,
  int radialSegments = 768,
  int lateralSegments = 12,
}) {
  final sink = _MeshSink();
  final segs = _arcSegments(radialSegments, arcCoverage);
  if (segs == 0) return sink.build();
  final spec = field.spec;
  final ihw = spec.interiorHalfWidthM;
  final dPhi = 2 * math.pi * arcCoverage / segs;
  final dZ = 2 * ihw / lateralSegments;

  final rows = <List<int>>[];
  for (var s = 0; s <= segs; s++) {
    final phi = s * dPhi;
    final row = <int>[];
    for (var l = 0; l <= lateralSegments; l++) {
      final z = -ihw + l * dZ;
      final rho = field.floorRadiusAt(phi, z) + haloStripSinkM;
      // Central-difference slope of the height field. Height increases toward
      // the axis, so the normal tilts off the inward radial.
      final hA = field.heightAt(phi + dPhi, z) - field.heightAt(phi - dPhi, z);
      final hZ = field.heightAt(phi, z + dZ) - field.heightAt(phi, z - dZ);
      final r = _rho(phi);
      final tArc = Vector3(-r.y, r.x, 0);
      final inward = -r;
      final n = (inward +
              tArc * (hA / (2 * dPhi * rho)) +
              Vector3(0, 0, hZ / (2 * dZ)))
          .normalized;
      row.add(sink.vertex(_pt(phi, rho, z), n));
    }
    rows.add(row);
  }
  for (var s = 0; s < segs; s++) {
    for (var l = 0; l < lateralSegments; l++) {
      sink.quad(rows[s][l], rows[s + 1][l], rows[s + 1][l + 1], rows[s][l + 1]);
    }
  }
  return sink.build();
}

/// Habitat lighting: one emissive ribbon along each wall crest, facing the
/// habitable void. Rendered unlit; brightness rides the material, not the
/// mesh.
SurfaceMesh crestLightsMesh(
  HaloRingSpec spec, {
  double arcCoverage = 1,
  int radialSegments = 384,
  double stripWidthM = 80,
}) {
  final sink = _MeshSink();
  final segs = _arcSegments(radialSegments, arcCoverage);
  if (segs == 0) return sink.build();
  final arcEnd = 2 * math.pi * arcCoverage;
  final rho = spec.crestRadiusM - 2; // just proud of the crest
  for (final side in [-1.0, 1.0]) {
    final zOuter = side * (spec.halfWidthM - 2);
    final zInner = side * (spec.halfWidthM - 2) - side * stripWidthM;
    _sweep(sink, rho, zInner, rho, zOuter, -1, 0,
        segments: segs, arcStart: 0, arcEnd: arcEnd);
  }
  return sink.build();
}
