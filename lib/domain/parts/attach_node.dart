// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../shared/quaternion.dart';
import '../shared/vector3.dart';

/// How two parts meet at an attach node.
///
/// The distinction matters to the editor, not to the physics bake: a [stack]
/// mate is axial (a tank's top ring to an engine's bell ring) and pairs with
/// exactly one opposing node, while a [surface] mate is radial (an RCS block or
/// a landing leg on a hull) and can host many children anywhere it is exposed.
enum AttachKind {
  /// Axial mate: the two nodes' directions are made anti-parallel and their
  /// positions coincide, so parts line up nose-to-tail along the stack.
  stack,

  /// Radial mate: the child's node is seated against the parent's skin, the
  /// child spun so its node points back along the parent's outward normal.
  surface,
}

/// A named mating point on a part.
///
/// Coordinates are PART LOCAL and Z-UP (the same body convention the vessel
/// uses, nose on +Z), in METRES. [direction] is a unit vector pointing OUT of
/// the part — away from the material — so two mating nodes always face each
/// other. [size] is the mating diameter class in metres (1.25, 2.5, ...); the
/// editor uses it to reject nonsense mates and to pick an adapter, it is not a
/// physical dimension of the part.
///
/// Nodes are pure geometry. They carry no reference to the part that owns them
/// and no reference to what is attached — [PartAttachment] on the placed part
/// records that, so a node list stays shareable across every instance of a
/// catalog part.
class AttachNode {
  /// Unique within one part. Referenced by name from [PartAttachment], so
  /// renaming a node breaks saved designs — treat these as stable ids.
  final String name;

  /// Where the node sits in part-local metres (Z-up).
  final Vector3 position;

  /// Unit normal pointing out of the part at [position].
  final Vector3 direction;

  /// Mating diameter class in metres.
  final double size;

  final AttachKind kind;

  const AttachNode({
    required this.name,
    required this.position,
    this.direction = Vector3.unitZ,
    this.size = 1.25,
    this.kind = AttachKind.stack,
  });

  /// This node expressed in the frame the part is rotated into.
  ///
  /// Needed to express a mate at all: the editor solves child placement as
  /// `parentPos + parentRot·parentNode.position - childRot·childNode.position`,
  /// which requires both the position AND the outward direction carried through
  /// the same rotation. Pure — returns a new node, name/size/kind unchanged.
  AttachNode rotated(Quaternion q) => AttachNode(
        name: name,
        position: q.rotate(position),
        direction: q.rotate(direction),
        size: size,
        kind: kind,
      );

  @override
  String toString() => 'AttachNode($name, ${kind.name}, size $size)';
}

/// Records that a placed part is mated to another placed part.
///
/// Keeping the parent's INSTANCE id (not its catalog id) plus the two node
/// names is enough to rebuild the assembly tree, re-solve a moved subtree, or
/// detach a branch — the geometry itself lives in the placed part's position
/// and rotation, which stay authoritative for the bake. A placed part with no
/// attachment is a root (or a free-floating part the editor has not mated yet).
class PartAttachment {
  /// [PlacedPart.instanceId] of the part this one hangs off.
  final String parentInstanceId;

  /// [AttachNode.name] on the parent that is consumed by this mate.
  final String parentNode;

  /// [AttachNode.name] on THIS part that is consumed by this mate.
  final String childNode;

  const PartAttachment({
    required this.parentInstanceId,
    required this.parentNode,
    required this.childNode,
  });

  @override
  String toString() =>
      'PartAttachment($parentInstanceId.$parentNode <- $childNode)';
}
