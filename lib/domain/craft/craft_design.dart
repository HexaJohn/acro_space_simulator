// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:collection';

import '../parts/attach_node.dart';
import '../parts/part_def.dart';
import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import 'attach_solver.dart';

/// A craft being built in the editor: an ordered bag of [PlacedPart]s plus the
/// tree of mates that holds them together.
///
/// This is the aggregate root of the craft-design context and the thing a 3D
/// editor drives. It is mutable — an editor is a long-lived mutation session,
/// and rebuilding an immutable design on every mouse move would churn — but
/// every mutation goes through a method that re-checks the invariants:
///
///   * instance ids are unique;
///   * every [PartAttachment] names a part that exists and nodes that exist on
///     both defs, with matching [AttachKind];
///   * the attach graph is a forest — no part is its own ancestor;
///   * a STACK node carries at most one mate, counted from BOTH ends — the node
///     is spent whether a child hangs off it or it is the node holding its own
///     part onto its parent (surface nodes host many, which is what lets four
///     radial copies share one hull node).
///
/// Geometry stays authoritative in [PlacedPart.position]/[PlacedPart.rotation];
/// the attachment record is structure, not a source of truth to re-solve from.
/// That keeps the bake ([VesselAssembler]) independent of the tree and means a
/// design loaded from an older save still flies even if a node moved on a def.
///
/// Units are METRES in the craft body frame: Z-up, nose on +Z.
class CraftDesign {
  final List<PlacedPart> _parts = [];

  /// instanceId -> index into [_parts]. Rebuilt on removal; lookups dominate.
  final Map<String, int> _index = {};

  String _name;
  String? _rootId;

  final AttachSolver _solver;

  CraftDesign({required String name, AttachSolver solver = AttachSolver.standard})
      : _name = _checkedName(name),
        _solver = solver;

  /// Rebuild a design from parts that already carry their geometry and
  /// attachments — the load path. Validates the whole forest up front so a
  /// corrupt save fails at the door instead of halfway through a bake.
  ///
  /// Throws [StateError] describing the first invariant broken.
  factory CraftDesign.fromParts({
    required String name,
    required Iterable<PlacedPart> parts,
    String? rootId,
    AttachSolver solver = AttachSolver.standard,
  }) {
    final d = CraftDesign(name: name, solver: solver);
    for (final p in parts) {
      if (d._index.containsKey(p.instanceId)) {
        throw StateError('duplicate part instance id "${p.instanceId}"');
      }
      d._index[p.instanceId] = d._parts.length;
      d._parts.add(p);
    }
    d._validate();
    if (rootId != null) {
      d.setRoot(rootId);
    } else {
      d._rootId = d._defaultRootId();
    }
    return d;
  }

  // ---------------- reading ----------------

  String get name => _name;

  /// Renaming is guarded only against blank — a craft with no name is
  /// unfindable in a save list.
  set name(String value) => _name = _checkedName(value);

  /// Parts in the order they were added. Stable across mutations of other
  /// parts, which is what lets the editor keep a selection index.
  List<PlacedPart> get parts => UnmodifiableListView(_parts);

  int get partCount => _parts.length;

  bool get isEmpty => _parts.isEmpty;

  PlacedPart? partById(String instanceId) {
    final i = _index[instanceId];
    return i == null ? null : _parts[i];
  }

  bool contains(String instanceId) => _index.containsKey(instanceId);

  /// The part everything else hangs off — the command pod, by convention.
  ///
  /// Not derived: a design can legitimately hold several unmated parts mid-edit,
  /// and which one is "the craft" is an authoring decision, not a geometric
  /// fact. Defaults to the first part added and follows removals.
  String? get rootId => _rootId;

  PlacedPart? get root => _rootId == null ? null : partById(_rootId!);

  /// Parts with no mate: the true root plus anything the player has dropped in
  /// but not yet attached.
  Iterable<PlacedPart> get roots => _parts.where((p) => p.attachment == null);

  /// Direct children of [instanceId], in insertion order.
  List<PlacedPart> childrenOf(String instanceId) => [
        for (final p in _parts)
          if (p.attachment?.parentInstanceId == instanceId) p
      ];

  /// [instanceId] and everything mated below it, parents before children.
  /// Deterministic (insertion order at each level) so callers can rely on it
  /// for stable ids and reproducible tests.
  List<String> subtreeIds(String instanceId) {
    if (!contains(instanceId)) return const [];
    final out = <String>[];
    final queue = <String>[instanceId];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      out.add(id);
      for (final c in childrenOf(id)) {
        queue.add(c.instanceId);
      }
    }
    return out;
  }

  List<PlacedPart> subtreeOf(String instanceId) =>
      [for (final id in subtreeIds(instanceId)) _parts[_index[id]!]];

  /// True when [nodeName] on [instanceId] already carries a stack mate — either
  /// a child hangs off it, or it is the node this part uses to hang off its own
  /// parent. Surface nodes always report false: they are meant to be shared.
  bool isStackNodeOccupied(String instanceId, String nodeName) {
    final owner = partById(instanceId);
    return owner != null && _stackNodeBlocker(owner, nodeName) != null;
  }

  /// The stages present, ascending. Handy for the staging UI; holes are real
  /// until [renumberStages] runs.
  List<int> get stages =>
      (_parts.map((p) => p.stage).toSet().toList()..sort());

  // ---------------- placing ----------------

  /// Drop a part in at an explicit body-frame placement, mated to nothing.
  ///
  /// Throws [StateError] on a duplicate [instanceId] — ids are the editor's
  /// handle on a part and a collision would silently retarget later edits.
  PlacedPart addPart({
    required PartDef def,
    required String instanceId,
    Vector3 position = Vector3.zero,
    Quaternion rotation = Quaternion.identity,
    int stage = 0,
  }) {
    _requireFreeId(instanceId);
    final p = PlacedPart(
      def: def,
      instanceId: instanceId,
      position: position,
      rotation: rotation,
      stage: stage,
    );
    _append(p);
    _rootId ??= instanceId;
    return p;
  }

  /// Add a part already mated to [toInstanceId]'s [parentNode].
  ///
  /// The child's position AND rotation are solved so the two nodes coincide
  /// with anti-parallel outward normals — a real joint, not a nearby placement.
  /// [roll] spins the child about the mate axis (radians), the only freedom the
  /// joint leaves. [stage] defaults to the parent's, because a part bolted onto
  /// a stage almost always separates with it.
  ///
  /// Throws [StateError] if the target or either node is missing, the kinds
  /// disagree, the sizes are incompatible, or the parent's stack node is taken.
  PlacedPart attachPart({
    required PartDef def,
    required String instanceId,
    required String toInstanceId,
    required String parentNode,
    required String childNode,
    double roll = 0,
    int? stage,
  }) {
    _requireFreeId(instanceId);
    final parent = _requirePart(toInstanceId);
    final pn = _requireNodeInBody(parent, parentNode);
    final cn = _requireNode(def, childNode, instanceId);
    _requireMatable(pn, cn, parent, parentNode);

    final mate = _solver.solveMate(
        parentNodeInBody: pn, childNodeLocal: cn, roll: roll);
    final p = PlacedPart(
      def: def,
      instanceId: instanceId,
      position: mate.position,
      rotation: mate.rotation,
      stage: stage ?? parent.stage,
      attachment: PartAttachment(
        parentInstanceId: toInstanceId,
        parentNode: parentNode,
        childNode: childNode,
      ),
    );
    _append(p);
    _rootId ??= instanceId;
    return p;
  }

  /// Mate a part that is ALREADY in the design, carrying its subtree along
  /// rigidly.
  ///
  /// The whole branch moves as one body: anything bolted below the part keeps
  /// its relative geometry, so re-parenting a half-built stack does not explode
  /// it.
  ///
  /// Throws [StateError] if the mate would make the part its own ancestor, or
  /// if either stack node is already spent — including [childNode] when the
  /// part's own children are hanging off it. The joint being replaced is the
  /// one thing that cannot block the move.
  PlacedPart mate({
    required String instanceId,
    required String toInstanceId,
    required String parentNode,
    required String childNode,
    double roll = 0,
  }) {
    final child = _requirePart(instanceId);
    final parent = _requirePart(toInstanceId);
    if (instanceId == toInstanceId) {
      throw StateError('cannot mate "$instanceId" to itself');
    }
    if (subtreeIds(instanceId).contains(toInstanceId)) {
      throw StateError(
          'mating "$instanceId" to "$toInstanceId" would create a cycle');
    }
    final pn = _requireNodeInBody(parent, parentNode);
    final cn = _requireNode(child.def, childNode, instanceId);
    _requireMatable(pn, cn, parent, parentNode, movingChild: child);

    final target = _solver
        .solveMate(parentNodeInBody: pn, childNodeLocal: cn, roll: roll);
    _transformSubtree(instanceId, target.position, target.rotation);
    final moved = _parts[_index[instanceId]!];
    final result = moved.copyWith(
      attachment: PartAttachment(
        parentInstanceId: toInstanceId,
        parentNode: parentNode,
        childNode: childNode,
      ),
    );
    _replace(result);
    return result;
  }

  /// Break a part's mate, leaving it exactly where it is as a free part (its
  /// own subtree stays bolted to it). The deliberate counterpart to [remove]:
  /// use this when the branch should survive.
  PlacedPart detach(String instanceId) {
    final p = _requirePart(instanceId);
    if (p.attachment == null) return p;
    final free = p.copyWith(clearAttachment: true);
    _replace(free);
    return free;
  }

  /// Delete a part AND everything mated below it. Returns the ids removed,
  /// parents first.
  ///
  /// Subtree removal, not re-rooting, is the deliberate choice: a mated child's
  /// placement only means anything relative to the joint that produced it, so
  /// re-rooting the orphans would leave a tank hanging in space beside the
  /// craft, structurally connected to nothing and quietly contributing mass and
  /// inertia to the bake. A player who wants to keep the branch says so with
  /// [detach] first.
  List<String> remove(String instanceId) {
    if (!contains(instanceId)) return const [];
    final doomed = subtreeIds(instanceId);
    final gone = doomed.toSet();
    _parts.removeWhere((p) => gone.contains(p.instanceId));
    _reindex();
    if (_rootId != null && gone.contains(_rootId)) {
      _rootId = _defaultRootId();
    }
    return doomed;
  }

  // ---------------- moving ----------------

  /// Move a FREE part (and its subtree) to a new body-frame origin.
  ///
  /// Refuses a mated part on purpose: its position is the output of a joint, so
  /// nudging it would put the design in a state where the tree says one thing
  /// and the geometry says another. Detach, move, re-[mate].
  void moveTo(String instanceId, Vector3 position) {
    final p = _requireFreePart(instanceId, 'move');
    _transformSubtree(instanceId, position, p.rotation);
  }

  /// Rotate a FREE part (and its subtree) about that part's own origin.
  /// Same rationale as [moveTo] for refusing mated parts.
  void rotateTo(String instanceId, Quaternion rotation) {
    final p = _requireFreePart(instanceId, 'rotate');
    _transformSubtree(instanceId, p.position, rotation.normalized);
  }

  /// Nominate the part the craft hangs off. Must be unmated — a part with a
  /// parent is by definition not the root of anything.
  void setRoot(String instanceId) {
    final p = _requirePart(instanceId);
    if (p.attachment != null) {
      throw StateError('"$instanceId" is mated to '
          '"${p.attachment!.parentInstanceId}" and cannot be the root');
    }
    _rootId = instanceId;
  }

  // ---------------- symmetry ----------------

  /// Attach [count] copies of [def] evenly around the craft's +Z axis, all
  /// mated to the same SURFACE node — the one-click "four RCS quads" op.
  ///
  /// Copy k is the seed placement spun by k*2pi/count about [axis], orientation
  /// included, so each copy faces its own outward direction. Instance ids are
  /// `$instanceIdPrefix-0` .. `-${count-1}`, assigned in angular order so a
  /// re-run of the same call reproduces the same design.
  ///
  /// Restricted to surface nodes: a stack node mates exactly once, so radial
  /// copies on one would break the single-occupancy invariant immediately.
  List<PlacedPart> attachRadial({
    required PartDef def,
    required String instanceIdPrefix,
    required String toInstanceId,
    required String parentNode,
    required String childNode,
    required int count,
    double roll = 0,
    int? stage,
    Vector3 axis = Vector3.unitZ,
  }) {
    final parent = _requirePart(toInstanceId);
    final pn = _requireNodeInBody(parent, parentNode);
    if (pn.kind != AttachKind.surface) {
      throw StateError('radial symmetry needs a surface node; '
          '"$toInstanceId.$parentNode" is a ${pn.kind.name} node');
    }
    final cn = _requireNode(def, childNode, instanceIdPrefix);
    _requireMatable(pn, cn, parent, parentNode);

    final seed = _solver
        .solveMate(parentNodeInBody: pn, childNodeLocal: cn, roll: roll);
    final copies = _solver.radialCopies(
      position: seed.position,
      rotation: seed.rotation,
      count: count,
      axis: axis,
    );
    return _placeSymmetry(
      def: def,
      copies: copies,
      ids: [for (var k = 0; k < copies.length; k++) '$instanceIdPrefix-$k'],
      toInstanceId: toInstanceId,
      parentNode: parentNode,
      childNode: childNode,
      stage: stage ?? parent.stage,
    );
  }

  /// Attach a surface-mounted part and its mirror image across the plane
  /// through the craft origin with normal [planeNormal] (YZ by default).
  ///
  /// Two parts, ids `$instanceIdPrefix-0` (the seed) and `-1` (the reflection).
  /// Mirror rather than 2x radial is the tool for anything off-axis: a mount at
  /// (2, 0.5, 1) mirrors to (-2, 0.5, 1), where a half-turn about +Z would send
  /// it to (-2, -0.5, 1) — the same part swung round, not its counterpart.
  ///
  /// Refuses a mount that sits ON the mirror plane, which would put the copy
  /// exactly on top of the seed.
  List<PlacedPart> attachMirrored({
    required PartDef def,
    required String instanceIdPrefix,
    required String toInstanceId,
    required String parentNode,
    required String childNode,
    double roll = 0,
    int? stage,
    Vector3 planeNormal = Vector3.unitX,
  }) {
    final parent = _requirePart(toInstanceId);
    final pn = _requireNodeInBody(parent, parentNode);
    if (pn.kind != AttachKind.surface) {
      throw StateError('mirror symmetry needs a surface node; '
          '"$toInstanceId.$parentNode" is a ${pn.kind.name} node');
    }
    if (_solver.nodeLiesOnMirrorPlane(pn, planeNormal)) {
      throw StateError('"$toInstanceId.$parentNode" lies on the mirror plane; '
          'its reflection is itself');
    }
    final cn = _requireNode(def, childNode, instanceIdPrefix);
    _requireMatable(pn, cn, parent, parentNode);

    final seed = _solver
        .solveMate(parentNodeInBody: pn, childNodeLocal: cn, roll: roll);
    final reflected = _solver.mirrorMate(
      parentNodeInBody: pn,
      childNodeLocal: cn,
      planeNormal: planeNormal,
      roll: roll,
    );
    return _placeSymmetry(
      def: def,
      copies: [seed, reflected],
      ids: ['$instanceIdPrefix-0', '$instanceIdPrefix-1'],
      toInstanceId: toInstanceId,
      parentNode: parentNode,
      childNode: childNode,
      stage: stage ?? parent.stage,
    );
  }

  /// Best mate for a part being dragged at [position]/[rotation], or null.
  ///
  /// Wraps [AttachSolver.findSnap] with this design's occupancy rule and, when
  /// [movingInstanceId] is given, excludes that part's whole subtree so a drag
  /// cannot mate a branch to itself.
  ///
  /// Occupancy is applied to both ends, so the editor is never offered a snap
  /// that [mate] would then refuse: a target node already carrying a mate is
  /// skipped, and so is a node on the DRAGGED part that its own children are
  /// using. The dragged part's mate to its current parent does NOT disqualify
  /// anything — that joint is what the drag is replacing.
  SnapCandidate? findSnap({
    required PartDef def,
    required Vector3 position,
    Quaternion rotation = Quaternion.identity,
    double? radius,
    String? movingInstanceId,
  }) {
    final moving = movingInstanceId == null ? null : partById(movingInstanceId);
    bool spentOnMovingPart(String nodeName) =>
        _stackNodeBlocker(moving!, nodeName,
            ignoreInstanceId: moving.instanceId) !=
        null;

    return _solver.findSnap(
      parts: _parts,
      def: def,
      position: position,
      rotation: rotation,
      radius: radius,
      isStackNodeOccupied: isStackNodeOccupied,
      isChildNodeOccupied: moving == null ? null : spentOnMovingPart,
      exclude: movingInstanceId == null
          ? const {}
          : subtreeIds(movingInstanceId).toSet(),
    );
  }

  // ---------------- staging ----------------

  /// Put a part in a staging group. With [withSubtree] the whole branch follows,
  /// which is what a player means when they drag a booster into a stage.
  void assignStage(String instanceId, int stage, {bool withSubtree = false}) {
    if (stage < 0) {
      throw ArgumentError.value(stage, 'stage', 'staging groups start at 0');
    }
    _requirePart(instanceId);
    final ids = withSubtree ? subtreeIds(instanceId) : [instanceId];
    for (final id in ids) {
      _replace(_parts[_index[id]!].copyWith(stage: stage));
    }
  }

  /// Squeeze staging groups down to 0..n-1, preserving their order.
  ///
  /// Deleting a booster leaves a hole, and holes matter: [Stage.index] drives
  /// firing order and the UI counts stages, so a design that jumps 0, 3, 7
  /// reads as four stages with two dead ones. Relative order is what the player
  /// authored, so that is what survives.
  void renumberStages() {
    final used = stages;
    final remap = {for (var i = 0; i < used.length; i++) used[i]: i};
    for (var i = 0; i < _parts.length; i++) {
      final p = _parts[i];
      final next = remap[p.stage]!;
      if (next != p.stage) _parts[i] = p.copyWith(stage: next);
    }
  }

  // ---------------- internals ----------------

  static String _checkedName(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, 'name', 'craft name must not be blank');
    }
    return value;
  }

  void _append(PlacedPart p) {
    _index[p.instanceId] = _parts.length;
    _parts.add(p);
  }

  void _replace(PlacedPart p) => _parts[_index[p.instanceId]!] = p;

  void _reindex() {
    _index.clear();
    for (var i = 0; i < _parts.length; i++) {
      _index[_parts[i].instanceId] = i;
    }
  }

  String? _defaultRootId() {
    for (final p in _parts) {
      if (p.attachment == null) return p.instanceId;
    }
    return _parts.isEmpty ? null : _parts.first.instanceId;
  }

  /// Rigidly carry [instanceId] and everything below it to a new placement.
  /// The delta is applied about the moved part's OLD origin so relative
  /// geometry inside the branch is preserved exactly.
  void _transformSubtree(
      String instanceId, Vector3 newPosition, Quaternion newRotation) {
    final anchor = _parts[_index[instanceId]!];
    final oldPos = anchor.position;
    final delta = (newRotation * anchor.rotation.conjugate).normalized;
    for (final id in subtreeIds(instanceId)) {
      final p = _parts[_index[id]!];
      _parts[_index[id]!] = p.copyWith(
        position: newPosition + delta.rotate(p.position - oldPos),
        rotation: (delta * p.rotation).normalized,
      );
    }
  }

  List<PlacedPart> _placeSymmetry({
    required PartDef def,
    required List<MateResult> copies,
    required List<String> ids,
    required String toInstanceId,
    required String parentNode,
    required String childNode,
    required int stage,
  }) {
    for (final id in ids) {
      _requireFreeId(id);
    }
    // One attachment record per copy, all naming the same surface node: the
    // node is what they are bolted to, and the geometry that separates them
    // already lives in each copy's position/rotation.
    final attachment = PartAttachment(
      parentInstanceId: toInstanceId,
      parentNode: parentNode,
      childNode: childNode,
    );
    final placed = <PlacedPart>[];
    for (var k = 0; k < copies.length; k++) {
      final p = PlacedPart(
        def: def,
        instanceId: ids[k],
        position: copies[k].position,
        rotation: copies[k].rotation,
        stage: stage,
        attachment: attachment,
      );
      _append(p);
      placed.add(p);
    }
    return placed;
  }

  void _requireFreeId(String instanceId) {
    if (instanceId.isEmpty) {
      throw ArgumentError.value(
          instanceId, 'instanceId', 'part instance id must not be empty');
    }
    if (_index.containsKey(instanceId)) {
      throw StateError('part instance id "$instanceId" is already in use');
    }
  }

  PlacedPart _requirePart(String instanceId) {
    final p = partById(instanceId);
    if (p == null) throw StateError('no part "$instanceId" in this design');
    return p;
  }

  PlacedPart _requireFreePart(String instanceId, String verb) {
    final p = _requirePart(instanceId);
    if (p.attachment != null) {
      throw StateError('cannot $verb mated part "$instanceId": its placement is '
          'owned by the joint to "${p.attachment!.parentInstanceId}" — detach first');
    }
    return p;
  }

  AttachNode _requireNodeInBody(PlacedPart part, String nodeName) {
    final n = part.nodeInBody(nodeName);
    if (n == null) {
      throw StateError(
          'part "${part.instanceId}" (${part.def.id}) has no attach node "$nodeName"');
    }
    return n;
  }

  AttachNode _requireNode(PartDef def, String nodeName, String who) {
    final n = def.node(nodeName);
    if (n == null) {
      throw StateError('"$who" (${def.id}) has no attach node "$nodeName"');
    }
    return n;
  }

  /// Instance id of the part whose mate already spends stack [nodeName] on
  /// [owner], or null when the node is free.
  ///
  /// A stack node is spent from EITHER direction and both have to be counted:
  /// by a child mated into it, and — when it is the node [owner]'s own
  /// [PartAttachment] names — by the joint holding [owner] onto its parent.
  /// Looking only at children is what lets a second part be bolted exactly on
  /// top of the first, since a node in use upward has no child of its own.
  ///
  /// [ignoreInstanceId] drops one part's current mate from the count, which is
  /// what makes re-mating legal: the joint a part is being moved out of must
  /// not block the joint it is being moved into.
  ///
  /// Surface nodes are never blocked — hosting many children is the point of
  /// them — so this returns null for anything that is not [AttachKind.stack].
  String? _stackNodeBlocker(
    PlacedPart owner,
    String nodeName, {
    String? ignoreInstanceId,
  }) {
    if (owner.def.node(nodeName)?.kind != AttachKind.stack) return null;
    final own = owner.attachment;
    if (own != null &&
        own.childNode == nodeName &&
        owner.instanceId != ignoreInstanceId) {
      return own.parentInstanceId;
    }
    for (final p in _parts) {
      final a = p.attachment;
      if (a == null) continue;
      if (p.instanceId == ignoreInstanceId) continue;
      if (a.parentInstanceId == owner.instanceId && a.parentNode == nodeName) {
        return p.instanceId;
      }
    }
    return null;
  }

  /// Guard every mate goes through: compatible kinds, compatible diameters, and
  /// a stack node free at BOTH ends of the joint.
  ///
  /// [movingChild] is the part already in the design that is being re-mated, if
  /// any. Its own node has to be checked too — a node carrying a child of its
  /// own cannot also seat the part on a new parent — while its existing mate is
  /// exempt on both sides, being the joint the move replaces.
  void _requireMatable(
    AttachNode parentNode,
    AttachNode childNode,
    PlacedPart parent,
    String parentNodeName, {
    PlacedPart? movingChild,
  }) {
    if (!_solver.kindsCompatible(parentNode, childNode)) {
      throw StateError('cannot mate a ${childNode.kind.name} node to a '
          '${parentNode.kind.name} node');
    }
    if (!_solver.sizesCompatible(parentNode, childNode)) {
      throw StateError('stack size mismatch: ${parentNode.size}m node '
          '"$parentNodeName" vs ${childNode.size}m node "${childNode.name}"');
    }
    if (parentNode.kind != AttachKind.stack) return;

    final moving = movingChild?.instanceId;
    final onParent =
        _stackNodeBlocker(parent, parentNodeName, ignoreInstanceId: moving);
    if (onParent != null) {
      throw StateError('stack node "${parent.instanceId}.$parentNodeName" is '
          'already mated to "$onParent"');
    }
    if (movingChild != null) {
      final onChild = _stackNodeBlocker(movingChild, childNode.name,
          ignoreInstanceId: moving);
      if (onChild != null) {
        throw StateError('stack node "$moving.${childNode.name}" is already '
            'mated to "$onChild"');
      }
    }
  }

  /// Full invariant sweep, used by the load path where nothing was built
  /// through the guarded mutators.
  void _validate() {
    for (final p in _parts) {
      final a = p.attachment;
      if (a == null) continue;
      final parent = partById(a.parentInstanceId);
      if (parent == null) {
        throw StateError('part "${p.instanceId}" is mated to missing part '
            '"${a.parentInstanceId}"');
      }
      final pn = parent.def.node(a.parentNode);
      if (pn == null) {
        throw StateError('part "${parent.instanceId}" (${parent.def.id}) has no '
            'attach node "${a.parentNode}"');
      }
      final cn = p.def.node(a.childNode);
      if (cn == null) {
        throw StateError('part "${p.instanceId}" (${p.def.id}) has no attach '
            'node "${a.childNode}"');
      }
      if (pn.kind != cn.kind) {
        throw StateError('part "${p.instanceId}" mates a ${cn.kind.name} node '
            'to a ${pn.kind.name} node');
      }
    }
    // Cycles: walk up from every part, bounded by the part count.
    for (final p in _parts) {
      var hops = 0;
      var cursor = p.attachment?.parentInstanceId;
      while (cursor != null) {
        if (cursor == p.instanceId || ++hops > _parts.length) {
          throw StateError('attach tree contains a cycle through '
              '"${p.instanceId}"');
        }
        cursor = partById(cursor)!.attachment?.parentInstanceId;
      }
    }
    // Stack single-occupancy, counted from BOTH ends of every mate: a joint
    // spends the parent's node AND the child's node, so a node claimed twice
    // from either direction means two parts sitting in the same place.
    //
    // Keyed on the (part, node) PAIR rather than on the two names joined by a
    // separator. A record compares field by field, so no character sequence a
    // name might contain — and no separator a tool might strip on the way past
    // — can re-split the key and make ('a', 'b-c') collide with ('a-b', 'c'),
    // which would reject a perfectly valid design.
    final taken = <(String instanceId, String nodeName)>{};
    for (final p in _parts) {
      final a = p.attachment;
      if (a == null) continue;
      final parent = partById(a.parentInstanceId)!;
      if (parent.def.node(a.parentNode)!.kind != AttachKind.stack) continue;
      for (final claim in [
        (a.parentInstanceId, a.parentNode),
        (p.instanceId, a.childNode),
      ]) {
        if (!taken.add(claim)) {
          throw StateError('stack node "${claim.$1}.${claim.$2}" '
              'carries more than one part');
        }
      }
    }
  }

  @override
  String toString() => 'CraftDesign($_name, ${_parts.length} parts)';
}
