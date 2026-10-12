// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The factory floor's lattice (docs/plans/factory-floors.md §3).
///
/// A floor is a hall of square tiles at REAL scale: [kFactoryTileM] metres a
/// side, so a person fills a tile, a pallet sits on one and a forklift aisle
/// is two. Tile (0, 0) is the hall's corner at the site frame's lowest x and
/// y (x along the frontage, y into the lot — `site_access/site_frame.dart`),
/// and +y runs away from the yard. Pure integer arithmetic: no trigonometry,
/// no platform hash, so a floor steps identically on every machine.
library;

/// Metres across one floor tile.
const double kFactoryTileM = 2.0;

/// The four tile directions. [east] is +x, [north] is +y.
enum Dir4 {
  east(1, 0),
  north(0, 1),
  west(-1, 0),
  south(0, -1);

  const Dir4(this.dx, this.dy);
  final int dx, dy;

  Dir4 get turnCw => Dir4.values[(index + 3) % 4];
  Dir4 get turnCcw => Dir4.values[(index + 1) % 4];
  Dir4 get opposite => Dir4.values[(index + 2) % 4];

  /// True for [north] and [south]: a footprint laid this way swaps w and h.
  bool get isVertical => dy != 0;
}

/// One tile's address.
class TilePos {
  const TilePos(this.x, this.y);
  final int x, y;

  TilePos step(Dir4 d, [int n = 1]) => TilePos(x + d.dx * n, y + d.dy * n);
  TilePos operator +(TilePos o) => TilePos(x + o.x, y + o.y);

  /// Manhattan distance in tiles.
  int manhattan(TilePos o) => (x - o.x).abs() + (y - o.y).abs();

  /// Packed key for maps (halls are far below 65,536 tiles a side).
  int get key => (y << 16) | x;
  static TilePos fromKey(int k) => TilePos(k & 0xFFFF, k >> 16);

  @override
  bool operator ==(Object other) =>
      other is TilePos && other.x == x && other.y == y;
  @override
  int get hashCode => key;
  @override
  String toString() => '($x, $y)';

  List<int> toJson() => [x, y];
  static TilePos fromJson(Object? j) {
    final l = j as List;
    return TilePos((l[0] as num).toInt(), (l[1] as num).toInt());
  }
}

/// An axis-aligned run of tiles: `[x0, x0 + w) × [y0, y0 + h)`.
class TileRect {
  const TileRect(this.x0, this.y0, this.w, this.h);
  final int x0, y0, w, h;

  int get x1 => x0 + w;
  int get y1 => y0 + h;
  int get area => w * h;

  bool contains(TilePos p) => p.x >= x0 && p.x < x1 && p.y >= y0 && p.y < y1;
  bool containsRect(TileRect r) =>
      r.x0 >= x0 && r.y0 >= y0 && r.x1 <= x1 && r.y1 <= y1;
  bool overlaps(TileRect r) =>
      r.x0 < x1 && x0 < r.x1 && r.y0 < y1 && y0 < r.y1;

  /// Row-major, so any walk over it is deterministic.
  Iterable<TilePos> get tiles sync* {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        yield TilePos(x, y);
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is TileRect &&
      other.x0 == x0 &&
      other.y0 == y0 &&
      other.w == w &&
      other.h == h;
  @override
  int get hashCode => Object.hash(x0, y0, w, h);
  @override
  String toString() => 'TileRect($x0, $y0, ${w}x$h)';
}

/// A hall's size in tiles. The hall IS the building: build cost scales with
/// [areaM2] (§3), so a compact layout pays.
class HallSize {
  const HallSize(this.w, this.h);

  /// The largest hall that fits [widthM] × [depthM] of site.
  factory HallSize.fitting(double widthM, double depthM) => HallSize(
      (widthM / kFactoryTileM).floor().clamp(0, 0xFFFF),
      (depthM / kFactoryTileM).floor().clamp(0, 0xFFFF));

  final int w, h;

  double get widthM => w * kFactoryTileM;
  double get depthM => h * kFactoryTileM;
  double get areaM2 => widthM * depthM;
  TileRect get rect => TileRect(0, 0, w, h);
  bool contains(TilePos p) => rect.contains(p);

  @override
  bool operator ==(Object other) =>
      other is HallSize && other.w == w && other.h == h;
  @override
  int get hashCode => Object.hash(w, h);
  @override
  String toString() => 'HallSize(${w}x$h)';

  List<int> toJson() => [w, h];
  static HallSize fromJson(Object? j) {
    final l = j as List;
    return HallSize((l[0] as num).toInt(), (l[1] as num).toInt());
  }
}
