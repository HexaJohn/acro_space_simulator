import '../../../domain/terrain/surface_nets.dart';
import '../../../domain/terrain/terrain_field.dart';

/// Mesh an axis-aligned box of the body-frame terrain field with Surface Nets.
///
/// The box is centred at `(cx,cy,cz)` (body-frame metres) with side [sizeM] and
/// [resolution] cells across, plus a one-voxel apron on every side so the
/// mesher's omitted boundary faces fall in the apron, not the visible patch
/// (seamless once neighbouring chunks share the apron).
///
/// Geometry is returned in metres RELATIVE TO THE CHUNK CENTRE (not absolute
/// body-frame): a body-frame chunk sits ~radius (1e6 m) from the origin, and
/// storing those absolutes in a float32 vertex buffer + float32 node transform
/// cancels catastrophically near the camera (violent sub-metre jitter). Local
/// vertices stay small, so precision holds; the caller places the chunk centre
/// via the floating origin.
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
  // Grid origin is LOCAL (centred on 0); the field is sampled at the absolute
  // body-frame position by offsetting each lookup by the chunk centre, so the
  // relief is identical while the emitted vertices are small.
  final grid = DensityGrid.sample(
    (x, y, z) => field.density(x + cx, y + cy, z + cz),
    nx: n,
    ny: n,
    nz: n,
    voxelSize: voxel,
    originX: -half - voxel,
    originY: -half - voxel,
    originZ: -half - voxel,
  );
  return surfaceNets(grid);
}
