import 'dart:math' as math;

import '../shared/quaternion.dart';
import '../shared/vector3.dart';

/// Metres per city grid cell. Mirrors the city builder's `_cellM` so the engine
/// and the 2D city view agree on building footprints.
const double kCityCellMetres = 24.0;

/// Computes body-fixed surface transforms for things that sit on a planet:
/// colony buildings and landed craft. Pure geometry on a smooth sphere of the
/// body's radius; terrain elevation (reported by the renderer) is folded in as
/// an extra radial offset.
///
/// Frame: right-handed, body-fixed (Z = spin axis / north pole). The returned
/// orientation's local +Z is radial-up and local +Y is north, so a building's
/// "up" points away from the planet centre. The renderer parents these under
/// the rotating body actor, so they spin with the planet automatically.
class SurfacePlacement {
  const SurfacePlacement();

  /// Transform at ([lat], [lon]) radians on a sphere of [radius] m, offset
  /// [east]/[north] m along the local tangent and lifted [elevation] m.
  ({Vector3 position, Quaternion orientation}) place({
    required double radius,
    required double lat,
    required double lon,
    double east = 0,
    double north = 0,
    double elevation = 0,
  }) {
    final cl = math.cos(lat), sl = math.sin(lat);
    final co = math.cos(lon), so = math.sin(lon);
    final up = Vector3(cl * co, cl * so, sl); // radial unit
    final eastAxis = Vector3(-so, co, 0); // d/dlon unit (horizontal)
    final northAxis = up.cross(eastAxis); // unit; completes the right-handed frame
    final position =
        up * (radius + elevation) + eastAxis * east + northAxis * north;
    final orientation = _basisToQuaternion(eastAxis, northAxis, up);
    return (position: position, orientation: orientation);
  }

  /// Transform for a colony building. The colony ([lat],[lon]) anchors grid cell
  /// origin; cell ([gridX],[gridY]) sits [cell] m east/north of it. [elevation]
  /// is the renderer-reported terrain height at the cell (0 = smooth sphere).
  ({Vector3 position, Quaternion orientation}) building({
    required double radius,
    required double lat,
    required double lon,
    required int gridX,
    required int gridY,
    double cell = kCityCellMetres,
    double elevation = 0,
  }) =>
      place(
        radius: radius,
        lat: lat,
        lon: lon,
        east: (gridX + 0.5) * cell,
        north: (gridY + 0.5) * cell,
        elevation: elevation,
      );
}

/// Quaternion from an orthonormal basis whose axes are the images of local
/// (+X, +Y, +Z) = (east, north, up). Shepperd's method on R = [east|north|up].
Quaternion _basisToQuaternion(Vector3 east, Vector3 north, Vector3 up) {
  final m00 = east.x, m10 = east.y, m20 = east.z;
  final m01 = north.x, m11 = north.y, m21 = north.z;
  final m02 = up.x, m12 = up.y, m22 = up.z;
  final trace = m00 + m11 + m22;
  if (trace > 0) {
    final s = math.sqrt(trace + 1.0) * 2;
    return Quaternion(0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s)
        .normalized;
  } else if (m00 > m11 && m00 > m22) {
    final s = math.sqrt(1.0 + m00 - m11 - m22) * 2;
    return Quaternion((m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s)
        .normalized;
  } else if (m11 > m22) {
    final s = math.sqrt(1.0 + m11 - m00 - m22) * 2;
    return Quaternion((m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s)
        .normalized;
  } else {
    final s = math.sqrt(1.0 + m22 - m00 - m11) * 2;
    return Quaternion((m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s)
        .normalized;
  }
}
