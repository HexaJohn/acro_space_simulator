// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../domain/craft/attach_targets.dart';
import '../../../../domain/craft/craft_balance.dart';
import '../../../../domain/craft/craft_design.dart';
import '../../../../domain/craft/craft_design_codec.dart';
import '../../../../domain/parts/attach_node.dart';
import '../../../../domain/parts/part_catalog.dart';
import '../../../../domain/parts/part_def.dart';
import '../../../../domain/shared/quaternion.dart';
import '../../../../domain/shared/vector3.dart';
import 'craft_design_store.dart';
import 'craft_editor_state.dart';

/// The craft editor's single mutation funnel.
///
/// ## Why everything goes through [edit]
///
/// Undo is total in this editor — including CLEAR, which the old assembly
/// screen could not take back — and that is only possible because no code path
/// anywhere touches the [CraftDesign] except through [edit]. Every public
/// mutator below is a thin wrapper that names the step and hands the domain
/// call over. A pane that reached into `controller.design` and called
/// `attachPart` itself would produce a craft the history has no snapshot of,
/// and the next undo would restore a state the player never saw.
///
/// [edit] earns its place three times over:
///
///   * it records the snapshot, so undo/redo is uniform across every op from a
///     one-part delete to a whole-vehicle auto-stage;
///   * it ROLLS BACK a mutation that threw partway. A symmetry op is four
///     `attachPart` calls; if the third is refused (a node was taken, a size
///     class disagrees) the domain has already committed the first two, and
///     without the rollback the craft would be left with half a ring nobody
///     asked for;
///   * it turns the domain's [StateError] into [blocked], a sentence the HUD
///     can show, instead of an exception crossing a gesture callback.
///
/// ## What is NOT in here
///
/// Camera pose and hover live in the viewport. They change per pointer move and
/// notifying every pane about them would rebuild the catalog list to move a
/// marker. The rule this file follows: state that survives an undo lives here,
/// state that dies with the frame does not.
///
/// ## The catalog contract
///
/// Undo and rollback both go through [CraftDesignCodec], which resolves part
/// defs by id through [catalog]. Every def placed in this design must therefore
/// be resolvable in it; [hold] and [placeRoot] refuse anything that is not,
/// because the alternative is an undo that throws hours into a session.
class CraftEditorController extends ChangeNotifier {
  CraftEditorController({
    required this.catalog,
    CraftDesign? design,
    CraftDesignStore? store,
    String craftName = 'New Craft',
    int undoDepth = 200,
    CraftDesignCodec codec = const CraftDesignCodec(),
  })  : store = store ?? CraftDesignStore(),
        _codec = codec,
        _design = design ?? CraftDesign(name: craftName) {
    _history =
        UndoStack<Map<String, dynamic>>(initial: _codec.encode(_design), depth: undoDepth);
  }

  /// Where part defs are resolved from — on load, on undo, and on rollback.
  final PartCatalog catalog;

  final CraftDesignStore store;

  final CraftDesignCodec _codec;

  late final UndoStack<Map<String, dynamic>> _history;

  CraftDesign _design;
  int _revision = 0;
  bool _disposed = false;

  EditorTool _tool = EditorTool.select;
  HeldPart? _held;
  SymmetryChoice _symmetry = SymmetryChoice.single;
  String? _selectedId;
  String? _blocked;
  bool _showNodes = true;
  bool _showBalance = true;

  /// Which continuous gesture the last recorded edit belongs to, or null when
  /// no gesture is open. See [edit]'s `coalesceKey`.
  Object? _openCoalesceKey;

  /// Auto-staging is offered ONCE per craft (spec 6.4): the first time a second
  /// engine or a decoupler lands, the design is staged for the player. After
  /// that the staging is theirs and re-deriving it would throw their work away.
  /// Deliberately NOT restored by undo — it records that the offer was made,
  /// not what the craft looks like.
  bool _autoStaged = false;

  int _nextId = 0;

  Timer? _autosaveTimer;

  /// Caches for the derived reads below.
  ///
  /// Every one of them is a pure function of the design, so nothing can change
  /// them without a [_revision] bump — and every one is read from a widget
  /// `build`, which a hover runs on EVERY pointer move. Recomputing them there
  /// reallocates the whole answer per frame for data byte-identical to the last
  /// one. [_selectionCache] carries the picked id as well, because [select] is
  /// view state and deliberately bumps no revision.
  int _pairingRevision = -1;
  String? _pairingDefId;
  List<TargetPairing> _pairingCache = const [];

  int _movePairingRevision = -1;
  String? _movePairingId;
  List<TargetPairing> _movePairingCache = const [];

  int _targetRevision = -1;
  List<AttachTarget> _targetCache = const [];

  int _looseRevision = -1;
  List<PlacedPart> _looseCache = const [];

  int _selectionRevision = -1;
  String? _selectionCacheId;
  Set<String> _selectionCache = const {};

  // ---------------- reading ----------------

  /// The craft. Read freely; mutate only through this controller.
  ///
  /// The IDENTITY changes on undo, redo and load — those restore by decoding a
  /// snapshot — so nothing may hold on to this across a notification.
  CraftDesign get design => _design;

  /// Bumps on every structural change AND on every restore. Panes and the scene
  /// graph diff against it rather than against the design's contents.
  int get revision => _revision;

  EditorTool get tool => _tool;

  /// The part on the cursor, or null.
  HeldPart? get held => _held;

  SymmetryChoice get symmetry => _symmetry;

  String? get selectedId => _selectedId;

  /// The selection: the picked part plus its symmetry siblings, so `Q`/`E`,
  /// staging and delete are one action instead of four.
  ///
  /// DERIVED from geometry (see [AttachTargets.symmetryGroupOf]) rather than
  /// stored, so it is right for a craft that was just loaded. The answer is
  /// held only while neither the craft nor the pick has moved: deriving it
  /// scans the whole design, and every pane reads it per row.
  Set<String> get selection {
    final id = _selectedId;
    if (_selectionRevision == _revision && _selectionCacheId == id) {
      return _selectionCache;
    }
    _selectionCache = id == null || !_design.contains(id)
        ? const {}
        : Set<String>.unmodifiable(AttachTargets.symmetryGroupOf(_design, id));
    _selectionRevision = _revision;
    _selectionCacheId = id;
    return _selectionCache;
  }

  /// Why the last action did not happen, in a sentence, or null. Cleared by the
  /// next successful edit.
  String? get blocked => _blocked;

  bool get showNodes => _showNodes;
  bool get showBalance => _showBalance;

  /// Has the one-shot auto-stage already fired for this craft?
  bool get autoStaged => _autoStaged;

  /// Every open node on the craft, whatever is held — what the `G` marker
  /// overlay draws.
  List<AttachTarget> get openTargets {
    if (_targetRevision != _revision) {
      _targetCache = List.unmodifiable(AttachTargets.openNodes(_design));
      _targetRevision = _revision;
    }
    return _targetCache;
  }

  /// Legal `(target, childNode)` pairings for the held part, empty when nothing
  /// is held. Ranked in pixels by the viewport, never here.
  List<TargetPairing> get pairings {
    final def = _held?.def;
    if (def == null) return const [];
    if (_pairingRevision == _revision && _pairingDefId == def.id) {
      return _pairingCache;
    }
    _pairingCache = List.unmodifiable(AttachTargets.pairingsFor(_design, def));
    _pairingRevision = _revision;
    _pairingDefId = def.id;
    return _pairingCache;
  }

  /// Legal pairings for re-seating [instanceId] — the offer set behind Move.
  ///
  /// Two-sided: its own subtree is excluded so a branch cannot be mated to
  /// itself, and the stack nodes its own children hold are excluded so every
  /// pairing offered is one [remate] will accept. See
  /// [AttachTargets.pairingsFor].
  ///
  /// The seat the part is on RIGHT NOW is not in the set — it reads as taken,
  /// by the mover itself. A gesture that ends there therefore has nothing to
  /// commit and should cancel, which is what a drag does against
  /// [CraftDesign.findSnap] too.
  ///
  /// Cached like [pairings], because a move is a DRAG: the offer set is asked
  /// for on every pointer move of it and cannot change until the drop lands.
  List<TargetPairing> pairingsForMove(String instanceId) {
    if (_movePairingRevision == _revision && _movePairingId == instanceId) {
      return _movePairingCache;
    }
    final part = _design.partById(instanceId);
    _movePairingCache = part == null
        ? const []
        : List.unmodifiable(AttachTargets.pairingsFor(_design, part.def,
            movingInstanceId: instanceId));
    _movePairingRevision = _revision;
    _movePairingId = instanceId;
    return _movePairingCache;
  }

  /// Parts attached to nothing that are not the root — the craft in pieces.
  /// Gates LAUNCH, because a loose part still contributes mass and inertia to
  /// the bake while being structurally connected to nothing.
  List<PlacedPart> get looseParts {
    if (_looseRevision != _revision) {
      _looseCache = List.unmodifiable([
        for (final p in _design.parts)
          if (p.attachment == null && p.instanceId != _design.rootId) p
      ]);
      _looseRevision = _revision;
    }
    return _looseCache;
  }

  bool get hasLooseParts => looseParts.isNotEmpty;

  /// The ring [target] sits on, or null when it is a lone node.
  NodeRing? ringAt(AttachTarget target) {
    final owner = _design.partById(target.ownerInstanceId);
    if (owner == null) return null;
    return AttachTargets.ringContaining(owner.def, target.nodeName);
  }

  /// Symmetry counts [target] can express, ascending and always including 1 —
  /// which chips the toolbar enables, and the honest reason the rest are grey.
  List<int> symmetryCountsAt(AttachTarget? target) =>
      AttachTargets.symmetryCountsFor(target == null ? null : ringAt(target));

  /// The node names one click on [target] would fill, under the current
  /// [symmetry]. One entry for a lone node or a symmetry the ring cannot
  /// express; [symmetry] copies otherwise.
  ///
  /// This is the ghost preview's source AND the commit's source, so the preview
  /// cannot lie about where the copies land.
  List<String> seatsFor(AttachTarget target) {
    final owner = _design.partById(target.ownerInstanceId);
    if (owner == null) return [target.nodeName];
    final ring = AttachTargets.ringContaining(owner.def, target.nodeName);
    if (ring == null) return [target.nodeName];
    final seed = ring.indexOf(target.nodeName);
    if (seed < 0) return [target.nodeName];
    if (_symmetry.mirror) {
      return ring.mirrorPair(seed, _symmetry.mirrorPlaneNormal, owner.def);
    }
    if (_symmetry.seatsOn(ring) < 2) return [target.nodeName];
    return ring.subset(_symmetry.count, seed);
  }

  /// [instanceId] and its symmetry siblings — the tree pane's grouping rule.
  Set<String> symmetryGroupOf(String instanceId) =>
      AttachTargets.symmetryGroupOf(_design, instanceId);

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  /// Name of the edit undo would reverse, for the menu item, or null.
  String? get undoLabel => _history.undoLabel;
  String? get redoLabel => _history.redoLabel;

  /// Steps available in each direction. A coalesced run (a roll drag, a name
  /// being typed) counts as ONE, which is the property the undo suite pins.
  int get undoCount => _history.undoCount;
  int get redoCount => _history.redoCount;

  // ---------------- view state (no history) ----------------

  /// Switch tools. Leaving [EditorTool.place] drops whatever is held, because a
  /// ghost that survives a tool change places a part on the next stray click.
  void setTool(EditorTool value) {
    if (_tool == value) return;
    _tool = value;
    if (value != EditorTool.place) _held = null;
    _endGesture();
    _notify();
  }

  /// Put [def] on the cursor. Not an edit: nothing has been placed yet.
  ///
  /// Refuses a def this controller's [catalog] cannot resolve — see the class
  /// doc. The failure is loud here because it is silent and hours late
  /// otherwise, as a decode failure inside undo.
  void hold(PartDef def) {
    if (catalog.byId(def.id) == null) {
      _refuse('"${def.name}" is not in this editor\'s catalog, so a craft using '
          'it could not be saved or undone.');
      return;
    }
    _held = HeldPart(def: def);
    _tool = EditorTool.place;
    _endGesture();
    _notify();
  }

  /// Drop the held part. `Esc`, and the first thing `Esc` does.
  void clearHeld() {
    if (_held == null) return;
    _held = null;
    if (_tool == EditorTool.place) _tool = EditorTool.select;
    _notify();
  }

  /// `W`/`S`: which of the held part's own nodes seats against the target.
  void cycleHeldNode(int delta) {
    final held = _held;
    if (held == null) return;
    final next = held.cycleNode(delta);
    if (next == held) return;
    _held = next;
    _notify();
  }

  /// Spin the ghost about its mate axis. Not an edit — the part is not placed.
  void rollHeld(double delta) {
    final held = _held;
    if (held == null || delta == 0) return;
    _held = held.rolledBy(delta);
    _notify();
  }

  void setSymmetry(SymmetryChoice value) {
    if (_symmetry == value) return;
    _symmetry = value;
    _notify();
  }

  /// The `1`/`2`/`4` chips. Clears mirror — they are alternatives, not layers.
  void setSymmetryCount(int count) =>
      setSymmetry(SymmetryChoice.radial(count < 1 ? 1 : count));

  /// The `M` chip. Toggling it off returns to a single copy rather than to the
  /// previous radial count, so the toolbar always reads as what will happen.
  void setMirror(bool value, {Vector3 planeNormal = Vector3.unitX}) =>
      setSymmetry(value
          ? SymmetryChoice.mirrored(mirrorPlaneNormal: planeNormal)
          : SymmetryChoice.single);

  /// Pick a part, or clear the selection with null. Ends any open gesture, so a
  /// roll on the next part opens its own undo step.
  void select(String? instanceId) {
    final next =
        instanceId != null && _design.contains(instanceId) ? instanceId : null;
    if (_selectedId == next) return;
    _selectedId = next;
    _endGesture();
    _notify();
  }

  void setShowNodes(bool value) {
    if (_showNodes == value) return;
    _showNodes = value;
    _notify();
  }

  void setShowBalance(bool value) {
    if (_showBalance == value) return;
    _showBalance = value;
    _notify();
  }

  void clearBlocked() {
    if (_blocked == null) return;
    _blocked = null;
    _notify();
  }

  // ---------------- the funnel ----------------

  /// Run [mutate] against the design as one undoable step named [label].
  ///
  /// Returns false and leaves the craft EXACTLY as it was when the domain
  /// refuses; the refusal's own sentence lands in [blocked]. The rollback
  /// decodes the pre-edit snapshot rather than trying to unwind, which is the
  /// only approach that is correct for a partially applied multi-part op.
  ///
  /// [coalesceKey] folds consecutive edits carrying the SAME key into one step
  /// — a roll drag, a rename being typed. The first edit of a run opens the
  /// step; every later one amends it. Any edit with a different key (or none),
  /// any selection change, and any undo closes the run. See [endGesture].
  bool edit(String label, void Function() mutate, {Object? coalesceKey}) {
    if (_disposed) return false;
    final before = _codec.encode(_design);
    final selectionBefore = _selectedId;
    try {
      mutate();
    } on ArgumentError catch (e) {
      // RangeError is an ArgumentError, so a bad ring index lands here too.
      _rollback(before, selectionBefore, '${e.message ?? e}');
      return false;
    } on StateError catch (e) {
      _rollback(before, selectionBefore, e.message);
      return false;
    }

    final after = _codec.encode(_design);
    if (coalesceKey != null &&
        _openCoalesceKey == coalesceKey &&
        _history.canUndo) {
      _history.amend(after);
    } else {
      _history.record(label, after);
      _openCoalesceKey = coalesceKey;
    }
    _revision++;
    _blocked = null;
    _pruneSelection();
    _notify();
    return true;
  }

  /// Close any open coalescing run: the next edit starts a fresh undo step.
  /// Call it on pointer-up of a roll drag, or when a text field loses focus.
  void endGesture() => _endGesture();

  bool undo() {
    final snapshot = _history.undo();
    if (snapshot == null) return false;
    _adoptSnapshot(snapshot);
    return true;
  }

  bool redo() {
    final snapshot = _history.redo();
    if (snapshot == null) return false;
    _adoptSnapshot(snapshot);
    return true;
  }

  // ---------------- placing ----------------

  /// The first part: dropped at the craft origin, mated to nothing.
  ///
  /// A VAB puts the first part on the pad, which is why there is no free
  /// placement anywhere else in this editor — every later part names a node.
  /// The held part clears afterwards, because a craft has one root.
  bool placeRoot({PartDef? def, Vector3 position = Vector3.zero}) {
    final part = def ?? _held?.def;
    if (part == null) {
      return _refuse('Pick a part from the catalog first.');
    }
    if (catalog.byId(part.id) == null) {
      return _refuse('"${part.name}" is not in this editor\'s catalog.');
    }
    if (!_design.isEmpty) {
      return _refuse('${_design.name} already has a root — attach to one of its '
          'nodes instead.');
    }

    final id = nextInstanceId(part);
    final heldBefore = _held;
    final toolBefore = _tool;
    _held = null;
    _tool = EditorTool.select;
    final ok = edit('place ${part.name}', () {
      _design.addPart(def: part, instanceId: id, position: position);
      _selectedId = id;
    });
    if (!ok) {
      _held = heldBefore;
      _tool = toolBefore;
    }
    return ok;
  }

  /// Commit the held part (or [def]) onto [pairing], with symmetry.
  ///
  /// One edit, one to four parts, ONE undo step — each copy an ordinary mate
  /// naming its own authored ring member. The held part PERSISTS, so the next
  /// click stacks another; `Esc` is what stops it.
  bool attachAt(TargetPairing pairing, {PartDef? def}) {
    final part = def ?? _held?.def;
    if (part == null) {
      return _refuse('Pick a part from the catalog first.');
    }
    final owner = _design.partById(pairing.target.ownerInstanceId);
    if (owner == null) {
      return _refuse('That attach point is no longer on the craft.');
    }

    final seats = seatsFor(pairing.target);
    final base = _freeInstanceBase(part, seats);
    final roll = _held?.def.id == part.id ? (_held?.roll ?? 0) : 0.0;
    final label = seats.length > 1
        ? 'mount ${part.name} x${seats.length}'
        : 'attach ${part.name}';

    return edit(label, () {
      var first = true;
      for (final node in seats) {
        final id = seats.length == 1 ? base : '$base@$node';
        _design.attachPart(
          def: part,
          instanceId: id,
          toInstanceId: owner.instanceId,
          parentNode: node,
          childNode: pairing.childNodeName,
          roll: roll,
        );
        if (first) {
          _selectedId = id;
          first = false;
        }
      }
      _autoStageIfDue();
    });
  }

  /// Bolt [def] onto the lowest free compatible STACK node without aiming — the
  /// catalog row's `+` button.
  ///
  /// The old assembly screen's whole interaction was this, and a player who
  /// just wants a rocket should never have to hit a 22 px marker to get one.
  /// Lowest node rather than nearest-to-anything because a stack grows
  /// downward from the pod: the next part goes under the last one.
  bool quickStack(PartDef def) {
    if (_design.isEmpty) return placeRoot(def: def);
    final options = [
      for (final p in AttachTargets.pairingsFor(_design, def))
        if (p.target.kind == AttachKind.stack) p
    ];
    if (options.isEmpty) {
      return _refuse('No free stack node fits ${def.name}. Place it on a '
          'surface node in the 3D view.');
    }
    options.sort((a, b) =>
        a.target.positionInCraft.z.compareTo(b.target.positionInCraft.z));
    return attachAt(options.first, def: def);
  }

  /// Re-seat a part already on the craft, carrying its subtree.
  ///
  /// "Move" in this editor is re-mate. There is no free placement to move to,
  /// and [CraftDesign.mate] already carries the branch rigidly, so a half-built
  /// stack survives being re-parented instead of exploding.
  ///
  /// [pairing] must come from `pairingsForMove(instanceId)` — that is the offer
  /// set the domain agreed to, and a pairing built any other way can be refused
  /// here for a reason the player has no way to see coming. Roll is carried
  /// across so a part keeps the spin it was placed with.
  bool remate(String instanceId, TargetPairing pairing) {
    final part = _design.partById(instanceId);
    if (part == null) return _refuse('That part is no longer on the craft.');
    final roll = AttachTargets.currentRoll(_design, instanceId);
    return edit('move ${part.def.name}', () {
      _design.mate(
        instanceId: instanceId,
        toInstanceId: pairing.target.ownerInstanceId,
        parentNode: pairing.target.nodeName,
        childNode: pairing.childNodeName,
        roll: roll,
      );
    });
  }

  /// Break a part's mate, leaving it and its branch exactly where they are.
  bool detach(String instanceId) {
    final part = _design.partById(instanceId);
    if (part == null) return _refuse('That part is no longer on the craft.');
    if (part.attachment == null) return false;
    return edit('detach ${part.def.name}', () => _design.detach(instanceId));
  }

  /// Delete a part, its subtree, and — by default — its symmetry siblings.
  ///
  /// Whole-group is the default because the group is what the player placed:
  /// deleting one of four RCS quads and leaving three is almost never the
  /// intent, and `Shift` is the way to say it was.
  bool deletePart(String instanceId, {bool wholeGroup = true}) {
    final part = _design.partById(instanceId);
    if (part == null) return _refuse('That part is no longer on the craft.');
    final ids = wholeGroup
        ? AttachTargets.symmetryGroupOf(_design, instanceId)
        : {instanceId};
    final label = ids.length > 1
        ? 'delete ${part.def.name} x${ids.length}'
        : 'delete ${part.def.name}';
    return edit(label, () {
      for (final id in ids) {
        // Already gone when an earlier sibling's subtree carried it.
        _design.remove(id);
      }
    });
  }

  bool deleteSelection({bool wholeGroup = true}) {
    final id = _selectedId;
    if (id == null) return _refuse('Select a part to delete it.');
    return deletePart(id, wholeGroup: wholeGroup);
  }

  /// Everything, in one step. Undoable — which it was not in the old screen,
  /// where `Clear` was the one action that could throw away an hour.
  bool clear() {
    if (_design.isEmpty) return false;
    return edit('clear ${_design.name}', () {
      // Removing a root takes its whole subtree, and every part chains up to
      // one, so this is the whole craft. Materialised first: `roots` is a lazy
      // view over the list being emptied.
      for (final id in [for (final p in _design.roots) p.instanceId]) {
        _design.remove(id);
      }
    });
  }

  /// Rename the craft. Coalesced, so typing a name is one undo step and not
  /// one per keystroke.
  bool rename(String name) {
    if (name.trim() == _design.name) return false;
    return edit('rename to "${name.trim()}"', () => _design.name = name,
        coalesceKey: 'rename');
  }

  /// Replace the craft as an UNDOABLE step — opening a saved design.
  ///
  /// The step is worth having: a player who opens the wrong slot over an
  /// unsaved craft has one keystroke to get it back.
  bool adopt(CraftDesign design, {String label = 'open craft'}) => edit(label, () {
        _design = design;
        _selectedId = null;
        _autoStaged = false;
      });

  /// Replace the craft as a fresh BASELINE, discarding the history.
  ///
  /// For startup and autosave recovery: the previous craft's steps are not
  /// steps in this one, and offering to undo into a design the player has left
  /// behind is worse than offering nothing.
  void reset(CraftDesign design) {
    _design = design;
    _history.reset(_codec.encode(design));
    _selectedId = null;
    _held = null;
    _blocked = null;
    _autoStaged = false;
    _openCoalesceKey = null;
    _revision++;
    _notify();
  }

  // ---------------- rotating ----------------

  /// `Q`/`E`: roll the ghost when a part is held, the selection otherwise.
  bool roll(double delta) {
    if (_held != null) {
      rollHeld(delta);
      return true;
    }
    return rollSelection(delta);
  }

  /// Spin the whole selection about each part's own mate axis.
  ///
  /// A mated part's ONLY freedom is roll about that axis, and re-solving the
  /// mate with a new roll is how it is expressed — there is no stored roll
  /// field and no schema change. A free/root part has no mate axis, so it spins
  /// about the craft's +Z instead.
  ///
  /// Coalesced per selection: a drag or a key repeat is one undo step.
  bool rollSelection(double delta) {
    final ids = selection;
    if (ids.isEmpty) return _refuse('Select a part to roll it.');
    if (delta == 0) return false;
    return edit('roll', () {
      for (final id in ids) {
        final part = _design.partById(id);
        if (part == null) continue;
        final mate = part.attachment;
        if (mate == null) {
          _design.rotateTo(
              id,
              (Quaternion.axisAngle(Vector3.unitZ, delta) * part.rotation)
                  .normalized);
          continue;
        }
        _design.mate(
          instanceId: id,
          toInstanceId: mate.parentInstanceId,
          parentNode: mate.parentNode,
          childNode: mate.childNode,
          roll: AttachTargets.currentRoll(_design, id) + delta,
        );
      }
    }, coalesceKey: 'roll:${_selectedId ?? ''}');
  }

  // ---------------- staging ----------------

  /// Put a part — and by default its symmetry group — in staging group [stage],
  /// then squeeze the numbering dense.
  ///
  /// Whole-group by default is the difference between one action and sixteen on
  /// a craft with four quads and four legs.
  bool assignStage(String instanceId, int stage, {bool wholeGroup = true}) {
    if (!_design.contains(instanceId)) {
      return _refuse('That part is no longer on the craft.');
    }
    final ids = wholeGroup
        ? AttachTargets.symmetryGroupOf(_design, instanceId)
        : {instanceId};
    final target = stage < 0 ? 0 : stage;
    return edit('stage $target', () {
      for (final id in ids) {
        _design.assignStage(id, target);
      }
      _design.renumberStages();
    });
  }

  /// The `Stage -/+` stepper, on the current selection.
  bool nudgeStage(int delta) {
    final id = _selectedId;
    final part = id == null ? null : _design.partById(id);
    if (part == null) return _refuse('Select a part to change its stage.');
    return assignStage(id!, part.stage + delta);
  }

  /// Drag-reorder of the staging list.
  ///
  /// [from] and [to] index [CraftDesign.stages], and [to] may be one past the
  /// end — `ReorderableListView` reports the drop slot, not the destination
  /// index, which is what the `if (to > from) to -= 1` correction is for. That
  /// off-by-one is the bug the old screen already fixed once; it is kept here
  /// rather than re-derived by every caller.
  bool moveStageGroup(int from, int to) {
    final order = _design.stages;
    if (from < 0 || from >= order.length) return false;
    if (to < 0 || to > order.length) return false;
    var at = to;
    if (at > from) at -= 1;
    if (at == from) return false;

    return edit('reorder stages', () {
      final reordered = List<int>.of(order);
      reordered.insert(at, reordered.removeAt(from));
      final rank = {for (var i = 0; i < reordered.length; i++) reordered[i]: i};
      // Iterate a COPY: assignStage rewrites the live list, and every part must
      // be ranked by the stage it had before the pass started.
      for (final p in [..._design.parts]) {
        _design.assignStage(p.instanceId, rank[p.stage] ?? p.stage);
      }
      _design.renumberStages();
    });
  }

  /// AUTO STAGE: derive the whole staging from the attach tree.
  bool autoStage() {
    if (_design.isEmpty) return false;
    return edit('auto stage', () {
      CraftBalance.autoStage(_design);
      _autoStaged = true;
    });
  }

  bool renumberStages() {
    if (_design.isEmpty) return false;
    return edit('renumber stages', () => _design.renumberStages());
  }

  // ---------------- persistence ----------------

  /// Named saves, newest first.
  Future<List<CraftSaveSlot>> savedSlots() async {
    try {
      return await store.list();
    } on Object catch (e) {
      _refuse('Could not read the save list: $e');
      return const [];
    }
  }

  Future<bool> save(String slot) async {
    try {
      await store.save(slot, _design);
    } on Object catch (e) {
      return _refuse('Could not save "$slot": ${_reason(e)}');
    }
    _blocked = null;
    _notify();
    return true;
  }

  /// Open a saved craft as an undoable step. False (with [blocked] set) when
  /// the slot is empty or the payload will not decode against [catalog].
  Future<bool> load(String slot) async {
    final CraftDesign? loaded;
    try {
      loaded = await store.load(slot, catalog: catalog);
    } on Object catch (e) {
      return _refuse('Could not open "$slot": ${_reason(e)}');
    }
    if (loaded == null) return _refuse('There is no saved craft called "$slot".');
    return adopt(loaded, label: 'open "$slot"');
  }

  Future<bool> deleteSlot(String slot) async {
    try {
      return await store.delete(slot);
    } on Object catch (e) {
      return _refuse('Could not delete "$slot": ${_reason(e)}');
    }
  }

  /// Write the recovery copy now. Never throws: losing an autosave is a
  /// cosmetic failure and must not take a gesture callback with it.
  Future<void> autosave() async {
    try {
      await store.saveAutosave(_design);
    } on Object catch (_) {
      // Deliberately silent — see above. A failed autosave is not a thing to
      // interrupt the player about, and the next edit tries again.
    }
  }

  /// Debounced [autosave]. Safe to call from every edit: only the last one in
  /// [delay] writes, so a symmetry drag does not hammer the preference store.
  void scheduleAutosave({Duration delay = const Duration(seconds: 3)}) {
    _autosaveTimer?.cancel();
    if (_disposed) return;
    _autosaveTimer = Timer(delay, () {
      if (_disposed) return;
      unawaited(autosave());
    });
  }

  /// Adopt the recovery copy as a fresh baseline. False when there is none, or
  /// when it will not decode.
  Future<bool> restoreAutosave() async {
    final CraftDesign? recovered;
    try {
      recovered = await store.loadAutosave(catalog: catalog);
    } on Object catch (e) {
      return _refuse('The autosaved craft could not be opened: ${_reason(e)}');
    }
    if (recovered == null) return false;
    reset(recovered);
    return true;
  }

  // ---------------- ids ----------------

  /// A free instance id for [def], shaped `<defId>-<n>` like the old screen's.
  ///
  /// The counter only ever moves forward, but the design is still checked:
  /// undo, redo and load all put back ids the counter has already passed.
  String nextInstanceId(PartDef def) => _freeInstanceBase(def, const ['']);

  /// A base id whose whole symmetry family — `<base>@<node>` for every seat —
  /// is free. Checking the family rather than the base is what stops a ×4 mount
  /// from failing on its third copy after an undo.
  String _freeInstanceBase(PartDef def, List<String> seats) {
    bool taken(int n) {
      final base = '${def.id}-$n';
      if (seats.length <= 1) return _design.contains(base);
      return seats.any((s) => _design.contains('$base@$s'));
    }

    var n = _nextId;
    while (taken(n)) {
      n++;
    }
    _nextId = n + 1;
    return '${def.id}-$n';
  }

  // ---------------- internals ----------------

  /// Stage the craft for the player the first time it becomes stageable.
  ///
  /// Spec 6.4: `attachPart` defaults a part's stage to its parent's, so a whole
  /// stacked craft lands in stage 0 — and `Vessel.deltaVCapacity()` sums
  /// propellant over the ACTIVE stage only, which would make the stats pane
  /// show a different number under the same label. Running this inside the
  /// caller's edit closure keeps it part of the same undo step, so the player
  /// can take it back in one keystroke if they had their own plan.
  void _autoStageIfDue() {
    if (_autoStaged) return;
    var engines = 0;
    var decoupler = false;
    for (final p in _design.parts) {
      if (p.def.isEngine) engines++;
      if (p.def.category == PartCategory.decoupler) decoupler = true;
    }
    if (engines < 2 && !decoupler) return;
    _autoStaged = true;
    CraftBalance.autoStage(_design);
  }

  void _rollback(
      Map<String, dynamic> snapshot, String? selection, String message) {
    _design = _codec.decode(snapshot, catalog: catalog);
    _selectedId = selection;
    _blocked = message;
    _revision++;
    _notify();
  }

  void _adoptSnapshot(Map<String, dynamic> snapshot) {
    _design = _codec.decode(snapshot, catalog: catalog);
    _openCoalesceKey = null;
    _blocked = null;
    _revision++;
    _pruneSelection();
    _notify();
  }

  void _pruneSelection() {
    final id = _selectedId;
    if (id != null && !_design.contains(id)) _selectedId = null;
  }

  void _endGesture() => _openCoalesceKey = null;

  bool _refuse(String message) {
    _blocked = message;
    _notify();
    return false;
  }

  /// The sentence out of a thrown object, without the exception's own prefix —
  /// [blocked] is shown to a player, not to a log.
  static String _reason(Object e) => switch (e) {
        StateError() => e.message,
        FormatException() => e.message,
        ArgumentError() => '${e.message ?? e}',
        _ => '$e',
      };

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    super.dispose();
  }
}
