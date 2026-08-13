// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Baked real-elevation data on the cubed sphere — Stage 4's runtime half.
///
/// ## Why cube faces and not equirectangular
///
/// Source DEMs ship equirectangular, and it is tempting to keep them that way.
/// Two reasons not to: the poles are a singularity where thousands of source
/// columns collapse onto one point (so polar terrain is both over-sampled and
/// ill-conditioned), and every lookup would need a projection change away from
/// the `ChunkKey` addressing the mesher and LOD already use. Baking onto cube
/// faces once, offline, removes both permanently.
///
/// ## Why int16
///
/// The Moon's relief spans about 19.2 km. Quantised across int16 that is ~0.3 m
/// per step — far below anything the mesher can resolve — while halving the
/// footprint against float32. The source `ldem_64.tif` is float32 and 1.06 GB;
/// it is working data, not ship data.
///
/// ## Determinism
///
/// The whole pyramid is decoded up front and held in memory. That is the point:
/// collision samples this from the deterministic tick, so it cannot be allowed
/// to depend on what has finished streaming. A resident pyramid at a few MB
/// gives every point a synchronous answer, forever, on server and client alike.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../shared/vector3.dart';
import 'cubed_sphere.dart';
import 'terrain_control.dart';

/// File magic — 'ACRODEM\x01'.
const int _magic0 = 0x4143524F; // 'ACRO'
const int _magic1 = 0x44454D01; // 'DEM\x01'

/// A mip pyramid of elevation over the six cube faces.
///
/// Level 0 is finest; each level halves the face edge. Elevations are metres
/// relative to the body's datum radius.
class DemPyramid {
  DemPyramid({
    required this.radiusM,
    required this.faceSize,
    required this.minElevM,
    required this.maxElevM,
    required this.levels,
  }) : assert(levels.isNotEmpty);

  /// Datum radius (m) the elevations are relative to.
  final double radiusM;

  /// Face edge in samples at level 0.
  final int faceSize;

  final double minElevM;
  final double maxElevM;

  /// `levels[l][face]` is a `size*size` int16 grid, `size = faceSize >> l`.
  final List<List<Int16List>> levels;

  int get levelCount => levels.length;

  /// Face edge in samples at [level].
  int sizeAt(int level) => faceSize >> level;

  /// Decode a quantised sample to metres.
  double _decode(int q) =>
      minElevM + (q + 32768) / 65535.0 * (maxElevM - minElevM);

  /// Quantise metres to int16.
  static int quantise(double elevM, double minElevM, double maxElevM) {
    final span = maxElevM - minElevM;
    if (span <= 0) return 0;
    final t = ((elevM - minElevM) / span).clamp(0.0, 1.0);
    return (t * 65535.0).round() - 32768;
  }

  /// Elevation (m) above the datum along a unit direction, bilinearly filtered.
  ///
  /// [level] selects detail; 0 is finest. Sampling CLAMPS at face edges rather
  /// than reaching into the neighbouring face. The error is sub-texel and both
  /// faces were baked from the same source, so the surface stays continuous
  /// across a seam without any cross-face addressing at runtime.
  double elevationAt(Vector3 dir, {int level = 0}) {
    final l = level.clamp(0, levelCount - 1);
    final size = sizeAt(l);
    final face = faceOfDirection(dir);
    final st = faceST(face, dir);

    // (s,t) in [-1,1] -> texel coordinates, half-texel inset so samples sit at
    // texel CENTRES and the bilinear weights are right at the edges.
    final u = ((st.s + 1.0) * 0.5 * size - 0.5).clamp(0.0, size - 1.0);
    final v = ((st.t + 1.0) * 0.5 * size - 0.5).clamp(0.0, size - 1.0);
    final x0 = u.floor(), y0 = v.floor();
    final x1 = math.min(x0 + 1, size - 1), y1 = math.min(y0 + 1, size - 1);
    final fx = u - x0, fy = v - y0;

    final grid = levels[l][face.index];
    final a = _decode(grid[y0 * size + x0]);
    final b = _decode(grid[y0 * size + x1]);
    final c = _decode(grid[y1 * size + x0]);
    final d = _decode(grid[y1 * size + x1]);
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
  }

  /// Local relief (m) around a direction, measured as the spread of the
  /// coarser levels around it.
  ///
  /// This is what makes a DEM able to drive a [TerrainControl]: roughness and
  /// relief are not stored channels, they are STATISTICS of the height field,
  /// and reading them off the pyramid costs four taps instead of a bake pass.
  double localReliefAt(Vector3 dir, {int level = 2}) {
    final l = level.clamp(0, levelCount - 1);
    final size = sizeAt(l);
    final face = faceOfDirection(dir);
    final st = faceST(face, dir);
    final step = 2.0 / size;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final e = elevationAt(
          directionOf(face, st.s + dx * step, st.t + dy * step),
          level: l,
        );
        if (e < lo) lo = e;
        if (e > hi) hi = e;
      }
    }
    return hi - lo;
  }

  /// Serialise. The tool writes this; the app reads it back with [decode].
  Uint8List encode() {
    var bytes = 4 + 4 + 8 + 4 + 4 + 8 + 8;
    for (var l = 0; l < levelCount; l++) {
      final size = sizeAt(l);
      bytes += 6 * size * size * 2;
    }
    final out = ByteData(bytes);
    var o = 0;
    out.setUint32(o, _magic0); o += 4;
    out.setUint32(o, _magic1); o += 4;
    out.setFloat64(o, radiusM); o += 8;
    out.setUint32(o, faceSize); o += 4;
    out.setUint32(o, levelCount); o += 4;
    out.setFloat64(o, minElevM); o += 8;
    out.setFloat64(o, maxElevM); o += 8;
    for (var l = 0; l < levelCount; l++) {
      for (var f = 0; f < 6; f++) {
        final grid = levels[l][f];
        for (var i = 0; i < grid.length; i++) {
          out.setInt16(o, grid[i]);
          o += 2;
        }
      }
    }
    return out.buffer.asUint8List();
  }

  /// Parse a baked pyramid. Throws [FormatException] on anything unexpected —
  /// a mis-parsed DEM would silently move the ground, which is far worse than
  /// failing to load.
  static DemPyramid decode(Uint8List data) {
    final view = ByteData.sublistView(data);
    var o = 0;
    if (view.lengthInBytes < 40) {
      throw const FormatException('DEM pyramid truncated');
    }
    if (view.getUint32(o) != _magic0 || view.getUint32(o + 4) != _magic1) {
      throw const FormatException('not an ACRODEM pyramid');
    }
    o += 8;
    final radiusM = view.getFloat64(o); o += 8;
    final faceSize = view.getUint32(o); o += 4;
    final levelCount = view.getUint32(o); o += 4;
    final minElevM = view.getFloat64(o); o += 8;
    final maxElevM = view.getFloat64(o); o += 8;
    if (faceSize <= 0 || levelCount <= 0 || levelCount > 20) {
      throw FormatException('bad DEM header: size=$faceSize levels=$levelCount');
    }
    final levels = <List<Int16List>>[];
    for (var l = 0; l < levelCount; l++) {
      final size = faceSize >> l;
      final faces = <Int16List>[];
      for (var f = 0; f < 6; f++) {
        final grid = Int16List(size * size);
        for (var i = 0; i < grid.length; i++) {
          grid[i] = view.getInt16(o);
          o += 2;
        }
        faces.add(grid);
      }
      levels.add(faces);
    }
    return DemPyramid(
      radiusM: radiusM,
      faceSize: faceSize,
      minElevM: minElevM,
      maxElevM: maxElevM,
      levels: levels,
    );
  }
}

/// A [TerrainControl] whose channels are DERIVED from real elevation data.
///
/// The counterpart to `SyntheticControl`, and the reason that is an interface:
/// "what kind of ground is here" has two answers depending on whether the body
/// has been surveyed, and both feed the same features. Relief and roughness
/// come out of the pyramid's own statistics rather than being invented, so the
/// detail layer extends real terrain instead of competing with it.
class DemDerivedControl implements TerrainControl {
  const DemDerivedControl(
    this.dem, {
    this.detailFraction = 0.35,
    this.roughnessReliefM = 4000,
    this.statLevel = 2,
  });

  final DemPyramid dem;

  /// How much relief the DETAIL layer may add, as a fraction of the local
  /// relief the DEM already carries. The DEM owns everything above its Nyquist;
  /// this layer only fills in below it, so it must stay a minority contributor
  /// or it will drown the real landforms.
  final double detailFraction;

  /// Local relief (m) treated as fully rough. Above this, roughness saturates.
  final double roughnessReliefM;

  /// Pyramid level the statistics are read at. Coarse on purpose — this is a
  /// regional character, not a per-sample one.
  final int statLevel;

  @override
  double reliefAt(Vector3 dir) =>
      dem.localReliefAt(dir, level: statLevel) * detailFraction;

  @override
  double roughnessAt(Vector3 dir) =>
      (dem.localReliefAt(dir, level: statLevel) / roughnessReliefM)
          .clamp(0.0, 1.0);

  @override
  double ridgednessAt(Vector3 dir) {
    // Ridged where the ground is both high AND broken — the signature of an
    // uplifted range rather than a rough basin floor.
    final relief = dem.localReliefAt(dir, level: statLevel);
    final elev = dem.elevationAt(dir, level: statLevel);
    final span = dem.maxElevM - dem.minElevM;
    if (span <= 0) return 0;
    final height = ((elev - dem.minElevM) / span).clamp(0.0, 1.0);
    return (height * (relief / roughnessReliefM)).clamp(0.0, 1.0);
  }

  @override
  Vector3 lineationAt(Vector3 dir) => Vector3.zero;
}
