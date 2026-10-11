// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The battle's ground, frozen (docs/plans/combat.md §7G; ref §8.3): an 8 m
/// raster of body-fixed ground radii over a 1.2 km square, baked once off
/// the main thread, then read bilinearly. Nothing that fights samples the
/// terrain field: a field sample is ~0.4 ms in a graded town (Spike S item
/// 1), and the frame has no room for one.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// The square's side and cell, m.
const double kRasterSideM = 1200;
const double kRasterCellM = 8;

/// The LZ's turret ring and a socket's half-width: what must fit inside.
const double kRasterLzMarginM = 87;

class BattleRaster {
  BattleRaster(this.centreE, this.centreN, {this.sideM = kRasterSideM, this.cellM = kRasterCellM})
      : n = (sideM / cellM).round(),
        radii = Float64List((sideM / cellM).round() * (sideM / cellM).round())
          ..fillRange(0, (sideM / cellM).round() * (sideM / cellM).round(), double.nan);

  /// The square's centre, colony-local east/north m.
  final double centreE, centreN;
  final double sideM, cellM;

  /// Cells a side.
  final int n;

  /// Ground radius per cell, row-major (east index fastest); NaN until baked.
  final Float64List radii;
  int filled = 0;

  bool get complete => filled == radii.length;
  double get progress => filled / radii.length;

  double get west => centreE - sideM / 2;
  double get south => centreN - sideM / 2;

  /// Cell [k]'s centre, colony-local.
  (double, double) cellCentre(int k) => (west + (k % n + 0.5) * cellM, south + (k ~/ n + 0.5) * cellM);

  bool contains(double e, double n_) =>
      e >= west && e <= west + sideM && n_ >= south && n_ <= south + sideM;

  void put(int k, double r) {
    if (radii[k].isNaN) filled++;
    radii[k] = r;
  }

  /// Every cell, the ones nearest [first] (the LZ, the objectives) first,
  /// then the rest in index order: cells within 120 m of a listed point lead.
  List<int> bakeOrder(List<(double, double)> first) {
    final near = <int>[], rest = <int>[];
    for (var k = 0; k < radii.length; k++) {
      final (e, nn) = cellCentre(k);
      final close = first.any((p) {
        final de = p.$1 - e, dn = p.$2 - nn;
        return de * de + dn * dn < 120 * 120;
      });
      (close ? near : rest).add(k);
    }
    return [...near, ...rest];
  }

  /// The ground radius at ([e], [n_]), bilinear between cell centres; null
  /// outside the square or where a needed cell is not baked yet.
  double? radiusAt(double e, double n_) {
    if (!contains(e, n_)) return null;
    final x = ((e - west) / cellM - 0.5).clamp(0.0, n - 1.0);
    final y = ((n_ - south) / cellM - 0.5).clamp(0.0, n - 1.0);
    final i = math.min(x.floor(), n - 2), j = math.min(y.floor(), n - 2);
    final fx = x - i, fy = y - j;
    final a = radii[j * n + i], b = radii[j * n + i + 1];
    final c = radii[(j + 1) * n + i], d = radii[(j + 1) * n + i + 1];
    if (a.isNaN || b.isNaN || c.isNaN || d.isNaN) return null;
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy;
  }

  /// Where the square goes: centred between the LZ and the goal, then pulled
  /// toward the LZ until its whole turret ring is inside.
  static (double, double) centreFor(double lzE, double lzN, double goalE, double goalN,
      {double sideM = kRasterSideM}) {
    var ce = (lzE + goalE) / 2, cn = (lzN + goalN) / 2;
    final room = sideM / 2 - kRasterLzMarginM;
    ce = ce.clamp(lzE - room, lzE + room);
    cn = cn.clamp(lzN - room, lzN + room);
    return (ce, cn);
  }
}
