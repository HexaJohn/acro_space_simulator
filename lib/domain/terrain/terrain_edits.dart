// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The per-body store of terrain deformations, indexed on the cubed sphere.
///
/// Edits are mutable world state, so this does NOT live on `CelestialBody`
/// (immutable reference data). It is threaded into `TerrainField` at
/// construction, which keeps every existing caller — collision, the cell
/// mesher, the renderer — on their current signatures.
///
/// ## Why an index at all
///
/// `TerrainField.density` is called per voxel: a single chunk at resolution 24
/// is tens of thousands of samples, and the LOD tree meshes many chunks. A
/// linear scan over every edit on the body would make deformation cost scale
/// with the planet's history rather than with what is on screen.
///
/// A ray cast from the body centre along a unit direction is exactly a POINT in
/// this index, which is why the same lookup serves both `density` (the sample's
/// own direction) and `groundRadiusAt` (the collision ray). Each brush is
/// inserted into every cell its angular footprint touches, so a lookup is one
/// map probe per occupied level with no neighbour walking — and therefore no
/// cube-seam special cases.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';
import 'cubed_sphere.dart';
import 'terrain_brush.dart';

/// Deepest level the index will bucket at. Level 22 cells are sub-metre on a
/// Moon-sized body, far below any brush worth indexing separately.
const int _maxIndexLevel = 22;

/// An ordered, spatially indexed collection of [TerrainBrush] edits for one
/// body.
///
/// Order is significant — the brushes compose by SDF `min`/`max`, which do not
/// commute — and insertion order is tick order in the authoritative sim. That
/// is what makes the composed field reproducible across the sim server and
/// every client.
class TerrainEdits {
  TerrainEdits();

  /// Rebuild from a serialised/replicated sequence, preserving order.
  factory TerrainEdits.of(Iterable<TerrainBrush> brushes) {
    final e = TerrainEdits();
    for (final b in brushes) {
      e.add(b);
    }
    return e;
  }

  final List<TerrainBrush> _all = [];

  /// level -> cell -> indices into [_all]. Sparse: only occupied cells exist.
  final Map<int, Map<ChunkKey, List<int>>> _buckets = {};

  var _maxBoundingRadiusM = 0.0;
  var _version = 0;

  /// Every edit, in application order.
  List<TerrainBrush> get all => List.unmodifiable(_all);

  int get length => _all.length;

  bool get isEmpty => _all.isEmpty;

  bool get isNotEmpty => _all.isNotEmpty;

  /// Bumped on every mutation. Cheap dirty-check for mesh invalidation and for
  /// deciding what a client still needs replicated.
  int get version => _version;

  /// Largest [TerrainBrush.boundingRadiusM] present (m), or 0 when empty. The
  /// radial raymarch uses this to pad its search band.
  double get maxBoundingRadiusM => _maxBoundingRadiusM;

  /// Append [brush] and index it. Returns its ordinal.
  int add(TerrainBrush brush) {
    final index = _all.length;
    _all.add(brush);
    if (brush.boundingRadiusM > _maxBoundingRadiusM) {
      _maxBoundingRadiusM = brush.boundingRadiusM;
    }
    final level = indexLevelFor(brush);
    final cells = _buckets.putIfAbsent(level, () => {});
    for (final c in chunksTouchedBy(brush, level)) {
      (cells[c] ??= []).add(index);
    }
    _version++;
    return index;
  }

  /// Drop every edit.
  void clear() {
    _all.clear();
    _buckets.clear();
    _maxBoundingRadiusM = 0;
    _version++;
  }

  /// The edits whose footprint covers unit direction [dir], in application
  /// order. Candidates only — a brush is returned when the RAY along [dir]
  /// passes through its influence, which does not mean any particular point on
  /// that ray is inside it.
  List<TerrainBrush> at(Vector3 dir) {
    if (_all.isEmpty) return const [];
    List<int>? single;
    Set<int>? merged;
    for (final entry in _buckets.entries) {
      final hits = entry.value[chunkAt(dir, entry.key)];
      if (hits == null) continue;
      if (single == null) {
        single = hits;
      } else {
        // Two or more occupied levels contribute: merge and re-sort so the
        // result is still in application order.
        merged ??= {...single};
        merged.addAll(hits);
      }
    }
    if (merged != null) {
      final ordered = merged.toList()..sort();
      return [for (final i in ordered) _all[i]];
    }
    if (single == null) return const [];
    return [for (final i in single) _all[i]];
  }

  /// Compose every edit covering [p] onto [density]. [p] is body-fixed metres.
  ///
  /// Returns [density] unchanged when nothing covers the point, which is the
  /// case for essentially the whole planet and keeps the common path free.
  double apply(double density, Vector3 p) {
    if (_all.isEmpty) return density;
    final dir = p.normalized;
    if (dir == Vector3.zero) return density;
    var d = density;
    for (final b in at(dir)) {
      d = b.apply(d, p);
    }
    return d;
  }

  /// The level [brush] is bucketed at: the deepest whose cells still comfortably
  /// exceed the brush's angular footprint, so it lands in a handful of cells
  /// rather than thousands.
  static int indexLevelFor(TerrainBrush brush) {
    final alpha = _angularRadius(brush);
    if (alpha <= 0) return _maxIndexLevel;
    if (alpha >= 0.125) return 0;
    // A level-L cell's angular half-extent is at least ~0.5/2^L rad (cells
    // shrink toward the cube corners, so this is the conservative bound). Ask
    // for a cell at least 4x the footprint, which bounds the cap to the cell it
    // centres in plus its immediate neighbours — few enough that the ring
    // sampling in [chunksTouchedBy] cannot step over an entirely enclosed cell.
    final level = (math.log(0.125 / alpha) / math.ln2).floor();
    return level.clamp(0, _maxIndexLevel);
  }

  /// Every level-[level] cell [brush]'s footprint touches.
  ///
  /// Found by sampling the footprint's spherical cap and asking [chunkAt] which
  /// cell each sample lands in, rather than by walking cell adjacency. That
  /// sidesteps the cube's seam and corner transforms entirely: a direction is a
  /// direction, and `chunkAt` is total. Over-covering is harmless (a redundant
  /// bounding-sphere test at lookup); under-covering would drop an edit, so the
  /// sampling is deliberately generous.
  static Set<ChunkKey> chunksTouchedBy(TerrainBrush brush, int level) {
    final centre = brush.centreBF;
    if (centre.lengthSquared == 0) return {...ChunkKey.roots};
    final dir = centre.normalized;
    final alpha = _angularRadius(brush);
    // A footprint this wide is not worth indexing — it can straddle the whole
    // cube, so bucket it at every root and let the bounding test do the work.
    if (alpha >= 0.5 || level == 0) return {...ChunkKey.roots};

    final out = <ChunkKey>{chunkAt(dir, level)};
    // Tangent frame around `dir` for walking the cap.
    final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    final tangent = seed.cross(dir).normalized;
    final bitangent = dir.cross(tangent);

    const rings = [1.0, 0.7, 0.4];
    const samples = 16;
    for (final ring in rings) {
      final sin = math.sin(alpha * ring), cos = math.cos(alpha * ring);
      for (var i = 0; i < samples; i++) {
        final phi = 2 * math.pi * i / samples;
        final offset =
            tangent * (math.cos(phi) * sin) + bitangent * (math.sin(phi) * sin);
        out.add(chunkAt((dir * cos + offset).normalized, level));
      }
    }
    return out;
  }

  /// Angular radius (rad) of [brush]'s footprint seen from the body centre.
  ///
  /// Uses [TerrainBrush.lateralReachM], not the bounding sphere: a ray's
  /// bucket decides whether the brush is a CANDIDATE for surface work along
  /// it, and sign changes only happen within the lateral reach. The bounding
  /// sphere over-covered badly for levelling brushes (a 12 m pad indexed a
  /// ~92 m footprint), and every false-positive cell sends the mesher's whole
  /// column down the per-voxel slow path.
  static double _angularRadius(TerrainBrush brush) {
    final dist = brush.centreBF.length;
    if (dist <= brush.lateralReachM) return math.pi / 2;
    return math.asin((brush.lateralReachM / dist).clamp(0.0, 1.0));
  }
}
