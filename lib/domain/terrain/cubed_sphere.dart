// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Cubed-sphere chunk addressing for full-planet terrain LOD (phase 4a).
///
/// The body's surface is covered by six cube faces, each an independent
/// quadtree. A chunk is `(face, level, u, v)`: at [ChunkKey.level] `L` a face
/// carries `2^L x 2^L` cells, indexed `u` along the face's right axis and `v`
/// along its up axis. Directions are unit vectors in the BODY-FIXED frame, the
/// same frame the terrain mesh and `TerrainField` live in.
///
/// The cube-to-sphere map here is plain normalisation (`normalize(f + s*r +
/// t*u)`), not an equal-area or tangent warp. Cells are therefore not uniform:
/// a face-corner cell subtends roughly 40% less angle than a face-centre cell
/// at the same level. That is harmless for LOD — selection is driven by
/// projected size per chunk, so a smaller cell simply splits one level later —
/// but it does mean chunk world size is a function of position, never a
/// constant. Anything needing a real size must call [ChunkKey.circumradiusM].
library;

import '../shared/vector3.dart';

/// The six cube faces, named for the body-fixed axis each one faces.
enum CubeFace { posX, negX, posY, negY, posZ, negZ }

/// Which of a chunk's four edges to step across. `s` is the face's right axis,
/// `t` its up axis.
enum ChunkEdge { minusS, plusS, minusT, plusT }

/// A face's orthonormal frame. `right x up == forward` for all six, so the
/// basis is right-handed everywhere and seam crossings never mirror.
class FaceBasis {
  const FaceBasis(this.forward, this.right, this.up);

  /// Outward normal of the face — the axis the face is named for.
  final Vector3 forward;

  /// The `s` axis.
  final Vector3 right;

  /// The `t` axis.
  final Vector3 up;
}

const Map<CubeFace, FaceBasis> _basis = {
  CubeFace.posX: FaceBasis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)),
  CubeFace.negX:
      FaceBasis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)),
  CubeFace.posY: FaceBasis(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)),
  CubeFace.negY:
      FaceBasis(Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)),
  CubeFace.posZ: FaceBasis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)),
  CubeFace.negZ:
      FaceBasis(Vector3(0, 0, -1), Vector3(0, 1, 0), Vector3(1, 0, 0)),
};

/// The orthonormal frame of [face].
FaceBasis basisOf(CubeFace face) => _basis[face]!;

/// The face owning [dir] — the one whose axis is [dir]'s dominant component.
///
/// Exactly on a cube edge or corner the dominant component ties; the `>=`
/// comparisons break the tie deterministically (X wins over Y wins over Z) so
/// this stays a total function. Callers relying on a specific side of a seam
/// must not depend on which way a tie falls.
CubeFace faceOfDirection(Vector3 dir) {
  final ax = dir.x.abs(), ay = dir.y.abs(), az = dir.z.abs();
  if (ax >= ay && ax >= az) return dir.x > 0 ? CubeFace.posX : CubeFace.negX;
  if (ay >= az) return dir.y > 0 ? CubeFace.posY : CubeFace.negY;
  return dir.z > 0 ? CubeFace.posZ : CubeFace.negZ;
}

/// Face-local `(s, t)` of [dir] on [face], both in `[-1, 1]` when [dir] really
/// belongs to [face]. Dividing by the forward component is the gnomonic
/// projection back onto the cube face.
({double s, double t}) faceST(CubeFace face, Vector3 dir) {
  final b = basisOf(face);
  final f = dir.dot(b.forward);
  if (f.abs() < 1e-300) return (s: 0, t: 0); // degenerate; caller picked wrong face
  return (s: dir.dot(b.right) / f, t: dir.dot(b.up) / f);
}

/// Unit direction for face-local `(s, t)`.
///
/// Values outside `[-1, 1]` are legal and land on a neighbouring face — that is
/// what makes seam crossing expressible as arithmetic on one face's frame.
Vector3 directionOf(CubeFace face, double s, double t) {
  final b = basisOf(face);
  return (b.forward + b.right * s + b.up * t).normalized;
}

/// The face whose forward axis is the unit axis vector [axis].
CubeFace _faceOfAxis(Vector3 axis) {
  for (final e in _basis.entries) {
    if (e.value.forward.dot(axis) > 0.5) return e.key;
  }
  throw ArgumentError('not a cube axis: $axis');
}

/// Centre coordinate of cell [i] of [n] across a `[-1, 1]` span.
double _cellCentre(int i, int n) => -1.0 + (2.0 * i + 1.0) / n;

/// Inverse of [_cellCentre], rounded — [c] is always exactly a cell centre
/// (possibly negated) when this is called, so rounding only kills float dust.
int _indexOfCentre(double c, int n) => (((c + 1.0) * n - 1.0) / 2.0).round();

/// One chunk of the cubed sphere: a quadtree cell on one cube face.
class ChunkKey {
  const ChunkKey(this.face, this.level, this.u, this.v);

  /// The root cell of [face].
  const ChunkKey.root(this.face)
      : level = 0,
        u = 0,
        v = 0;

  final CubeFace face;

  /// Subdivision depth. Level `L` splits the face into `2^L x 2^L` cells.
  final int level;

  /// Cell index along the face's right (`s`) axis, in `[0, 2^level)`.
  final int u;

  /// Cell index along the face's up (`t`) axis, in `[0, 2^level)`.
  final int v;

  /// The six level-0 chunks covering the whole body.
  static List<ChunkKey> get roots =>
      [for (final f in CubeFace.values) ChunkKey.root(f)];

  /// Cells across the face at this level.
  int get cellsPerSide => 1 << level;

  /// Face-local `s` at the cell's low edge.
  double get s0 => -1.0 + 2.0 * u / cellsPerSide;

  /// Face-local `s` at the cell's high edge.
  double get s1 => -1.0 + 2.0 * (u + 1) / cellsPerSide;

  /// Face-local `t` at the cell's low edge.
  double get t0 => -1.0 + 2.0 * v / cellsPerSide;

  /// Face-local `t` at the cell's high edge.
  double get t1 => -1.0 + 2.0 * (v + 1) / cellsPerSide;

  /// Unit direction through the cell's centre.
  Vector3 get centreDirection =>
      directionOf(face, _cellCentre(u, cellsPerSide), _cellCentre(v, cellsPerSide));

  /// Unit directions through the cell's four corners.
  List<Vector3> get cornerDirections => [
        directionOf(face, s0, t0),
        directionOf(face, s1, t0),
        directionOf(face, s0, t1),
        directionOf(face, s1, t1),
      ];

  /// Whether [dir] falls inside this cell. Inclusive on all four edges, so a
  /// direction exactly on a shared boundary is reported by both cells.
  ///
  /// Deliberately computed with the SAME shifted arithmetic [chunkAt] floors —
  /// `(s + 1.0) * 0.5 * n` — not by comparing raw `s` against [s0]/[s1]. The
  /// two differ by rounding: for `s` within half an ulp below a cell boundary
  /// through the face centre (`s0 == 0`), the `+ 1.0` rounds half-even UP onto
  /// the boundary, so [chunkAt] assigns the upper cell while a raw compare
  /// against `s0` rejects it — breaking `chunkAt(d, L).contains(d)`, which
  /// `pinned()`/`_applyRefinements` in terrain_lod.dart and the mesher's
  /// interior tests all rely on. Sharing the arithmetic makes the invariant
  /// hold by construction.
  bool contains(Vector3 dir) {
    if (faceOfDirection(dir) != face) return false;
    final st = faceST(face, dir);
    final n = cellsPerSide;
    final qs = (st.s + 1.0) * 0.5 * n;
    final qt = (st.t + 1.0) * 0.5 * n;
    return qs >= u && qs <= u + 1 && qt >= v && qt <= v + 1;
  }

  /// Half the cell's world extent at sphere radius [radiusM]: the chord from
  /// the centre to the farthest corner.
  ///
  /// This is a circumradius, so it over-covers rather than under-covers — the
  /// conservative direction for a split test, which should err toward more
  /// detail rather than a chunk that stays coarse while it fills the screen.
  double circumradiusM(double radiusM) {
    final c = centreDirection;
    var maxChord = 0.0;
    for (final k in cornerDirections) {
      final d = (k - c).length;
      if (d > maxChord) maxChord = d;
    }
    return maxChord * radiusM;
  }

  /// The coarser cell containing this one, or null at level 0.
  ChunkKey? get parent =>
      level == 0 ? null : ChunkKey(face, level - 1, u >> 1, v >> 1);

  /// The four finer cells tiling this one.
  List<ChunkKey> get children => [
        ChunkKey(face, level + 1, u * 2, v * 2),
        ChunkKey(face, level + 1, u * 2 + 1, v * 2),
        ChunkKey(face, level + 1, u * 2, v * 2 + 1),
        ChunkKey(face, level + 1, u * 2 + 1, v * 2 + 1),
      ];

  /// Every ancestor from [parent] up to the level-0 root, coarsest last.
  List<ChunkKey> get ancestors {
    final out = <ChunkKey>[];
    for (var k = parent; k != null; k = k.parent) {
      out.add(k);
    }
    return out;
  }

  /// The same-level cell across [edge]. Never null: the cube surface is closed,
  /// so every cell has four edge neighbours.
  ///
  /// Within a face this is index arithmetic. Across a seam it is NOT — the two
  /// faces' `(s, t)` axes meet rotated and/or mirrored. Rather than a
  /// hand-written 24-entry adjacency table, the transform is derived from the
  /// face bases: the crossed edge's cell-centre direction is `forward + outward
  /// + a*along`, and re-expressing that in the neighbour's frame yields
  /// coordinates that are exactly `+-1` (the shared edge) and `+-a` (the
  /// position along it). Both are exact in floating point, so the resulting
  /// indices are exact.
  ///
  /// The tempting alternative — step one cell in `(s, t)`, normalise, and
  /// re-project — is subtly wrong: the cube-to-sphere map is non-linear, so a
  /// step from an edge-adjacent cell lands exactly ON a cell boundary near face
  /// corners and the neighbour comes out ambiguous. That is the corner case
  /// `docs/plans/terrain-lod.md` warns about.
  ChunkKey neighbour(ChunkEdge edge) {
    final n = cellsPerSide;
    var nu = u, nv = v;
    switch (edge) {
      case ChunkEdge.minusS:
        nu -= 1;
      case ChunkEdge.plusS:
        nu += 1;
      case ChunkEdge.minusT:
        nv -= 1;
      case ChunkEdge.plusT:
        nv += 1;
    }
    if (nu >= 0 && nu < n && nv >= 0 && nv < n) {
      return ChunkKey(face, level, nu, nv);
    }

    final b = basisOf(face);
    // outward: the axis pointing out of the crossed edge. along: the in-face
    // axis running parallel to it. alongIdx: this cell's index on that axis.
    final (Vector3 outward, Vector3 along, int alongIdx) = switch (edge) {
      ChunkEdge.plusS => (b.right, b.up, v),
      ChunkEdge.minusS => (-b.right, b.up, v),
      ChunkEdge.plusT => (b.up, b.right, u),
      ChunkEdge.minusT => (-b.up, b.right, u),
    };
    final a = _cellCentre(alongIdx, n);

    // A point on the crossed edge, at this cell's centre along it. Unnormalised
    // on purpose: the neighbour's forward component is then exactly 1, so the
    // projection below divides by one and stays exact.
    final onEdge = b.forward + outward + along * a;
    final g = _faceOfAxis(outward);
    final gb = basisOf(g);
    final sG = onEdge.dot(gb.right);
    final tG = onEdge.dot(gb.up);

    // Exactly one of the two is the shared edge (+-1); the other carries the
    // along-edge position (+-a), possibly reversed by the faces' relative
    // orientation.
    if (sG.abs() == 1.0) {
      return ChunkKey(g, level, sG > 0 ? n - 1 : 0, _indexOfCentre(tG, n));
    }
    return ChunkKey(g, level, _indexOfCentre(sG, n), tG > 0 ? n - 1 : 0);
  }

  @override
  bool operator ==(Object other) =>
      other is ChunkKey &&
      other.face == face &&
      other.level == level &&
      other.u == u &&
      other.v == v;

  @override
  int get hashCode => Object.hash(face, level, u, v);

  @override
  String toString() => '${face.name}/$level/$u,$v';
}

/// The chunk containing [dir] at [level].
ChunkKey chunkAt(Vector3 dir, int level) {
  final face = faceOfDirection(dir);
  final st = faceST(face, dir);
  final n = 1 << level;
  // clamp: a direction exactly on a seam can project a hair outside [-1, 1].
  final u = (((st.s + 1.0) * 0.5 * n).floor()).clamp(0, n - 1);
  final v = (((st.t + 1.0) * 0.5 * n).floor()).clamp(0, n - 1);
  return ChunkKey(face, level, u, v);
}
