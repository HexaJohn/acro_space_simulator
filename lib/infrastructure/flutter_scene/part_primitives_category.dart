// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../domain/parts/part_def.dart';
import '../../domain/shared/vector3.dart';
import 'proc_part_geometry.dart';
import 'vessel_nodes.dart';

/// One procedural silhouette, together with the box that silhouette fills in
/// the space it is authored in.
///
/// The extent is half of a shape's identity, not a footnote about it. The
/// editor scales a stand-in so that the DRAWN box is the oriented box
/// `CraftEditorPick` hit-tests, and a scale can only do that if it knows how
/// big the mesh already is: [PartPrimitives.slab] is authored 1.0 x 0.4 x
/// 0.06 m, so a scale that assumed a unit cube draws a 3.22 m landing leg
/// 0.19 m deep and leaves its click target floating 1.5 m above the picture.
///
/// Units are METRES in the part frame — right-handed, Z-up, nose on +Z —
/// centred on the part origin, which is the point [PartDef.size] is measured
/// about.
enum PartStandInShape {
  /// Cone with its apex on +Z. A nose.
  nose(Vector3(1, 1, 1)),

  /// Cone with its apex on -Z. A bell.
  nozzle(Vector3(1, 1, 1)),

  /// Cylinder about the part axis.
  cylinder(Vector3(1, 1, 1)),

  /// Cube. The honest shape for a part whose real one is unknown.
  box(Vector3(1, 1, 1)),

  /// A plate: wide in X, shallow in Y, thin in Z. The one shape here that is
  /// NOT a unit cube, and therefore the reason this enum carries an extent.
  slab(Vector3(1.0, 0.4, 0.06));

  const PartStandInShape(this.authoredExtentM);

  /// The mesh's own bounding box, METRES, before any part scale.
  ///
  /// Every component is strictly positive, so a caller may divide by it.
  final Vector3 authoredExtentM;
}

/// How a stand-in is finished. Named rather than held as a [fs.Material],
/// because `fscene` reads a material straight through to the render item and
/// one shared instance handed to two parts is one edit away from recolouring
/// both.
enum _Finish { hull, dark, panel }

/// One table row: the shape a part draws as and the finish it wears.
typedef _StandIn = ({PartStandInShape shape, _Finish finish});

/// The procedural silhouette a part is drawn with when it has no baked art —
/// resolved in three tiers: the id-substring table ([hasIdShape]) first, the
/// part's [PartCategory] second, a grey cuboid last.
///
/// Shared by BOTH renderers of a catalog craft — `CraftEditorNodes` in the VAB
/// and `VesselNodes` in flight — because a craft that changed shape when it
/// launched would make the editor a liar about what it was building. The two
/// reach it differently: the editor holds the [PartDef] already, while the
/// flight renderer has only a type key off the snapshot and recovers the def
/// through `PartModelLibrary.defFor`.
///
/// ## Why the category tier exists
///
/// The id tier matches on words a hand-built vessel names its parts with
/// (`tank`, `engine`, `wing`). All seven `eagle-*` catalog ids happen to
/// contain one, so the LEM is already shaped. The STOCK roster mostly is not:
/// `fl-t400`, `merlin-1d`, `rl10`, `tr-18a-decoupler`, `landing-gear`,
/// `mk16-chute`, `ram-intake`, `cockpit-mk1` and `thermometer` all fall through
/// to the same grey box, and a catalog where nine parts are visually identical
/// is one nobody can build from. The category is a fact the catalog already
/// states about every part, so it costs no new data.
///
/// ## Why this is not an error path
///
/// A stand-in is the FIRST FRAME of every part, not a failure mode: bakes are
/// absent on a fresh clone (the source models are licensed for use but not
/// redistribution), absent on web by build policy, and asynchronous everywhere
/// else. The editor's picking is OBB-based off [PartDef.size] and never touches
/// the mesh, so a part that draws as a primitive is still fully placeable —
/// which is what makes "every catalog part is buildable" a structural property
/// rather than a property of whether the art shipped.
///
/// ## Why the shape is resolved here and the mesh is built here
///
/// The id tier draws with the SAME primitives and materials [PartPrimitives]
/// uses, so a stock engine and an `eagle-thruster` are one silhouette — but it
/// resolves them through [shapeFor] rather than calling
/// [PartPrimitives.forType]. A renderer has to know the box a stand-in fills as
/// well as which mesh it is, and a mesh handed over without its extent cannot
/// be scaled to fill [PartDef.size]. Deriving both from one table
/// ([standInScaleM]) is what makes "the drawn box is the box the picker tests"
/// true by construction instead of true as long as two files agree.
class PartPrimitivesByCategory {
  PartPrimitivesByCategory._();

  /// Type-key substring -> silhouette, in MATCH ORDER: the first key an id
  /// contains wins, so a longer key must precede any key it contains.
  ///
  /// The keys are [PartPrimitives.forType]'s, and each row resolves to the
  /// primitive that registry resolves the same key to.
  static const Map<String, _StandIn> _byIdKey = {
    'capsule': (shape: PartStandInShape.nose, finish: _Finish.hull),
    'pod': (shape: PartStandInShape.nose, finish: _Finish.hull),
    'fuselage': (shape: PartStandInShape.cylinder, finish: _Finish.hull),
    'tank': (shape: PartStandInShape.cylinder, finish: _Finish.hull),
    'engine': (shape: PartStandInShape.nozzle, finish: _Finish.dark),
    // Named separately from 'engine': a thruster reads as an engine but shares
    // no substring with it, and every LM part would otherwise land on the
    // unknown-key cuboid.
    'thruster': (shape: PartStandInShape.nozzle, finish: _Finish.dark),
    'rcs': (shape: PartStandInShape.box, finish: _Finish.dark),
    'leg': (shape: PartStandInShape.slab, finish: _Finish.hull),
    'wing': (shape: PartStandInShape.slab, finish: _Finish.hull),
    'panel': (shape: PartStandInShape.slab, finish: _Finish.panel),
  };

  /// Silhouette per category, chosen to be distinguishable AT A GLANCE and
  /// truthful about which way the part faces, because in an editor the
  /// silhouette is how a player tells a decoupler from a heat shield before
  /// either has art.
  ///
  /// A map rather than a switch, and that is deliberate: a category this file
  /// has no opinion about must still be placeable and visible, which means
  /// falling through to the cuboid — something a non-exhaustive switch could
  /// not express.
  static const Map<PartCategory, _StandIn> _byCategory = {
    // Blunt cone, apex on +Z: a capsule reads as a nose.
    PartCategory.commandPod: (shape: PartStandInShape.nose, finish: _Finish.hull),
    PartCategory.fuelTank:
        (shape: PartStandInShape.cylinder, finish: _Finish.hull),
    // Apex aft, matching the id tier's 'engine' row, so a stock engine and an
    // eagle-thruster are the same silhouette.
    PartCategory.rocketEngine:
        (shape: PartStandInShape.nozzle, finish: _Finish.dark),
    PartCategory.jetEngine:
        (shape: PartStandInShape.cylinder, finish: _Finish.dark),
    PartCategory.intake: (shape: PartStandInShape.cylinder, finish: _Finish.dark),
    PartCategory.wing: (shape: PartStandInShape.slab, finish: _Finish.hull),
    PartCategory.controlSurface:
        (shape: PartStandInShape.slab, finish: _Finish.hull),
    // A short dark disc between two stacks: the one part whose whole job is to
    // be the seam.
    PartCategory.decoupler:
        (shape: PartStandInShape.cylinder, finish: _Finish.dark),
    PartCategory.landingGear:
        (shape: PartStandInShape.slab, finish: _Finish.hull),
    // The stowed canister, which is what [PartDef.size] measures.
    PartCategory.parachute:
        (shape: PartStandInShape.cylinder, finish: _Finish.hull),
    PartCategory.science: (shape: PartStandInShape.box, finish: _Finish.panel),
    PartCategory.rcsThruster: (shape: PartStandInShape.box, finish: _Finish.dark),
    // Blunt face AFT (the wide end is on -Z): the shield is the last thing
    // between the craft and the airstream, and it must look like it.
    PartCategory.heatShield: (shape: PartStandInShape.nose, finish: _Finish.dark),
    PartCategory.structural: (shape: PartStandInShape.box, finish: _Finish.hull),
  };

  /// The last resort: a part this file has no opinion about is still drawn, and
  /// is drawn as the shape that claims the least.
  static const _StandIn _fallback =
      (shape: PartStandInShape.box, finish: _Finish.hull);

  /// Floor on a stand-in's box, METRES. A [PartDef] with a zero extent on some
  /// axis would otherwise collapse its silhouette to an invisible plane.
  static const double minExtentM = 0.01;

  /// Per-axis factor that takes [def]'s silhouette from the box the mesh is
  /// AUTHORED in to the box [PartDef.size] declares. Dimensionless (metres per
  /// authored metre); a caller working in scene units converts each component
  /// with `lengthToScene`.
  ///
  /// Non-uniform on purpose — a 1.25 x 1.25 x 1.9 m tank is not a cube — and
  /// divided by the primitive's OWN authored extent, because the primitives are
  /// not all unit cubes: [PartPrimitives.slab] is 1.0 x 0.4 x 0.06, so a bare
  /// [PartDef.size] would draw a 3.22 m landing leg 0.19 m deep. Dividing makes
  /// the DRAWN box equal the declared box, which is what lets the editor's
  /// OBB picking hit exactly the silhouette on screen and what lets a craft
  /// look the same in the VAB and in flight.
  ///
  /// Every component is strictly positive: [PartStandInShape.authoredExtentM]
  /// is, and the numerator is floored at [minExtentM].
  static Vector3 standInScaleM(PartDef def) {
    final extent = authoredExtentM(def);
    double side(double s) => s > minExtentM ? s : minExtentM;
    return Vector3(
      side(def.size.x) / extent.x,
      side(def.size.y) / extent.y,
      side(def.size.z) / extent.z,
    );
  }

  /// The box the mesh [forPart] returns is AUTHORED in, metres — the
  /// denominator of [standInScaleM], and the number a test multiplies that
  /// scale back through to recover the drawn box.
  ///
  /// A procedural part's mesh is generated at TRUE size, so its authored
  /// extent is its own spec's — and because the catalog pins spec == size,
  /// the resulting scale is exactly 1 per axis for the shipped roster. Going
  /// through the division anyway keeps the invariant structural: a def whose
  /// spec and size ever disagreed would still draw filling its declared
  /// (picked) box. Pure and GPU-free, like [shapeFor].
  static Vector3 authoredExtentM(PartDef def) =>
      def.procShape?.extentM ?? shapeFor(def).authoredExtentM;

  /// The type-key substrings the id tier has a shaped silhouette for.
  static Iterable<String> get idShapeKeys => _byIdKey.keys;

  /// Whether the id tier answers for [id], i.e. whether tier one shapes it.
  ///
  /// Pure and GPU-free on purpose: building an [fs.Mesh] needs an Impeller
  /// context and cannot run in a headless test, so the TIER CHOICE is the part
  /// of this file a test can pin.
  static bool hasIdShape(String id) {
    final t = id.toLowerCase();
    for (final key in _byIdKey.keys) {
      if (t.contains(key)) return true;
    }
    return false;
  }

  /// Whether [c] has a shape of its own, i.e. whether tier two answers for it
  /// rather than falling through to the cuboid. Pure, so the tier map's
  /// coverage of the catalog is assertable without a GPU.
  static bool hasCategoryShape(PartCategory c) => _byCategory.containsKey(c);

  /// The silhouette [def] draws as, whichever tier answers.
  ///
  /// Pure and GPU-free, which is what lets a test assert the relation between
  /// the mesh a part gets and the box it is scaled into. Keyed off [PartDef.id]
  /// rather than [PartDef.name]: names are display text and change with the
  /// copy, ids do not.
  static PartStandInShape shapeFor(PartDef def) => _rowFor(def).shape;

  /// The mesh to draw [def] with.
  ///
  /// TIER ZERO: a def carrying a [PartDef.procShape] gets its GENERATED mesh —
  /// for such a part this is not a stand-in but the art itself, which is why
  /// the spec outranks both the id table and the category (an id like
  /// `sphere-tank-s` contains 'tank' and would otherwise draw as the id
  /// tier's cylinder).
  ///
  /// Built per call and never cached: an [fs.Mesh] is bound into the node that
  /// draws it, so one shared instance would couple every part using it.
  static fs.Mesh forPart(PartDef def) {
    final proc = def.procShape;
    if (proc != null) return ProcPartGeometry.meshFor(proc);
    return _mesh(_rowFor(def));
  }

  /// The mesh for a category; the cuboid for one this file does not shape.
  static fs.Mesh forCategory(PartCategory c) => _mesh(_byCategory[c] ?? _fallback);

  static _StandIn _rowFor(PartDef def) {
    final t = def.id.toLowerCase();
    for (final e in _byIdKey.entries) {
      if (t.contains(e.key)) return e.value;
    }
    return _byCategory[def.category] ?? _fallback;
  }

  static fs.Mesh _mesh(_StandIn row) =>
      fs.Mesh(_geometry(row.shape), _material(row.finish));

  /// The geometry for a shape. Exhaustive by construction — [PartStandInShape]
  /// is this file's own closed set, so a new shape must state its mesh here as
  /// well as its extent there, and the two cannot be added apart.
  static fs.MeshGeometry _geometry(PartStandInShape shape) => switch (shape) {
        PartStandInShape.nose => PartPrimitives.cone(),
        PartStandInShape.nozzle => PartPrimitives.cone(flip: true),
        PartStandInShape.cylinder => PartPrimitives.cylinder(),
        PartStandInShape.box => fs.CuboidGeometry(vm.Vector3(1.0, 1.0, 1.0)),
        PartStandInShape.slab => PartPrimitives.slab(),
      };

  static fs.Material _material(_Finish finish) => switch (finish) {
        _Finish.hull => PartPrimitives.hull(),
        _Finish.dark => PartPrimitives.dark(),
        _Finish.panel => PartPrimitives.panel(),
      };
}
