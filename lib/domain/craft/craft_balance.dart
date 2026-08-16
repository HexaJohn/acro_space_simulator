// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../parts/attach_node.dart';
import '../parts/part_def.dart';
import '../shared/vector3.dart';
import 'craft_design.dart';

/// The mass, thrust and staging reads an editor draws on top of a craft, none of
/// which [CraftDesign] should own: the design is structure and geometry, and
/// these are questions about the vehicle that structure describes.
///
/// Every method is a pure read over the design's public API. Nothing here is
/// cached — a craft is tens of parts and these run once per structural change,
/// not per frame — and nothing here mutates except [autoStage], which says so.
///
/// Units are METRES and KILOGRAMS in the craft body frame: Z-up, nose on +Z.
class CraftBalance {
  const CraftBalance._();

  /// The direction a part's engine throws its exhaust, in the PART frame.
  ///
  /// The nose is +Z, so a nozzle fires aft. This is the axis [thrust] carries
  /// through each part's rotation.
  static const Vector3 _exhaustAxisLocal = Vector3(0, 0, -1);

  /// Dry mass plus the mass of everything in the part's tanks (kg).
  ///
  /// Deliberately a re-derivation of `VesselAssembler._partMass` rather than a
  /// call into it: that method is private and its file is owned elsewhere.
  /// `craft_balance_test.dart` asserts these totals equal
  /// `VesselAssembler.assemble(...).mass` for the same parts, so the two cannot
  /// drift — a VAB whose centre of mass disagrees with the craft that flies is
  /// worse than a VAB with no marker at all.
  ///
  /// Reads the DEF's containers, which are full by construction: the editor
  /// weighs a craft as it would leave the pad, and the per-part copies that hold
  /// burn state only exist after the bake.
  static double partMass(PartDef def) =>
      def.dryMass + def.resources.fold(0.0, (sum, r) => sum + r.mass);

  /// Mass-weighted mean of the placed part origins — the loaded craft's centre
  /// of mass, in craft-frame metres.
  ///
  /// Part origins, not part centroids: [PlacedPart.position] IS the part's
  /// origin and the catalog measures each part's box about it, which is the same
  /// point `VesselAssembler` builds its mass properties from. Using anything
  /// else here would put the editor's marker somewhere the physics never sees.
  ///
  /// A design with no parts, or no mass, reports the origin.
  static Vector3 centreOfMass(CraftDesign design) =>
      _weightedMean(design, partMass);

  /// The same, over DRY mass only: where the craft balances at burnout.
  ///
  /// Worth showing beside [centreOfMass] because the gap between them is how far
  /// the centre of mass travels during the burn, and a craft that is stable full
  /// and unstable empty is a craft that flips at staging.
  static Vector3 dryCentreOfMass(CraftDesign design) =>
      _weightedMean(design, (def) => def.dryMass);

  /// Summed engine thrust: application point, unit direction, newtons. Null when
  /// the craft carries no rocket engine.
  ///
  /// [direction] is the EXHAUST axis — part-local -Z carried through each
  /// engine's rotation — so the reaction on the craft is along `-direction`.
  /// That is the axis an editor draws as a line from [origin] and compares
  /// against the centre of mass: a thrust line that misses the centre of mass
  /// torques the craft every time the engine lights.
  ///
  /// [thrustN] is the NET, vector-summed magnitude at vacuum rating, so two
  /// opposed engines report the thrust they actually produce rather than the sum
  /// of their labels. When they cancel exactly the magnitude is zero and
  /// [direction] falls back to the craft's nominal exhaust axis, since there is
  /// no measured one.
  ///
  /// Rocket engines only. A `JetEngine` carries no vacuum rating and its static
  /// thrust is Mach-dependent, so an air-breathing craft has no meaningful
  /// single number here; it reports null rather than a made-up one.
  ///
  /// Note the flight model does NOT read per-part rotation: `_ThrustForce`
  /// pushes the baked rigid body along body +Z whatever the parts are turned to.
  /// This is an editor read of how the engines are actually pointed, and a
  /// difference between the two is a real finding about the craft.
  static ({Vector3 origin, Vector3 direction, double thrustN})? thrust(
      CraftDesign design) {
    var axis = Vector3.zero;
    var weightedOrigin = Vector3.zero;
    var centroid = Vector3.zero;
    var rating = 0.0;
    var engines = 0;

    for (final p in design.parts) {
      final engine = p.def.rocketEngine;
      if (engine == null) continue;
      engines++;
      centroid = centroid + p.position;
      final newtons = engine.maxThrustVacuum;
      axis = axis + p.rotation.rotate(_exhaustAxisLocal) * newtons;
      weightedOrigin = weightedOrigin + p.position * newtons;
      rating += newtons;
    }
    if (engines == 0) return null;

    // Thrust-weighted mean of the engine seats; an unrated engine still has a
    // position, so a roster of zero-thrust engines falls back to their centroid
    // instead of dividing by nothing.
    final origin =
        rating > 0 ? weightedOrigin / rating : centroid / engines.toDouble();
    final net = axis.length;
    return (
      origin: origin,
      direction: net < 1e-9 ? _exhaustAxisLocal : axis / net,
      thrustN: net,
    );
  }

  /// Craft-frame axis-aligned bounds over the union of the part boxes, each
  /// carried through its own rotation. Null for an empty design.
  ///
  /// Every part's eight box corners are projected, not just its origin: a
  /// landing leg reaches 2.5 m out from a seat on the hull, and framing a camera
  /// on origins alone would cut the gear off every LM.
  static ({Vector3 min, Vector3 max})? bounds(CraftDesign design) {
    if (design.isEmpty) return null;
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;

    for (final p in design.parts) {
      final half = p.def.size * 0.5;
      for (final sx in const [-1.0, 1.0]) {
        for (final sy in const [-1.0, 1.0]) {
          for (final sz in const [-1.0, 1.0]) {
            final corner = p.position +
                p.rotation
                    .rotate(Vector3(sx * half.x, sy * half.y, sz * half.z));
            if (corner.x < minX) minX = corner.x;
            if (corner.y < minY) minY = corner.y;
            if (corner.z < minZ) minZ = corner.z;
            if (corner.x > maxX) maxX = corner.x;
            if (corner.y > maxY) maxY = corner.y;
            if (corner.z > maxZ) maxZ = corner.z;
          }
        }
      }
    }
    return (min: Vector3(minX, minY, minZ), max: Vector3(maxX, maxY, maxZ));
  }

  /// Re-group every part into staging groups derived from the attach tree, then
  /// [CraftDesign.renumberStages] to squeeze the result dense. MUTATES [design].
  ///
  /// ## The rule
  ///
  /// Walk each root's tree outward. A part opens a NEW group when either
  ///
  ///   * it is a [PartCategory.decoupler] — the decoupler and everything hanging
  ///     below it leave together, which is the entire point of the part; or
  ///   * it is STACK-mated to an engine — an engine is the bottom of its stack,
  ///     so anything bolted under one belongs to the next thing to fire.
  ///
  /// Anything else inherits its parent's group. Surface mounts never open a
  /// group: an RCS quad or a landing leg rides whatever hull it is bolted to,
  /// and that is why the stack-mate qualifier is on the engine test — an ascent
  /// stage that carries its own engine would otherwise push its own RCS quads
  /// into the stage below and leave them on the Moon.
  ///
  /// ## Why the numbering runs this way
  ///
  /// Group 0 sits at the root and the index grows outward, so the group farthest
  /// from the root — the boosters at the bottom — carries the HIGHEST index.
  /// That is what the flight model means by a stage: `Vessel.activeStage` is
  /// `stages.last` and `Vessel.separateStage()` drops the last, so the highest
  /// index is the one that burns and separates first. It is also the direction
  /// the old assembly screen's `stage: _placed.length` ran, without its "every
  /// part is its own stage" artefact.
  ///
  /// Keeping a tank and the engine it feeds in ONE group is not cosmetic:
  /// `Vessel.deltaVCapacity()` sums propellant over the active stage only, so a
  /// rule that split them would report a stage with an engine and no fuel as
  /// having no delta-v at all.
  static void autoStage(CraftDesign design) {
    final group = <String, int>{};
    for (final root in design.roots) {
      // Parents before children, so a parent's group is always decided by the
      // time its child asks for it.
      for (final id in design.subtreeIds(root.instanceId)) {
        final part = design.partById(id)!;
        final mate = part.attachment;
        if (mate == null) {
          group[id] = 0;
          continue;
        }
        final parent = design.partById(mate.parentInstanceId);
        final parentGroup = group[mate.parentInstanceId] ?? 0;
        group[id] = parentGroup + (_opensStage(part, parent) ? 1 : 0);
      }
    }

    final ids = [for (final p in design.parts) p.instanceId];
    for (final id in ids) {
      design.assignStage(id, group[id] ?? 0);
    }
    design.renumberStages();
  }

  /// True when [part] begins a staging group of its own. [parent] is the part it
  /// is mated to, already resolved.
  static bool _opensStage(PlacedPart part, PlacedPart? parent) {
    if (part.def.category == PartCategory.decoupler) return true;
    if (parent == null) return false;
    final seat = parent.def.node(part.attachment!.parentNode);
    if (seat == null || seat.kind != AttachKind.stack) return false;
    return parent.def.isEngine;
  }

  static Vector3 _weightedMean(
      CraftDesign design, double Function(PartDef) weightOf) {
    var total = 0.0;
    var weighted = Vector3.zero;
    for (final p in design.parts) {
      final w = weightOf(p.def);
      total += w;
      weighted = weighted + p.position * w;
    }
    return total > 0 ? weighted / total : Vector3.zero;
  }
}
