// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../../../../domain/craft/attach_targets.dart';
import '../../../../domain/parts/part_def.dart';
import '../../../../domain/shared/vector3.dart';

// The plain value types the craft editor's controller holds.
//
// Deliberately Flutter-free: nothing here imports a widget, so the editor's
// state machine — which part is on the cursor, which of its nodes is going to
// mate, how many copies a click will place, and what undo will put back — is
// testable in a plain `test()` without pumping a tree. The controller that owns
// these is the only thing that needs `ChangeNotifier`.
//
// Units are METRES and RADIANS in the craft body frame: Z-up, nose on +Z.

/// What a click in the viewport does.
///
/// The tool is explicit rather than derived from "is a part held", because the
/// staging view has to keep painting `S#` badges while nothing is held, and a
/// derived mode would have no way to say so.
enum EditorTool {
  /// Click picks a part; drag orbits. The resting state.
  select,

  /// A part is on the cursor and a click commits it to the hovered target.
  /// Entered by holding a part, left by dropping it.
  place,

  /// Click picks a part to re-stage; the overlay shows staging badges.
  stage,
}

/// The part on the cursor, plus the two choices that travel with it.
///
/// [childNodeName] is which of the HELD part's own nodes seats against the
/// target — a decoupler has two and they are not interchangeable, so `W`/`S`
/// cycles this and the ghost flips end for end. Null means "whatever the
/// pairing offers", which is what a freshly held part wants: most parts have
/// exactly one plausible mating node and asking the player to choose it would
/// be noise.
///
/// [roll] is the spin about the mate axis the commit will be solved with. It
/// lives on the held part rather than on the controller because it is a
/// property of the thing being placed: dropping the part and picking up a
/// different one must not inherit the last part's roll.
class HeldPart {
  final PartDef def;

  /// Attach-node name on [def], or null to let the pairing decide.
  final String? childNodeName;

  /// Radians about the mate axis, normalised to `(-pi, pi]`.
  final double roll;

  const HeldPart({required this.def, this.childNodeName, this.roll = 0});

  /// Every node [def] authors, in authored order — the cycle `W`/`S` walks.
  List<String> get nodeNames => [for (final n in def.attachNodes) n.name];

  /// The next node in [nodeNames], wrapping. From "no choice yet" a forward
  /// step lands on the first node and a backward step on the last, so the first
  /// press always moves somewhere visible instead of appearing to do nothing.
  HeldPart cycleNode(int delta) {
    final names = nodeNames;
    if (names.isEmpty) return this;
    final at = childNodeName == null ? -1 : names.indexOf(childNodeName!);
    if (at < 0) return withChildNode(delta >= 0 ? names.first : names.last);
    return withChildNode(names[(at + delta) % names.length]);
  }

  HeldPart withChildNode(String? name) =>
      HeldPart(def: def, childNodeName: name, roll: roll);

  HeldPart withRoll(double value) =>
      HeldPart(def: def, childNodeName: childNodeName, roll: normaliseRoll(value));

  HeldPart rolledBy(double delta) => withRoll(roll + delta);

  /// Fold an angle into `(-pi, pi]` so a roll widget and a HUD readout never
  /// show 375 degrees, and so two rolls that mean the same orientation compare
  /// equal.
  static double normaliseRoll(double radians) {
    const twoPi = 2 * math.pi;
    // Dart's `%` on doubles returns a value in [0, twoPi) for a positive
    // divisor, including for negative input, so one fold is enough.
    final wrapped = radians % twoPi;
    return wrapped > math.pi ? wrapped - twoPi : wrapped;
  }

  @override
  bool operator ==(Object other) =>
      other is HeldPart &&
      other.def.id == def.id &&
      other.childNodeName == childNodeName &&
      other.roll == roll;

  @override
  int get hashCode => Object.hash(def.id, childNodeName, roll);

  @override
  String toString() =>
      'HeldPart(${def.id}${childNodeName == null ? '' : '.$childNodeName'}, '
      'roll ${roll.toStringAsFixed(3)})';
}

/// How many copies one click places, and how they are spaced.
///
/// Radial [count] means "one copy on each of [count] evenly spaced members of
/// the target node's ring" — never a rotation about the craft origin. The
/// distinction is the whole symmetry model: each copy names its OWN authored
/// node, so the design validates on load and works for an off-axis parent. See
/// [NodeRing].
///
/// [mirror] replaces the count with a reflected PAIR, which is the right tool
/// for anything off-axis: a mount at (2, 0.5, 1) mirrors to (-2, 0.5, 1), where
/// a half turn about +Z would send it to (-2, -0.5, 1) — the same part swung
/// round, not its counterpart.
///
/// A choice is only ever a REQUEST. What actually lands is [seatsOn], because a
/// target with no ring can express nothing but one copy and the editor greys
/// the rest rather than scattering parts.
class SymmetryChoice {
  /// Copies to place, >= 1. Ignored when [mirror] is set.
  final int count;

  final bool mirror;

  /// Craft-frame normal of the mirror plane through the origin. +X (the YZ
  /// plane) matches `CraftDesign.attachMirrored`'s default and the left/right
  /// symmetry a player means by "mirror".
  final Vector3 mirrorPlaneNormal;

  const SymmetryChoice({
    this.count = 1,
    this.mirror = false,
    this.mirrorPlaneNormal = Vector3.unitX,
  });

  /// One copy per click. The default, and what a target without a ring gets.
  static const SymmetryChoice single = SymmetryChoice();

  const SymmetryChoice.radial(this.count)
      : mirror = false,
        mirrorPlaneNormal = Vector3.unitX;

  const SymmetryChoice.mirrored({this.mirrorPlaneNormal = Vector3.unitX})
      : count = 2,
        mirror = true;

  bool get isSingle => !mirror && count <= 1;

  /// How many copies this choice can actually express on [ring].
  ///
  /// Null ring, or a count the ring cannot divide evenly, collapses to 1: three
  /// copies on a four-ring have nowhere even to sit, and placing them anyway
  /// would build a craft that yaws under thrust and still look valid in the
  /// save file.
  int seatsOn(NodeRing? ring) {
    if (ring == null || ring.count < 2) return 1;
    if (mirror) return 2;
    if (count < 2 || ring.count % count != 0) return 1;
    return count;
  }

  @override
  bool operator ==(Object other) =>
      other is SymmetryChoice &&
      other.count == count &&
      other.mirror == mirror &&
      other.mirrorPlaneNormal == mirrorPlaneNormal;

  @override
  int get hashCode => Object.hash(count, mirror, mirrorPlaneNormal);

  @override
  String toString() => mirror ? 'SymmetryChoice(mirror)' : 'SymmetryChoice(x$count)';
}

/// One reversible step: the snapshot to go back to, and the name of the edit
/// that left it behind.
class UndoEntry<T> {
  /// Human-readable name of the edit applied AFTER [snapshot] was current —
  /// so a menu reads "Undo mount RCS quad x4" off the entry it would restore.
  final String label;

  final T snapshot;

  const UndoEntry(this.label, this.snapshot);

  @override
  String toString() => 'UndoEntry($label)';
}

/// Past / present / future over whole-state snapshots.
///
/// Snapshots rather than inverse operations: the craft editor's mutations are
/// not individually invertible in any cheap way (a symmetry delete removes four
/// parts and their subtrees; auto-staging rewrites every part's stage; a
/// re-mate carries a whole branch), and an inverse-op scheme has to be correct
/// for every one of them or undo silently corrupts the craft. A `CraftDesign`
/// encodes to a few kilobytes of plain maps, so keeping [depth] of them is
/// cheaper than being wrong.
///
/// The type parameter is the snapshot form; the controller uses
/// `Map<String, dynamic>` from `CraftDesignCodec`, which makes "undo restored
/// the exact craft" a comparison a test can actually make.
class UndoStack<T> {
  UndoStack({required T initial, this.depth = 200})
      : assert(depth > 0),
        _present = initial;

  /// How many past states are kept. The oldest is dropped past this, so a long
  /// session cannot grow without bound.
  final int depth;

  final List<UndoEntry<T>> _past = [];
  final List<UndoEntry<T>> _future = [];
  T _present;

  /// The state the world is in right now.
  T get present => _present;

  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  /// Name of the edit [undo] would reverse, or null.
  String? get undoLabel => _past.isEmpty ? null : _past.last.label;

  /// Name of the edit [redo] would re-apply, or null.
  String? get redoLabel => _future.isEmpty ? null : _future.last.label;

  int get undoCount => _past.length;
  int get redoCount => _future.length;

  /// Commit an edit named [label] that produced [next].
  ///
  /// Drops the redo stack, because once the timeline forks there is no honest
  /// way to keep both branches: a redo that re-applied an edit made against a
  /// state that no longer exists would put parts back at coordinates the craft
  /// has moved past.
  void record(String label, T next) {
    _past.add(UndoEntry(label, _present));
    if (_past.length > depth) _past.removeAt(0);
    _future.clear();
    _present = next;
  }

  /// Fold [next] into the step already on the stack instead of opening a new
  /// one — the continuous-gesture case.
  ///
  /// A roll drag or a rename fires a mutation per frame or per keystroke; each
  /// one is a real edit and none of them is a step a player wants to undo
  /// separately. The caller decides when a gesture starts (first mutation:
  /// [record]) and when it ends; everything between is amended.
  void amend(T next) => _present = next;

  /// Step back one edit, or null when there is nothing to go back to.
  T? undo() {
    if (_past.isEmpty) return null;
    final entry = _past.removeLast();
    _future.add(UndoEntry(entry.label, _present));
    _present = entry.snapshot;
    return _present;
  }

  /// Step forward one edit, or null when nothing was undone.
  T? redo() {
    if (_future.isEmpty) return null;
    final entry = _future.removeLast();
    _past.add(UndoEntry(entry.label, _present));
    _present = entry.snapshot;
    return _present;
  }

  /// Adopt [present] as a fresh baseline with no history.
  ///
  /// For opening a craft at startup: the previous craft's steps are not steps
  /// in this one, and offering to undo into a design the player has left is
  /// worse than offering nothing.
  void reset(T present) {
    _past.clear();
    _future.clear();
    _present = present;
  }

  @override
  String toString() => 'UndoStack(${_past.length} back, ${_future.length} forward)';
}
