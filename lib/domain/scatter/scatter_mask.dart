// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Ground that is already taken — the footprint a colony has claimed, as a
/// gate the scatter placement can ask in O(1).
///
/// Scatter is a pure function of the terrain: it knows about biome, altitude
/// and slope, and nothing whatever about what has been BUILT. That is the
/// right default for a planet and the wrong one for a town, where it puts
/// trees through roofs and shrubs down the middle of a carriageway.
///
/// The mask is the missing input. It carries the colony's road corridors and
/// building sites as capsules (a segment plus a radius; a disc is the
/// degenerate case), bucketed into a hash grid so a candidate tests against
/// the handful of features near it rather than all of them.
///
/// Three properties matter:
///
/// * **It is built from the FRAME.** Roads and buildings arrive in the world
///   snapshot as body-fixed geometry, which is the only source a renderer is
///   allowed to use — a networked client never sees `CitySim`.
/// * **It is flat.** Every test drops the radial component, so the question is
///   "is this candidate inside the footprint", not "is it within a sphere of
///   it" — a 900 m pad on a hillside spans a hundred metres of elevation and a
///   3D distance test would let trees through at its high end.
/// * **It draws no randomness.** Like the other placement gates, it can be
///   consulted without changing the RNG stream, so masking a colony does not
///   reshuffle the forest a kilometre away.
library;

import 'dart:typed_data';

import '../shared/vector3.dart';

/// A colony footprint the scatter must leave alone.
class ScatterMask {
  ScatterMask({
    required this.version,
    required this.originBF,
    required this.groundRadiusM,
    required this.features,
    required this.extentM,
    this.cellM = 96,
  }) : _up = originBF.lengthSquared > 0
            ? originBF.normalized
            : const Vector3(0, 0, 1);

  /// Identity of the layout this was built from. A change means every resident
  /// scatter cell over the colony is stale.
  final int version;

  /// Colony centre, body-fixed metres. Feature coordinates are relative to it
  /// so they fit float32 without losing millimetres to a planet-sized
  /// magnitude.
  final Vector3 originBF;

  /// Radius (m from the body centre) the colony's ground sits at. Candidates
  /// arrive as directions; this turns one into a point without a field sample.
  final double groundRadiusM;

  /// Six floats per feature — ax, ay, az, bx, by, bz — then a radius, all
  /// relative to [originBF] and already flattened into the tangent plane.
  final Float32List features;

  /// Bounding radius of the whole footprint (m), for the one-line reject that
  /// answers for every candidate on the rest of the planet.
  final double extentM;

  /// Hash-grid cell size, metres.
  final double cellM;

  final Vector3 _up;

  /// Lazily built, and deliberately NOT part of what crosses an isolate port:
  /// the flat list is the payload, the index is rebuilt where it is used.
  Map<int, List<int>>? _grid;

  static const int _stride = 7;

  int get featureCount => features.length ~/ _stride;

  bool get isEmpty => features.isEmpty;

  /// Whether a candidate on the ray through [dir] falls inside the footprint.
  bool blocks(Vector3 dir) {
    if (features.isEmpty) return false;
    // The other half of the planet, first. Flattening drops the radial
    // component, and the ANTIPODE of a colony flattens onto its centre — so
    // without this every candidate on the far side of the world lands inside
    // whatever stands here. Points in between are caught by the extent reject
    // below (a quarter turn away is thousands of kilometres of tangential
    // distance); it is only the far cap that aliases.
    if (dir.dot(_up) <= 0) return false;
    final p = dir * groundRadiusM - originBF;
    final t = p - _up * p.dot(_up);
    final tx = t.x, ty = t.y, tz = t.z;
    // Whole-colony reject. Every candidate on the planet that is not over this
    // town leaves here, which is nearly all of them.
    final d2 = tx * tx + ty * ty + tz * tz;
    if (d2 > extentM * extentM) return false;

    final grid = _grid ??= _buildGrid();
    final bucket = grid[_key(tx, ty, tz)];
    if (bucket == null) return false;
    for (final i in bucket) {
      final o = i * _stride;
      final r = features[o + 6];
      if (_distanceToSegmentSq(
              tx, ty, tz,
              features[o], features[o + 1], features[o + 2],
              features[o + 3], features[o + 4], features[o + 5]) <=
          r * r) {
        return true;
      }
    }
    return false;
  }

  int _key(double x, double y, double z) => Object.hash(
        (x / cellM).floor(),
        (y / cellM).floor(),
        (z / cellM).floor(),
      );

  /// Index every feature into the cells its capsule can reach.
  Map<int, List<int>> _buildGrid() {
    final grid = <int, List<int>>{};
    for (var i = 0; i < featureCount; i++) {
      final o = i * _stride;
      final r = features[o + 6];
      final lo = [
        (features[o] < features[o + 3] ? features[o] : features[o + 3]) - r,
        (features[o + 1] < features[o + 4] ? features[o + 1] : features[o + 4]) - r,
        (features[o + 2] < features[o + 5] ? features[o + 2] : features[o + 5]) - r,
      ];
      final hi = [
        (features[o] > features[o + 3] ? features[o] : features[o + 3]) + r,
        (features[o + 1] > features[o + 4] ? features[o + 1] : features[o + 4]) + r,
        (features[o + 2] > features[o + 5] ? features[o + 2] : features[o + 5]) + r,
      ];
      for (var cx = (lo[0] / cellM).floor(); cx <= (hi[0] / cellM).floor(); cx++) {
        for (var cy = (lo[1] / cellM).floor(); cy <= (hi[1] / cellM).floor(); cy++) {
          for (var cz = (lo[2] / cellM).floor();
              cz <= (hi[2] / cellM).floor();
              cz++) {
            (grid[Object.hash(cx, cy, cz)] ??= <int>[]).add(i);
          }
        }
      }
    }
    return grid;
  }

  static double _distanceToSegmentSq(double px, double py, double pz,
      double ax, double ay, double az, double bx, double by, double bz) {
    final abx = bx - ax, aby = by - ay, abz = bz - az;
    final apx = px - ax, apy = py - ay, apz = pz - az;
    final ab2 = abx * abx + aby * aby + abz * abz;
    var t = ab2 <= 0 ? 0.0 : (apx * abx + apy * aby + apz * abz) / ab2;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final dx = apx - abx * t, dy = apy - aby * t, dz = apz - abz * t;
    return dx * dx + dy * dy + dz * dz;
  }
}

/// Accumulates a colony's footprint, then freezes it into a [ScatterMask].
///
/// Callers work in body-fixed metres and never think about the tangent frame:
/// the builder flattens as it goes.
class ScatterMaskBuilder {
  ScatterMaskBuilder({
    required this.originBF,
    required this.groundRadiusM,
  }) : _up = originBF.lengthSquared > 0
            ? originBF.normalized
            : const Vector3(0, 0, 1);

  final Vector3 originBF;
  final double groundRadiusM;
  final Vector3 _up;

  final List<double> _f = [];
  double _extent = 0;

  bool get isEmpty => _f.isEmpty;

  /// A circular footprint of [radiusM] at body-fixed [centre].
  void addDisc(Vector3 centre, double radiusM) =>
      addCapsule(centre, centre, radiusM);

  /// A corridor of [radiusM] from body-fixed [a] to [b] — a road, a runway,
  /// the long axis of anything.
  void addCapsule(Vector3 a, Vector3 b, double radiusM) {
    if (radiusM <= 0) return;
    final ta = _flatten(a), tb = _flatten(b);
    _f
      ..add(ta.x)
      ..add(ta.y)
      ..add(ta.z)
      ..add(tb.x)
      ..add(tb.y)
      ..add(tb.z)
      ..add(radiusM);
    final ra = ta.length + radiusM, rb = tb.length + radiusM;
    if (ra > _extent) _extent = ra;
    if (rb > _extent) _extent = rb;
  }

  Vector3 _flatten(Vector3 pBF) {
    final p = pBF - originBF;
    return p - _up * p.dot(_up);
  }

  ScatterMask build(int version, {double cellM = 96}) => ScatterMask(
        version: version,
        originBF: originBF,
        groundRadiusM: groundRadiusM,
        features: Float32List.fromList(_f),
        extentM: _extent,
        cellM: cellM,
      );
}
