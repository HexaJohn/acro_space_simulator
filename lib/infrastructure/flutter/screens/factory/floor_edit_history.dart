// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Undo / redo for every floor edit (docs/plans/factory-floors.md §10 item
/// 9; the user chose undo for EVERY edit, not just area deletes).
///
/// **Through the editor surface, never around it.** Each recorded edit is a
/// call on [FactoryFloorEditor] and so is each undo: undoing a placement is
/// a `remove`, undoing a removal is a `place` of the old placement, undoing
/// a turn is a `setDir` back. The floor's own rules still judge every step,
/// so the fake in the tests, the sandbox floor and a colony's live floor
/// all undo the same way, and nothing here can put the floor in a state its
/// editor surface couldn't.
///
/// **Structure, not goods.** Undo restores the LAYOUT. Goods a removal (or
/// a recipe change) set down as floor piles stay piles: re-placing a
/// station gives back an empty station, and the piles are still on the
/// floor for handlers to clear. Faking goods back into buffers would mint
/// or destroy items behind the floor's conservation ledger, so it is
/// deliberately not done.
///
/// **Undo isn't a purchase.** Replays pass `restore: true` to `place`,
/// `setMode` and `hire`, which skips the colony's unlock gate but no layout
/// rule: a young colony that area-deleted part of a template floor
/// (assisted stations it can't buy yet) must still be able to take the
/// delete back.
///
/// **Capex stays honest.** A colony settles a floor edit when the floor is
/// closed (`CityFactories.closeFloor`), as the cost difference between the
/// blueprint it opened with and the one it closes with. Undo only changes
/// that "after" blueprint like any other edit, so an undone edit costs
/// nothing and nothing is double-charged.
///
/// **Ids.** A floor hands out `max id + 1`, so a removed object's id can be
/// reused by the next placement, and a re-placed object (an undone removal)
/// comes back with a NEW id. Recorded ops therefore never hold floor ids:
/// they hold history-local HANDLES, bound to whatever floor id the object
/// has while it stands and unbound while it is gone. A reused id can then
/// never be mistaken for the object that used to have it.
library;

import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';

/// Most undo steps kept; older ones fall off the bottom.
const int kUndoLimit = 200;

/// One primitive, invertible edit (see the library doc for handles).
sealed class _Op {}

final class _Place extends _Op {
  _Place(this.p, this.h);
  final Placement p;
  final int h;
}

final class _Remove extends _Op {
  _Remove(this.old, this.h);
  final Placement old;
  final int h;
}

final class _Turn extends _Op {
  _Turn(this.h, this.from, this.to);
  final int h;
  final Dir4 from, to;
}

final class _Recipe extends _Op {
  _Recipe(this.h, this.from, this.to);
  final int h;
  final String from, to;
}

final class _Mode extends _Op {
  _Mode(this.h, this.from, this.to);
  final int h;
  final MachineMode from, to;
}

final class _Hire extends _Op {
  _Hire(this.kind, this.delta);
  final HandlerKind kind;
  final int delta;
}

/// One undo step: every primitive edit one player action made (a dragged
/// belt run, an area delete, an arm's filter change), undone together.
class _FloorEdit {
  _FloorEdit(this.label, this._ops);
  final String label;
  final List<_Op> _ops;
  int get length => _ops.length;
}

/// What an [FloorEditHistory.undo] or [FloorEditHistory.redo] did.
class HistoryOutcome {
  const HistoryOutcome(this.label, this.failed);
  final String label;

  /// Primitive steps the floor refused (something now stands in the way, or
  /// an unlock was lost). The step is then dropped, not kept for redo: a
  /// half-applied step can't be replayed faithfully.
  final int failed;
  bool get ok => failed == 0;
}

class FloorEditHistory {
  FloorEditHistory(this.sim, {this.limit = kUndoLimit});

  final FactoryFloorEditor sim;
  final int limit;

  final List<_FloorEdit> _undo = [];
  final List<_FloorEdit> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  // ---- handles -----------------------------------------------------------

  int _nextHandle = 0;
  final Map<int, int> _simOf = {};
  final Map<int, int> _handleOf = {};

  int _handle(int simId) {
    final had = _handleOf[simId];
    if (had != null) return had;
    final h = _nextHandle++;
    _bind(h, simId);
    return h;
  }

  void _bind(int h, int simId) {
    // A reused floor id: whatever handle held it is for an object that is
    // gone, and must not follow the id to its new owner.
    final stale = _handleOf[simId];
    if (stale != null && stale != h) _simOf.remove(stale);
    _simOf[h] = simId;
    _handleOf[simId] = h;
  }

  void _unbind(int h) {
    final s = _simOf.remove(h);
    if (s != null) _handleOf.remove(s);
  }

  // ---- recording ---------------------------------------------------------

  List<_Op>? _open;
  String _openLabel = '';
  int _depth = 0;

  /// Runs [body] and records every edit it makes as ONE undo step named
  /// [label]. Nested groups fold into the outermost. A group that edited
  /// nothing leaves no step.
  void group(String label, void Function() body) {
    beginGroup(label);
    try {
      body();
    } finally {
      endGroup();
    }
  }

  /// Opens a step that stays open ACROSS events, for a player action that
  /// isn't one synchronous call: the hover-delete sweep (hold X and move
  /// the mouse, docs/plans/factory-floors.md §10 item 12) deletes one tile
  /// per pointer event, yet the player thinks of the whole sweep as one
  /// edit, so one Ctrl+Z must bring all of it back. Every [beginGroup]
  /// needs its [endGroup]; nesting folds into the outermost like [group].
  void beginGroup(String label) {
    if (_depth++ == 0) {
      _open = [];
      _openLabel = label;
    }
  }

  /// Closes the step [beginGroup] opened (a no-op when none is open, so a
  /// lost key-up can be closed defensively more than once).
  void endGroup() {
    if (_depth == 0) return;
    if (--_depth == 0) {
      final ops = _open!;
      _open = null;
      _push(_FloorEdit(_openLabel, ops));
    }
  }

  /// A [beginGroup] step is open (a sweep in progress).
  bool get grouping => _depth > 0;

  void _record(_Op op, String label) {
    final open = _open;
    if (open != null) {
      open.add(op);
    } else {
      _push(_FloorEdit(label, [op]));
    }
  }

  void _push(_FloorEdit e) {
    if (e._ops.isEmpty) return;
    _undo.add(e);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  EditResult place(Placement p) {
    final r = sim.place(p);
    final id = r.placementId;
    if (r.ok && id != null) {
      final h = _nextHandle++;
      _bind(h, id);
      _record(_Place(p, h), 'Place');
    }
    return r;
  }

  /// Removes [old] (the placement as it stands, so undo can put it back).
  EditResult remove(Placement old) {
    final h = _handle(old.id);
    final r = sim.remove(old.id);
    if (r.ok) {
      _unbind(h);
      _record(_Remove(old, h), 'Delete');
    }
    return r;
  }

  EditResult rotate(Placement p, {bool ccw = false}) {
    final r = sim.rotate(p.id, ccw: ccw);
    if (r.ok) {
      _record(_Turn(_handle(p.id), p.dir, ccw ? p.dir.turnCcw : p.dir.turnCw),
          'Rotate');
    }
    return r;
  }

  EditResult setDir(Placement p, Dir4 dir) {
    final r = sim.setDir(p.id, dir);
    if (r.ok && p.dir != dir) {
      _record(_Turn(_handle(p.id), p.dir, dir), 'Redirect');
    }
    return r;
  }

  EditResult setRecipe(Placement p, String recipe) {
    final r = sim.setRecipe(p.id, recipe);
    final from = p.recipe;
    if (r.ok && from != null && from != recipe) {
      _record(_Recipe(_handle(p.id), from, recipe), 'Recipe');
    }
    return r;
  }

  EditResult setMode(Placement p, MachineMode mode) {
    final r = sim.setMode(p.id, mode);
    if (r.ok && p.crew != mode) {
      _record(_Mode(_handle(p.id), p.crew, mode), 'Crew mode');
    }
    return r;
  }

  EditResult hire(HandlerKind kind, int delta) {
    final r = sim.hire(kind, delta);
    if (r.ok && delta != 0) _record(_Hire(kind, delta), 'Hire');
    return r;
  }

  // ---- replay --------------------------------------------------------------

  /// The floor id handle [h] is bound to now, or -1 (gone: the floor
  /// answers noSuchPlacement and the step counts as failed).
  int _id(int h) => _simOf[h] ?? -1;

  bool _placeBound(Placement p, int h) {
    final r = sim.place(p, restore: true);
    final id = r.placementId;
    if (!r.ok || id == null) return false;
    _bind(h, id);
    return true;
  }

  bool _removeBound(int h) {
    final ok = sim.remove(_id(h)).ok;
    if (ok) _unbind(h);
    return ok;
  }

  bool _invert(_Op op) => switch (op) {
        _Place(:final h) => _removeBound(h),
        _Remove(:final old, :final h) => _placeBound(old, h),
        _Turn(:final h, :final from) => sim.setDir(_id(h), from).ok,
        _Recipe(:final h, :final from) => sim.setRecipe(_id(h), from).ok,
        _Mode(:final h, :final from) => sim.setMode(_id(h), from, restore: true).ok,
        _Hire(:final kind, :final delta) => sim.hire(kind, -delta, restore: true).ok,
      };

  bool _apply(_Op op) => switch (op) {
        _Place(:final p, :final h) => _placeBound(p, h),
        _Remove(:final h) => _removeBound(h),
        _Turn(:final h, :final to) => sim.setDir(_id(h), to).ok,
        _Recipe(:final h, :final to) => sim.setRecipe(_id(h), to).ok,
        _Mode(:final h, :final to) => sim.setMode(_id(h), to, restore: true).ok,
        _Hire(:final kind, :final delta) => sim.hire(kind, delta, restore: true).ok,
      };

  /// Takes back the last step (null: nothing to undo). Its primitive edits
  /// are inverted newest first.
  HistoryOutcome? undo() {
    if (_undo.isEmpty) return null;
    final e = _undo.removeLast();
    var failed = 0;
    for (var i = e._ops.length - 1; i >= 0; i--) {
      if (!_invert(e._ops[i])) failed++;
    }
    if (failed == 0) _redo.add(e);
    return HistoryOutcome(e.label, failed);
  }

  /// Re-does the last undone step (null: nothing to redo).
  HistoryOutcome? redo() {
    if (_redo.isEmpty) return null;
    final e = _redo.removeLast();
    var failed = 0;
    for (final op in e._ops) {
      if (!_apply(op)) failed++;
    }
    if (failed == 0) _undo.add(e);
    return HistoryOutcome(e.label, failed);
  }
}
