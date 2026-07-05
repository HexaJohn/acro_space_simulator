import '../../../domain/terrain/surface_nets.dart';
import '../../../domain/terrain/terrain_field.dart';

/// Mesh an axis-aligned box of the body-frame terrain field with Surface Nets.
///
/// The box is centred at `(cx,cy,cz)` (body-frame metres) with side [sizeM] and
/// [resolution] cells across, plus a one-voxel apron on every side so the
/// mesher's omitted boundary faces fall in the apron, not the visible patch
/// (seamless once neighbouring chunks share the apron). Returns geometry in
/// body-frame metres.
SurfaceMesh meshTerrainChunk(
  TerrainField field, {
  required double cx,
  required double cy,
  required double cz,
  required double sizeM,
  required int resolution,
}) {
  final voxel = sizeM / resolution;
  final n = resolution + 3; // resolution cells -> +1 sample, +2 apron samples
  final half = sizeM / 2;
  final grid = DensityGrid.sample(
    field.density,
    nx: n,
    ny: n,
    nz: n,
    voxelSize: voxel,
    originX: cx - half - voxel,
    originY: cy - half - voxel,
    originZ: cz - half - voxel,
  );
  return surfaceNets(grid);
}
