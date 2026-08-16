// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../parts/attach_node.dart';
import '../parts/part_def.dart';
import '../shared/quaternion.dart';
import '../shared/vector3.dart';

/// Where a mate puts a part: its origin and orientation in the CRAFT body
/// frame (metres, Z-up, nose on +Z).
///
/// Deliberately not a [PlacedPart] — the solver answers a geometry question and
/// has no opinion about instance ids, staging, or whether the caller will keep
/// the result. [CraftDesign] is what turns one of these into a placed part.
class MateResult {
  final Vector3 position;
  final Quaternion rotation;

  const MateResult({required this.position, required this.rotation});

  @override
  String toString() => 'MateResult($position, $rotation)';
}

/// A mate the solver found for a part the editor is dragging.
///
/// Carries the identity of both ends so the caller can record a
/// [PartAttachment] without re-running the search, plus the [gap] it closed —
/// the editor ranks by that and can fade a snap indicator as the part nears.
class SnapCandidate {
  /// `PlacedPart.instanceId` of the part being mated to.
  final String parentInstanceId;

  /// [AttachNode.name] on the parent.
  final String parentNode;

  /// [AttachNode.name] on the dragged part.
  final String childNode;

  /// Where the mate puts the dragged part's origin (body frame, metres).
  final Vector3 position;

  /// The orientation the mate forces on the dragged part.
  final Quaternion rotation;

  /// Distance in metres between the two nodes BEFORE snapping. The search key;
  /// also what a UI uses to show how strong the snap is.
  final double gap;

  const SnapCandidate({
    required this.parentInstanceId,
    required this.parentNode,
    required this.childNode,
    required this.position,
    required this.rotation,
    required this.gap,
  });

  MateResult get mate => MateResult(position: position, rotation: rotation);

  @override
  String toString() => 'SnapCandidate($parentInstanceId.$parentNode <- '
      '$childNode, gap ${gap.toStringAsFixed(3)}m)';
}

/// The geometry behind part snapping and symmetry.
///
/// Stateless and deterministic: every method is a pure function of its
/// arguments, so the editor, a replay, and a test all get identical placements.
/// Everything is METRES in the craft BODY frame (Z-up, nose on +Z).
///
/// What a mate means here: the two [AttachNode]s end up at the same point and
/// their outward directions end up ANTI-parallel. That single rule covers both
/// kinds — a stack mate lines two rings up nose-to-tail, and a surface mate
/// presses the child's mount face into the parent's skin, which necessarily
/// leaves the rest of the child pointing outward.
class AttachSolver {
  /// How far a dragged node may sit from a target node and still snap (m).
  /// Roughly a part-radius; large enough to feel magnetic, small enough that
  /// two nearby nodes do not fight over the same part.
  final double snapRadius;

  /// Relative slop allowed between two [AttachNode.size] classes on a STACK
  /// mate, as a fraction of the larger. 0.05 accepts float noise in an authored
  /// 1.25 but rejects 1.25-to-2.5.
  final double sizeTolerance;

  const AttachSolver({this.snapRadius = 0.5, this.sizeTolerance = 0.05});

  /// Default tuning, so call sites do not each invent a snap radius.
  static const AttachSolver standard = AttachSolver();

  // ---------------- primitive rotations ----------------

  /// The minimal rotation carrying unit vector [from] onto unit vector [to].
  ///
  /// Uses the half-way form q = (1 + a·b, a×b) normalized, which stays
  /// well-conditioned as the vectors approach parallel where an axis-angle
  /// build would divide by a vanishing sine. The anti-parallel case has no
  /// minimal answer — any axis perpendicular to [from] turns it through pi —
  /// so one is chosen deterministically rather than left to float noise.
  static Quaternion rotationBetween(Vector3 from, Vector3 to) {
    final a = from.normalized;
    final b = to.normalized;
    if (a.lengthSquared == 0 || b.lengthSquared == 0) return Quaternion.identity;

    final d = a.dot(b).clamp(-1.0, 1.0);
    if (d > 1 - 1e-12) return Quaternion.identity;
    if (d < -1 + 1e-12) {
      // Opposed: pick a stable perpendicular. Cross with the axis [a] is least
      // aligned with, so the cross product never collapses.
      final alt = a.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
      return Quaternion.axisAngle(a.cross(alt), math.pi);
    }
    final c = a.cross(b);
    return Quaternion(1 + d, c.x, c.y, c.z).normalized;
  }

  /// Reflection of a point across the plane through the craft origin with unit
  /// normal [planeNormal].
  static Vector3 mirrorPosition(Vector3 p, Vector3 planeNormal) {
    final n = planeNormal.normalized;
    if (n.lengthSquared == 0) return p;
    return p - n * (2 * p.dot(n));
  }

  /// A body-frame attach node reflected across the plane through the craft
  /// origin with unit normal [planeNormal]: the seat reflects as a point, the
  /// outward normal as a free vector. Name, size, and kind are untouched.
  static AttachNode mirrorNode(AttachNode nodeInBody, Vector3 planeNormal) {
    final n = planeNormal.normalized;
    if (n.lengthSquared == 0) return nodeInBody;
    final d = nodeInBody.direction;
    return AttachNode(
      name: nodeInBody.name,
      position: mirrorPosition(nodeInBody.position, n),
      direction: d - n * (2 * d.dot(n)),
      size: nodeInBody.size,
      kind: nodeInBody.kind,
    );
  }

  // ---------------- mating ----------------

  /// Solve where a part must sit so [childNodeLocal] mates with
  /// [parentNodeInBody].
  ///
  /// [parentNodeInBody] is already expressed in the craft body frame (use
  /// `PlacedPart.nodeInBody`); [childNodeLocal] is the raw catalog node, in the
  /// child's own frame. [roll] spins the child about the mate axis in radians —
  /// the one degree of freedom a mate leaves open, which the editor exposes as
  /// "rotate part" without breaking the joint.
  ///
  /// Throws [ArgumentError] if either node carries a degenerate direction; a
  /// zero normal has no meaningful "out of the part" and would silently place
  /// the child at an arbitrary attitude.
  MateResult solveMate({
    required AttachNode parentNodeInBody,
    required AttachNode childNodeLocal,
    double roll = 0,
  }) {
    if (parentNodeInBody.direction.lengthSquared == 0 ||
        childNodeLocal.direction.lengthSquared == 0) {
      throw ArgumentError(
          'attach node direction must be a non-zero outward normal');
    }
    // The child's outward normal must end up facing back into the parent.
    final target = -parentNodeInBody.direction.normalized;
    var rotation = rotationBetween(childNodeLocal.direction, target);
    if (roll != 0) {
      // Extrinsic: align first, then spin about the (body-frame) mate axis.
      rotation = (Quaternion.axisAngle(target, roll) * rotation).normalized;
    }
    // Put the child's node exactly on the parent's node.
    final position =
        parentNodeInBody.position - rotation.rotate(childNodeLocal.position);
    return MateResult(position: position, rotation: rotation);
  }

  /// Convenience over [solveMate] that resolves both nodes by name and refuses
  /// an incompatible pair, returning null instead of throwing so a drag can
  /// simply not snap.
  MateResult? mateTo({
    required PlacedPart parent,
    required String parentNode,
    required PartDef childDef,
    required String childNode,
    double roll = 0,
  }) {
    final pn = parent.nodeInBody(parentNode);
    final cn = childDef.node(childNode);
    if (pn == null || cn == null) return null;
    if (!kindsCompatible(pn, cn)) return null;
    if (!sizesCompatible(pn, cn)) return null;
    return solveMate(
        parentNodeInBody: pn, childNodeLocal: cn, roll: roll);
  }

  /// Stack mates to stack, surface to surface. A tank ring cannot bolt to a
  /// hull panel; that is a modelling error, not a near miss.
  bool kindsCompatible(AttachNode a, AttachNode b) => a.kind == b.kind;

  /// Diameter-class check.
  ///
  /// Enforced only for [AttachKind.stack], where the two rings physically butt
  /// together and a mismatch means the player wanted an adapter. Surface mounts
  /// are exempt on purpose: a 0.3 m RCS block bolts to a 4 m hull all day, and
  /// gating that on size would make most legitimate radial mounts impossible.
  bool sizesCompatible(AttachNode a, AttachNode b) {
    if (a.kind != AttachKind.stack || b.kind != AttachKind.stack) return true;
    final larger = math.max(a.size, b.size);
    if (larger <= 0) return true;
    return (a.size - b.size).abs() <= sizeTolerance * larger;
  }

  // ---------------- snapping ----------------

  /// Best mate for a part the editor is dragging, or null when nothing is in
  /// range or compatible.
  ///
  /// [position]/[rotation] are the dragged part's CURRENT free placement — the
  /// search measures from where its nodes are right now, so the snap the player
  /// gets is the one nearest the cursor rather than the nearest in the abstract.
  ///
  /// [isStackNodeOccupied] lets the caller veto a TARGET node that already
  /// carries a mate, and [isChildNodeOccupied] vetoes a node on the DRAGGED
  /// part that is already spent — a node whose own child hangs off it cannot
  /// also seat the part on a new parent, and offering that snap would produce a
  /// mate the caller has to refuse. Both are consulted for stack nodes only,
  /// since a surface node hosts many.
  ///
  /// [exclude] skips instance ids that must not be mated to — at minimum the
  /// dragged part itself and everything hanging off it, or the design would
  /// grow a cycle.
  SnapCandidate? findSnap({
    required Iterable<PlacedPart> parts,
    required PartDef def,
    required Vector3 position,
    Quaternion rotation = Quaternion.identity,
    double? radius,
    bool Function(String instanceId, String nodeName)? isStackNodeOccupied,
    bool Function(String nodeName)? isChildNodeOccupied,
    Set<String> exclude = const {},
  }) {
    final limit = radius ?? snapRadius;
    final limitSq = limit * limit;
    SnapCandidate? best;
    var bestGapSq = double.infinity;

    for (final childNode in def.attachNodes) {
      if (childNode.kind == AttachKind.stack &&
          (isChildNodeOccupied?.call(childNode.name) ?? false)) {
        continue;
      }
      // Where this node of the dragged part currently sits in the body frame.
      final childAt = position + rotation.rotate(childNode.position);

      for (final parent in parts) {
        if (exclude.contains(parent.instanceId)) continue;

        for (final raw in parent.def.attachNodes) {
          if (!kindsCompatible(raw, childNode)) continue;
          if (!sizesCompatible(raw, childNode)) continue;

          final pn = parent.nodeInBody(raw.name)!;
          final gapSq = (pn.position - childAt).lengthSquared;
          if (gapSq > limitSq || gapSq >= bestGapSq) continue;

          if (raw.kind == AttachKind.stack &&
              (isStackNodeOccupied?.call(parent.instanceId, raw.name) ??
                  false)) {
            continue;
          }

          final mate =
              solveMate(parentNodeInBody: pn, childNodeLocal: childNode);
          bestGapSq = gapSq;
          best = SnapCandidate(
            parentInstanceId: parent.instanceId,
            parentNode: raw.name,
            childNode: childNode.name,
            position: mate.position,
            rotation: mate.rotation,
            gap: math.sqrt(gapSq),
          );
        }
      }
    }
    return best;
  }

  // ---------------- symmetry ----------------

  /// [count] copies of a placement spun evenly about [axis] (the craft's +Z by
  /// default), the original included as element 0.
  ///
  /// This is what makes four RCS quads a single click: each copy is rotated
  /// about the craft axis by k*2pi/count, and crucially its ORIENTATION is
  /// carried through the same rotation, so copy 1 of a block that faced +X
  /// faces +Y rather than sitting at +Y still facing +X.
  ///
  /// Throws [ArgumentError] for [count] < 2 or a degenerate axis.
  List<MateResult> radialCopies({
    required Vector3 position,
    required Quaternion rotation,
    required int count,
    Vector3 axis = Vector3.unitZ,
  }) {
    if (count < 2) {
      throw ArgumentError.value(count, 'count', 'radial symmetry needs >= 2');
    }
    if (axis.lengthSquared == 0) {
      throw ArgumentError.value(axis, 'axis', 'symmetry axis must be non-zero');
    }
    final step = 2 * math.pi / count;
    return [
      for (var k = 0; k < count; k++)
        if (k == 0)
          MateResult(position: position, rotation: rotation)
        else
          _spun(position, rotation, axis, step * k),
    ];
  }

  MateResult _spun(Vector3 p, Quaternion r, Vector3 axis, double angle) {
    final q = Quaternion.axisAngle(axis, angle);
    return MateResult(
      position: q.rotate(p),
      rotation: (q * r).normalized,
    );
  }

  /// The mirror-image mate: the same child mated to the REFLECTION of
  /// [parentNodeInBody] across the plane through the craft origin with normal
  /// [planeNormal] (the YZ plane by default — the one that turns a left wing
  /// into a right wing).
  ///
  /// Mirroring is done on the JOINT, not on the finished placement, and that is
  /// deliberate. Reflection is improper, so no rotation reproduces it: any
  /// attempt to "reflect an orientation" silently flips one of the part's axes,
  /// and for a surface mount that axis is usually the mount face — the copy
  /// ends up seated backwards, pointing into the hull. Reflecting the node and
  /// re-solving gives a placement that is a genuine rotation AND still bolted
  /// down. What is lost is chirality: a truly handed part comes out as itself
  /// on the other side, which is a job for a mirrored MESH, not for geometry.
  ///
  /// [roll] is negated relative to the seed because a reflection reverses the
  /// sense of a spin about the mate axis; passing the seed's roll straight
  /// through would break the symmetry it was asked to create.
  ///
  /// Unlike [radialCopies] this returns ONLY the reflected copy; the caller
  /// already has the original.
  MateResult mirrorMate({
    required AttachNode parentNodeInBody,
    required AttachNode childNodeLocal,
    Vector3 planeNormal = Vector3.unitX,
    double roll = 0,
  }) {
    if (planeNormal.lengthSquared == 0) {
      throw ArgumentError.value(
          planeNormal, 'planeNormal', 'mirror plane normal must be non-zero');
    }
    return solveMate(
      parentNodeInBody: mirrorNode(parentNodeInBody, planeNormal),
      childNodeLocal: childNodeLocal,
      roll: -roll,
    );
  }

  /// True when reflecting [nodeInBody] leaves it exactly where it was — the
  /// node lies on the mirror plane and faces along it. Mirroring such a mount
  /// would stack the copy on top of the original, so callers reject it rather
  /// than build two coincident parts.
  bool nodeLiesOnMirrorPlane(AttachNode nodeInBody, Vector3 planeNormal) {
    final m = mirrorNode(nodeInBody, planeNormal);
    return (m.position - nodeInBody.position).length < 1e-9 &&
        (m.direction - nodeInBody.direction).length < 1e-9;
  }
}
