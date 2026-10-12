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
/// fake in the tests, the demo sim and the real floor are interchangeable.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../../../domain/colony/city/factory/factory_colony_port.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_ledger.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
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

/// The ledger is taken once per this many sim seconds and pushed onto the
/// rolling rate window.
const double kRateSampleS = 1.0;

/// Sim seconds the throughput readout averages over.
const double kRateWindowS = 30.0;

/// Tiles per side of one traffic heat-map cell (8 m: coarse enough to read
/// at a glance, fine enough to show which aisle is jammed).
const int kHeatCellTiles = 4;

/// Per-sample decay of the heat map (per [kRateSampleS]): ~30 s half-life,
/// so the map shows the current pattern, not the whole session.
const double kHeatDecay = 0.977;

/// Default span a click (no drag) lays for a spanned kind: a 2-tile forklift
/// aisle's width, square.
const (int, int) kDefaultSpan = (2, 2);

/// One tile (or one piece) of the placement preview.
class GhostPiece {
  const GhostPiece(this.placement, this.rect, this.check);
  final Placement placement;

  /// Tiles the piece would cover (for a machine with no recipe yet, the
  /// station's footprint, so the player sees the space it needs).
  final TileRect rect;
  final LayoutCheck check;
}

/// A rolling-window sample of one ledger period.
class _RateSample {
  _RateSample(this.seconds, this.inUnits, this.outUnits);
  final double seconds;
  final Map<String, double> inUnits;
  final Map<String, double> outUnits;
}

class FactoryEditorController extends ChangeNotifier {
  FactoryEditorController(this.sim, this.port);

  final FactorySim sim;
  final FactoryColonyPort port;

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

  void hire(HandlerKind k, int delta) {
    _report(sim.hire(k, delta));
    notifyListeners();
  }

  void setMachineRecipe(int id, String recipe) {
    _report(sim.setRecipe(id, recipe));
    frame.value++;
    notifyListeners();
  }

  void setMachineMode(int id, MachineMode mode) {
    _report(sim.setMode(id, mode));
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

  /// Tiles of a belt run being dragged, in order.
  final List<TilePos> beltPath = [];
  TilePos? _rectStart;

  bool get ghostValid => ghost.isNotEmpty && ghost.every((g) => g.check.ok);

  /// The single placement [k] would make with its anchor on [t].
  GhostPiece _pieceAt(EntityKind k, TilePos t, Dir4 dir, {Set<int>? pending}) {
    if (kSpannedKinds.contains(k)) {
      final p = Placement(id: 0, kind: k, pos: t, span: kDefaultSpan);
      return GhostPiece(p, p.footprint, index.check(p));
    }
    String? item;
    if (k == EntityKind.receivingDock) item = itemChoice ?? FactoryItems.ore.id;
    if (k == EntityKind.shippingDock || k == EntityKind.chest) item = itemChoice;
    if (k == EntityKind.machine) {
      final r = effectiveRecipe;
      var (w, h) = (station.footW, station.footH);
      if (dir.isVertical) (w, h) = (h, w);
      final pos = TilePos(t.x - w ~/ 2, t.y - h ~/ 2);
      final p = Placement(id: 0, kind: k, pos: pos, dir: dir, recipe: r);
      return GhostPiece(p, TileRect(pos.x, pos.y, w, h), index.check(p));
    }
    var (w, h) = kEntityFootprint[k] ?? (1, 1);
    if (dir.isVertical) (w, h) = (h, w);
    final pos = TilePos(t.x - (w - 1) ~/ 2, t.y - (h - 1) ~/ 2);
    final p = Placement(id: 0, kind: k, pos: pos, dir: dir, item: item);
    return GhostPiece(p, p.footprint, index.check(p, pending: pending));
  }

  void _refreshGhost() {
    final k = kind;
    final h = hover;
    if (tool != FactoryTool.place || k == null) {
      ghost = const [];
      return;
    }
    if (k == EntityKind.belt && beltPath.isNotEmpty) {
      final pending = <int>{};
      final out = <GhostPiece>[];
      for (var i = 0; i < beltPath.length; i++) {
        final dir = beltRunDir(beltPath, i, ghostDir);
        final g = _pieceAt(k, beltPath[i], dir, pending: pending);
        pending.add(beltPath[i].key);
        out.add(g);
      }
      ghost = out;
      return;
    }
    final rs = _rectStart;
    if (kSpannedKinds.contains(k) && rs != null && h != null) {
      final x0 = math.min(rs.x, h.x), y0 = math.min(rs.y, h.y);
      final w = (rs.x - h.x).abs() + 1, hh = (rs.y - h.y).abs() + 1;
      final p = Placement(id: 0, kind: k, pos: TilePos(x0, y0), span: (w, hh));
      ghost = [GhostPiece(p, p.footprint, index.check(p))];
      return;
    }
    if (h == null) {
      ghost = const [];
      return;
    }
    ghost = [_pieceAt(k, h, ghostDir)];
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
        if (kind == EntityKind.belt) {
          beltPath
            ..clear()
            ..add(t);
        } else if (kind != null && kSpannedKinds.contains(kind)) {
          _rectStart = t;
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
    if (_placing && kind == EntityKind.belt && beltPath.isNotEmpty) {
      _extendBelt(t);
    }
    _refreshGhost();
    frame.value++;
  }

  void pointerUp(int pointer, Offset local) {
    if (pointer != _pointer) return;
    if (_placing) {
      hover = localToTile(local);
      if (kind == EntityKind.belt && beltPath.isNotEmpty) {
        _extendBelt(hover!);
      }
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
      final r = sim.place(g.placement);
      if (r.ok) {
        placed++;
      } else {
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
  final List<_RateSample> _window = [];

  /// Commodity units per sim second over the rolling window.
  Map<String, double> ratesIn = const {};
  Map<String, double> ratesOut = const {};
  double windowSeconds = 0;

  /// Handler-time per heat cell (sim seconds, decaying).
  Float32List _heat = Float32List(0);
  int heatW = 0, heatH = 0;
  double heatMax = 0;
  Float32List get heat => _heat;

  /// One animation frame: [wallDt] real seconds since the last.
  void tick(double wallDt) {
    final dt = wallDt.clamp(0.0, kMaxFrameDt) * speed;
    if (dt > 0) {
      sim.step(dt, port);
      _accumulateHeat(dt);
      _sampleAcc += dt;
      if (_sampleAcc >= kRateSampleS) {
        _sampleAcc = 0;
        _sampleRates();
        _decayHeat();
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

  void _decayHeat() {
    var m = 0.0;
    for (var i = 0; i < _heat.length; i++) {
      final v = _heat[i] * kHeatDecay;
      _heat[i] = v;
      if (v > m) m = v;
    }
    heatMax = m;
  }

  void _sampleRates() {
    final FactoryLedger l = sim.takeLedger();
    _window.add(_RateSample(l.seconds, {...l.received}, {...l.shipped}));
    var total = 0.0;
    for (final s in _window) {
      total += s.seconds;
    }
    while (_window.length > 1 && total - _window.first.seconds >= kRateWindowS) {
      total -= _window.removeAt(0).seconds;
    }
    windowSeconds = total;
    final inn = <String, double>{}, out = <String, double>{};
    for (final s in _window) {
      s.inUnits.forEach((k, v) => inn[k] = (inn[k] ?? 0) + v);
      s.outUnits.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
    }
    if (total > 0) {
      inn.updateAll((_, v) => v / total);
      out.updateAll((_, v) => v / total);
    }
    ratesIn = inn;
    ratesOut = out;
  }

  @override
  void dispose() {
    frame.dispose();
    live.dispose();
    super.dispose();
  }
}
