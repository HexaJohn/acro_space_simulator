// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../parts/attach_node.dart';
import '../parts/part_def.dart';
import '../shared/vector3.dart';
import 'attach_solver.dart';
import 'craft_design.dart';

/// An attach node on a placed part, expressed in the CRAFT body frame (metres,
/// Z-up, nose on +Z).
///
/// The editor's unit of "somewhere a part may go". [AttachNode] is part-local
/// and says nothing about which instance owns it; this pairs the geometry with
/// the owner so a marker can be projected, picked, and turned straight back into
/// an `attachPart` call without re-deriving anything.
class AttachTarget {
  /// [PlacedPart.instanceId] of the part carrying this node.
  final String ownerInstanceId;

  /// [AttachNode.name] on that part's def. Stable across saves — it is what a
  /// [PartAttachment] records.
  final String nodeName;

  /// The seat, in craft-frame metres.
  final Vector3 positionInCraft;

  /// Unit outward normal at the seat, carried through the owner's rotation.
  final Vector3 directionInCraft;

  /// Mating diameter class (m). Also drives marker radius on screen, which is
  /// why it is carried rather than looked up again.
  final double size;

  final AttachKind kind;

  const AttachTarget({
    required this.ownerInstanceId,
    required this.nodeName,
    required this.positionInCraft,
    required this.directionInCraft,
    required this.size,
    required this.kind,
  });

  /// Value equality over every field, matching [Vector3] and the rest of the
  /// domain's value objects.
  ///
  /// Deliberately NOT keyed on `(ownerInstanceId, nodeName)` alone: a target is
  /// a snapshot of where a node is right now, and re-mating the owner moves the
  /// seat without renaming it. An editor comparing "is this the same target I
  /// hovered last frame" wants the moved node to compare unequal, because the
  /// marker it drew is no longer where it drew it.
  @override
  bool operator ==(Object other) =>
      other is AttachTarget &&
      other.ownerInstanceId == ownerInstanceId &&
      other.nodeName == nodeName &&
      other.positionInCraft == positionInCraft &&
      other.directionInCraft == directionInCraft &&
      other.size == size &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(ownerInstanceId, nodeName, positionInCraft,
      directionInCraft, size, kind);

  @override
  String toString() =>
      'AttachTarget($ownerInstanceId.$nodeName, ${kind.name}, size $size)';
}

/// One of a held def's own nodes paired with one open [AttachTarget].
///
/// A pairing is a mate the domain has already agreed to: kinds match and, for a
/// stack mate, so do the diameter classes. Everything left is a choice — which
/// target the cursor is nearest, and which of the held part's nodes the player
/// wants seated (a decoupler has two) — so the editor ranks pairings rather than
/// re-deriving legality per frame.
class TargetPairing {
  final AttachTarget target;

  /// [AttachNode.name] on the part being placed.
  final String childNodeName;

  const TargetPairing({required this.target, required this.childNodeName});

  @override
  bool operator ==(Object other) =>
      other is TargetPairing &&
      other.target == target &&
      other.childNodeName == childNodeName;

  @override
  int get hashCode => Object.hash(target, childNodeName);

  @override
  String toString() => 'TargetPairing(${target.ownerInstanceId}.'
      '${target.nodeName} <- $childNodeName)';
}

/// A family of surface nodes forming an even ring about a part's local +Z:
/// `<prefix>-1`..`<prefix>-n`, all at one radius and one height, evenly spaced
/// in azimuth.
///
/// This is what makes symmetry data-driven rather than a rotation about the
/// craft origin. [AttachSolver.radialCopies] spins a seed placement about the
/// CRAFT axis and records every copy against the seed's single node: the
/// geometry lands right for an on-axis parent and is wrong for any other, and
/// the saved design then claims four parts share one node. A ring instead names
/// four real authored nodes, so four RCS quads are four ordinary mates — every
/// attachment survives `CraftDesign` validation and the codec, and the ring
/// works for an off-axis or rotated parent because each mate is solved against
/// that node's own `nodeInBody`.
///
/// [radius] and [height] are PART-LOCAL metres; the ring is a property of the
/// def, not of any placement of it.
class NodeRing {
  /// The shared name stem: `quad` for `quad-1`..`quad-4`.
  final String prefix;

  /// Member node names in ASCENDING AZIMUTH about part-local +Z, measured from
  /// +X toward +Y and normalised to `[0, 2pi)`. Ordering by angle rather than by
  /// the numeric suffix is what lets [subset] pick evenly spaced members and
  /// [mirrorPair] reason about opposites without re-reading the geometry.
  final List<String> nodeNames;

  /// Distance from the part's Z axis to every member, metres.
  final double radius;

  /// Part-local Z of every member, metres.
  final double height;

  const NodeRing({
    required this.prefix,
    required this.nodeNames,
    required this.radius,
    required this.height,
  });

  int get count => nodeNames.length;

  /// Index of [nodeName] in [nodeNames], or -1 — [List.indexOf]'s contract.
  int indexOf(String nodeName) => nodeNames.indexOf(nodeName);

  /// [n] evenly spaced members starting at [fromIndex].
  ///
  /// Requires `count % n == 0`; returns just `[nodeNames[fromIndex]]` otherwise,
  /// because three copies on a four-ring have nowhere even to sit and a UI that
  /// silently placed them anyway would produce a craft that yaws under thrust.
  /// The caller decides which counts to offer from [AttachTargets.symmetryCountsFor];
  /// this is the guard for the case it did not.
  ///
  /// Throws [RangeError] when [fromIndex] is not a member index — pass
  /// [indexOf]'s result only after checking it is not -1.
  List<String> subset(int n, int fromIndex) {
    RangeError.checkValidIndex(fromIndex, nodeNames, 'fromIndex');
    if (n < 2 || count % n != 0) return [nodeNames[fromIndex]];
    final step = count ~/ n;
    return [
      for (var k = 0; k < n; k++) nodeNames[(fromIndex + k * step) % count],
    ];
  }

  /// [fromIndex] plus the member nearest its reflection across the plane through
  /// the PART origin with normal [planeNormal].
  ///
  /// One element when the seat lies on the plane — its reflection is itself, and
  /// placing a mirror copy there would stack two parts in one hole. That is the
  /// same refusal [AttachSolver.nodeLiesOnMirrorPlane] makes, arrived at by
  /// asking which ring member is closest rather than by re-solving a mate.
  ///
  /// [def] supplies the member positions: a ring records names and its own
  /// radius/height, never a copy of the node coordinates, so it cannot drift
  /// from the catalog it was detected on.
  ///
  /// Throws [RangeError] when [fromIndex] is not a member index.
  List<String> mirrorPair(int fromIndex, Vector3 planeNormal, PartDef def) {
    RangeError.checkValidIndex(fromIndex, nodeNames, 'fromIndex');
    final seed = def.node(nodeNames[fromIndex]);
    if (seed == null) return [nodeNames[fromIndex]];

    final image = AttachSolver.mirrorPosition(seed.position, planeNormal);
    var best = fromIndex;
    var bestDistSq = double.infinity;
    for (var i = 0; i < count; i++) {
      final n = def.node(nodeNames[i]);
      if (n == null) continue;
      final d = (n.position - image).lengthSquared;
      if (d < bestDistSq) {
        bestDistSq = d;
        best = i;
      }
    }
    return best == fromIndex
        ? [nodeNames[fromIndex]]
        : [nodeNames[fromIndex], nodeNames[best]];
  }

  @override
  String toString() => 'NodeRing($prefix x$count, r $radius, h $height)';
}

/// Read-only queries over a [CraftDesign] that an attach-node editor needs and
/// the design itself has no business owning.
///
/// Every method here is a pure function of the design and the catalog, and
/// nothing here mutates either. That is what lets symmetry groups and roll
/// angles be DERIVED FROM GEOMETRY — they survive a codec round trip exactly,
/// with no schema change and no risk of a saved craft carrying a symmetry record
/// that no longer matches where its parts are.
///
/// Nothing keyed on a DESIGN is remembered — a design is mutable and any such
/// memo would be a second source of truth for where the parts are. [ringsOf] is
/// the one memo, and it is keyed on the immutable [PartDef]; see its doc.
///
/// Units are METRES in the craft body frame unless a member says part-local.
class AttachTargets {
  const AttachTargets._();

  /// Legality tuning for [pairingsFor].
  ///
  /// [CraftDesign] keeps its own solver private, so a design built with a
  /// non-standard [AttachSolver.sizeTolerance] would be offered pairings judged
  /// by the standard one. Nothing in the app builds a design that way; if
  /// something does, this is the line that has to learn about it.
  static const AttachSolver _solver = AttachSolver.standard;

  /// `<prefix>-<n>`: the shape `LemParts._ring()` authors its rings in, and the
  /// only naming a ring is recognised from.
  static final RegExp _memberPattern = RegExp(r'^(.+)-(\d+)$');

  /// [ringsOf]'s memo, keyed on the def INSTANCE. See that method for why the
  /// answer cannot go stale and why an [Expando] rather than a map.
  static final Expando<List<NodeRing>> _ringsByDef =
      Expando<List<NodeRing>>('AttachTargets.rings');

  /// How far two members' radii may differ and still be one ring (m).
  static const double _ringRadiusToleranceM = 0.01;

  /// How far two members' heights may differ and still be one ring (m).
  static const double _ringHeightToleranceM = 0.01;

  /// How far a member may sit from its even share of the circle (rad, 0.5 deg).
  static const double _ringAzimuthToleranceRad = 0.5 * math.pi / 180;

  /// Below this radius a node has no meaningful azimuth, so a family of them is
  /// a coincidence of names rather than a ring (m).
  static const double _ringMinRadiusM = 1e-6;

  /// Every node on every placed part that can still accept a child, in part
  /// insertion order and then in the order the def authors its nodes.
  ///
  /// Stack nodes already carrying a mate are excluded via
  /// [CraftDesign.isStackNodeOccupied], which counts occupancy from BOTH ends —
  /// a node is spent whether a child hangs off it or it is the node holding its
  /// own part onto its parent. Surface nodes are never consumed: hosting many
  /// children is the point of them, `isStackNodeOccupied` reports false for
  /// anything that is not [AttachKind.stack], and the design's own mate guard
  /// enforces occupancy only for stack nodes. So a hull that already carries
  /// three RCS quads still offers its fourth seat, and its first three as well.
  ///
  /// [kind] filters to one mate kind, which is how a held part with only surface
  /// nodes lights up only the chevrons.
  static List<AttachTarget> openNodes(CraftDesign design, {AttachKind? kind}) {
    final out = <AttachTarget>[];
    for (final part in design.parts) {
      for (final authored in part.def.attachNodes) {
        if (kind != null && authored.kind != kind) continue;
        if (design.isStackNodeOccupied(part.instanceId, authored.name)) {
          continue;
        }
        final inBody = part.nodeInBody(authored.name);
        if (inBody == null) continue;
        out.add(AttachTarget(
          ownerInstanceId: part.instanceId,
          nodeName: inBody.name,
          positionInCraft: inBody.position,
          directionInCraft: inBody.direction.normalized,
          size: inBody.size,
          kind: inBody.kind,
        ));
      }
    }
    return out;
  }

  /// Every legal `(target, childNode)` pairing for [def] against this design,
  /// grouped target-major so the alternatives for one marker are adjacent.
  ///
  /// NOT pre-filtered by a metre radius. The editor ranks these in SCREEN
  /// PIXELS, because "near the cursor" is a screen judgement about a projection
  /// the domain cannot see; a metre-based cut here would drop the far end of a
  /// zoomed-out craft that is two pixels from the pointer.
  ///
  /// Legality is exactly the design's own: [AttachSolver.kindsCompatible] and
  /// [AttachSolver.sizesCompatible], so a pairing offered here is one
  /// [CraftDesign.attachPart] — or, with [movingInstanceId], [CraftDesign.mate]
  /// — will accept. Size is enforced for stack mates only — a 0.25 m
  /// RCS mount bolts to a 4.2 m hull, and gating that would make most radial
  /// mounts impossible.
  ///
  /// [exclude] drops instance ids that must not be mated to: pass the whole
  /// subtree of a part being re-seated, or the design grows a cycle.
  ///
  /// [movingInstanceId] names a part ALREADY on the craft that is being
  /// re-seated, and [def] must then be that part's own def. It turns the offer
  /// set two-sided, exactly as [CraftDesign.findSnap] does for a drag:
  ///
  ///   * its whole subtree is excluded, so a branch cannot be mated to itself;
  ///   * its own stack nodes that its CHILDREN are using are dropped, because
  ///     [CraftDesign.mate] refuses a joint whose child-side node is spent.
  ///
  /// Without the second rule the editor draws a marker for a mate the domain
  /// throws on, and the player reads the refusal as bad aim. The joint holding
  /// the mover to its current parent is deliberately NOT counted — that joint is
  /// the one the move replaces, and counting it would leave a part in the middle
  /// of a stack with no legal way off it.
  static List<TargetPairing> pairingsFor(
    CraftDesign design,
    PartDef def, {
    Set<String> exclude = const {},
    String? movingInstanceId,
  }) {
    final moving =
        movingInstanceId == null ? null : design.partById(movingInstanceId);
    final blocked = moving == null
        ? exclude
        : {...exclude, ...design.subtreeIds(moving.instanceId)};

    // Node names on the mover that its own children occupy. Surface names land
    // in here too and are harmless: the set is only consulted for a child node
    // of the STACK kind, matching the design's own guard, which never blocks a
    // surface node because hosting many children is the point of one.
    final spentOnMover = <String>{};
    if (moving != null) {
      for (final child in design.childrenOf(moving.instanceId)) {
        final mate = child.attachment;
        if (mate != null) spentOnMover.add(mate.parentNode);
      }
    }

    final out = <TargetPairing>[];
    for (final target in openNodes(design)) {
      if (blocked.contains(target.ownerInstanceId)) continue;
      final parentNode = AttachNode(
        name: target.nodeName,
        position: target.positionInCraft,
        direction: target.directionInCraft,
        size: target.size,
        kind: target.kind,
      );
      for (final child in def.attachNodes) {
        if (child.kind == AttachKind.stack &&
            spentOnMover.contains(child.name)) {
          continue;
        }
        if (!_solver.kindsCompatible(parentNode, child)) continue;
        if (!_solver.sizesCompatible(parentNode, child)) continue;
        out.add(TargetPairing(target: target, childNodeName: child.name));
      }
    }
    return out;
  }

  /// Surface-node rings on [def], in the order their first member is authored.
  ///
  /// Detected by BOTH the `<prefix>-<n>` name pattern AND geometric coherence:
  /// equal radius and height to a centimetre, azimuths evenly spaced to half a
  /// degree. Requiring the geometry as well as the name means a mistyped
  /// constant produces NO ring rather than a crooked one — the failure mode of
  /// name-only detection is a symmetry op that scatters four landing legs and
  /// still looks structurally valid in the save file.
  ///
  /// Stack nodes are never ringed. A ring exists to be mated many times over,
  /// and a stack node mates exactly once.
  ///
  /// MEMOISED on the def instance, and the result is unmodifiable. Detection
  /// costs a scan of the nodes, a regex per surface node, a map, and a sort,
  /// while the panes ask for it PER ROW on every notification — a tree pane
  /// walking a 40-part craft runs it 39 times for 39 identical answers. The
  /// memo is sound because a [PartDef] is immutable: its nodes are fixed at
  /// construction, so its rings are a property of the object and can never go
  /// stale. An [Expando] rather than a map, so a catalog that falls out of
  /// scope takes its entries with it.
  static List<NodeRing> ringsOf(PartDef def) {
    final memo = _ringsByDef[def];
    if (memo != null) return memo;

    final members = <String, List<AttachNode>>{};
    final prefixOrder = <String>[];
    for (final n in def.attachNodes) {
      if (n.kind != AttachKind.surface) continue;
      final match = _memberPattern.firstMatch(n.name);
      if (match == null) continue;
      final prefix = match.group(1)!;
      final group = members[prefix];
      if (group == null) {
        members[prefix] = [n];
        prefixOrder.add(prefix);
      } else {
        group.add(n);
      }
    }

    final out = <NodeRing>[];
    for (final prefix in prefixOrder) {
      final ring = _ringFrom(prefix, members[prefix]!);
      if (ring != null) out.add(ring);
    }
    final rings = List<NodeRing>.unmodifiable(out);
    _ringsByDef[def] = rings;
    return rings;
  }

  /// The ring [nodeName] belongs to on [def], or null when it is not a ring
  /// member.
  static NodeRing? ringContaining(PartDef def, String nodeName) {
    for (final ring in ringsOf(def)) {
      if (ring.nodeNames.contains(nodeName)) return ring;
    }
    return null;
  }

  /// Symmetry counts a ring can express, ascending and always including 1.
  ///
  /// The divisors of the member count, because those are the only counts whose
  /// copies land evenly: a 4-ring gives `[1, 2, 4]` and `x2` means diametrically
  /// opposite, not "the first two". A part whose target has no ring gives `[1]`,
  /// and the UI greys the rest with that as the reason — honest, and it cannot
  /// produce a scattered ring.
  static List<int> symmetryCountsFor(NodeRing? ring) {
    if (ring == null || ring.count < 2) return const [1];
    return [
      for (var n = 1; n <= ring.count; n++)
        if (ring.count % n == 0) n,
    ];
  }

  /// [instanceId] and its symmetry siblings.
  ///
  /// DERIVED, never stored: siblings are the parts built from the same catalog
  /// def, mated to the same parent through the same child node, in the same
  /// stage, on parent nodes that are peers in one ring. That costs nothing at
  /// save time and survives a codec round trip exactly, which is why symmetry
  /// needs no schema change — a stored group id would be a second source of
  /// truth that a hand-edited or older save could contradict.
  ///
  /// Compared by [PartDef.id] rather than by object identity: a decoded design
  /// resolves its defs through a fresh catalog, so the instances differ even
  /// though the parts are the same.
  ///
  /// A free, root, or non-ring part is its own group of one. An unknown id gives
  /// the empty set.
  static Set<String> symmetryGroupOf(CraftDesign design, String instanceId) {
    final part = design.partById(instanceId);
    if (part == null) return const {};
    final mate = part.attachment;
    if (mate == null) return {instanceId};
    final parent = design.partById(mate.parentInstanceId);
    if (parent == null) return {instanceId};
    final ring = ringContaining(parent.def, mate.parentNode);
    if (ring == null) return {instanceId};

    final seats = ring.nodeNames.toSet();
    final group = <String>{};
    for (final other in design.parts) {
      final theirs = other.attachment;
      if (theirs == null) continue;
      if (other.def.id != part.def.id) continue;
      if (other.stage != part.stage) continue;
      if (theirs.parentInstanceId != mate.parentInstanceId) continue;
      if (theirs.childNode != mate.childNode) continue;
      if (!seats.contains(theirs.parentNode)) continue;
      group.add(other.instanceId);
    }
    return group;
  }

  /// The part's current spin about its mate axis, radians in `(-2pi, 2pi]`.
  ///
  /// Derived from geometry, so roll needs no stored field and no schema change:
  /// [AttachSolver.solveMate] builds a mated orientation as
  /// `axisAngle(mateAxis, roll) * alignment`, so re-solving the alignment at
  /// roll 0 and cancelling it off the placed rotation leaves exactly the spin.
  ///
  /// Exact for any placement [CraftDesign.attachPart] or [CraftDesign.mate]
  /// produced. For a placement built some other way — a radial copy spun about
  /// the CRAFT axis, or a hand-written save — the residual rotation is not about
  /// the mate axis at all, and this reports its component along that axis: a
  /// reasonable number to hand a roll widget, not a claim about the part.
  ///
  /// Returns 0 for a free or root part, and for a mate whose nodes no longer
  /// resolve.
  static double currentRoll(CraftDesign design, String instanceId) {
    final part = design.partById(instanceId);
    final mate = part?.attachment;
    if (part == null || mate == null) return 0;
    final parent = design.partById(mate.parentInstanceId);
    final parentNode = parent?.nodeInBody(mate.parentNode);
    final childNode = part.def.node(mate.childNode);
    if (parentNode == null || childNode == null) return 0;
    if (parentNode.direction.lengthSquared == 0 ||
        childNode.direction.lengthSquared == 0) {
      return 0;
    }

    final aligned = _solver.solveMate(
        parentNodeInBody: parentNode, childNodeLocal: childNode);
    // The mate axis: the child's outward normal ends up facing back into the
    // parent, so the joint's one remaining freedom is a spin about this.
    final axis = -parentNode.direction.normalized;
    final residual = (part.rotation * aligned.rotation.conjugate).normalized;
    final vector = Vector3(residual.x, residual.y, residual.z);
    final sine = vector.length;
    if (sine < 1e-9) return 0;
    // q = (cos(roll/2), axis * sin(roll/2)); the dot recovers the sign that
    // |vector| threw away, and atan2 keeps the answer stable through roll = pi
    // where a plain acos on w loses precision.
    return 2 * math.atan2(sine * vector.dot(axis).sign, residual.w);
  }

  /// One ring, or null when [group] is not geometrically a ring.
  static NodeRing? _ringFrom(String prefix, List<AttachNode> group) {
    if (group.length < 2) return null;

    final byAzimuth = <({double azimuth, double radius, String name})>[];
    var minRadius = double.infinity, maxRadius = -double.infinity;
    var minHeight = double.infinity, maxHeight = -double.infinity;
    var radiusSum = 0.0, heightSum = 0.0;
    for (final n in group) {
      final radius =
          math.sqrt(n.position.x * n.position.x + n.position.y * n.position.y);
      if (radius < _ringMinRadiusM) return null;
      var azimuth = math.atan2(n.position.y, n.position.x);
      if (azimuth < 0) azimuth += 2 * math.pi;
      byAzimuth.add((azimuth: azimuth, radius: radius, name: n.name));

      minRadius = math.min(minRadius, radius);
      maxRadius = math.max(maxRadius, radius);
      radiusSum += radius;
      minHeight = math.min(minHeight, n.position.z);
      maxHeight = math.max(maxHeight, n.position.z);
      heightSum += n.position.z;
    }
    if (maxRadius - minRadius > _ringRadiusToleranceM) return null;
    if (maxHeight - minHeight > _ringHeightToleranceM) return null;
    byAzimuth.sort((a, b) => a.azimuth.compareTo(b.azimuth));

    // Even spacing, measured from the first member so a ring authored at any
    // phase passes: member k must sit k/n of the way round.
    final step = 2 * math.pi / group.length;
    for (var k = 1; k < group.length; k++) {
      final expected = byAzimuth[0].azimuth + k * step;
      if ((byAzimuth[k].azimuth - expected).abs() > _ringAzimuthToleranceRad) {
        return null;
      }
    }

    return NodeRing(
      prefix: prefix,
      nodeNames: [for (final m in byAzimuth) m.name],
      radius: radiusSum / group.length,
      height: heightSum / group.length,
    );
  }
}
