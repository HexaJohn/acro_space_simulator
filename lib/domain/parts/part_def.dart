// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../vessel/docking_port.dart';
import '../vessel/propulsion.dart';
import '../vessel/resource_container.dart';
import 'attach_node.dart';
import 'jet_engine.dart';
import 'lifting_surface.dart';
import 'proc_shape.dart';

enum PartCategory {
  commandPod, // crewed control + reaction wheels
  fuelTank,
  rocketEngine,
  jetEngine,
  intake, // feeds air to jet engines
  wing, // lifting surface
  controlSurface, // movable lifting surface (aileron/elevator/rudder)
  structural,
  decoupler, // stage separation
  landingGear,
  parachute,
  science,
  rcsThruster,
  heatShield,
}

/// A catalog template for a part: the immutable spec the [VesselAssembler]
/// stamps into a concrete [Part]/sub-part when assembling a craft. One [PartDef]
/// can describe a rocket part, an aircraft part, or a utility part depending on
/// which optional capability it carries.
class PartDef {
  final String id;
  final String name;
  final PartCategory category;
  final double dryMass; // kg

  /// Bounding size (m), used for inertia + stacking. (x,y,z).
  final Vector3 size;

  /// Drag profile.
  final double dragCoefficient;
  final double crossSectionArea; // m^2
  final double maxTemperature; // K

  // Optional capabilities — at most one of the engine kinds is set.
  final Engine? rocketEngine;
  final JetEngine? jetEngine;
  final LiftingSurface? wing;
  final List<ResourceContainer> resources; // tanks, monoprop, etc.
  final DockingPort? dockingPort;
  final double intakeArea; // air provided to jets (intake parts)
  final int crewCapacity; // command pods
  final double ablator; // heat shields

  // ---------------- Render binding ----------------
  // The sim does not need any of this to fly a craft; it travels so the editor
  // and the renderer agree on what a part LOOKS like without a second table
  // keyed off names that change.

  /// Baked mesh for this part (an `assets/mesh/*.fsceneb` path), or null when
  /// the part has no art yet and the renderer must fall back to a procedural
  /// stand-in. Keyed off [id], never [name] — names are display text.
  final String? modelAsset;

  /// Model units -> METRES. The bakes come out of glTF at whatever scale the
  /// artist worked in; this is the one multiplier that makes a part the size
  /// its [size] box claims.
  final double modelScale;

  /// Extra body-frame correction applied ON TOP of the standard glTF Y-up ->
  /// Z-up fix, for models whose authored axis is not the nose. Identity for a
  /// model already baked nose-on-+Z.
  final Quaternion modelRotation;

  /// Where the model sits relative to the PART ORIGIN: METRES, part-local frame
  /// (Z-up, nose on +Z), applied AFTER [modelScale] and [modelRotation] and
  /// BEFORE the part's placement in the craft.
  ///
  /// An export's origin is wherever the exporter left it, which is rarely the
  /// geometric centre that [size] and [attachNodes] are measured from. Without
  /// this the art hangs off the joints the domain believes in. The value is the
  /// translation that brings the mesh back onto the origin, so a model whose
  /// geometry sits 0.4 m too low needs `Vector3(0, 0, 0.4)`.
  ///
  /// ART ONLY. Mass, centre of mass, inertia, attach nodes, docking ports and
  /// every other physical quantity are anchored to the part origin and never
  /// see this — moving it re-seats the picture, never the craft.
  final Vector3 modelOffset;

  /// The parametric recipe for a GENERATED mesh, or null for a part whose art
  /// is baked (or pending). Mutually exclusive with [modelAsset]: a def
  /// carrying both would have the renderer race a bake against a generator for
  /// the same slot. A procedural part's spec must agree with [size]
  /// ([ProcShape.extentM] equal component for component), so the drawn box,
  /// the declared box and the editor's picked box are one box by construction
  /// — `proc_parts_catalog_test` pins that for the shipped roster.
  final ProcShape? procShape;

  /// Where other parts may mate to this one. Empty means the part cannot be
  /// attached to (or from) — the editor then only allows free placement.
  final List<AttachNode> attachNodes;

  const PartDef({
    required this.id,
    required this.name,
    required this.category,
    required this.dryMass,
    this.size = const Vector3(1, 1, 1),
    this.dragCoefficient = 0.2,
    this.crossSectionArea = 1.0,
    this.maxTemperature = 2000,
    this.rocketEngine,
    this.jetEngine,
    this.wing,
    this.resources = const [],
    this.dockingPort,
    this.intakeArea = 0,
    this.crewCapacity = 0,
    this.ablator = 0,
    this.modelAsset,
    this.modelScale = 1.0,
    this.modelRotation = Quaternion.identity,
    this.modelOffset = Vector3.zero,
    this.procShape,
    this.attachNodes = const [],
  }) : assert(modelAsset == null || procShape == null,
            'a part is baked or generated, never both');

  bool get isEngine => rocketEngine != null || jetEngine != null;

  /// The named attach node, or null. Linear scan — parts carry a handful of
  /// nodes, so an index would cost more than it saves.
  AttachNode? node(String name) {
    for (final n in attachNodes) {
      if (n.name == name) return n;
    }
    return null;
  }
}

/// A [PartDef] placed at a position/orientation within a craft being assembled.
class PlacedPart {
  final PartDef def;
  final String instanceId;
  final Vector3 position; // m, relative to the craft origin
  final int stage; // staging group index

  /// Orientation of the part within the craft body frame (Z-up, nose on +Z).
  /// Identity means the part sits the way it was authored. Radial parts (RCS
  /// blocks, legs, side boosters) are turned by this, not by a second mesh.
  final Quaternion rotation;

  /// The mate that put this part where it is, or null for a root/free part.
  ///
  /// [position] and [rotation] stay authoritative — the assembler never
  /// re-solves geometry from this. It exists so the editor can walk the tree
  /// to move or detach a whole subtree, and so a saved design reloads with its
  /// structure intact rather than as a pile of loose coordinates.
  final PartAttachment? attachment;

  const PlacedPart({
    required this.def,
    required this.instanceId,
    this.position = Vector3.zero,
    this.stage = 0,
    this.rotation = Quaternion.identity,
    this.attachment,
  });

  PlacedPart copyWith({
    Vector3? position,
    int? stage,
    Quaternion? rotation,
    PartAttachment? attachment,
    bool clearAttachment = false,
  }) =>
      PlacedPart(
        def: def,
        instanceId: instanceId,
        position: position ?? this.position,
        stage: stage ?? this.stage,
        rotation: rotation ?? this.rotation,
        attachment: clearAttachment ? null : (attachment ?? this.attachment),
      );

  /// [node] of this part's def, expressed in the CRAFT body frame (metres,
  /// origin at the craft origin). This is what a mate is solved against, so it
  /// lives here rather than being re-derived at each editor call site.
  AttachNode? nodeInBody(String name) {
    final n = def.node(name);
    if (n == null) return null;
    final r = n.rotated(rotation);
    return AttachNode(
      name: r.name,
      position: position + r.position,
      direction: r.direction,
      size: r.size,
      kind: r.kind,
    );
  }
}
