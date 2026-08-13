// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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
    // Local (+X, +Y, +Z) = (east, north, up), so a building's "up" points away
    // from the planet centre.
    final orientation = Quaternion.fromBasis(eastAxis, northAxis, up);
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

