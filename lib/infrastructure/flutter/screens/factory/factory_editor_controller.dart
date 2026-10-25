// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The floor editor's state and gestures, kept out of the widget tree
/// (docs/plans/factory-floors.md §4).
///
/// The screen is a thin shell: panels call commands here, the canvas feeds
/// raw pointer events here, and the painter reads the camera, ghost and
/// overlays from here. Keeping it one plain object means the interaction
/// rules — which button pans, how a dragged belt run is directed, when a
/// ghost turns red — are testable and live in one place.
///
/// Two notifiers split the redraw cost: [frame] ticks every animation frame
/// and repaints ONLY the canvas; [live] ticks a few times a second and
/// rebuilds the side panels (readouts, inspector contents). The controller
/// itself notifies on discrete changes (tool, selection, roster).
///
/// Everything the editor does to the floor goes through [FactorySim]'s
/// editor surface; the controller never edits a blueprint directly, so the
/// fake in the tests and the real `FactoryFloor` are interchangeable. The
/// ghost preview asks the sim too ([FactoryFloorEditor.check], the dry run
/// of `place`), so the preview and the commit can never disagree.
///
/// **Who drives the floor.** In the sandbox the editor is the floor's only
/// driver and steps it every frame ([drivesSim]). Inside a colony (wave 3)
/// the colony steps every floor and owns its period ledger; the editor then
/// only watches. Either way the throughput readout diffs the floor's
/// never-reset [FactoryFloorView.lifetime] over a rolling wall-clock window
/// and NEVER calls `takeLedger`, so opening a floor can't steal a period's
/// counters from the colony's books.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../../../domain/colony/city/factory/factory_capex.dart';
import '../../../../domain/colony/city/factory/factory_catalog.dart';
import '../../../../domain/colony/city/factory/factory_colony_port.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_ledger.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_scenario.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/factory_unlocks.dart';
import 'floor_edit_history.dart';
import 'floor_layout_index.dart';

/// What a primary click on the floor does.
enum FactoryTool { select, place, delete }

/// Diagnostic tints over the floor (§4 "Overlays").
enum FactoryOverlay { power, staffing, bottleneck, traffic }

/// Closest the camera zooms out / in, screen pixels per tile.
const double kMinPxPerTile = 0.5;
const double kMaxPxPerTile = 64;

/// Wheel delta (logical px) that zooms by a factor of e.
const double kWheelZoomScale = 400;

/// Largest wall-clock step fed to the sim in one frame, seconds: a stall
/// (window drag, breakpoint) must not turn into a burst of sub-steps.
const double kMaxFrameDt = 0.1;

/// Side panels refresh this often (wall seconds); the canvas runs every
/// frame regardless.
const double kLiveEveryS = 0.25;

/// The floor's lifetime ledger is sampled once per this many WALL seconds
/// and pushed onto the rolling rate window (wall time, not sim time, so the
/// readout keeps moving whoever steps the floor and at whatever speed).
const double kRateSampleS = 1.0;

/// Wall seconds the throughput readout looks back over: 30 s is a few of
/// the template's slowest cycles at 1x, yet short enough that an edit's
/// effect shows within half a minute.
const double kRateWindowS = 30.0;

/// The sim-time unit [kHeatDecay] is quoted per; decay is applied
/// continuously as kHeatDecay^(simDt / kHeatSampleS).
const double kHeatSampleS = 1.0;

/// Tiles per side of one traffic heat-map cell (8 m: coarse enough to read
/// at a glance, fine enough to show which aisle is jammed).
const int kHeatCellTiles = 4;

/// Per-sample decay of the heat map (per [kHeatSampleS]): ~30 s half-life,
/// so the map shows the current pattern, not the whole session.
const double kHeatDecay = 0.977;

/// Default span a click (no drag) lays for a spanned kind: a 2-tile forklift
/// aisle's width, square.
const (int, int) kDefaultSpan = (2, 2);

/// How a dragged belt (or crossing) run, or an aisle, follows the cursor
/// (docs/plans/factory-floors.md §10 item 10).
///
/// Freeform grows the run tile by tile along the path the cursor actually
/// took — great for snaking around machines, maddening for a long straight
/// line, where a wobble of the hand puts a kink in it. So the editor also
/// offers the two shapes nearly every run really is.
enum RunMode {
  /// One leg, locked to the drag's dominant axis.
  straight,

  /// Two legs with one corner; F flips which leg comes first.
  lShape,

  /// Follows the cursor's path (the original behaviour).
  freeform,
}

/// One tile (or one piece) of the placement preview.
class GhostPiece {
  const GhostPiece(this.placement, this.rect, this.check,
      {this.replaces, this.redirects});
  final Placement placement;

  /// A belt this piece swaps out (a crossing laid over an existing belt
  /// tile): committed as remove-then-place, restored if the place fails.
  final int? replaces;

  /// An existing belt or crossing this piece RE-POINTS instead of placing
  /// anything (a run redrawn over a run, §10 item 8): committed as
  /// `setDir`, so the items riding on it stay on it. [placement] is that
  /// belt as it will be (same id, kind and tile, the run's new facing).
  final int? redirects;

  /// Tiles the piece would cover (for a machine with no recipe yet, the
  /// station's footprint, so the player sees the space it needs).
  final TileRect rect;

  /// The sim's verdict ([FactoryFloorEditor.check]), or a refusal for a
  /// tile an earlier piece of the same dragged run already claims.
  final EditResult check;
}

/// The floor's lifetime counters at one wall-clock instant.
/// What a [FactoryFloorEditor.check] verdict depends on besides the layout:
/// every field of the trial placement (its id is always the sim's next).
typedef _CheckKey = (
  EntityKind,
  int,
  Dir4,
  (int, int)?,
  String?,
  String?,
  MachineMode?,
);

class _LifeSample {
  _LifeSample(this.wall, FactoryLedger l)
      : simSeconds = l.seconds,
        inUnits = {...l.received},
        outUnits = {...l.shipped};
  final double wall;
  final double simSeconds;
  final Map<String, double> inUnits;
  final Map<String, double> outUnits;
}

class FactoryEditorController extends ChangeNotifier {
  FactoryEditorController(this.sim, this.port,
      {this.drivesSim = true, this.unlocks = FactoryUnlocks.all}) {
    // The pickers list the real catalog; make sure it is registered even
    // when the sim is a fake that never touched it.
    ensureFactoryCatalog();
    _lastSim = sim.simSeconds;
    _window.add(_LifeSample(0, sim.lifetime));
  }

  final FactorySim sim;
  final FactoryColonyPort port;

  /// True: the editor steps the floor every frame (the sandbox). False: the
  /// colony does, and the editor never calls `step` or `takeLedger`.
  final bool drivesSim;

  /// What the colony has unlocked, for DISPLAY only (greyed roster rows and
  /// mode chips). The sim enforces its own unlocks and has the last word.
  ///
  /// Mutable, and swapped with [setUnlocks], because a colony parent may
  /// build a fresh (equal) [FactoryUnlocks] on every rebuild: replacing the
  /// whole controller for that would throw away the camera, tool, ghost,
  /// heat map and the rate window, and the readout would never fill.
  FactoryUnlocks unlocks;

  /// Swaps the displayed unlocks in place (see [unlocks]).
  void setUnlocks(FactoryUnlocks u) {
    if (identical(u, unlocks)) return;
    unlocks = u;
    notifyListeners();
  }

  FloorCapex? _capex;
  int _capexRev = -1;
  List<int> _capexRoster = const [];

  /// The layout's build cost in ore, cached per layout revision and roster.
  /// The cost strip rebuilds on every hover and every live tick, and
  /// [capexOf] walks every placement, so the walk runs only when the layout
  /// or the hired fleet actually changed (the roster is compared directly:
  /// a hire need not bump `layoutRev`).
  FloorCapex get capex {
    final bp = sim.blueprint;
    final roster = [for (final k in HandlerKind.values) bp.roster[k] ?? 0];
    final c = _capex;
    if (c != null &&
        _capexRev == sim.layoutRev &&
        listEquals(roster, _capexRoster)) {
      return c;
    }
    _capexRev = sim.layoutRev;
    _capexRoster = roster;
    return _capex = capexOf(bp);
  }

  // ---- Camera ----------------------------------------------------------

  /// Screen pixels per tile.
  double pxPerTile = 12;

  /// Canvas-local position of tile corner (0, 0). +x right, +y (north) UP.
  Offset origin = Offset.zero;

  Size viewSize = Size.zero;
  bool _fitted = false;

  Offset tileToLocal(double tx, double ty) =>
      Offset(origin.dx + tx * pxPerTile, origin.dy - ty * pxPerTile);

  TilePos localToTile(Offset l) => TilePos(
      ((l.dx - origin.dx) / pxPerTile).floor(),
      ((origin.dy - l.dy) / pxPerTile).floor());

  Offset tileCenterLocal(TilePos t) => tileToLocal(t.x + 0.5, t.y + 0.5);

  /// Tiles on screen (clamped to the hall), for culling.
  TileRect get visibleTiles {
    final hall = sim.blueprint.hall;
    final x0 = ((-origin.dx) / pxPerTile).floor() - 1;
    final x1 = ((viewSize.width - origin.dx) / pxPerTile).ceil() + 1;
    final y0 = ((origin.dy - viewSize.height) / pxPerTile).floor() - 1;
    final y1 = (origin.dy / pxPerTile).ceil() + 1;
    final cx0 = x0.clamp(0, hall.w), cx1 = x1.clamp(0, hall.w);
    final cy0 = y0.clamp(0, hall.h), cy1 = y1.clamp(0, hall.h);
    return TileRect(cx0, cy0, cx1 - cx0, cy1 - cy0);
  }

  /// Sets the canvas size; the first call frames the whole hall.
  void setViewSize(Size s) {
    if (s == viewSize) return;
    viewSize = s;
    if (!_fitted && !s.isEmpty) {
      _fitted = true;
      fitHall(notify: false);
    }
  }

  /// Frames the whole hall. [notify] = false when called mid-build (the
  /// first layout), where the coming paint picks the camera up anyway.
  void fitHall({bool notify = true}) {
    final hall = sim.blueprint.hall;
    final w = math.max(1, hall.w + 4), h = math.max(1, hall.h + 4);
    pxPerTile = math
        .min(viewSize.width / w, viewSize.height / h)
        .clamp(kMinPxPerTile, kMaxPxPerTile);
    origin = Offset((viewSize.width - hall.w * pxPerTile) / 2,
        (viewSize.height + hall.h * pxPerTile) / 2);
    if (notify) frame.value++;
  }

  void zoomAt(Offset local, double factor) {
    final next = (pxPerTile * factor).clamp(kMinPxPerTile, kMaxPxPerTile);
    final k = next / pxPerTile;
    origin = local + (origin - local) * k;
    pxPerTile = next;
    _refreshGhost();
    frame.value++;
  }

  // ---- Layout index ----------------------------------------------------

  FloorLayoutIndex? _ix;

  /// The layout index for the sim's current `layoutRev`.
  FloorLayoutIndex get index {
    final ix = _ix;
    if (ix != null && ix.rev == sim.layoutRev) return ix;
    return _ix = FloorLayoutIndex(sim.blueprint, sim.layoutRev);
  }

  // ---- Tool and palette ------------------------------------------------

  FactoryTool tool = FactoryTool.select;

  /// The palette entry being placed (with [tool] == place).
  EntityKind? kind;
  StationKind station = StationKind.smelter;

  /// Recipe for new machines; null = the station's first, if any.
  String? recipeChoice;

  /// Item for new docks and chests.
  String? itemChoice;

  /// The item last chosen for each placeable kind. One shared choice made a
  /// shipping dock placed after a Tubes receiving dock a tubes-ONLY door that
  /// silently refused every frame (found building the tutorial): a receiving
  /// dock must name its item, a shipping dock and a chest default to any.
  final Map<EntityKind, String?> _itemByKind = {};

  /// Facing of the next placement (R turns it).
  Dir4 ghostDir = Dir4.east;

  int? selectedId;
  String? message;

  final Set<FactoryOverlay> overlays = {};

  /// Sim speed multiplier (0 = paused).
  double speed = 1;

  void setTool(FactoryTool t) {
    tool = t;
    if (t != FactoryTool.place) kind = null;
    _cancelDrag();
    _refreshGhost();
    notifyListeners();
  }

  /// Picks a palette entry: [k], and for machines the [st] station.
  void choose(EntityKind k, {StationKind? st}) {
    tool = FactoryTool.place;
    kind = k;
    if (st != null && st != station) {
      station = st;
      recipeChoice = null;
    }
    itemChoice = _itemByKind.containsKey(k)
        ? _itemByKind[k]
        : (k == EntityKind.receivingDock ? FactoryItems.ore.id : null);
    _cancelDrag();
    _refreshGhost();
    notifyListeners();
  }

  /// Recipes the current station can run (empty while the table is).
  List<FactoryRecipe> get stationRecipes => FactoryRecipes.forStation(station);

  /// The recipe new machines get: the chosen one, else the station's first.
  String? get effectiveRecipe {
    final c = recipeChoice;
    if (c != null && FactoryRecipes.byId(c)?.station == station) return c;
    final all = stationRecipes;
    return all.isEmpty ? null : all.first.id;
  }

  void setRecipeChoice(String? id) {
    recipeChoice = id;
    _refreshGhost();
    notifyListeners();
  }

  void setItemChoice(String? id) {
    itemChoice = id;
    final k = kind;
    if (k != null) _itemByKind[k] = id;
    _refreshGhost();
    notifyListeners();
  }

  void select(int? id) {
    selectedId = id;
    notifyListeners();
  }

  void setSpeed(double s) {
    speed = s;
    notifyListeners();
  }

  void toggleOverlay(FactoryOverlay o) {
    if (!overlays.remove(o)) overlays.add(o);
    frame.value++;
    notifyListeners();
  }

  /// A recipe id the product tree is pointing at (docs/plans/
  /// factory-floors.md §4): the painter outlines every machine on this floor
  /// running it, so "where does this step happen here?" is answered on the
  /// floor itself. Null = nothing highlighted.
  String? highlightRecipe;

  void setHighlightRecipe(String? id) {
    if (highlightRecipe == id) return;
    highlightRecipe = id;
    frame.value++;
    notifyListeners();
  }

  /// What a scenario's current tutorial hint points at (empty: nothing).
  /// The palette, roster and header pulse the matching control's border, so
  /// "pick Receiving Dock" shows WHERE without the tutorial card having to
  /// know any widget. Set by the tutorial panel; the editor never reads it
  /// for anything but drawing.
  Set<ScenarioHintTarget> hintTargets = const {};

  void setHintTargets(Set<ScenarioHintTarget> t) {
    if (setEquals(t, hintTargets)) return;
    hintTargets = t;
    notifyListeners();
  }

  bool hinted(ScenarioHintTarget t) => hintTargets.contains(t);

  /// Machines on this floor running [recipeId] (the tree's "N here" hint).
  int machinesRunning(String recipeId) {
    var n = 0;
    for (final m in index.machines) {
      if (m.recipe == recipeId) n++;
    }
    return n;
  }

  // ---- Edits through the sim -------------------------------------------

  /// Every edit the editor makes goes through here, so each is undoable
  /// (Ctrl+Z / Ctrl+Y) and still judged by the sim (see floor_edit_history
  /// .dart: undo restores structure, not goods). One player action — a
  /// dragged run, an area delete, an arm's filter change — is grouped into
  /// one undo step.
  late final FloorEditHistory history = FloorEditHistory(sim);

  void _report(EditResult r) {
    final why = r.refusal;
    message = why == null ? null : refusalText(why);
  }

  /// Hires or lets go through the sim. Buying is the only hire the sim
  /// refuses for policy ([EditRefusal.notAllowed]: not unlocked), so that
  /// refusal is worded as "locked".
  void hire(HandlerKind k, int delta) {
    final r = history.hire(k, delta);
    if (delta > 0 && r.refusal == EditRefusal.notAllowed) {
      message = '${kHandlerSpecs[k]!.label} is locked: '
          'not unlocked by this colony yet';
    } else {
      _report(r);
    }
    notifyListeners();
  }

  void setMachineRecipe(int id, String recipe) {
    final p = index.byId(id);
    _report(p == null
        ? const EditResult.refused(EditRefusal.noSuchPlacement)
        : history.setRecipe(p, recipe));
    frame.value++;
    notifyListeners();
  }

  /// Sets an arm's pick filter ([item] null = any item). The editor surface
  /// has no setItem, so this is an edit like any other: the arm is removed
  /// and placed again with the filter (same tile, same facing), and put
  /// back as it was if the new one is refused. The selection follows the
  /// re-placed arm's new id. One undo step either way.
  void setArmFilter(int id, String? item) {
    final old = index.byId(id);
    if (old == null || old.kind != EntityKind.arm) {
      message = refusalText(EditRefusal.wrongKind);
      notifyListeners();
      return;
    }
    if (old.item == item) return;
    history.group('Arm filter', () {
      final gone = history.remove(old);
      if (!gone.ok) {
        _report(gone);
        return;
      }
      final next = Placement(id: 0, kind: EntityKind.arm, pos: old.pos,
          dir: old.dir, item: item);
      final r = history.place(next);
      if (r.ok) {
        _report(r);
        if (selectedId == id) selectedId = r.placementId;
      } else {
        final back = history.place(Placement(id: 0, kind: EntityKind.arm,
            pos: old.pos, dir: old.dir, item: old.item));
        if (selectedId == id) selectedId = back.placementId;
        _report(r);
      }
    });
    frame.value++;
    notifyListeners();
  }

  void setMachineMode(int id, MachineMode mode) {
    final p = index.byId(id);
    final r = p == null
        ? const EditResult.refused(EditRefusal.noSuchPlacement)
        : history.setMode(p, mode);
    if (r.refusal == EditRefusal.notAllowed) {
      message = '${mode.name[0].toUpperCase()}${mode.name.substring(1)} '
          'stations are locked: not unlocked by this colony yet';
    } else {
      _report(r);
    }
    frame.value++;
    notifyListeners();
  }

  /// Turns the selected object clockwise, or counter-clockwise with [ccw].
  void rotateSelected({bool ccw = false}) {
    final id = selectedId;
    if (id == null) return;
    final p = index.byId(id);
    _report(p == null
        ? const EditResult.refused(EditRefusal.noSuchPlacement)
        : history.rotate(p, ccw: ccw));
    frame.value++;
    notifyListeners();
  }

  void removeSelected() {
    final id = selectedId;
    if (id == null) return;
    final p = index.byId(id);
    _report(p == null
        ? const EditResult.refused(EditRefusal.noSuchPlacement)
        : history.remove(p));
    selectedId = null;
    frame.value++;
    notifyListeners();
  }

  /// R: turns the ghost while placing, else the selected object; [ccw]
  /// (Shift+R) turns the other way (§10 item 7).
  void rotate({bool ccw = false}) {
    if (tool == FactoryTool.place) {
      ghostDir = ccw ? ghostDir.turnCcw : ghostDir.turnCw;
      _refreshGhost();
      frame.value++;
      notifyListeners();
    } else {
      rotateSelected(ccw: ccw);
    }
  }

  /// After an undo or redo: the selection may name something that is gone
  /// (an undone placement) and every cached verdict is stale.
  void _afterHistory(HistoryOutcome? o, String verb) {
    if (o == null) {
      message = 'Nothing to $verb';
    } else if (o.ok) {
      message = null;
    } else {
      message = "Couldn't fully $verb ${o.label.toLowerCase()}: "
          'the floor refused ${o.failed} step${o.failed == 1 ? '' : 's'}';
    }
    final id = selectedId;
    if (id != null && index.byId(id) == null) selectedId = null;
    _refreshGhost();
    _refreshDelete();
    frame.value++;
    notifyListeners();
  }

  /// Ctrl+Z: takes back the last edit's STRUCTURE. Goods it set down as
  /// piles stay piles (floor_edit_history.dart).
  void undo() {
    if (_pointer != null) return; // never mid-drag: the ghost is the edit
    _afterHistory(history.undo(), 'undo');
  }

  /// Ctrl+Y (or Ctrl+Shift+Z): re-does the last undone edit.
  void redo() {
    if (_pointer != null) return;
    _afterHistory(history.redo(), 'redo');
  }

  // ---- Run modes -------------------------------------------------------

  /// How belt runs and aisles follow a drag (§10 item 10).
  RunMode runMode = RunMode.freeform;

  /// L-shape: false = along the drag's x first, then y; true = y first.
  bool lFlip = false;

  void setRunMode(RunMode m) {
    if (m == runMode) return;
    runMode = m;
    _onRunShapeChanged();
  }

  /// M cycles Straight → L-shape → Freeform.
  void cycleRunMode() =>
      setRunMode(RunMode.values[(runMode.index + 1) % RunMode.values.length]);

  /// F flips which leg of an L comes first.
  void flipL() {
    lFlip = !lFlip;
    _onRunShapeChanged();
  }

  void _onRunShapeChanged() {
    _updateRun();
    _refreshGhost();
    frame.value++;
    notifyListeners();
  }

  /// Shift is down (forces Straight while dragging a run; adds floor
  /// markings to an area delete).
  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  /// The run shape in force right now: Shift held mid-drag forces
  /// Straight whatever the toggle says.
  RunMode get effectiveRunMode =>
      _placing && _shift ? RunMode.straight : runMode;

  static bool _isShiftKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.shiftLeft ||
      k == LogicalKeyboardKey.shiftRight ||
      k == LogicalKeyboardKey.shift;

  /// The editor's keys:
  ///
  /// | key              | does                                       |
  /// |------------------|--------------------------------------------|
  /// | R / Shift+R      | rotate ghost or selection cw / ccw         |
  /// | Del, Backspace   | delete the selection                       |
  /// | Esc              | back to Select                             |
  /// | Ctrl+Z           | undo                                       |
  /// | Ctrl+Y, Ctrl+Shift+Z | redo                                   |
  /// | M                | cycle the run mode (Straight, L, Freeform) |
  /// | F                | flip the L-shape's corner                  |
  /// | Shift (held)     | Straight while dragging; area delete also takes floor markings |
  bool handleKey(KeyEvent e) {
    final k = e.logicalKey;
    // Shift changes what a drag in progress previews, pressed or released,
    // without the pointer moving. Never consumed: it is a modifier.
    if (_isShiftKey(k) && e is! KeyRepeatEvent) {
      _updateRun();
      _refreshGhost();
      _refreshDelete();
      frame.value++;
      return false;
    }
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return false;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && k == LogicalKeyboardKey.keyZ) {
      kb.isShiftPressed ? redo() : undo();
      return true;
    }
    if (ctrl && k == LogicalKeyboardKey.keyY) {
      redo();
      return true;
    }
    if (ctrl) return false;
    if (e is KeyRepeatEvent) return false;
    if (k == LogicalKeyboardKey.keyR) {
      rotate(ccw: kb.isShiftPressed);
      return true;
    }
    if (k == LogicalKeyboardKey.keyM) {
      cycleRunMode();
      return true;
    }
    if (k == LogicalKeyboardKey.keyF) {
      flipL();
      return true;
    }
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      removeSelected();
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      setTool(FactoryTool.select);
      return true;
    }
    return false;
  }

  // ---- Ghost -----------------------------------------------------------

  TilePos? hover;
  List<GhostPiece> ghost = const [];

  /// Tiles of a belt (or crossing) run being dragged, in order, in the
  /// shape [effectiveRunMode] gives it (rebuilt by [_updateRun]).
  final List<TilePos> beltPath = [];

  /// The tiles the cursor actually crossed: Freeform's run, and the start
  /// tile every other shape is drawn from. Kept even while Shift forces
  /// Straight, so letting go of Shift gives the freehand path back.
  final List<TilePos> _freePath = [];
  TilePos? _rectStart;

  /// True once a spanned-kind drag has left its start tile; until then the
  /// gesture is a plain click and lays the [kDefaultSpan] the hover showed.
  bool _rectMoved = false;

  /// Kinds laid by dragging a directed run.
  static bool _isRunKind(EntityKind? k) =>
      k == EntityKind.belt || k == EntityKind.crossing;

  static bool _isBeltLike(EntityKind k) =>
      k == EntityKind.belt || k == EntityKind.crossing;

  /// Is [t] on a walkway (an aisle marking)? A belt run laid across one
  /// becomes crossings there, so the aisle stays walkable.
  bool _onWalkway(TilePos t) {
    for (final o in index.overlays) {
      if (o.kind == EntityKind.aisle && o.footprint.contains(t)) return true;
    }
    return false;
  }

  bool get ghostValid => ghost.isNotEmpty && ghost.every((g) => g.check.ok);

  /// [FactoryFloorEditor.check] verdicts for the current layout revision.
  /// The real floor's check scans every placement, and a dragged run
  /// re-checks every one of its pieces on each pointer move, so without
  /// this a long belt drag in a big hall costs O(run × placements) per move.
  /// A verdict depends only on the layout and the placement, so it is
  /// reused until `layoutRev` changes and a drag checks only its new tiles.
  final Map<_CheckKey, EditResult> _checks = {};
  int _checksRev = -1;

  /// [sim.check] through the per-revision memo (see [_checks]).
  EditResult _simCheck(Placement p) {
    final rev = sim.layoutRev;
    if (rev != _checksRev) {
      _checks.clear();
      _checksRev = rev;
    }
    final key = (
      p.kind,
      p.pos.key,
      p.dir,
      p.span,
      p.recipe,
      p.item,
      p.mode,
    );
    return _checks[key] ??= sim.check(p);
  }

  /// The sim's dry-run verdict on [p], refused as an overlap when a tile of
  /// it is already claimed by an earlier piece of the same dragged run
  /// ([pending], tile keys) — the sim can't know about pieces not yet sent.
  EditResult _check(Placement p, {Set<int>? pending}) {
    final r = _simCheck(p);
    if (!r.ok || pending == null || pending.isEmpty) return r;
    for (final t in p.footprint.tiles) {
      if (pending.contains(t.key)) {
        return const EditResult.refused(EditRefusal.overlaps);
      }
    }
    return r;
  }

  /// The single placement [k] would make with its anchor on [t].
  GhostPiece _pieceAt(EntityKind k, TilePos t, Dir4 dir, {Set<int>? pending}) {
    if (kSpannedKinds.contains(k)) {
      final p = Placement(id: 0, kind: k, pos: t, span: kDefaultSpan);
      return GhostPiece(p, p.footprint, _check(p));
    }
    final under = index.solidAt(t);
    final claimed = pending?.contains(t.key) ?? false;
    if (_isBeltLike(k) &&
        under != null &&
        _isBeltLike(under.kind) &&
        !claimed &&
        !(k == EntityKind.crossing && under.kind == EntityKind.belt)) {
      // A run redrawn over a run (§10 item 8): the belt (or crossing —
      // its walkway stays) already there takes the new direction. Nothing
      // is placed, so the items riding on it stay on it. A crossing laid
      // on a plain belt still swaps it, below.
      final p = under.copyWith(dir: dir);
      return GhostPiece(p, p.footprint, EditResult.ok(under.id),
          redirects: under.id);
    }
    if (k == EntityKind.crossing) {
      // A crossing is a walkable belt tile: laid over an existing belt it
      // takes that belt's place and keeps its direction, so the line still
      // flows and walkers gain a way over it.
      if (under != null && under.kind == EntityKind.belt && !claimed) {
        final p = Placement(id: 0, kind: k, pos: t, dir: under.dir);
        // The sim's only objection may be the belt it replaces.
        final r = _simCheck(p);
        final swap = !r.ok &&
            r.refusal == EditRefusal.overlaps &&
            r.otherId == under.id;
        return GhostPiece(p, p.footprint, swap ? const EditResult.ok(null) : r,
            replaces: under.id);
      }
    }
    String? item;
    if (k == EntityKind.receivingDock) item = itemChoice ?? FactoryItems.ore.id;
    if (k == EntityKind.shippingDock ||
        k == EntityKind.chest ||
        k == EntityKind.arm) {
      item = itemChoice;
    }
    if (k == EntityKind.machine) {
      final r = effectiveRecipe;
      var (w, h) = (station.footW, station.footH);
      if (dir.isVertical) (w, h) = (h, w);
      final pos = TilePos(t.x - w ~/ 2, t.y - h ~/ 2);
      final p = Placement(id: 0, kind: k, pos: pos, dir: dir, recipe: r);
      return GhostPiece(p, TileRect(pos.x, pos.y, w, h), _check(p));
    }
    var (w, h) = kEntityFootprint[k] ?? (1, 1);
    if (dir.isVertical) (w, h) = (h, w);
    final pos = TilePos(t.x - (w - 1) ~/ 2, t.y - (h - 1) ~/ 2);
    final p = Placement(id: 0, kind: k, pos: pos, dir: dir, item: item);
    return GhostPiece(p, p.footprint, _check(p, pending: pending));
  }

  void _refreshGhost() {
    final k = kind;
    final h = hover;
    if (tool != FactoryTool.place || k == null) {
      ghost = const [];
      return;
    }
    if (_isRunKind(k) && beltPath.isNotEmpty) {
      final pending = <int>{};
      final out = <GhostPiece>[];
      for (var i = 0; i < beltPath.length; i++) {
        final dir = beltRunDir(beltPath, i, ghostDir);
        final at = beltPath[i];
        final pk = k == EntityKind.belt && _onWalkway(at)
            ? EntityKind.crossing
            : k;
        final g = _pieceAt(pk, at, dir, pending: pending);
        pending.add(at.key);
        out.add(g);
      }
      ghost = out;
      return;
    }
    final rs = _rectStart;
    if (kSpannedKinds.contains(k) && rs != null && h != null && _rectMoved) {
      final m = effectiveRunMode;
      if (k == EntityKind.aisle && m != RunMode.freeform) {
        ghost = [
          for (final r in aisleStrips(rs, h, m, flip: lFlip))
            () {
              final p = Placement(id: 0, kind: k, pos: TilePos(r.x0, r.y0),
                  span: (r.w, r.h));
              return GhostPiece(p, p.footprint, _check(p));
            }(),
        ];
        return;
      }
      final x0 = math.min(rs.x, h.x), y0 = math.min(rs.y, h.y);
      final w = (rs.x - h.x).abs() + 1, hh = (rs.y - h.y).abs() + 1;
      final p = Placement(id: 0, kind: k, pos: TilePos(x0, y0), span: (w, hh));
      ghost = [GhostPiece(p, p.footprint, _check(p))];
      return;
    }
    final at = rs ?? h;
    if (at == null) {
      ghost = const [];
      return;
    }
    final pk = k == EntityKind.belt && _onWalkway(at) ? EntityKind.crossing : k;
    ghost = [_pieceAt(pk, at, ghostDir)];
  }

  /// Direction of tile [i] of a dragged run: toward the next tile; the last
  /// tile keeps the run's final heading; a lone tile uses [fallback].
  static Dir4 beltRunDir(List<TilePos> path, int i, Dir4 fallback) {
    if (path.length < 2) return fallback;
    final a = i < path.length - 1 ? path[i] : path[i - 1];
    final b = i < path.length - 1 ? path[i + 1] : path[i];
    final dx = b.x - a.x, dy = b.y - a.y;
    for (final d in Dir4.values) {
      if (d.dx == dx && d.dy == dy) return d;
    }
    return fallback;
  }

  /// The tiles of a run from [a] to [b] in [mode]'s shape: Straight locks
  /// to the drag's dominant axis (a tie goes along x), L-shape turns one
  /// corner — x first, or y first with [flip]. Freeform has no shape of its
  /// own (it is the cursor's path), so it is answered as Straight here.
  static List<TilePos> runPath(TilePos a, TilePos b, RunMode mode,
      {bool flip = false}) {
    if (mode == RunMode.lShape) {
      final corner = flip ? TilePos(a.x, b.y) : TilePos(b.x, a.y);
      return [..._line(a, corner), ..._line(corner, b).skip(1)];
    }
    final alongX = (b.x - a.x).abs() >= (b.y - a.y).abs();
    return _line(a, alongX ? TilePos(b.x, a.y) : TilePos(a.x, b.y));
  }

  /// Every tile from [a] to [b] inclusive; the two share a row or column.
  static List<TilePos> _line(TilePos a, TilePos b) {
    final dx = (b.x - a.x).sign, dy = (b.y - a.y).sign;
    final out = [a];
    var t = a;
    while (t != b) {
      t = TilePos(t.x + dx, t.y + dy);
      out.add(t);
    }
    return out;
  }

  /// The aisle strips a Straight or L drag from [a] to [b] lays: each leg
  /// is [width] tiles wide (an aisle is laid as wide as a click lays one),
  /// anchored on the run's tiles the way a click's square is, and the
  /// second leg of an L stops where the first one's corner square begins,
  /// so no tile is paid for twice.
  static List<TileRect> aisleStrips(TilePos a, TilePos b, RunMode mode,
      {bool flip = false, int width = 2}) {
    TileRect leg(TilePos p, TilePos q) => TileRect(
        math.min(p.x, q.x),
        math.min(p.y, q.y),
        (p.x - q.x).abs() + width,
        (p.y - q.y).abs() + width);
    if (mode != RunMode.lShape) {
      final path = runPath(a, b, RunMode.straight);
      return [leg(path.first, path.last)];
    }
    final corner = flip ? TilePos(a.x, b.y) : TilePos(b.x, a.y);
    final first = leg(a, corner);
    if (corner == b) return [first];
    final second = _minus(leg(corner, b), first);
    return [first, ?second];
  }

  /// [r] (a strip crossing [cut] at one end) without its part inside
  /// [cut]; null when nothing is left.
  static TileRect? _minus(TileRect r, TileRect cut) {
    if (!r.overlaps(cut)) return r;
    if (cut.x0 <= r.x0 && cut.x1 >= r.x1) {
      if (cut.y0 <= r.y0) {
        final y0 = cut.y1;
        return y0 < r.y1 ? TileRect(r.x0, y0, r.w, r.y1 - y0) : null;
      }
      return TileRect(r.x0, r.y0, r.w, cut.y0 - r.y0);
    }
    if (cut.y0 <= r.y0 && cut.y1 >= r.y1) {
      if (cut.x0 <= r.x0) {
        final x0 = cut.x1;
        return x0 < r.x1 ? TileRect(x0, r.y0, r.x1 - x0, r.h) : null;
      }
      return TileRect(r.x0, r.y0, cut.x0 - r.x0, r.h);
    }
    return r;
  }

  /// Grows the cursor's path to [t], one orthogonal step at a time (the
  /// longer axis first), cutting back when the drag doubles back on itself.
  void _extendBelt(TilePos t) {
    var guard = 0;
    while (_freePath.last != t && guard++ < 4096) {
      final last = _freePath.last;
      final dx = t.x - last.x, dy = t.y - last.y;
      final next = dx.abs() >= dy.abs()
          ? TilePos(last.x + dx.sign, last.y)
          : TilePos(last.x, last.y + dy.sign);
      final at = _freePath.indexOf(next);
      if (at >= 0) {
        _freePath.removeRange(at + 1, _freePath.length);
      } else {
        _freePath.add(next);
      }
    }
  }

  /// Re-derives [beltPath] from the cursor's path and the run shape in
  /// force (the shape, Shift, F or the cursor may have changed).
  void _updateRun() {
    final h = hover;
    if (_freePath.isEmpty) {
      beltPath.clear();
      return;
    }
    final m = effectiveRunMode;
    final next = m == RunMode.freeform || h == null
        ? [..._freePath]
        : runPath(_freePath.first, h, m, flip: lFlip);
    beltPath
      ..clear()
      ..addAll(next);
  }

  // ---- Area delete -----------------------------------------------------

  TilePos? _delStart;
  bool _delMoved = false;

  /// The Delete tool's dragged rectangle (null: no area drag), and what
  /// releasing it would delete — the red preview (§10 item 9). Solids
  /// whose footprint touches the rectangle; floor markings too only while
  /// Shift is held, so sweeping a line off an aisle keeps the aisle.
  TileRect? deleteRect;
  List<Placement> deleteTargets = const [];

  void _refreshDelete() {
    final s = _delStart, h = hover;
    if (tool != FactoryTool.delete || s == null || h == null || !_delMoved) {
      deleteRect = null;
      deleteTargets = const [];
      return;
    }
    final r = TileRect(math.min(s.x, h.x), math.min(s.y, h.y),
        (s.x - h.x).abs() + 1, (s.y - h.y).abs() + 1);
    deleteRect = r;
    deleteTargets = index.overlapping(r, markings: _shift);
  }

  /// The preview's counts, most numerous first: "3 Belt · 1 Arm".
  String get deleteSummary {
    final n = <EntityKind, int>{};
    for (final p in deleteTargets) {
      n[p.kind] = (n[p.kind] ?? 0) + 1;
    }
    if (n.isEmpty) return 'Nothing to delete';
    final ks = n.keys.toList()
      ..sort((a, b) {
        final c = n[b]!.compareTo(n[a]!);
        return c != 0 ? c : a.index.compareTo(b.index);
      });
    return 'Delete ${ks.map((k) => '${n[k]} ${entityKindLabel(k)}').join(' · ')}';
  }

  /// Deletes every previewed target as ONE undo step. Each goes through
  /// `remove`, so what a station held is set down as a floor pile exactly
  /// as a single delete does.
  void _commitDelete() {
    final targets = deleteTargets;
    var kept = 0;
    EditRefusal? why;
    history.group('Delete area', () {
      for (final p in targets) {
        final r = history.remove(p);
        if (r.ok) {
          if (selectedId == p.id) selectedId = null;
        } else {
          kept++;
          why ??= r.refusal;
        }
      }
    });
    final w = why;
    message = w == null ? null : '${refusalText(w)} ($kept kept)';
  }

  // ---- Pointer ---------------------------------------------------------

  int? _pointer;
  bool _panning = false;
  bool _placing = false;
  Offset _last = Offset.zero;

  void _cancelDrag() {
    _pointer = null;
    _panning = false;
    _placing = false;
    beltPath.clear();
    _freePath.clear();
    _rectStart = null;
    _rectMoved = false;
    _delStart = null;
    _delMoved = false;
    deleteRect = null;
    deleteTargets = const [];
  }

  void pointerHover(Offset local) {
    final t = localToTile(local);
    if (t == hover) return;
    hover = t;
    _refreshGhost();
    frame.value++;
  }

  /// Primary does the tool's work (and pans on empty floor with Select);
  /// middle always pans; every other button is ignored, so a right click
  /// never edits the floor.
  void pointerDown(int pointer, Offset local, int buttons) {
    if (_pointer != null) return;
    final t = localToTile(local);
    hover = t;
    if (buttons & kMiddleMouseButton != 0) {
      _pointer = pointer;
      _panning = true;
      _last = local;
      return;
    }
    if (buttons & kPrimaryButton == 0) return;
    _pointer = pointer;
    _last = local;
    switch (tool) {
      case FactoryTool.select:
        final hit = index.hit(t);
        if (hit == null) {
          selectedId = null;
          _panning = true;
        } else {
          selectedId = hit.id;
        }
        notifyListeners();
      case FactoryTool.delete:
        // A click deletes what it lands on, a drag the rectangle: which one
        // is known only on release.
        _delStart = t;
        _delMoved = false;
      case FactoryTool.place:
        _placing = true;
        if (_isRunKind(kind)) {
          _freePath
            ..clear()
            ..add(t);
          _updateRun();
        } else if (kind != null && kSpannedKinds.contains(kind)) {
          _rectStart = t;
          _rectMoved = false;
        }
    }
    _refreshGhost();
    frame.value++;
  }

  void pointerMove(int pointer, Offset local) {
    if (pointer != _pointer) {
      if (_pointer == null) pointerHover(local);
      return;
    }
    if (_panning) {
      origin += local - _last;
      _last = local;
      frame.value++;
      return;
    }
    final t = localToTile(local);
    if (t == hover) return;
    hover = t;
    if (_placing && _isRunKind(kind) && _freePath.isNotEmpty) {
      _extendBelt(t);
      _updateRun();
    }
    if (_placing && _rectStart != null && t != _rectStart) _rectMoved = true;
    if (_delStart != null && t != _delStart) _delMoved = true;
    _refreshGhost();
    _refreshDelete();
    frame.value++;
  }

  void pointerUp(int pointer, Offset local) {
    if (pointer != _pointer) return;
    final t = localToTile(local);
    if (_placing) {
      hover = t;
      if (_isRunKind(kind) && _freePath.isNotEmpty) {
        _extendBelt(t);
        _updateRun();
      }
      if (_rectStart != null && t != _rectStart) _rectMoved = true;
      _refreshGhost();
      _commitGhost();
    }
    final ds = _delStart;
    if (ds != null) {
      hover = t;
      if (t != ds) _delMoved = true;
      if (_delMoved) {
        _refreshDelete();
        _commitDelete();
      } else {
        final hit = index.hit(ds);
        if (hit == null) {
          message = refusalText(EditRefusal.noSuchPlacement);
        } else {
          _report(history.remove(hit));
          if (selectedId == hit.id) selectedId = null;
        }
      }
      notifyListeners();
    }
    _cancelDrag();
    _refreshGhost();
    frame.value++;
  }

  void pointerCancel(int pointer) {
    if (pointer != _pointer) return;
    _cancelDrag();
    _refreshGhost();
    frame.value++;
  }

  void scroll(Offset local, double dy) =>
      zoomAt(local, math.exp(-dy / kWheelZoomScale));

  /// Places every valid piece of the ghost as ONE undo step; refused pieces
  /// are reported, never sent (the preview already said no). A piece over
  /// an existing belt is a `setDir` on it, not a placement (§10 item 8).
  void _commitGhost() {
    var placed = 0, refused = 0;
    EditRefusal? why;
    final k = kind;
    history.group(k == null ? 'Place' : 'Place ${entityKindLabel(k)}', () {
      for (final g in ghost) {
        if (!g.check.ok) {
          refused++;
          why ??= g.check.refusal;
          continue;
        }
        final re = g.redirects;
        if (re != null) {
          final cur = index.byId(re);
          final r = cur == null
              ? const EditResult.refused(EditRefusal.noSuchPlacement)
              : history.setDir(cur, g.placement.dir);
          if (r.ok) {
            placed++;
          } else {
            refused++;
            why ??= r.refusal;
          }
          continue;
        }
        final swap = g.replaces;
        final old = swap == null ? null : index.byId(swap);
        if (old != null) {
          final gone = history.remove(old);
          if (!gone.ok) {
            refused++;
            why ??= gone.refusal;
            continue;
          }
          if (selectedId == old.id) selectedId = null;
        }
        final r = history.place(g.placement);
        if (r.ok) {
          placed++;
        } else {
          if (old != null) history.place(old.copyWith(id: 0));
          refused++;
          why ??= r.refusal;
        }
      }
    });
    final w = why;
    message = w == null
        ? null
        : refused > 1 || placed > 0
            ? '${refusalText(w)} ($refused refused)'
            : refusalText(w);
    notifyListeners();
  }

  // ---- Running ---------------------------------------------------------

  /// Repaints the canvas (every frame while running).
  final ValueNotifier<int> frame = ValueNotifier(0);

  /// Rebuilds the side panels (a few times a second).
  final ValueNotifier<int> live = ValueNotifier(0);

  double _liveAcc = 0;
  double _sampleAcc = 0;
  double _wall = 0;

  /// The floor's sim clock at the last frame (heat accrues by sim time
  /// passed, whoever stepped it).
  double _lastSim = 0;
  final List<_LifeSample> _window = [];

  /// Commodity units per sim second over the rolling window.
  Map<String, double> ratesIn = const {};
  Map<String, double> ratesOut = const {};

  /// Sim seconds the current rates span.
  double windowSeconds = 0;

  /// Handler-time per heat cell (sim seconds, decaying).
  Float32List _heat = Float32List(0);
  int heatW = 0, heatH = 0;
  double heatMax = 0;
  Float32List get heat => _heat;

  /// One animation frame: [wallDt] real seconds since the last.
  void tick(double wallDt) {
    if (drivesSim) {
      final dt = wallDt.clamp(0.0, kMaxFrameDt) * speed;
      if (dt > 0) sim.step(dt, port);
    }
    final now = sim.simSeconds;
    final simDt = now - _lastSim;
    _lastSim = now;
    if (simDt > 0) {
      _accumulateHeat(simDt);
      // Decay by the sim time that actually passed, not once per frame: at
      // 4x, or when the colony steps the floor in big jumps, a per-frame
      // decay would stretch the ~30 s half-life with the warp and saturate
      // the map.
      _decayHeatBy(math.pow(kHeatDecay, simDt / kHeatSampleS).toDouble());
    }
    if (wallDt > 0) {
      _wall += wallDt;
      _sampleAcc += wallDt;
      if (_sampleAcc >= kRateSampleS) {
        _sampleAcc = 0;
        _sampleRates();
      }
    }
    _liveAcc += wallDt;
    if (_liveAcc >= kLiveEveryS) {
      _liveAcc = 0;
      live.value++;
    }
    frame.value++;
  }

  void _accumulateHeat(double dt) {
    final hall = sim.blueprint.hall;
    final w = (hall.w + kHeatCellTiles - 1) ~/ kHeatCellTiles;
    final h = (hall.h + kHeatCellTiles - 1) ~/ kHeatCellTiles;
    if (w != heatW || h != heatH) {
      heatW = w;
      heatH = h;
      _heat = Float32List(w * h);
      heatMax = 0;
    }
    if (w == 0 || h == 0) return;
    for (final hv in sim.handlers) {
      final cx = (hv.x / kHeatCellTiles).floor();
      final cy = (hv.y / kHeatCellTiles).floor();
      if (cx < 0 || cy < 0 || cx >= w || cy >= h) continue;
      final i = cy * w + cx;
      final v = _heat[i] + dt;
      _heat[i] = v;
      if (v > heatMax) heatMax = v;
    }
  }

  /// Scales the whole heat map by [k] (the decay for the sim time passed).
  void _decayHeatBy(double k) {
    var m = 0.0;
    for (var i = 0; i < _heat.length; i++) {
      final v = _heat[i] * k;
      _heat[i] = v;
      if (v > m) m = v;
    }
    heatMax = m;
  }

  /// Samples the floor's lifetime counters and re-derives the rates as
  /// (newest - oldest) / sim seconds between them, over the last
  /// [kRateWindowS] wall seconds. While the floor is paused the rates hold
  /// their last value rather than dropping to nothing.
  void _sampleRates() {
    _window.add(_LifeSample(_wall, sim.lifetime));
    while (_window.length > 2 && _wall - _window[1].wall >= kRateWindowS) {
      _window.removeAt(0);
    }
    final a = _window.first, b = _window.last;
    final ds = b.simSeconds - a.simSeconds;
    if (ds <= 0) return;
    Map<String, double> per(Map<String, double> hi, Map<String, double> lo) {
      final out = <String, double>{};
      hi.forEach((k, v) {
        final d = v - (lo[k] ?? 0);
        if (d > 0) out[k] = d / ds;
      });
      return out;
    }

    windowSeconds = ds;
    ratesIn = per(b.inUnits, a.inUnits);
    ratesOut = per(b.outUnits, a.outUnits);
  }

  @override
  void dispose() {
    frame.dispose();
    live.dispose();
    super.dispose();
  }
}
