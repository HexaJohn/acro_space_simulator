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
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/factory_unlocks.dart';
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

/// One tile (or one piece) of the placement preview.
class GhostPiece {
  const GhostPiece(this.placement, this.rect, this.check, {this.replaces});
  final Placement placement;

  /// A belt this piece swaps out (a crossing laid over an existing belt
  /// tile): committed as remove-then-place, restored if the place fails.
  final int? replaces;

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
    if (k == EntityKind.receivingDock && itemChoice == null) {
      itemChoice = FactoryItems.ore.id;
    }
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

  // ---- Edits through the sim -------------------------------------------

  void _report(EditResult r) {
    final why = r.refusal;
    message = why == null ? null : refusalText(why);
  }

  /// Hires or lets go through the sim. Buying is the only hire the sim
  /// refuses for policy ([EditRefusal.notAllowed]: not unlocked), so that
  /// refusal is worded as "locked".
  void hire(HandlerKind k, int delta) {
    final r = sim.hire(k, delta);
    if (delta > 0 && r.refusal == EditRefusal.notAllowed) {
      message = '${kHandlerSpecs[k]!.label} is locked: '
          'not unlocked by this colony yet';
    } else {
      _report(r);
    }
    notifyListeners();
  }

  void setMachineRecipe(int id, String recipe) {
    _report(sim.setRecipe(id, recipe));
    frame.value++;
    notifyListeners();
  }

  /// Sets an arm's pick filter ([item] null = any item). The editor surface
  /// has no setItem, so this is an edit like any other: the arm is removed
  /// and placed again with the filter (same tile, same facing), and put
  /// back as it was if the new one is refused. The selection follows the
  /// re-placed arm's new id.
  void setArmFilter(int id, String? item) {
    final old = index.byId(id);
    if (old == null || old.kind != EntityKind.arm) {
      message = refusalText(EditRefusal.wrongKind);
      notifyListeners();
      return;
    }
    if (old.item == item) return;
    final gone = sim.remove(id);
    if (!gone.ok) {
      _report(gone);
      notifyListeners();
      return;
    }
    final next = Placement(id: 0, kind: EntityKind.arm, pos: old.pos,
        dir: old.dir, item: item);
    final r = sim.place(next);
    if (r.ok) {
      _report(r);
      if (selectedId == id) selectedId = r.placementId;
    } else {
      final back = sim.place(Placement(id: 0, kind: EntityKind.arm,
          pos: old.pos, dir: old.dir, item: old.item));
      if (selectedId == id) selectedId = back.placementId;
      _report(r);
    }
    frame.value++;
    notifyListeners();
  }

  void setMachineMode(int id, MachineMode mode) {
    final r = sim.setMode(id, mode);
    if (r.refusal == EditRefusal.notAllowed) {
      message = '${mode.name[0].toUpperCase()}${mode.name.substring(1)} '
          'stations are locked: not unlocked by this colony yet';
    } else {
      _report(r);
    }
    frame.value++;
    notifyListeners();
  }

  void rotateSelected() {
    final id = selectedId;
    if (id == null) return;
    _report(sim.rotate(id));
    frame.value++;
    notifyListeners();
  }

  void removeSelected() {
    final id = selectedId;
    if (id == null) return;
    _report(sim.remove(id));
    selectedId = null;
    frame.value++;
    notifyListeners();
  }

  /// R: turns the ghost while placing, else the selected object.
  void rotate() {
    if (tool == FactoryTool.place) {
      ghostDir = ghostDir.turnCw;
      _refreshGhost();
      frame.value++;
      notifyListeners();
    } else {
      rotateSelected();
    }
  }

  bool handleKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyR) {
      rotate();
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

  /// Tiles of a belt (or crossing) run being dragged, in order.
  final List<TilePos> beltPath = [];
  TilePos? _rectStart;

  /// True once a spanned-kind drag has left its start tile; until then the
  /// gesture is a plain click and lays the [kDefaultSpan] the hover showed.
  bool _rectMoved = false;

  /// Kinds laid by dragging a directed run.
  static bool _isRunKind(EntityKind? k) =>
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
    if (k == EntityKind.crossing) {
      // A crossing is a walkable belt tile: laid over an existing belt it
      // takes that belt's place and keeps its direction, so the line still
      // flows and walkers gain a way over it.
      final under = index.solidAt(t);
      if (under != null &&
          under.kind == EntityKind.belt &&
          !(pending?.contains(t.key) ?? false)) {
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

  /// Grows the dragged run to [t], one orthogonal step at a time (the
  /// longer axis first), cutting back when the drag doubles back on itself.
  void _extendBelt(TilePos t) {
    var guard = 0;
    while (beltPath.last != t && guard++ < 4096) {
      final last = beltPath.last;
      final dx = t.x - last.x, dy = t.y - last.y;
      final next = dx.abs() >= dy.abs()
          ? TilePos(last.x + dx.sign, last.y)
          : TilePos(last.x, last.y + dy.sign);
      final at = beltPath.indexOf(next);
      if (at >= 0) {
        beltPath.removeRange(at + 1, beltPath.length);
      } else {
        beltPath.add(next);
      }
    }
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
    _rectStart = null;
    _rectMoved = false;
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
        final hit = index.hit(t);
        if (hit == null) {
          message = refusalText(EditRefusal.noSuchPlacement);
        } else {
          _report(sim.remove(hit.id));
          if (selectedId == hit.id) selectedId = null;
        }
        notifyListeners();
      case FactoryTool.place:
        _placing = true;
        if (_isRunKind(kind)) {
          beltPath
            ..clear()
            ..add(t);
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
    if (_placing && _isRunKind(kind) && beltPath.isNotEmpty) {
      _extendBelt(t);
    }
    if (_placing && _rectStart != null && t != _rectStart) _rectMoved = true;
    _refreshGhost();
    frame.value++;
  }

  void pointerUp(int pointer, Offset local) {
    if (pointer != _pointer) return;
    if (_placing) {
      final t = localToTile(local);
      hover = t;
      if (_isRunKind(kind) && beltPath.isNotEmpty) {
        _extendBelt(t);
      }
      if (_rectStart != null && t != _rectStart) _rectMoved = true;
      _refreshGhost();
      _commitGhost();
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

  /// Places every valid piece of the ghost; refused pieces are reported,
  /// never sent (the preview already said no).
  void _commitGhost() {
    var placed = 0, refused = 0;
    EditRefusal? why;
    for (final g in ghost) {
      if (!g.check.ok) {
        refused++;
        why ??= g.check.refusal;
        continue;
      }
      final swap = g.replaces;
      final old = swap == null ? null : index.byId(swap);
      if (swap != null) {
        final gone = sim.remove(swap);
        if (!gone.ok) {
          refused++;
          why ??= gone.refusal;
          continue;
        }
        if (selectedId == swap) selectedId = null;
      }
      final r = sim.place(g.placement);
      if (r.ok) {
        placed++;
      } else {
        if (old != null) sim.place(old.copyWith(id: 0));
        refused++;
        why ??= r.refusal;
      }
    }
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
