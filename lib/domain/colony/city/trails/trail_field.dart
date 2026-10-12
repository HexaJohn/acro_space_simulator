// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The ground a colony's people cross where no road goes
/// (docs/plans/desire-paths.md §3, §7).
///
/// A coarse grid over the plat in colony-local metres. Each cell knows the
/// height of the natural ground, how WORN it is by the trips that have
/// crossed it, and whether it can be crossed at all: a building's footprint
/// cannot, except at its door. Wear is what a desire path is: a trip lays it
/// along its route, a worn cell is quicker to cross, so later trips bend
/// onto the same line, and an unused trail fades.
///
/// Pure data and arithmetic. The aggregate owns one (`CitySim.trails`),
/// keeps its footprints in step with the plat and samples its heights from
/// the body; the router (`trail_router.dart`) reads it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';

/// Metres across a cell: a rover's turning circle, and fine enough that a
/// trail drawn on the plat reads as a line rather than a staircase.
const double kTrailCellM = 10;

/// How far the field reaches past the plat, so a trail can swing wide of a
/// hill rather than be held to the lots' own bounding box.
const double kTrailMarginM = 400;

/// The most cells along either side. 4.8 km: past that a colony has roads.
const int kTrailMaxCells = 480;

/// Wear a finished leg lays on each cell it crossed, as a share of what is
/// left to wear: `w += kTrailWearPerLeg · (1 − w)`. One rover pass
/// compacts loose regolith into tracks the next driver follows, so a single
/// leg already counts; three make a trail half worn, ten a beaten track.
/// Big enough that the second trip finds the first one's tracks worth a
/// short detour, which is what pulls nearby routes onto one line.
const double kTrailWearPerLeg = 0.2;

/// Colony seconds for unused wear to halve: six hours, a few dozen commute
/// cycles (agent-traffic.md §6.5's 915 s) — a line people stop taking is
/// gone within a couple of days.
const double kTrailHalfLifeS = 6 * 3600;

/// Wear below this is bare ground again, and is not saved.
const double kTrailWearFloor = 0.01;

/// [TrailField.flags] bits.
const int kTrailBlocked = 1; // inside a building's footprint
const int kTrailRoad = 2; // under a road's carriageway
const int kTrailTube = 4; // under a pedestrian tube (desire-paths.md §9)

class TrailField {
  TrailField({
    required this.originE,
    required this.originN,
    required this.cols,
    required this.rows,
    this.cellM = kTrailCellM,
  })  : height = Float32List(cols * rows),
        wear = Float32List(cols * rows),
        footWear = Float32List(cols * rows),
        flags = Uint8List(cols * rows);

  /// The field that covers [box] with [kTrailMarginM] to spare, clamped to
  /// [kTrailMaxCells] a side about the box's centre.
  factory TrailField.covering(
      double minE, double minN, double maxE, double maxN) {
    int side(double lo, double hi) => math.min(
        kTrailMaxCells,
        math.max(1, ((hi - lo + 2 * kTrailMarginM) / kTrailCellM).ceil()));
    final cols = side(minE, maxE), rows = side(minN, maxN);
    // Snapped to the cell lattice, so a regrown field's cells sit exactly on
    // the old ones and its wear copies across without resampling.
    double snap(double v) => (v / kTrailCellM).floorToDouble() * kTrailCellM;
    final ce = (minE + maxE) / 2, cn = (minN + maxN) / 2;
    return TrailField(
      originE: snap(ce - cols * kTrailCellM / 2),
      originN: snap(cn - rows * kTrailCellM / 2),
      cols: cols,
      rows: rows,
    );
  }

  /// The south-west corner of cell 0, colony-local metres.
  final double originE, originN;
  final int cols, rows;
  final double cellM;

  /// Natural ground, metres above the body datum, per cell centre.
  final Float32List height;

  /// 0 bare ground … 1 a beaten track: the rovers'.
  final Float32List wear;

  /// The same for walkers (§9): a foot track, which on an airless world
  /// becomes a tube.
  final Float32List footWear;

  /// [kTrailBlocked], [kTrailRoad].
  final Uint8List flags;

  /// Moves whenever any wear does: a cached route compares against it.
  int wearRev = 0;

  /// Moves whenever the footprints or roads are laid again.
  int shapeRev = 0;

  /// Whether [height] has been sampled from the body.
  bool heightsReady = false;

  int get length => cols * rows;

  double get maxE => originE + cols * cellM;
  double get maxN => originN + rows * cellM;

  bool covers(double e, double n) =>
      e >= originE && n >= originN && e < maxE && n < maxN;

  /// The cell under (e, n), or −1 off the field.
  int cellAt(double e, double n) {
    final c = ((e - originE) / cellM).floor();
    final r = ((n - originN) / cellM).floor();
    if (c < 0 || r < 0 || c >= cols || r >= rows) return -1;
    return r * cols + c;
  }

  double centreE(int i) => originE + (i % cols + 0.5) * cellM;
  double centreN(int i) => originN + (i ~/ cols + 0.5) * cellM;
  Vec2 centreOf(int i) => Vec2(centreE(i), centreN(i));

  bool blocked(int i) => flags[i] & kTrailBlocked != 0;
  bool road(int i) => flags[i] & kTrailRoad != 0;
  bool tube(int i) => flags[i] & kTrailTube != 0;

  /// Whether [i] is a tube cell or beside one (eight neighbours).
  bool nearTube(int i) {
    final c = i % cols, r = i ~/ cols;
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        final cc = c + dc, rr = r + dr;
        if (cc < 0 || rr < 0 || cc >= cols || rr >= rows) continue;
        if (tube(rr * cols + cc)) return true;
      }
    }
    return false;
  }

  /// Samples the ground through [heightAt] on a lattice [stride] cells
  /// apart and fills the cells between bilinearly. A relief sample costs
  /// ~17 µs, so every cell of a starter field would be a second on the UI
  /// thread; one in sixteen is a tenth of that, and smooths away the
  /// single-cell noise a rover's wheels would ride over anyway.
  void fillHeights(double Function(double e, double n) heightAt,
      {int stride = 4}) {
    final lc = (cols - 1) ~/ stride + 2, lr = (rows - 1) ~/ stride + 2;
    final lattice = Float64List(lc * lr);
    for (var r = 0; r < lr; r++) {
      for (var c = 0; c < lc; c++) {
        final h = heightAt(originE + (c * stride + 0.5) * cellM,
            originN + (r * stride + 0.5) * cellM);
        lattice[r * lc + c] = h.isFinite ? h : 0;
      }
    }
    for (var r = 0; r < rows; r++) {
      final r0 = r ~/ stride, fr = (r % stride) / stride;
      for (var c = 0; c < cols; c++) {
        final c0 = c ~/ stride, fc = (c % stride) / stride;
        final a = lattice[r0 * lc + c0], b = lattice[r0 * lc + c0 + 1];
        final d = lattice[(r0 + 1) * lc + c0], e = lattice[(r0 + 1) * lc + c0 + 1];
        height[r * cols + c] =
            (a + (b - a) * fc) + ((d + (e - d) * fc) - (a + (b - a) * fc)) * fr;
      }
    }
    heightsReady = true;
  }

  /// Lays the footprints and roads again from scratch: [footprints] blocked
  /// (every cell whose centre lies inside one), their [doors] open again,
  /// and every cell within reach of a road sample marked road.
  void layShapes({
    required Iterable<List<Vec2>> footprints,
    required Iterable<Vec2> doors,
    required Iterable<(List<Vec2> samples, double halfWidthM)> roads,
    Iterable<List<Vec2>> tubes = const [],
  }) {
    for (var i = 0; i < length; i++) {
      flags[i] = 0;
    }
    for (final poly in footprints) {
      _fillPolygon(poly);
    }
    for (final d in doors) {
      final i = cellAt(d.e, d.n);
      if (i >= 0) flags[i] &= ~kTrailBlocked;
    }
    for (final (samples, hw) in roads) {
      final reach = hw + cellM * 0.5;
      for (final p in samples) {
        _stamp(p, reach, kTrailRoad);
      }
    }
    // A tube is a line of cells: stamped every few metres along it.
    for (final t in tubes) {
      for (var k = 1; k < t.length; k++) {
        final a = t[k - 1], b = t[k];
        final d = a.distanceTo(b);
        final n = math.max(1, (d / (cellM * 0.4)).ceil());
        for (var s = 0; s <= n; s++) {
          _stamp(Vec2(a.e + (b.e - a.e) * s / n, a.n + (b.n - a.n) * s / n),
              cellM * 0.5, kTrailTube);
        }
      }
    }
    shapeRev++;
  }

  void _stamp(Vec2 p, double reach, int bit) {
    final c0 = ((p.e - reach - originE) / cellM).floor();
    final c1 = ((p.e + reach - originE) / cellM).floor();
    final r0 = ((p.n - reach - originN) / cellM).floor();
    final r1 = ((p.n + reach - originN) / cellM).floor();
    for (var r = math.max(0, r0); r <= math.min(rows - 1, r1); r++) {
      for (var c = math.max(0, c0); c <= math.min(cols - 1, c1); c++) {
        final i = r * cols + c;
        final de = centreE(i) - p.e, dn = centreN(i) - p.n;
        if (de * de + dn * dn <= reach * reach) flags[i] |= bit;
      }
    }
  }

  /// Scanline fill of [poly]: a cell is inside when its centre is.
  void _fillPolygon(List<Vec2> poly) {
    if (poly.length < 3) return;
    var lo = double.infinity, hi = -double.infinity;
    for (final v in poly) {
      lo = math.min(lo, v.n);
      hi = math.max(hi, v.n);
    }
    final r0 = math.max(0, ((lo - originN) / cellM - 0.5).ceil());
    final r1 = math.min(rows - 1, ((hi - originN) / cellM - 0.5).floor());
    final xs = <double>[];
    for (var r = r0; r <= r1; r++) {
      final y = originN + (r + 0.5) * cellM;
      xs.clear();
      for (var k = 0; k < poly.length; k++) {
        final a = poly[k], b = poly[(k + 1) % poly.length];
        if ((a.n <= y) == (b.n <= y)) continue;
        xs.add(a.e + (y - a.n) / (b.n - a.n) * (b.e - a.e));
      }
      xs.sort();
      for (var k = 0; k + 1 < xs.length; k += 2) {
        final c0 = math.max(0, ((xs[k] - originE) / cellM - 0.5).ceil());
        final c1 =
            math.min(cols - 1, ((xs[k + 1] - originE) / cellM - 0.5).floor());
        for (var c = c0; c <= c1; c++) {
          flags[r * cols + c] |= kTrailBlocked;
        }
      }
    }
  }

  /// A finished leg's wear, laid on each of [cells] once.
  void lay(List<int> cells,
      {double amount = kTrailWearPerLeg, bool foot = false}) {
    final w = foot ? footWear : wear;
    for (final i in cells) {
      w[i] += amount * (1 - w[i]);
    }
    if (cells.isNotEmpty) wearRev++;
  }

  /// [dtS] colony seconds of fading.
  void decay(double dtS) {
    if (dtS <= 0) return;
    final k = math.pow(0.5, dtS / kTrailHalfLifeS).toDouble();
    // Fading is slow and even: a route cached against the last deposit is
    // still the right one, so decay alone does not move [wearRev].
    for (final w in [wear, footWear]) {
      for (var i = 0; i < length; i++) {
        final v = w[i];
        if (v == 0) continue;
        final next = v * k;
        w[i] = next < kTrailWearFloor ? 0 : next;
      }
    }
  }

  /// [other]'s wear copied onto the cells of this field they coincide with:
  /// a regrown field keeps the trails it had.
  void adoptWear(TrailField other) {
    for (var i = 0; i < other.length; i++) {
      final w = other.wear[i], fw = other.footWear[i];
      if (w == 0 && fw == 0) continue;
      final j = cellAt(other.centreE(i), other.centreN(i));
      if (j < 0) continue;
      wear[j] = w;
      footWear[j] = fw;
    }
    wearRev++;
  }

  /// The worn cells only, as `[e0, n0, cols, rows, i, w, i, w, …]` with wear
  /// rounded to 1/1000: a starter colony's trails are a few hundred cells.
  Map<String, dynamic> toJson() {
    List<num> sparse(Float32List w) {
      final out = <num>[];
      for (var i = 0; i < length; i++) {
        if (w[i] < kTrailWearFloor) continue;
        out
          ..add(i)
          ..add((w[i] * 1000).round());
      }
      return out;
    }

    final foot = sparse(footWear);
    return {
      'e0': originE,
      'n0': originN,
      'cols': cols,
      'rows': rows,
      'worn': sparse(wear),
      if (foot.isNotEmpty) 'foot': foot,
    };
  }

  static TrailField fromJson(Map<String, dynamic> j) {
    final f = TrailField(
      originE: (j['e0'] as num).toDouble(),
      originN: (j['n0'] as num).toDouble(),
      cols: (j['cols'] as num).toInt(),
      rows: (j['rows'] as num).toInt(),
    );
    void read(Object? list, Float32List into) {
      final l = list is List ? list : const [];
      for (var k = 0; k + 1 < l.length; k += 2) {
        final i = (l[k] as num).toInt();
        if (i >= 0 && i < f.length) into[i] = (l[k + 1] as num) / 1000;
      }
    }

    read(j['worn'], f.wear);
    read(j['foot'], f.footWear);
    return f;
  }
}
