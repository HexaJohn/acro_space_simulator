// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../shared/vector3.dart';
import 'prop_catalog.dart';

/// One prop placed on a body's surface, in the BODY-FIXED frame (metres).
///
/// Body-fixed, not world: the surface rotates, and a scattered field that did
/// not rotate with it would slide across the ground as the planet turned. This
/// is the same frame the terrain mesher keeps its chunks in, for the same
/// reason, so a prop and the ground under it can never drift apart.
///
/// Plain data with no identity of its own — an instance is fully determined by
/// its cell and index (see [ScatterPlacement]), so nothing here needs storing
/// or syncing. Regenerate it and you get the identical prop back.
class ScatterInstance {
  const ScatterInstance({
    required this.kind,
    required this.seed,
    required this.positionBF,
    required this.upBF,
    required this.yaw,
    required this.scale,
  });

  /// Which prop to grow. Pair with [seed] to fetch the mesh.
  final PropKind kind;

  /// Which individual of that kind — the generator's seed.
  final int seed;

  /// Ground contact point (body-fixed metres). A prop's own origin is its base,
  /// so this is where the origin goes.
  final Vector3 positionBF;

  /// Surface normal at [positionBF]. Props stand along this rather than along
  /// the radius: on a slope the difference is the whole point, and a tree
  /// planted radially on a hillside leans visibly downhill.
  final Vector3 upBF;

  /// Rotation about [upBF] (radians).
  final double yaw;

  /// Size multiplier on the kind's default. Variation in size does more for a
  /// field's realism than variation in species.
  final double scale;
}
