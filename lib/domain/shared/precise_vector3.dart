import 'vector3.dart';

/// World position at 1:1 scale (meters) without catastrophic floating point
/// cancellation.
///
/// THE PRECISION PROBLEM
/// ---------------------
/// A `double` has ~15-16 significant decimal digits. At solar-system distances
/// (1 AU ~ 1.5e11 m) the unit-in-the-last-place is tens of microns, and
/// computing a ship's centimetre-scale motion as the *difference* of two huge
/// numbers loses almost all precision -> visible jitter.
///
/// THE SOLUTION — a granularity lattice
/// ------------------------------------
/// A position is split into:
///   * [cell]   : integer lattice coordinate (the "high" part), each axis an
///                `int` (Dart int is 64-bit on native), and
///   * [local]  : a small `double` offset inside the cell (the "low" part).
///
/// [granularity] is the exponent `g` such that one cell edge is `10^g` metres.
/// Compose granularities (10^2, 10^3, ... 10^6 ...) by re-basing — see
/// [rebase]. Physics and rendering happen in a *local* frame near the focus,
/// where magnitudes are small and `double` is exact enough; absolute storage
/// stays in this lattice. This is the "extra dimension for granularity".
class PreciseVector3 {
  /// Integer lattice cell. World metres for this part = cell * 10^granularity.
  final int cellX;
  final int cellY;
  final int cellZ;

  /// Sub-cell offset in metres. Kept within [-cellSize, cellSize) by [normalized].
  final Vector3 local;

  /// log10 of the cell edge length in metres. e.g. 3 => 1 km cells.
  final int granularity;

  const PreciseVector3({
    required this.cellX,
    required this.cellY,
    required this.cellZ,
    required this.local,
    required this.granularity,
  });

  /// Edge length of one cell, in metres.
  double get cellSize => _pow10(granularity);

  static PreciseVector3 origin({int granularity = 3}) => PreciseVector3(
        cellX: 0,
        cellY: 0,
        cellZ: 0,
        local: Vector3.zero,
        granularity: granularity,
      );

  /// Build from absolute metres. Beware: [meters] itself is a lossy `double`
  /// for very large worlds — prefer constructing from cell + local directly,
  /// or from a body-local frame. Adequate for seeding small/medium systems.
  factory PreciseVector3.fromMeters(Vector3 meters, {int granularity = 3}) {
    final s = _pow10(granularity);
    final cx = (meters.x / s).floor();
    final cy = (meters.y / s).floor();
    final cz = (meters.z / s).floor();
    return PreciseVector3(
      cellX: cx,
      cellY: cy,
      cellZ: cz,
      local: Vector3(meters.x - cx * s, meters.y - cy * s, meters.z - cz * s),
      granularity: granularity,
    );
  }

  /// Carry any [local] overflow into [cell] so [local] stays inside one cell.
  PreciseVector3 get normalized {
    final s = cellSize;
    final dx = (local.x / s).floor();
    final dy = (local.y / s).floor();
    final dz = (local.z / s).floor();
    if (dx == 0 && dy == 0 && dz == 0) return this;
    return PreciseVector3(
      cellX: cellX + dx,
      cellY: cellY + dy,
      cellZ: cellZ + dz,
      local: Vector3(local.x - dx * s, local.y - dy * s, local.z - dz * s),
      granularity: granularity,
    );
  }

  /// Re-express at a different [granularity] without changing the world point
  /// (subject to `double` limits of the coarser local offset). Lets callers
  /// compose 10^2 / 10^3 / 10^6 lattices as requested.
  PreciseVector3 rebase(int newGranularity) {
    if (newGranularity == granularity) return this;
    final s = cellSize;
    // Total offset from origin, in the *new* cell's units, kept split so the
    // large integer part never enters a double.
    // worldMeters = cell * s + local ; newCell = floor(worldMeters / ns).
    // Decompose cell*s into newCell-units integer-exactly when newGranularity
    // <= granularity (coarse->fine), else best-effort.
    if (newGranularity < granularity) {
      final factor = _intPow10(granularity - newGranularity);
      return PreciseVector3(
        cellX: cellX * factor,
        cellY: cellY * factor,
        cellZ: cellZ * factor,
        local: local,
        granularity: newGranularity,
      ).normalized;
    } else {
      final factor = _intPow10(newGranularity - granularity);
      // cell / factor with remainder folded into local.
      final qx = _floorDiv(cellX, factor), rx = cellX - qx * factor;
      final qy = _floorDiv(cellY, factor), ry = cellY - qy * factor;
      final qz = _floorDiv(cellZ, factor), rz = cellZ - qz * factor;
      return PreciseVector3(
        cellX: qx,
        cellY: qy,
        cellZ: qz,
        local: local + Vector3(rx * s, ry * s, rz * s),
        granularity: newGranularity,
      ).normalized;
    }
  }

  PreciseVector3 operator +(Vector3 deltaMeters) => PreciseVector3(
        cellX: cellX,
        cellY: cellY,
        cellZ: cellZ,
        local: local + deltaMeters,
        granularity: granularity,
      ).normalized;

  PreciseVector3 operator -(Vector3 deltaMeters) => this + (-deltaMeters);

  /// Displacement to [other], in metres, as a plain [Vector3].
  ///
  /// SAFE near the same region (the integer cell parts cancel as integers
  /// before touching a double), which is exactly the floating-origin trick.
  Vector3 vectorTo(PreciseVector3 other) {
    final o = other.granularity == granularity ? other : other.rebase(granularity);
    final s = cellSize;
    final dCellX = (o.cellX - cellX).toDouble();
    final dCellY = (o.cellY - cellY).toDouble();
    final dCellZ = (o.cellZ - cellZ).toDouble();
    return Vector3(
      dCellX * s + (o.local.x - local.x),
      dCellY * s + (o.local.y - local.y),
      dCellZ * s + (o.local.z - local.z),
    );
  }

  /// Position relative to a floating [origin], in metres — feed this to physics
  /// and to the painter so they only ever see small numbers.
  Vector3 toLocalFrame(PreciseVector3 origin) => origin.vectorTo(this);

  static double _pow10(int e) {
    var r = 1.0;
    final n = e.abs();
    for (var i = 0; i < n; i++) {
      r *= 10.0;
    }
    return e < 0 ? 1.0 / r : r;
  }

  static int _intPow10(int e) {
    var r = 1;
    for (var i = 0; i < e; i++) {
      r *= 10;
    }
    return r;
  }

  static int _floorDiv(int a, int b) {
    final q = a ~/ b;
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
  }

  @override
  String toString() =>
      'PreciseVector3(cell:($cellX,$cellY,$cellZ) g:$granularity local:$local)';
}
