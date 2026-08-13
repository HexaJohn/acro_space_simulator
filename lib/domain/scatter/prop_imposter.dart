// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

/// Which palette slot an imposter shape paints with. The concrete colours live
/// in the renderer (they follow the same procedural textures the meshes wear),
/// so the domain stays free of any colour representation.
enum ImposterInk {
  /// Trunk and branch wood.
  bark,

  /// Canopy foliage — leaves, needles, fronds.
  foliage,

  /// Shaded underside of a canopy mass, for a hint of self-shadowing.
  foliageShadow,

  /// Stone.
  rock,
}

/// A filled circle in imposter card space.
class ImposterBlob {
  const ImposterBlob({
    required this.x,
    required this.y,
    required this.radius,
    required this.ink,
  });

  /// Horizontal centre, `-0.5` (card left) .. `0.5` (card right).
  final double x;

  /// Vertical centre, `0.0` (card bottom / ground) .. `1.0` (card top).
  final double y;

  /// Radius as a fraction of the card WIDTH.
  final double radius;

  final ImposterInk ink;
}

/// A tapered stroke (trunk or limb) in imposter card space.
class ImposterStroke {
  const ImposterStroke({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.width0,
    required this.width1,
    this.ink = ImposterInk.bark,
  });

  final double x0, y0, x1, y1;

  /// End widths as a fraction of the card WIDTH.
  final double width0, width1;

  final ImposterInk ink;
}

/// A resolution-independent description of what a prop looks like in
/// silhouette, for painting the distant billboard that replaces its geometry.
///
/// Deriving this from the SAME skeleton that produced the meshes is the whole
/// point: an imposter baked from an unrelated recipe pops visibly at the
/// switch distance, because its canopy sits somewhere the geometry's did not.
/// Here the blobs are literally the foliage clusters' positions and the strokes
/// are the limbs, so the two representations agree by construction.
///
/// Card space has its origin at the BOTTOM CENTRE of the card — where the prop
/// meets the ground — with x in `[-0.5, 0.5]` and y in `[0, 1]`, both scaled by
/// the card's own extent. Pure geometry: no pixels, no colours, no canvas.
class PropImposter {
  PropImposter({
    required this.widthM,
    required this.heightM,
    required this.blobs,
    required this.strokes,
  });

  /// Card size in metres. Width comes from the prop's horizontal extent, so a
  /// broad canopy gets a wide card and a grass tuft a narrow one.
  final double widthM;
  final double heightM;

  final List<ImposterBlob> blobs;
  final List<ImposterStroke> strokes;

  bool get isEmpty => blobs.isEmpty && strokes.isEmpty;

  /// A trivial imposter for props that never need a painted silhouette.
  static PropImposter get empty =>
      PropImposter(widthM: 0, heightM: 0, blobs: const [], strokes: const []);
}

/// Accumulates imposter shapes in METRES (prop-local, Z-up, origin at the base)
/// and normalises them into card space on [build].
///
/// Generators add shapes in the same coordinates they build geometry in, which
/// keeps the two in step without any per-species conversion code.
class ImposterBuilder {
  final List<_MetreBlob> _blobs = [];
  final List<_MetreStroke> _strokes = [];

  /// A canopy mass centred at prop-local `(x, y, z)` metres with [radius]
  /// metres. The horizontal position is flattened to a single axis — the card
  /// is a 2D projection, and averaging x/y would pull every blob toward the
  /// trunk and shrink the silhouette.
  void blob({
    required double x,
    required double y,
    required double z,
    required double radius,
    ImposterInk ink = ImposterInk.foliage,
  }) {
    // Project onto the card plane: signed horizontal distance from the axis,
    // preserving spread so the canopy keeps its true width.
    final r = math.sqrt(x * x + y * y);
    _blobs.add(_MetreBlob(x < 0 || (x == 0 && y < 0) ? -r : r, z, radius, ink));
  }

  /// A limb from one prop-local point to another, with metre end radii.
  void stroke({
    required double x0,
    required double y0,
    required double z0,
    required double x1,
    required double y1,
    required double z1,
    required double radius0,
    required double radius1,
    ImposterInk ink = ImposterInk.bark,
  }) {
    final r0 = math.sqrt(x0 * x0 + y0 * y0);
    final r1 = math.sqrt(x1 * x1 + y1 * y1);
    _strokes.add(_MetreStroke(
      x0 < 0 || (x0 == 0 && y0 < 0) ? -r0 : r0,
      z0,
      x1 < 0 || (x1 == 0 && y1 < 0) ? -r1 : r1,
      z1,
      radius0,
      radius1,
      ink,
    ));
  }

  /// Normalise into card space. [widthM]/[heightM] come from the LOD0 bounds so
  /// the card matches the geometry it replaces; a card sized from the shapes
  /// alone would clip whatever the imposter happens to under-represent.
  PropImposter build({required double widthM, required double heightM}) {
    if (widthM <= 1e-6 || heightM <= 1e-6) return PropImposter.empty;
    double nx(double m) => m / widthM;
    double ny(double m) => m / heightM;
    return PropImposter(
      widthM: widthM,
      heightM: heightM,
      blobs: [
        for (final b in _blobs)
          ImposterBlob(
            x: nx(b.x),
            y: ny(b.z),
            radius: nx(b.radius),
            ink: b.ink,
          ),
      ],
      strokes: [
        for (final s in _strokes)
          ImposterStroke(
            x0: nx(s.x0),
            y0: ny(s.z0),
            x1: nx(s.x1),
            y1: ny(s.z1),
            width0: nx(s.radius0 * 2),
            width1: nx(s.radius1 * 2),
            ink: s.ink,
          ),
      ],
    );
  }
}

class _MetreBlob {
  const _MetreBlob(this.x, this.z, this.radius, this.ink);
  final double x, z, radius;
  final ImposterInk ink;
}

class _MetreStroke {
  const _MetreStroke(
      this.x0, this.z0, this.x1, this.z1, this.radius0, this.radius1, this.ink);
  final double x0, z0, x1, z1, radius0, radius1;
  final ImposterInk ink;
}
