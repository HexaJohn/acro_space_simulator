// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../shared/vector3.dart';

/// The parametric recipe for a part whose mesh is GENERATED rather than baked.
///
/// A [PartDef] carrying one of these has no `modelAsset` and never will: the
/// procedural silhouette IS the part's art, on every platform, forever — not a
/// stand-in awaiting a bake. That inverts the meaning of the fallback path
/// (`PartPrimitivesByCategory`), which is why the spec is authored data on the
/// def rather than a renderer-side table keyed off ids: the catalog is the one
/// scale registry, and a shape parameter written down twice is a shape that
/// will eventually be two different numbers.
///
/// Everything here is in METRES in the part-local frame — right-handed, Z-up,
/// nose on +Z, centred on the part origin — the same frame [PartDef.size] and
/// [AttachNode] positions are measured in. Generated meshes are authored at
/// TRUE size, so [extentM] must equal the owning def's `size`: the editor
/// scales a drawn part by `size / authoredExtent`, and equality is what makes
/// that scale exactly 1 and the drawn box exactly the picked box.
///
/// Pure data, no behaviour: the mesh math lives in `proc_part_mesh.dart`
/// (domain, testable without a GPU) and the material choice in the renderer.
sealed class ProcShape {
  const ProcShape();

  /// The generated mesh's bounding box, metres. Every component strictly
  /// positive, so a caller may divide by it.
  Vector3 get extentM;
}

/// A spherical pressure tank: poles on ±Z.
class ProcSphere extends ProcShape {
  const ProcSphere({required this.diameterM});

  final double diameterM;

  @override
  Vector3 get extentM => Vector3(diameterM, diameterM, diameterM);
}

/// A pill tank: a cylinder about Z capped with true hemispheres.
///
/// [lengthM] is pole to pole and must be at least [diameterM] — at equality
/// the cylinder section vanishes and the pill degenerates to a sphere.
class ProcPill extends ProcShape {
  const ProcPill({required this.diameterM, required this.lengthM})
      : assert(lengthM >= diameterM,
            'a pill shorter than its diameter is not a pill');

  final double diameterM;

  /// Total length along Z, hemispherical caps included.
  final double lengthM;

  @override
  Vector3 get extentM => Vector3(diameterM, diameterM, lengthM);
}

/// An open lattice girder: four corner longerons about Z, ring rungs at each
/// bay boundary, and one zig-zag diagonal per face per bay.
///
/// [widthM] is the square cross-section; bays are as close to cubic as the
/// length divides into. [strutFrac] is strut thickness as a fraction of
/// [widthM] — the default reads as rolled steel at every catalog size.
class ProcTruss extends ProcShape {
  const ProcTruss({
    required this.widthM,
    required this.lengthM,
    this.strutFrac = 0.12,
  });

  final double widthM;
  final double lengthM;
  final double strutFrac;

  @override
  Vector3 get extentM => Vector3(widthM, widthM, lengthM);
}

/// A flat rectangular plate: wide in X, tall in Y, thin in Z — the slab
/// convention. [armor] selects the heavy finish (gunmetal, rough) over the
/// bare-aluminium skin; it changes how the renderer paints it, nothing else —
/// mass and temperature limits are the owning [PartDef]'s to state.
class ProcPlate extends ProcShape {
  const ProcPlate({
    required this.widthM,
    required this.heightM,
    required this.thicknessM,
    this.armor = false,
  });

  final double widthM;
  final double heightM;
  final double thicknessM;
  final bool armor;

  @override
  Vector3 get extentM => Vector3(widthM, heightM, thicknessM);
}
