// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The ground under a colony, cheap enough to ask on every mouse move.
///
/// The road tool needs the ground under the road being drawn — where each
/// end stands (the tool's elevation is measured from it), and along the
/// route (which stretch is a bridge, which a tunnel, how steep it is). A
/// query of the edited terrain field composes every brush a graded town has
/// laid, 8 to 16 ms a sample, and a preview that asked one per few metres
/// of route on every mouse move stalled the editor for seconds. This holds
/// the answers on a coarse raster of the colony's ground, filled lazily
/// from the field under a per-frame budget and read bilinearly, so a hover
/// costs arithmetic once the cells around the cursor are warm. A new field
/// (a brush landed) drops the raster.
///
/// Pure: it is handed the field's queries as functions, so it knows no
/// terrain type and tests can hand it any ground they like.
library;

import '../../shared/vector3.dart';
import 'parcel.dart';

class ColonyGroundSampler {
  ColonyGroundSampler({
    required this.toDirection,
    required this.bodyRadiusM,
    this.cellM = 8,
    this.fillBudget = 48,
  });

  /// Colony-local point to a body-fixed direction from the body centre
  /// (need not be unit: the queries normalise).
  final Vector3 Function(Vec2) toDirection;

  /// The body datum heights are measured above.
  final double bodyRadiusM;

  /// Raster spacing. Coarse on purpose: the ground a road's grade and its
  /// bridges are judged by does not change inside eight metres, and a
  /// finer raster is more cells to fill per metre of cursor travel.
  final double cellM;

  /// Most cells filled from the field per frame (see [beginFrame]); a
  /// corner past the budget reads the pristine ground instead, uncached.
  final int fillBudget;

  double Function(double, double, double)? _surface;
  double Function(double, double, double)? _base;
  Object? _key;
  final Map<int, double> _cells = {};
  int _fills = 0;

  /// Cells filled since the last [bind], for tests and the perf panel.
  int get cachedCells => _cells.length;

  /// Point the sampler at a field: [surfaceRadiusAt] (the edited ground's
  /// radius along a direction) and optionally [baseRadiusAt] (the pristine
  /// ground's — one heightfield evaluation, used when the budget is spent).
  /// A different [key] — pass the edits version — drops every cell.
  void bind(
    Object key, {
    required double Function(double, double, double) surfaceRadiusAt,
    double Function(double, double, double)? baseRadiusAt,
  }) {
    if (key == _key) return;
    _key = key;
    _surface = surfaceRadiusAt;
    _base = baseRadiusAt;
    _cells.clear();
  }

  bool get bound => _surface != null;

  /// Start a frame's fill budget. Call once per frame (or per mouse move).
  void beginFrame() => _fills = 0;

  /// The edited ground's height above the datum under [p], exactly: one
  /// field query. For a commit, not a hover.
  double exactHeightAt(Vec2 p) {
    final s = _surface;
    if (s == null) return 0;
    final d = toDirection(p);
    return s(d.x, d.y, d.z) - bodyRadiusM;
  }

  /// The ground's height above the datum under [p], bilinear over the
  /// raster — exact on a plane, within the raster's reach of the relief
  /// elsewhere. Zero before [bind].
  double heightAt(Vec2 p) {
    if (_surface == null) return 0;
    final fx = p.e / cellM, fy = p.n / cellM;
    final ix = fx.floor(), iy = fy.floor();
    final tx = fx - ix, ty = fy - iy;
    final h00 = _corner(ix, iy), h10 = _corner(ix + 1, iy);
    final h01 = _corner(ix, iy + 1), h11 = _corner(ix + 1, iy + 1);
    final a = h00 + (h10 - h00) * tx;
    final b = h01 + (h11 - h01) * tx;
    return a + (b - a) * ty;
  }

  /// Heights at each of [pts] — what a route preview asks.
  List<double> profile(List<Vec2> pts) => [for (final p in pts) heightAt(p)];

  /// Drop every cell (a brush landed somewhere the key did not see).
  void invalidate() => _cells.clear();

  /// Whether [p]'s four raster corners are all cached.
  bool warmAt(Vec2 p) {
    final ix = (p.e / cellM).floor(), iy = (p.n / cellM).floor();
    for (final (x, y) in [
      (ix, iy),
      (ix + 1, iy),
      (ix, iy + 1),
      (ix + 1, iy + 1)
    ]) {
      if (!_cells.containsKey(_keyOf(x, y))) return false;
    }
    return true;
  }

  double _corner(int ix, int iy) {
    final key = _keyOf(ix, iy);
    final hit = _cells[key];
    if (hit != null) return hit;
    final d = toDirection(Vec2(ix * cellM, iy * cellM));
    final base = _base;
    if (_fills >= fillBudget && base != null) {
      // Past the budget: the pristine ground, not remembered, so the cell
      // is filled properly on a later frame.
      return base(d.x, d.y, d.z) - bodyRadiusM;
    }
    _fills++;
    final h = _surface!(d.x, d.y, d.z) - bodyRadiusM;
    _cells[key] = h;
    return h;
  }

  static const int _half = 1 << 20;
  static int _keyOf(int ix, int iy) =>
      (ix + _half) * (1 << 21) + (iy + _half).clamp(0, (1 << 21) - 1);
}
