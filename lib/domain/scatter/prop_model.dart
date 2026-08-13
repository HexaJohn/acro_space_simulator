// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'prop_imposter.dart';
import 'prop_mesh.dart';

/// One prop at one detail level, split by the two materials a scattered prop
/// ever needs.
///
/// The split is a RENDERING constraint, not taxonomy: bark and stone are opaque
/// single-sided surfaces, while leaves, needles and grass blades are
/// alpha-masked cards that must draw double-sided. Those cannot share a
/// material, so they cannot share a mesh — a tree is two instanced draws, and
/// keeping them separate here is what lets the whole forest stay at two draws
/// total rather than two per tree.
class PropModel {
  const PropModel({required this.solid, required this.foliage});

  /// Opaque geometry — trunk, branches, stone. Back-face culled.
  final PropMesh solid;

  /// Alpha-masked cards — leaves, needles, blades, fronds. Double-sided.
  final PropMesh foliage;

  bool get isEmpty => solid.isEmpty && foliage.isEmpty;
  int get triangleCount => solid.triangleCount + foliage.triangleCount;
  int get vertexCount => solid.vertexCount + foliage.vertexCount;

  /// Union of both parts' bounds.
  PropBounds get bounds => solid.bounds.union(foliage.bounds);

  static final PropModel empty =
      PropModel(solid: PropMesh.empty, foliage: PropMesh.empty);
}

/// Detail levels, coarsest last. [billboard] carries no geometry of its own —
/// it is drawn as a single camera-facing card from [PropLodSet.imposter].
enum PropLod {
  /// Full detail. Near the camera only.
  lod0,

  /// Roughly half the triangles: shallower branch recursion, coarser tubes,
  /// fewer but larger foliage cards.
  lod1,

  /// Silhouette only: trunk plus a handful of big canopy cards.
  lod2,

  /// One textured card facing the camera.
  billboard,
}

/// The full set of levels for one generated prop, plus the imposter that
/// replaces geometry entirely at distance.
///
/// [lodForApparentPx] picks a level from the prop's ON-SCREEN size rather than
/// raw distance, which is the only measure that stays correct across the app's
/// continuously-zooming camera — a metre threshold tuned at one field of view
/// is wrong at every other.
class PropLodSet {
  PropLodSet({
    required this.levels,
    required this.imposter,
    required this.bounds,
  });

  /// Indexed by [PropLod.index] for [PropLod.lod0] .. [PropLod.lod2].
  final List<PropModel> levels;

  /// The distant stand-in, painted from the same skeleton the meshes came from.
  final PropImposter imposter;

  /// Bounds of [PropLod.lod0] — the authority for height, cull radius and
  /// imposter card size (coarser levels shrink slightly and would bias these).
  final PropBounds bounds;

  double get heightM => bounds.heightM;
  double get radiusM => bounds.radiusM;

  PropModel operator [](PropLod lod) =>
      lod == PropLod.billboard ? PropModel.empty : levels[lod.index];

  /// Screen height (logical px) at or below which each level takes over.
  /// Generous at the top: foliage cards alias badly once a tree is only a few
  /// dozen pixels tall, and the imposter is both cheaper AND steadier there.
  static const double lod1BelowPx = 220.0;
  static const double lod2BelowPx = 90.0;
  static const double billboardBelowPx = 34.0;

  /// The level to draw for a prop covering [px] logical pixels of screen
  /// height.
  static PropLod lodForApparentPx(double px) {
    if (px <= billboardBelowPx) return PropLod.billboard;
    if (px <= lod2BelowPx) return PropLod.lod2;
    if (px <= lod1BelowPx) return PropLod.lod1;
    return PropLod.lod0;
  }

  /// Apparent height in logical pixels of a prop [distanceM] from an eye with
  /// vertical field of view [fovY] rendering into [viewportHeightPx].
  double apparentPx(
    double distanceM, {
    required double fovY,
    required double viewportHeightPx,
  }) {
    if (distanceM <= 1e-6) return double.infinity;
    // Small-angle-free form: the projected size of a segment of length h at
    // distance d spanning a viewport that covers 2*tan(fov/2)*d metres.
    final metresPerScreen = 2.0 * math.tan(fovY * 0.5) * distanceM;
    if (metresPerScreen <= 1e-9) return double.infinity;
    return heightM / metresPerScreen * viewportHeightPx;
  }

  int get totalTriangles =>
      levels.fold(0, (sum, m) => sum + m.triangleCount);
}
