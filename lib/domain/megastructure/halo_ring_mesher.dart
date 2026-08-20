// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Voxel meshing for the halo ring's inner terrain surface.
///
/// The planetary pipeline chunks on a cubed sphere and meshes thin RADIAL
/// shells — both assume a filled ball. A ring band unrolls to a long strip
/// instead, so its chunks are a plain 2D grid: [RingCellKey] indexes cells
/// along the circumference (i) and across the band (j).
///
/// Each cell is meshed with the SAME primitives as planets — `DensityGrid` +
/// `surfaceNets` — but in a cell-LOCAL frame so the lattice hugs the curved
/// floor at constant quality anywhere on the ring:
///
///   local +X = tangent (direction of increasing phi)
///   local +Y = -ring Z (across the band)
///   local +Z = radially INWARD (toward the axis — "up" under spin gravity)
///
/// The mesh comes out in local metres around a floor-datum anchor;
/// [RingCellMesh.anchorRF]/[localToRing] place it in the ring frame. Anchored
/// local coords keep float32 vertex buffers jitter-free at a 5,000 km ring
/// radius, the same trick `CellMesh.anchorBF` plays for planets.
library;

import 'dart:math' as math;

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../terrain/surface_nets.dart';
import 'halo_ring.dart';

/// Grid address of one voxel terrain cell on the ring band.
class RingCellKey {
  const RingCellKey(this.i, this.j);

  /// Cell index around the circumference, 0..[HaloRingGrid.cellsAround]-1.
  final int i;

  /// Cell index across the band interior, 0..[HaloRingGrid.cellsAcross]-1.
  final int j;

  @override
  bool operator ==(Object other) =>
      other is RingCellKey && other.i == i && other.j == j;

  @override
  int get hashCode => Object.hash(i, j);

  @override
  String toString() => 'RingCell($i,$j)';
}

/// The fixed chunk grid a spec implies. Pure functions of the spec so the
/// simulation and renderer derive identical addressing without shared state.
class HaloRingGrid {
  const HaloRingGrid(this.spec, {this.cellSizeM = 512});

  final HaloRingSpec spec;

  /// Nominal cell edge (m) along both the arc and the band.
  final double cellSizeM;

  /// Cells around the full circumference. Derived from the arc length at the
  /// floor datum so cells stay ~square.
  int get cellsAround =>
      math.max(1, (2 * math.pi * spec.radiusM / cellSizeM).ceil());

  /// Cells across the band interior (wall feet excluded — the walls are
  /// procedural hull geometry, not voxel terrain).
  int get cellsAcross =>
      math.max(1, (2 * spec.interiorHalfWidthM / cellSizeM).ceil());

  /// Arc angle of one cell (rad).
  double get cellArcRad => 2 * math.pi / cellsAround;

  /// Band-axis extent of one cell (m).
  double get cellSpanM => 2 * spec.interiorHalfWidthM / cellsAcross;

  /// Centre angle of column [i].
  double phiOf(int i) => (i + 0.5) * cellArcRad;

  /// Centre z of row [j].
  double zOf(int j) => -spec.interiorHalfWidthM + (j + 0.5) * cellSpanM;

  /// The cell containing band coordinates ([phi], [z]); phi in any range.
  RingCellKey cellAt(double phi, double z) {
    var p = phi % (2 * math.pi);
    if (p < 0) p += 2 * math.pi;
    final i = (p / cellArcRad).floor().clamp(0, cellsAround - 1);
    final j = ((z + spec.interiorHalfWidthM) / cellSpanM)
        .floor()
        .clamp(0, cellsAcross - 1);
    return RingCellKey(i, j);
  }

  /// Wrap a circumference index into range (columns wrap; rows do not).
  int wrapI(int i) {
    final n = cellsAround;
    final m = i % n;
    return m < 0 ? m + n : m;
  }
}

/// One meshed terrain cell: local-frame geometry plus the transform that
/// plants it on the ring.
class RingCellMesh {
  const RingCellMesh({
    required this.key,
    required this.mesh,
    required this.anchorRF,
    required this.localToRing,
  });

  final RingCellKey key;

  /// Vertices/normals in cell-LOCAL metres about [anchorRF].
  final SurfaceMesh mesh;

  /// Cell anchor in ring body-fixed metres (on the floor datum cylinder).
  final Vector3 anchorRF;

  /// Rotation taking cell-local axes into the ring body-fixed frame.
  final Quaternion localToRing;
}

/// Mesh one terrain cell of [field]'s ring.
///
/// [resolution] is lateral voxels across the cell; the radial (local Z) extent
/// covers the terrain relief plus [depthMarginM] each way, so pristine ground
/// and shallow edits mesh correctly. (Deep excavation past the margin wants
/// the brush `surfaceBand` treatment the planetary cell mesher does — a later
/// pass, once mining targets rings.)
RingCellMesh meshHaloRingCell(
  HaloRingField field,
  HaloRingGrid grid,
  RingCellKey key, {
  int resolution = 32,
  double marginVoxels = 2,
  double depthMarginM = 40,
}) {
  final spec = field.spec;
  final phiC = grid.phiOf(key.i);
  final zC = grid.zOf(key.j);
  final cosP = math.cos(phiC), sinP = math.sin(phiC);

  // Local basis in ring coords (right-handed; +Z toward the axis = walker up).
  final ux = Vector3(-sinP, cosP, 0); // tangent
  final uz = Vector3(-cosP, -sinP, 0); // radially inward
  final uy = uz.cross(ux); // = -ring Z; completes the right-handed set
  final anchor = Vector3(cosP * spec.radiusM, sinP * spec.radiusM, zC);

  // Lateral extents: half a cell plus margin so neighbouring cells overlap by
  // the padding Surface Nets needs (no cross-chunk stitching pass; skirtless
  // v1 accepts the hairline seam).
  final halfArc = spec.radiusM * grid.cellArcRad / 2;
  final halfSpan = grid.cellSpanM / 2;
  final voxel = math.max(halfArc, halfSpan) * 2 / resolution;
  final margin = marginVoxels * voxel;
  final ex = halfArc + margin;
  final ey = halfSpan + margin;
  // Radial: bracket the relief band. Local +Z is toward the axis, so positive
  // z_local sits ABOVE the datum (hills), negative below (valleys + digs).
  final ez = spec.terrainAmplitudeM + depthMarginM;

  final nx = math.max(2, (2 * ex / voxel).ceil() + 1);
  final ny = math.max(2, (2 * ey / voxel).ceil() + 1);
  final nz = math.max(2, (2 * ez / voxel).ceil() + 1);

  double sample(double lx, double ly, double lz) {
    final p = Vector3(
      anchor.x + ux.x * lx + uy.x * ly + uz.x * lz,
      anchor.y + ux.y * lx + uy.y * ly + uz.y * lz,
      anchor.z + ux.z * lx + uy.z * ly + uz.z * lz,
    );
    return field.density(p.x, p.y, p.z);
  }

  final gridSamples = DensityGrid.sample(
    sample,
    nx: nx,
    ny: ny,
    nz: nz,
    voxelSize: voxel,
    originX: -ex,
    originY: -ey,
    originZ: -ez,
  );
  final mesh = surfaceNets(gridSamples);

  return RingCellMesh(
    key: key,
    mesh: mesh,
    anchorRF: anchor,
    localToRing: Quaternion.fromBasis(ux, uy, uz),
  );
}
