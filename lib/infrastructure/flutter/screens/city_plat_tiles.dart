// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The plat's spatial bucketing, and its triangle batches — pure, so the
/// view's culling can be pinned without a canvas.
///
/// The first plat drew the whole colony as a handful of colony-wide paths:
/// every lot outline of a use in one path, every street of a class in
/// another. A path is one draw, but the renderer tessellates ALL of it
/// every frame whatever the clip, so at street scale a 127k-building
/// colony cost the raster thread 206 ms a frame for the nine percent of
/// it that was on screen. Bucketed by cell, a frame draws the cells the
/// viewport overlaps and nothing else; and lot fills go as retained
/// triangle batches (one vertex buffer per cell, a colour per vertex)
/// instead of polygons the renderer has to tessellate again each frame.
library;

import 'dart:typed_data';

import '../../../domain/colony/city/parcel.dart' show Vec2;

/// A square grid over the plat's drawing plane (east, y = -north), keyed
/// by cell.
class PlatGrid {
  const PlatGrid(this.cellM);

  /// The cell side, metres.
  final double cellM;

  /// Cells are keyed by two 16-bit offset indices in one int: enough for
  /// ±32k cells a side (16,000 km at 500 m), and a cheap map key.
  static const int _half = 1 << 15;

  int indexOf(double v) => (v / cellM).floor();

  static int key(int ie, int iy) => ((ie + _half) << 16) | (iy + _half);

  int keyOf(double e, double y) => key(indexOf(e), indexOf(y));

  /// Every cell key a box overlaps, plus [margin] cells around it: a lot
  /// is bucketed by its centre and may straddle a cell edge, so the ring
  /// beyond the viewport is drawn too.
  List<int> keysIn(double minE, double minY, double maxE, double maxY,
      {int margin = 0}) {
    final ie0 = indexOf(minE) - margin, ie1 = indexOf(maxE) + margin;
    final iy0 = indexOf(minY) - margin, iy1 = indexOf(maxY) + margin;
    final out = <int>[];
    for (var ie = ie0; ie <= ie1; ie++) {
      for (var iy = iy0; iy <= iy1; iy++) {
        out.add(key(ie, iy));
      }
    }
    return out;
  }

  /// A polyline cut into runs per cell, in the drawing plane. Each run
  /// holds the points inside one cell; a segment that crosses a cell edge
  /// goes to both cells, so neither shows a gap at the edge. Points are
  /// (e, y) with y already negated north.
  List<(int key, List<Vec2> pts)> splitPolyline(List<Vec2> pts) {
    final runs = <(int, List<Vec2>)>[];
    if (pts.isEmpty) return runs;
    var current = keyOf(pts[0].e, pts[0].n);
    var run = <Vec2>[pts[0]];
    for (var i = 1; i < pts.length; i++) {
      final k = keyOf(pts[i].e, pts[i].n);
      if (k == current) {
        run.add(pts[i]);
        continue;
      }
      run.add(pts[i]);
      runs.add((current, run));
      run = [pts[i - 1], pts[i]];
      current = k;
    }
    runs.add((current, run));
    return runs;
  }
}

/// A growable triangle list with a colour per vertex, for
/// `Canvas.drawVertices`: positions as (x, y) pairs, colours as ARGB.
class PlatTriangles {
  Float32List _pos = Float32List(6 * 64);
  Int32List _col = Int32List(3 * 64);
  int _verts = 0;

  int get vertexCount => _verts;
  bool get isEmpty => _verts == 0;

  Float32List get positions => Float32List.sublistView(_pos, 0, _verts * 2);
  Int32List get colors => Int32List.sublistView(_col, 0, _verts);

  void _grow(int more) {
    final need = _verts + more;
    if (need * 2 <= _pos.length) return;
    var cap = _pos.length ~/ 2;
    while (cap < need) {
      cap *= 2;
    }
    _pos = Float32List(cap * 2)..setRange(0, _verts * 2, _pos);
    _col = Int32List(cap)..setRange(0, _verts, _col);
  }

  void _vertex(double x, double y, int color) {
    _pos[_verts * 2] = x;
    _pos[_verts * 2 + 1] = y;
    _col[_verts] = color;
    _verts++;
  }

  /// A polygon as a fan from its first vertex — right for the convex
  /// quads the subdivider cuts, which is every lot that is not
  /// hand-drawn (those go as paths). Points are (e, n); y is negated.
  void addFan(List<Vec2> poly, int color) {
    if (poly.length < 3) return;
    _grow((poly.length - 2) * 3);
    for (var i = 1; i + 1 < poly.length; i++) {
      _vertex(poly[0].e, -poly[0].n, color);
      _vertex(poly[i].e, -poly[i].n, color);
      _vertex(poly[i + 1].e, -poly[i + 1].n, color);
    }
  }

  /// An axis-aligned box in the drawing plane (y already negated).
  void addRect(
      double left, double top, double right, double bottom, int color) {
    _grow(6);
    _vertex(left, top, color);
    _vertex(right, top, color);
    _vertex(right, bottom, color);
    _vertex(left, top, color);
    _vertex(right, bottom, color);
    _vertex(left, bottom, color);
  }
}
