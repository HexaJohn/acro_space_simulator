// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the road tool wants drawn over the world, beyond the tiles.
///
/// The editor (the flight view's colony part) WRITES this; the city
/// renderer READS it and draws it as its own nodes, on the UI thread, the
/// frame it changes — never through the worker-meshed tiles, which take
/// seconds to land. A view that has to answer the mouse cannot wait on a
/// tile.
///
/// Everything is body-fixed metres on [bodyId]. Writers replace lists
/// rather than mutating them and call [changed]; the renderer rebuilds
/// what it draws only when [revision] moves, so a frame with no edit costs
/// one integer compare.
library;

import '../../../domain/shared/vector3.dart';

/// How the road being drawn reads.
enum RoadGhostState {
  /// Buildable as drawn.
  ok,

  /// Refused — too steep, too high, too deep, locked, unaffordable. Red.
  refused,

  /// An existing road picked by the Upgrade tool or the Adjust view.
  selected,
}

/// A polyline laid over the world: a route in the Traffic Routes view, a
/// snapping guideline, the highlight on the road under the cursor, a
/// tunnel seen from above.
class OverlayLine {
  const OverlayLine({
    required this.pointsBF,
    required this.argb,
    this.widthM = 2,
    this.liftM = 0.5,
    this.dashed = false,
    this.liftsM,
  });

  /// Centreline, body-fixed metres, on the ground (or the deck).
  final List<Vector3> pointsBF;

  /// Colour, 0xAARRGGBB; alpha below 0xFF draws translucent.
  final int argb;
  final double widthM;

  /// Height above the points it is drawn at — clear of the road surface
  /// (ribbon 0.12, junction plate 0.16, pavement 0.27 m), so it never
  /// z-fights what it describes.
  final double liftM;
  final bool dashed;

  /// Optional per-point extra lift (a raised road's deck above the drape),
  /// parallel to [pointsBF]. Null: none.
  final List<double>? liftsM;
}

/// A marker on the world: a junction in the Junctions view, an adjust
/// handle at a road end.
enum OverlayMarkerKind {
  /// A filled disc.
  dot,

  /// A ring — an adjust-road end handle.
  ring,

  /// A traffic-light junction.
  lights,

  /// A junction without lights.
  noLights,

  /// A stop sign on one leg.
  stop,
}

class OverlayMarker {
  const OverlayMarker({
    required this.atBF,
    required this.argb,
    this.radiusM = 4,
    this.kind = OverlayMarkerKind.dot,
    this.liftM = 0.6,
  });

  final Vector3 atBF;
  final int argb;
  final double radiusM;
  final OverlayMarkerKind kind;
  final double liftM;
}

/// The road tool's overlays: one instance, written by the editor, read by
/// the renderer.
class RoadOverlayState {
  RoadOverlayState._();

  static final RoadOverlayState instance = RoadOverlayState._();

  /// Bumped by [changed]. The renderer's only question each frame.
  int revision = 0;

  /// The body everything below is on.
  String bodyId = '';

  // ---- The ghost: the road being drawn -------------------------------------

  /// Centreline of the road being drawn, body-fixed, ON THE GROUND (the
  /// drape) — [ghostLiftsM] raises it to its deck.
  List<Vector3> ghostBF = const [];

  /// Deck minus ground, metres, per [ghostBF] point: 0 at grade, positive
  /// on piers, below `-RoadElevation.tunnelCoverM` in a tunnel. Empty: 0.
  List<double> ghostLiftsM = const [];

  /// The class being drawn (`RoadClass.index`) and its half width, so the
  /// ghost can show real lanes, piers and portals.
  int ghostClassIndex = 0;
  double ghostHalfWidthM = 4;
  RoadGhostState ghostState = RoadGhostState.ok;

  /// Direction-of-travel arrows on the ghost: true for a one-way type.
  bool ghostOneWay = false;

  // ---- Everything else ------------------------------------------------------

  /// Lines: snapping guidelines, route lines, highlights, tunnels seen
  /// from above. Drawn in list order.
  List<OverlayLine> lines = const [];

  /// Markers: adjust handles, junction states, stop signs.
  List<OverlayMarker> markers = const [];

  /// Tunnels are drawn (as [lines] the editor adds) only while the road tool
  /// is held below ground. The renderer may also use it to reveal portals.
  bool showUnderground = false;

  /// Publish a change: the renderer redraws on its next frame.
  void changed() => revision++;

  /// Drop everything — the editor closed, or the tool changed.
  void clear() {
    final hadAny = ghostBF.isNotEmpty ||
        lines.isNotEmpty ||
        markers.isNotEmpty ||
        showUnderground;
    ghostBF = const [];
    ghostLiftsM = const [];
    ghostState = RoadGhostState.ok;
    ghostOneWay = false;
    lines = const [];
    markers = const [];
    showUnderground = false;
    if (hadAny) changed();
  }
}
