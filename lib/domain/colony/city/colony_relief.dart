// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The lie of the land under a colony, as a map draws it: a lattice of
/// natural ground heights and the contour lines through it.
///
/// A relief sample costs ~17 µs, so the lattice fills a budget at a time
/// ([ReliefGrid.fill]) and a map can sample a few hundred points a frame
/// rather than stall for a third of a second. Contours are marching squares
/// over the finished lattice, in colony-local metres.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class ReliefGrid {
  ReliefGrid({
    required this.originE,
    required this.originN,
    required this.cols,
    required this.rows,
    required this.stepM,
  }) : height = Float32List(cols * rows);

  /// The lattice over a square [halfM] each way of (e, n), [stepM] apart.
  factory ReliefGrid.around(double e, double n,
      {required double halfM, double stepM = 40}) {
    final cells = (2 * halfM / stepM).ceil() + 1;
    return ReliefGrid(
      originE: e - halfM,
      originN: n - halfM,
      cols: cells,
      rows: cells,
      stepM: stepM,
    );
  }

  /// Lattice point (0, 0), colony-local metres.
  final double originE, originN;
  final int cols, rows;
  final double stepM;

  /// Metres above the body datum, row-major from the south-west corner.
  final Float32List height;

  int _next = 0;
  double _lo = double.infinity, _hi = -double.infinity;

  bool get complete => _next >= height.length;
  double get lowest => _lo;
  double get highest => _hi;

  /// Samples up to [budget] more lattice points through [heightAt]; true
  /// once every point has been.
  bool fill(double Function(double e, double n) heightAt, int budget) {
    final end = math.min(height.length, _next + budget);
    for (var i = _next; i < end; i++) {
      var h = heightAt(originE + (i % cols) * stepM, originN + (i ~/ cols) * stepM);
      if (!h.isFinite) h = 0;
      height[i] = h;
      if (h < _lo) _lo = h;
      if (h > _hi) _hi = h;
    }
    _next = end;
    return complete;
  }
}

/// A contour interval for relief [rangeM] high: a round number giving some
/// ten to twenty-five lines across it.
double contourInterval(double rangeM) {
  const nice = [1.0, 2.0, 5.0, 10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 500.0];
  for (final s in nice) {
    if (rangeM / s <= 25) return s;
  }
  return 1000;
}

/// One contour level: its height, whether it is an index contour (every
/// fifth), and its line as flat segments `[e0, n0, e1, n1, …]`.
class Contour {
  const Contour(this.level, this.major, this.segments);
  final double level;
  final bool major;
  final Float64List segments;
}

/// The contours through [g] every [interval] metres (by [contourInterval]
/// of its range when null). Empty until the grid is complete, or when the
/// ground is flat.
List<Contour> contoursOf(ReliefGrid g, {double? interval}) {
  if (!g.complete || !(g.highest > g.lowest)) return const [];
  final step = interval ?? contourInterval(g.highest - g.lowest);
  final out = <Contour>[];
  final first = (g.lowest / step).ceil();
  final last = (g.highest / step).floor();
  final cols = g.cols, h = g.height, s = g.stepM;
  for (var k = first; k <= last; k++) {
    final level = k * step;
    final segs = <double>[];
    for (var r = 0; r + 1 < g.rows; r++) {
      for (var c = 0; c + 1 < cols; c++) {
        final a = h[r * cols + c], b = h[r * cols + c + 1];
        final d = h[(r + 1) * cols + c], e = h[(r + 1) * cols + c + 1];
        var idx = 0;
        if (a >= level) idx |= 1;
        if (b >= level) idx |= 2;
        if (e >= level) idx |= 4;
        if (d >= level) idx |= 8;
        if (idx == 0 || idx == 15) continue;
        final x0 = g.originE + c * s, y0 = g.originN + r * s;
        // Where the level crosses each edge: bottom (a–b), right (b–e),
        // top (d–e), left (a–d).
        double t(double p, double q) => (level - p) / (q - p);
        List<double> bottom() => [x0 + t(a, b) * s, y0];
        List<double> right() => [x0 + s, y0 + t(b, e) * s];
        List<double> top() => [x0 + t(d, e) * s, y0 + s];
        List<double> left() => [x0, y0 + t(a, d) * s];
        void seg(List<double> p, List<double> q) => segs
          ..add(p[0])
          ..add(p[1])
          ..add(q[0])
          ..add(q[1]);
        switch (idx) {
          case 1 || 14:
            seg(left(), bottom());
          case 2 || 13:
            seg(bottom(), right());
          case 3 || 12:
            seg(left(), right());
          case 4 || 11:
            seg(right(), top());
          case 6 || 9:
            seg(bottom(), top());
          case 7 || 8:
            seg(left(), top());
          case 5 || 10:
            // A saddle: which pair joins is the centre's call.
            final centre = (a + b + d + e) / 4;
            if ((centre >= level) == (idx == 5)) {
              seg(left(), top());
              seg(bottom(), right());
            } else {
              seg(left(), bottom());
              seg(right(), top());
            }
        }
      }
    }
    if (segs.isNotEmpty) {
      out.add(Contour(level, k % 5 == 0, Float64List.fromList(segs)));
    }
  }
  return out;
}
