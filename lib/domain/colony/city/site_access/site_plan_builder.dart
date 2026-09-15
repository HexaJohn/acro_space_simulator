// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// [PlanBuilder]: the one writer of [SiteAccessChunk]s
/// (docs/plans/site-access.md §2.3, §2.4, §3.9).
///
/// A generator describes one site at a time — `beginSite`, then points,
/// joins, nodes, segments, stalls, bays, paves, lamps, paths and fence gaps,
/// each call returning the new row's plan-local index, then `endSite` — and
/// [PlanBuilder.build] packs every site into one immutable chunk.
///
/// What the builder decides, so no generator can get it wrong:
/// - `segLenM`: the 2-D polyline length, unless a length is given;
/// - stall ORDER: `(seg, s, side)` ascending, ties in call order (V10);
/// - stall KEYS: an `fnv1aU32` chain over the stall's generator-lattice
///   integers `(segment kind ordinal, row, bay, side, heading octant relative
///   to the frame's u)`, collisions resolved in lattice-tuple order by `+1`
///   (V10), and the sorted key index;
/// - `rev` (V12).
///
/// Deterministic: the same calls give the same bytes on any isolate of one
/// platform. No platform hash, draw, clock, map iteration or trigonometry.
///
/// `build` validates every site in debug builds (an `assert`), against the
/// [RoadGraph] given to the constructor when there is one (V1–V3 need it).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../hash32.dart';
import '../road_graph.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_plan_validator.dart';

typedef _L = SiteChunkLayout;

/// Builds [SiteAccessChunk]s. See the library comment.
class PlanBuilder {
  PlanBuilder({this.graph});

  /// The graph joins are resolved against: what `build` validates with.
  final RoadGraph? graph;

  final List<String> _ids = [];
  final List<int?> _revOverride = [];

  /// Chunk-level rows per column (numbers; packed at build).
  final List<List<num>> _cols =
      List.generate(SiteCol.count, (_) => <num>[], growable: false);

  /// Rows per count family per site, flattened `[site × countFamilies]`.
  final List<int> _counts = [];

  // ---- the site being described ------------------------------------------

  bool _open = false;
  final List<List<num>> _site =
      List.generate(SiteCol.count, (_) => <num>[], growable: false);
  final List<List<int>> _segVias = [];
  final List<List<int>> _paveRings = [];
  final List<List<int>> _paths = [];
  final List<int> _stallLattice = []; // row, bay per stall
  int? _siteRevOverride;
  double _uE = 1, _uN = 0;

  int get siteCount => _ids.length;

  /// Starts site [siteId] (the caller's own string instance is kept).
  void beginSite(
    String siteId, {
    required SiteProgram program,
    int flags = 0,
    int graphStamp = 0,
    int graphLot = -1,
    required double frameE,
    required double frameN,
    required double frameUE,
    required double frameUN,
    double envX0 = 0,
    double envX1 = 0,
    double envY0 = 0,
    double envY1 = 0,
    double envFrontInset = 0,
    double gateX = 0,
    double gateW = 0,
    double truckTurnRadiusM = 0,
  }) {
    if (_open) throw StateError('site ${_ids.last} was not ended');
    if (_ids.length >= kSitesPerChunk) {
      throw StateError('a chunk holds at most $kSitesPerChunk sites');
    }
    _open = true;
    _ids.add(siteId);
    for (final c in _site) {
      c.clear();
    }
    _segVias.clear();
    _paveRings.clear();
    _paths.clear();
    _stallLattice.clear();
    _lenGiven.clear();
    _siteRevOverride = null;
    _uE = frameUE;
    _uN = frameUN;
    _put(SiteCol.rev, 0);
    _put(SiteCol.flags, flags);
    _put(SiteCol.graphStamp, graphStamp);
    _put(SiteCol.graphLot, graphLot);
    _put(SiteCol.program, program.index);
    _put(SiteCol.frameE, frameE);
    _put(SiteCol.frameN, frameN);
    _put(SiteCol.frameUE, frameUE);
    _put(SiteCol.frameUN, frameUN);
    _put(SiteCol.envX0, envX0);
    _put(SiteCol.envX1, envX1);
    _put(SiteCol.envY0, envY0);
    _put(SiteCol.envY1, envY1);
    _put(SiteCol.envFrontInset, envFrontInset);
    _put(SiteCol.gateX, gateX);
    _put(SiteCol.gateW, gateW);
    _put(SiteCol.truckTurnRadiusM, truckTurnRadiusM);
    _put(SiteCol.entrancePt, -1);
    _put(SiteCol.pavementPt, -1);
    _put(SiteCol.entranceNode, -1);
  }

  void _put(int col, num v) => _site[col].add(v);
  int _rows(int col) => _site[col].length;

  void _need() {
    if (!_open) throw StateError('no site begun');
  }

  /// A point (colony-local east, north metres) and its height reference.
  int point(double e, double n,
      {SiteHeightRef ref = SiteHeightRef.pad,
      int hJoin = kPtNoJoin,
      double hT = 0,
      double dz = 0}) {
    _need();
    final i = _rows(SiteCol.ptE);
    _put(SiteCol.ptE, e);
    _put(SiteCol.ptN, n);
    _put(SiteCol.ptHRef, ref.index);
    _put(SiteCol.ptHJoin, hJoin);
    _put(SiteCol.ptHT, hT);
    _put(SiteCol.ptDz, dz);
    return i;
  }

  /// A join: its slot (0, 1, or 2 = side street), handle and piece at the
  /// graph it was resolved against, the copied slot values, and the plan's
  /// own role, kind, kerb node, throat and cut half. Join 0 is slot 0.
  int join({
    required int slot,
    required int ref,
    required int piece,
    required double roadS,
    required bool right,
    required int dirs,
    SiteJoinRole role = SiteJoinRole.both,
    SiteJoinKind kind = SiteJoinKind.cut,
    int roadNo = -1,
    int kerbNode = -1,
    int throatSeg = -1,
    double cutHalfM = 0,
  }) {
    _need();
    final i = _rows(SiteCol.joinSlot);
    _put(SiteCol.joinSlot, slot);
    _put(SiteCol.joinRight, right ? 1 : 0);
    _put(SiteCol.joinDirs, dirs);
    _put(SiteCol.joinRole, role.index);
    _put(SiteCol.joinKind, kind.index);
    _put(SiteCol.joinRef, ref);
    _put(SiteCol.joinPiece, piece);
    _put(SiteCol.joinRoadNo, roadNo);
    _put(SiteCol.joinRoadIdIdx, -1);
    _put(SiteCol.joinKerbNode, kerbNode);
    _put(SiteCol.joinThroatSeg, throatSeg);
    _put(SiteCol.joinRoadS, roadS);
    _put(SiteCol.joinCutHalfM, cutHalfM);
    return i;
  }

  /// Sets join [j]'s kerb node and throat, once they exist.
  void setJoinNetwork(int j, {required int kerbNode, required int throatSeg}) {
    _need();
    _site[SiteCol.joinKerbNode][j] = kerbNode;
    _site[SiteCol.joinThroatSeg][j] = throatSeg;
  }

  /// A node on point [pt] (`kNode*` flags, turnaround).
  int node(int pt,
      {int flags = 0,
      TurnaroundKind turn = TurnaroundKind.none,
      double turnR = 0,
      double turnHx = 0,
      double turnHn = 0}) {
    _need();
    final i = _rows(SiteCol.nodePt);
    _put(SiteCol.nodePt, pt);
    _put(SiteCol.nodeFlags, flags);
    _put(SiteCol.nodeTurnKind, turn.index);
    _put(SiteCol.nodeTurnR, turnR);
    _put(SiteCol.nodeTurnHx, turnHx);
    _put(SiteCol.nodeTurnHn, turnHn);
    return i;
  }

  /// A segment from node [from] to node [to] through the via points [vias]
  /// (plan-local points). `lenM` null: the polyline length.
  int segment(
    int from,
    int to, {
    List<int> vias = const [],
    required SiteSegmentKind kind,
    required SiteLaneMode mode,
    required double widthM,
    double? speedMps,
    double maxVehLenM = kSegMinVehLenM,
    int flags = 0,
    double? lenM,
  }) {
    _need();
    final i = _rows(SiteCol.segFrom);
    _put(SiteCol.segFrom, from);
    _put(SiteCol.segTo, to);
    _put(SiteCol.segLenM, lenM ?? double.nan); // resolved at endSite
    _put(SiteCol.segWidthM, widthM);
    _put(SiteCol.segSpeedMps,
        speedMps ??
            (kind == SiteSegmentKind.accessRoad
                ? kAccessRoadSpeedMps
                : kAisleSpeedMps));
    _put(SiteCol.segMaxVehLenM, maxVehLenM);
    _put(SiteCol.segKind, kind.index);
    _put(SiteCol.segLaneMode, mode.index);
    _put(SiteCol.segFlags, flags);
    _segVias.add(List.of(vias));
    _lenGiven.add(lenM != null);
    return i;
  }

  final List<bool> _lenGiven = [];

  /// A stall: its segment and mouth arc, side (0 right or on the axis, 1
  /// left), angle, direction bits, pose (centre and nose), size, and its
  /// generator-lattice [row] and [bay] (V10 keys). Returns its CALL index;
  /// stalls are reordered by `(seg, s, side)` at [endSite].
  int stall({
    required int seg,
    required double s,
    required int side,
    required StallAngle angle,
    required int inDirs,
    required int outDirs,
    required double e,
    required double n,
    required double dirE,
    required double dirN,
    double lenM = 5.2,
    double widthM = 2.6,
    required int row,
    required int bay,
  }) {
    _need();
    final i = _rows(SiteCol.stallSeg);
    _put(SiteCol.stallSeg, seg);
    _put(SiteCol.stallKey, 0);
    _put(SiteCol.stallKeySorted, 0);
    _put(SiteCol.stallKeyIdx, 0);
    _put(SiteCol.stallS, s);
    _put(SiteCol.stallDirE, dirE);
    _put(SiteCol.stallDirN, dirN);
    _put(SiteCol.stallLenM, lenM);
    _put(SiteCol.stallWidthM, widthM);
    _put(SiteCol.stallE, e);
    _put(SiteCol.stallN, n);
    _put(SiteCol.stallSide, side);
    _put(SiteCol.stallAngle, angle.index);
    _put(SiteCol.stallInDirs, inDirs);
    _put(SiteCol.stallOutDirs, outDirs);
    _stallLattice
      ..add(row)
      ..add(bay);
    return i;
  }

  /// A loading bay (reserved; yards and installations).
  int bay({
    required int seg,
    required double s,
    required int side,
    required double e,
    required double n,
    required double dirE,
    required double dirN,
    double lenM = 15,
    double widthM = 3.5,
    BayKind kind = BayKind.dock,
  }) {
    _need();
    final i = _rows(SiteCol.bayE);
    _put(SiteCol.bayE, e);
    _put(SiteCol.bayN, n);
    _put(SiteCol.bayDirE, dirE);
    _put(SiteCol.bayDirN, dirN);
    _put(SiteCol.bayLenM, lenM);
    _put(SiteCol.bayWidthM, widthM);
    _put(SiteCol.bayS, s);
    _put(SiteCol.baySeg, seg);
    _put(SiteCol.baySide, side);
    _put(SiteCol.bayKind, kind.index);
    return i;
  }

  /// A convex counter-clockwise pave ring over plan-local points [ring].
  int pave(List<int> ring,
      {PaveSurface surface = PaveSurface.asphalt, int paveClass = 0}) {
    _need();
    final i = _rows(SiteCol.paveSurface);
    _put(SiteCol.paveSurface, surface.index);
    _put(SiteCol.paveClass, paveClass);
    _paveRings.add(List.of(ring));
    return i;
  }

  /// A lamp post on point [pt].
  int lamp(int pt) {
    _need();
    final i = _rows(SiteCol.lampPt);
    _put(SiteCol.lampPt, pt);
    return i;
  }

  /// A footpath through plan-local points [pts].
  int path(List<int> pts) {
    _need();
    _paths.add(List.of(pts));
    return _paths.length - 1;
  }

  /// A fence gap on edge [edge] of the real parcel polygon, `t0..t1`.
  int fenceGap(int edge, double t0, double t1) {
    _need();
    final i = _rows(SiteCol.fenceGapEdge);
    _put(SiteCol.fenceGapEdge, edge);
    _put(SiteCol.fenceGapT0, t0);
    _put(SiteCol.fenceGapT1, t1);
    return i;
  }

  /// The door ([pt]) and, for a network plan, its entrance node.
  void entrance(int pt, {int node = -1}) {
    _need();
    _site[SiteCol.entrancePt][0] = pt;
    _site[SiteCol.entranceNode][0] = node;
  }

  /// The pavement point.
  void pavement(int pt) {
    _need();
    _site[SiteCol.pavementPt][0] = pt;
  }

  /// Tests only: publish [rev] instead of the computed revision (a broken
  /// fixture for V12).
  void debugOverrideRev(int rev) {
    _need();
    _siteRevOverride = rev;
  }

  /// Ends the site: segment lengths, stall order and keys, CSR columns.
  void endSite() {
    _need();
    _open = false;
    // Segment lengths.
    final nSeg = _rows(SiteCol.segFrom);
    for (var k = 0; k < nSeg; k++) {
      if (_lenGiven[k]) continue;
      _site[SiteCol.segLenM][k] = _polylineLength(k);
    }
    _lenGiven.clear();
    // CSR: vias, pave rings, paths.
    var v = 0;
    for (var k = 0; k < nSeg; k++) {
      _put(SiteCol.segViaStart, v);
      for (final p in _segVias[k]) {
        _put(SiteCol.viaPt, p);
        v++;
      }
    }
    _put(SiteCol.segViaStart, v);
    var q = 0;
    for (final ring in _paveRings) {
      _put(SiteCol.paveStart, q);
      for (final p in ring) {
        _put(SiteCol.pavePt, p);
        q++;
      }
    }
    _put(SiteCol.paveStart, q);
    q = 0;
    for (final pts in _paths) {
      _put(SiteCol.pathStart, q);
      for (final p in pts) {
        _put(SiteCol.pathPt, p);
        q++;
      }
    }
    _put(SiteCol.pathStart, q);
    _orderStalls();
    _keyStalls();
    // Append to the chunk.
    for (var col = 0; col < SiteCol.count; col++) {
      if (_L.familyOf(col) == _L.fStart) continue;
      _cols[col].addAll(_site[col]);
    }
    for (final f in _L.countFamilies) {
      _counts.add(_countOf(f));
    }
    _revOverride.add(_siteRevOverride);
  }

  int _countOf(int f) => switch (f) {
        _L.fPt => _rows(SiteCol.ptE),
        _L.fJoin => _rows(SiteCol.joinSlot),
        _L.fNode => _rows(SiteCol.nodePt),
        _L.fSeg => _rows(SiteCol.segFrom),
        _L.fVia => _rows(SiteCol.viaPt),
        _L.fStall => _rows(SiteCol.stallSeg),
        _L.fBay => _rows(SiteCol.bayE),
        _L.fPave => _rows(SiteCol.paveSurface),
        _L.fPavePt => _rows(SiteCol.pavePt),
        _L.fLamp => _rows(SiteCol.lampPt),
        _L.fPath => _paths.length,
        _L.fPathPt => _rows(SiteCol.pathPt),
        _L.fFenceGap => _rows(SiteCol.fenceGapEdge),
        _ => 0,
      };

  double _polylineLength(int k) {
    final pts = [
      _site[SiteCol.nodePt][_site[SiteCol.segFrom][k].toInt()].toInt(),
      ..._segVias[k],
      _site[SiteCol.nodePt][_site[SiteCol.segTo][k].toInt()].toInt(),
    ];
    var len = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final de = _site[SiteCol.ptE][pts[i]] - _site[SiteCol.ptE][pts[i - 1]];
      final dn = _site[SiteCol.ptN][pts[i]] - _site[SiteCol.ptN][pts[i - 1]];
      len += math.sqrt(de * de + dn * dn);
    }
    return len;
  }

  /// The stall columns of this site's stall family.
  static const List<int> _stallCols = [
    SiteCol.stallSeg, SiteCol.stallKey, SiteCol.stallKeySorted, //
    SiteCol.stallKeyIdx, SiteCol.stallS, SiteCol.stallDirE, SiteCol.stallDirN,
    SiteCol.stallLenM, SiteCol.stallWidthM, SiteCol.stallE, SiteCol.stallN,
    SiteCol.stallSide, SiteCol.stallAngle, SiteCol.stallInDirs,
    SiteCol.stallOutDirs,
  ];

  /// Reorders the stalls by `(seg, s, side)`, ties by call order.
  void _orderStalls() {
    final n = _rows(SiteCol.stallSeg);
    if (n < 2) return;
    final seg = _site[SiteCol.stallSeg];
    final s = _site[SiteCol.stallS];
    final side = _site[SiteCol.stallSide];
    final order = List<int>.generate(n, (i) => i);
    order.sort((a, b) {
      var c = seg[a].compareTo(seg[b]);
      if (c != 0) return c;
      // Compare as stored: Float32.
      c = _f32(s[a]).compareTo(_f32(s[b]));
      if (c != 0) return c;
      c = side[a].compareTo(side[b]);
      return c != 0 ? c : a.compareTo(b);
    });
    for (final col in _stallCols) {
      final src = List<num>.of(_site[col]);
      for (var i = 0; i < n; i++) {
        _site[col][i] = src[order[i]];
      }
    }
    final lat = List<int>.of(_stallLattice);
    for (var i = 0; i < n; i++) {
      _stallLattice[2 * i] = lat[2 * order[i]];
      _stallLattice[2 * i + 1] = lat[2 * order[i] + 1];
    }
  }

  static final Float32List _f32Scratch = Float32List(1);
  static double _f32(num x) {
    _f32Scratch[0] = x.toDouble();
    return _f32Scratch[0];
  }

  /// The heading octant (0 = +u, counter-clockwise in 45° steps) of a
  /// direction, relative to the frame's u, without trigonometry.
  static int headingOctant(double dirE, double dirN, double uE, double uN) {
    const t = 0.41421356; // tan 22.5°
    final x = dirE * uE + dirN * uN;
    final y = -dirE * uN + dirN * uE; // along v = u turned CCW
    final ax = x.abs(), ay = y.abs();
    if (ay <= t * ax) return x >= 0 ? 0 : 4;
    if (ax <= t * ay) return y >= 0 ? 2 : 6;
    if (x > 0) return y > 0 ? 1 : 7;
    return y > 0 ? 3 : 5;
  }

  /// The raw key of a lattice tuple (before collision resolution).
  static int latticeKey(int kindOrdinal, int row, int bay, int side, int octant) {
    var h = kFnvOffset32;
    h = fnv1aU32(h, kindOrdinal);
    h = fnv1aU32(h, row);
    h = fnv1aU32(h, bay);
    h = fnv1aU32(h, side);
    return fnv1aU32(h, octant);
  }

  void _keyStalls() {
    final n = _rows(SiteCol.stallSeg);
    if (n == 0) return;
    final tuples = List<List<int>>.generate(n, (i) {
      final seg = _site[SiteCol.stallSeg][i].toInt();
      final kind = seg >= 0 && seg < _rows(SiteCol.segKind)
          ? _site[SiteCol.segKind][seg].toInt()
          : 0;
      return [
        kind,
        _stallLattice[2 * i],
        _stallLattice[2 * i + 1],
        _site[SiteCol.stallSide][i].toInt(),
        headingOctant(_site[SiteCol.stallDirE][i].toDouble(),
            _site[SiteCol.stallDirN][i].toDouble(), _uE, _uN),
      ];
    });
    // Lattice-tuple order decides who keeps a colliding key.
    final byTuple = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        for (var k = 0; k < 5; k++) {
          final c = tuples[a][k].compareTo(tuples[b][k]);
          if (c != 0) return c;
        }
        return a.compareTo(b);
      });
    final keys = List<int>.filled(n, 0);
    final used = <int>[];
    for (final i in byTuple) {
      final t = tuples[i];
      var key = latticeKey(t[0], t[1], t[2], t[3], t[4]);
      while (used.contains(key)) {
        key = (key + 1).toUnsigned(32);
      }
      used.add(key);
      keys[i] = key.toSigned(32);
    }
    final sorted = List<int>.generate(n, (i) => i)
      ..sort((a, b) => keys[a].compareTo(keys[b]));
    for (var i = 0; i < n; i++) {
      _site[SiteCol.stallKey][i] = keys[i];
      _site[SiteCol.stallKeySorted][i] = keys[sorted[i]];
      _site[SiteCol.stallKeyIdx][i] = sorted[i];
    }
  }

  /// Packs every ended site into a chunk. With [validate] (the default), an
  /// `assert` checks V1–V13 (V1–V3 only when the builder has a [graph]).
  SiteAccessChunk build({bool validate = true}) {
    if (_open) throw StateError('site ${_ids.last} was not ended');
    final nS = _ids.length;
    final nF = _L.countFamilies.length;
    // Start columns.
    final starts = List<List<int>>.generate(nF, (_) => List.filled(nS + 1, 0));
    for (var f = 0; f < nF; f++) {
      var acc = 0;
      for (var k = 0; k < nS; k++) {
        starts[f][k] = acc;
        acc += _counts[k * nF + f];
      }
      starts[f][nS] = acc;
    }
    // Offsets, by backing type, in column order.
    final offsets = Int32List(SiteCol.count);
    final used = [0, 0, 0, 0];
    int rowsOf(int col) {
      final f = _L.familyOf(col);
      if (f == _L.fStart) return nS + 1;
      return _cols[col].length;
    }

    for (var col = 0; col < SiteCol.count; col++) {
      final t = _L.typeOf(col);
      offsets[col] = used[t];
      used[t] += rowsOf(col);
    }
    final f64 = Float64List(used[_L.tF64]);
    final f32 = Float32List(used[_L.tF32]);
    final i32 = Int32List(used[_L.tI32]);
    final u8 = Uint8List(used[_L.tU8]);
    for (var col = 0; col < SiteCol.count; col++) {
      final o = offsets[col];
      final f = _L.familyOf(col);
      final List<num> rows = f == _L.fStart
          ? starts[col - SiteCol.startBase]
          : _cols[col];
      switch (_L.typeOf(col)) {
        case _L.tF64:
          for (var r = 0; r < rows.length; r++) {
            f64[o + r] = rows[r].toDouble();
          }
        case _L.tF32:
          for (var r = 0; r < rows.length; r++) {
            f32[o + r] = rows[r].toDouble();
          }
        case _L.tI32:
          for (var r = 0; r < rows.length; r++) {
            i32[o + r] = rows[r].toInt();
          }
        default:
          for (var r = 0; r < rows.length; r++) {
            u8[o + r] = rows[r].toInt();
          }
      }
    }
    final chunk = SiteAccessChunk.packed(
      siteId: List.unmodifiable(_ids),
      f64: f64,
      f32: f32,
      i32: i32,
      u8: u8,
      offsets: offsets,
    );
    final revBase = offsets[SiteCol.rev];
    for (var k = 0; k < nS; k++) {
      i32[revBase + k] = _revOverride[k] ?? chunk.revisionOf(k);
    }
    if (validate) {
      assert(() {
        final bad = SitePlanValidator.validateChunk(chunk, graph: graph);
        if (bad.isNotEmpty) {
          throw StateError('PlanBuilder: invalid plans:\n${bad.join('\n')}');
        }
        return true;
      }());
    }
    return chunk;
  }
}
