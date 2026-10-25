// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Draws a factory floor top-down (docs/plans/factory-floors.md §4).
///
/// A hall can be ~550 × 400 tiles with thousands of placements, and the
/// floor animates every frame while it is open. So the drawing is split by
/// how often it changes:
///
/// * **Static layers** — the hall, floor markings and every entity body —
///   are recorded ONCE per `layoutRev` into two [ui.Picture]s ([FloorLayerCache])
///   in tile units, and replayed under the camera transform. Panning and
///   zooming cost a replay, not a rebuild. Like shapes are batched into one
///   [Path] each, so a hall of 2,000 belts is a handful of draw calls.
/// * **Dynamic layers** — grid lines, machine status, overlays, belt items,
///   handlers, the ghost and labels — are drawn per frame, CULLED to the
///   tiles on screen, with paints held in finals so a frame allocates
///   nearly nothing.
///
/// **Edit previews read at a glance** (§10 items 1, 6, 8, 9): every
/// directed ghost carries a filled arrowhead, an arm's ghost tints the tile
/// it takes from (cyan, "take") and drops into (amber, "drop"), a belt
/// redrawn over a belt is tinted blue, the Delete tool's box tints its
/// targets red with their counts, and a receiving dock nothing here uses
/// wears an amber warning mark. All of it is FILLED geometry ([addArrow],
/// [_T]): strokes smear on the Windows GLES renderer.
///
/// Tile space is y-up (north is up the screen) to match the floor's +y
/// running away from the yard; labels are drawn after the transform is
/// popped, in screen pixels, so text never mirrors.
///
/// **Handlers are drawn where they really are.** A [HandlerView]'s (x, y)
/// is the ANCHOR — the low corner of the square it covers — so every kind
/// is centred on [handlerSquare]: one tile for a walker, jack or crane
/// hook, a 2 × 2 square for a forklift or AGV (its aisle width). Each kind
/// has its own glyph (a dot, a diamond, a body with forks, a robot, a
/// bridge across the crane's bay), battery vehicles carry a charge bar, and
/// goods set down on the floor are drawn as piles.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../../../domain/colony/city/factory/dock_geometry.dart';
import '../../../../domain/colony/city/factory/dock_logistics.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_floor.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/station_ports.dart';
import '../../../../domain/colony/city/factory/factory_staffing.dart';
import 'factory_editor_controller.dart';
import 'floor_item_info.dart' show itemAbbrev;
import 'floor_layout_index.dart';
import 'machine_ports_view.dart';

/// Below this zoom (px per tile) the grid is gone; it is fully drawn
/// [kGridFadePx] px per tile later.
const double kGridMinPx = 4;
const double kGridFadePx = 8;

/// Grid line opacity at full strength.
const double kGridAlpha = 0.18;

/// Belt items and handlers vanish below this zoom (sub-pixel dots are noise
/// and the per-item cost is the frame's biggest).
const double kDynamicMinPx = 1.5;

/// Machine labels need at least this zoom to be legible.
const double kLabelMinPx = 9;

/// Closest zoom (px per tile) at which belt items and piles carry a 2-3
/// letter label (§10 item 18).
const double kItemLabelMinPx = 36;

/// Label font size, logical px.
const double kLabelFont = 11;

/// Pixels per tile above which port notches name their items (a label
/// needs about a tile and a half of room).
const double kPortLabelMinPx = 40;

/// Colors.
const Color kFactoryBg = Color(0xFF070B12);
const Color _hallFloor = Color(0xFF1A212A);
const Color _hallWall = Color(0xFF5E6E80);
const Color _beltBody = Color(0xFF39424D);
const Color _beltChevron = Color(0xFF9AA8B6);
const Color _okGhost = Color(0x707FE0A0);
const Color _badGhost = Color(0x80FF6B6B);

/// A ghost tile that RE-POINTS an existing belt rather than laying a new
/// one (§10 item 8): blue, so a redraw reads apart from fresh belt.
const Color kRedirectGhost = Color(0x804FA3FF);

/// An arm's "takes from" tile (cyan) and "drops into" tile (amber), on its
/// ghost and as the pick notch of a placed arm (§10 item 1).
const Color kArmTakeColor = Color(0xFF4FE3E8);
const Color kArmDropColor = Color(0xFFFFB74D);

/// The Delete tool's area preview (§10 item 9).
const Color kDeletePreview = Color(0x80FF3030);

/// The hover-delete (X held) target outline (§10 item 12).
const Color kSweepOutline = Color(0xFFFF3B3B);

/// Appends a filled arrow from [a] to [b] onto [path]: a [shaft]-wide bar
/// to the neck, then a [headLen] × [headWidth] triangle whose point is
/// [b]. Both are closed polygons for a FILL paint: a stroked arrow smears
/// ~10x wide on the Windows GLES renderer (see [_T]), and the playtest's
/// "bare line" facing read as nothing at all.
void addArrow(Path path, Offset a, Offset b,
    {double shaft = 0.1, double headLen = 0.3, double headWidth = 0.36}) {
  final d = b - a;
  final len = d.distance;
  if (len <= 0) return;
  final u = d / len;
  final n = Offset(-u.dy, u.dx);
  final hl = math.min(headLen, len);
  final neck = b - u * hl;
  final s = n * (shaft / 2), h = n * (headWidth / 2);
  if (len > hl) {
    path
      ..moveTo(a.dx + s.dx, a.dy + s.dy)
      ..lineTo(neck.dx + s.dx, neck.dy + s.dy)
      ..lineTo(neck.dx - s.dx, neck.dy - s.dy)
      ..lineTo(a.dx - s.dx, a.dy - s.dy)
      ..close();
  }
  path
    ..moveTo(neck.dx + h.dx, neck.dy + h.dy)
    ..lineTo(b.dx, b.dy)
    ..lineTo(neck.dx - h.dx, neck.dy - h.dy)
    ..close();
}

/// One color per station kind, so a line reads at a glance.
const Map<StationKind, Color> kStationColor = {
  StationKind.smelter: Color(0xFF8D4E2E),
  StationKind.furnace: Color(0xFF9C3B2B),
  StationKind.press: Color(0xFF4E5D8D),
  StationKind.mill: Color(0xFF5D6E7E),
  StationKind.assembler: Color(0xFF3E7A63),
  StationKind.chem: Color(0xFF6E4E8D),
  StationKind.packer: Color(0xFF8D7A3E),
  StationKind.unpacker: Color(0xFF7A6A4E),
};

const Map<HandlerKind, Color> kHandlerColor = {
  HandlerKind.onFoot: Color(0xFF7FE0A0),
  HandlerKind.palletJack: Color(0xFFFFD54F),
  HandlerKind.forklift: Color(0xFFFF8C66),
  HandlerKind.crane: Color(0xFFB388FF),
  HandlerKind.agv: Color(0xFF4FC3F7),
};

/// Hired station operators and technicians (§10 item 20).
const Color kOperatorColor = Color(0xFF8FD3FF);
const Color kTechnicianColor = Color(0xFFFFB74D);

const Map<MachineStatus, Color> kStatusColor = {
  MachineStatus.working: Color(0xFF7FE0A0),
  // Starved reads red (the line is broken upstream: nothing arrives), blocked
  // reads yellow (it works, but its output has nowhere to go) — the user's
  // call, 2026-10-25.
  MachineStatus.starved: Color(0xFFFF6B6B),
  MachineStatus.blocked: Color(0xFFFFD54F),
  MachineStatus.unstaffed: Color(0xFFFF8C66),
  MachineStatus.unpowered: Color(0xFFB388FF),
  MachineStatus.idle: Color(0xFF8499AE),
  MachineStatus.broken: Color(0xFFE53935),
};

/// A stable color per item id (no platform hash: the same item is the same
/// color on every run and every machine).
Color itemColor(String id) {
  var h = 7;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return HSVColor.fromAHSV(1, (h % 360).toDouble(), 0.55, 0.95).toColor();
}

/// Tiles a side of the square a handler of [k] covers: its aisle width for
/// a drive-layer vehicle, else one tile (`HandlerView`'s anchor rule).
int handlerSquareTiles(HandlerKind k) {
  final w = kHandlerSpecs[k]!.aisleTiles;
  return w < 1 ? 1 : w;
}

/// The square [h] covers, in tile units: anchored at (x, y), so its centre
/// is where the handler is drawn.
Rect handlerSquare(HandlerView h) {
  final w = handlerSquareTiles(h.kind).toDouble();
  return Rect.fromLTWH(h.x, h.y, w, w);
}

/// A crane's bridge: the full width of its [bay] across the runway, one
/// tile thick, at the hook's place along it. The runway runs along the
/// bay's long side (matching the rails the floor layer draws).
Rect craneBridge(HandlerView h, TileRect bay) {
  if (bay.w >= bay.h) {
    return Rect.fromLTWH(h.x, bay.y0.toDouble(), 1, bay.h.toDouble());
  }
  return Rect.fromLTWH(bay.x0.toDouble(), h.y, bay.w.toDouble(), 1);
}

/// Battery bar colour: green when full fading to red when flat.
Color batteryColor(double frac) =>
    Color.lerp(const Color(0xFFFF5252), const Color(0xFF69F0AE),
        frac.clamp(0.0, 1.0))!;

Paint _fill(Color c) => Paint()..color = c;
Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w;

/// The two static pictures for one layout revision.
class FloorLayerCache {
  int _rev = -1;
  ui.Picture? _floor;
  ui.Picture? _entities;

  /// Pictures built so far (tests check the cache holds across frames).
  int builds = 0;

  void ensure(FloorLayoutIndex ix) {
    if (ix.rev == _rev && _floor != null && _entities != null) return;
    final oldA = _floor, oldB = _entities;
    _floor = _recordFloor(ix);
    _entities = _recordEntities(ix);
    _rev = ix.rev;
    builds++;
    // The replaced pictures may still be referenced by the frame being
    // built; release them once it is out.
    if (oldA != null || oldB != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        oldA?.dispose();
        oldB?.dispose();
      });
    }
  }

  ui.Picture get floor => _floor!;
  ui.Picture get entities => _entities!;

  void dispose() {
    _floor?.dispose();
    _entities?.dispose();
    _floor = null;
    _entities = null;
  }

  static Rect _r(TileRect t, [double inset = 0]) => Rect.fromLTWH(
      t.x0 + inset, t.y0 + inset, t.w - 2 * inset, t.h - 2 * inset);

  ui.Picture _recordFloor(FloorLayoutIndex ix) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final hall = ix.hall;
    final hallRect = Rect.fromLTWH(0, 0, hall.w.toDouble(), hall.h.toDouble());
    _T.rect(c, hallRect, _fill(_hallFloor));
    final aisle = Path(), staging = Path(), bay = Path();
    final aisleEdge = _SP(), stagingEdge = _SP(), rails = _SP();
    for (final p in ix.overlays) {
      final r = _r(p.footprint);
      switch (p.kind) {
        case EntityKind.aisle:
          aisle.addRect(r);
          aisleEdge.addRect(r);
        case EntityKind.staging:
          staging.addRect(r);
          stagingEdge.addRect(r);
        case EntityKind.craneBay:
          bay.addRect(r);
          // Runway rails along the bay's long sides.
          if (r.width >= r.height) {
            rails
              ..moveTo(r.left, r.top + 0.15)
              ..lineTo(r.right, r.top + 0.15)
              ..moveTo(r.left, r.bottom - 0.15)
              ..lineTo(r.right, r.bottom - 0.15);
          } else {
            rails
              ..moveTo(r.left + 0.15, r.top)
              ..lineTo(r.left + 0.15, r.bottom)
              ..moveTo(r.right - 0.15, r.top)
              ..lineTo(r.right - 0.15, r.bottom);
          }
        default:
      }
    }
    c.drawPath(aisle, _fill(const Color(0x30FFD54F)));
    aisleEdge.draw(c, const Color(0x90FFD54F), 0.08);
    c.drawPath(staging, _fill(const Color(0x284FC3F7)));
    stagingEdge.draw(c, const Color(0x704FC3F7), 0.08);
    c.drawPath(bay, _fill(const Color(0x22FF8C66)));
    rails.draw(c, const Color(0xB0FF8C66), 0.18);
    _T.rect(c, hallRect.inflate(0.25), _stroke(_hallWall, 0.5));
    return rec.endRecording();
  }

  ui.Picture _recordEntities(FloorLayoutIndex ix) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    // Every outline and line here is a [_SP]: drawn as FILLED geometry, never
    // a stroke (see [_T]). A stroked machine output bar smeared into a wide
    // blurred white slab beside the machine on Windows (user report,
    // 2026-10-25).
    final belts = Path(), chevrons = _SP(), zebra = _SP();
    final chests = Path(), chestEdges = _SP(), recv = Path(), ship = Path();
    final doors = _SP();
    final racks = Path(), rackEdges = _SP(), rackBeams = _SP();
    final charge = Path(), bolts = _SP();
    final arms = Path(), armLines = Path(), armPicks = Path();
    final byStation = <StationKind?, Path>{};
    final stationEdges = _SP();
    final notches = _SP();
    for (final p in ix.blueprint.placements) {
      final f = p.footprint;
      final cx = f.x0 + f.w / 2, cy = f.y0 + f.h / 2;
      final fx = p.dir.dx.toDouble(), fy = p.dir.dy.toDouble();
      final sx = -fy, sy = fx;
      switch (p.kind) {
        case EntityKind.belt:
        case EntityKind.crossing:
          // A crossing is a belt (it carries items along its dir) with a
          // zebra walkway painted over it.
          belts.addRect(_r(f, 0.06));
          chevrons
            ..moveTo(cx - fx * 0.12 + sx * 0.26, cy - fy * 0.12 + sy * 0.26)
            ..lineTo(cx + fx * 0.22, cy + fy * 0.22)
            ..lineTo(cx - fx * 0.12 - sx * 0.26, cy - fy * 0.12 - sy * 0.26);
          if (p.kind != EntityKind.crossing) break;
          for (var i = 0; i < 4; i++) {
            final o = -0.36 + i * 0.24;
            zebra
              ..moveTo(cx + sx * 0.4 + fx * o, cy + sy * 0.4 + fy * o)
              ..lineTo(cx - sx * 0.4 + fx * o, cy - sy * 0.4 + fy * o);
          }
        case EntityKind.arm:
          // An arm reads its direction at a glance (§10 item 1): a filled
          // arrow from its pick side to its drop side, and a pick notch on
          // the back edge, the side it TAKES from. Filled, not stroked: a
          // stroked line smeared into a blob on Windows (see [_T]).
          arms.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: 0.28));
          addArrow(armLines, Offset(cx - fx * 0.3, cy - fy * 0.3),
              Offset(cx + fx * 0.5, cy + fy * 0.5),
              shaft: 0.12, headLen: 0.3, headWidth: 0.42);
          armPicks.addRect(Rect.fromCenter(
              center: Offset(cx - fx * 0.42, cy - fy * 0.42),
              width: fx != 0 ? 0.12 : 0.5,
              height: fx != 0 ? 0.5 : 0.12));
        case EntityKind.chest:
          chests.addRect(_r(f, 0.12));
          chestEdges.addRect(_r(f, 0.12));
        case EntityKind.receivingDock:
        case EntityKind.shippingDock:
          (p.kind == EntityKind.receivingDock ? recv : ship)
              .addRect(_r(f, 0.04));
          // The door: a heavy bar along the footprint's long side.
          final r = _r(f);
          if (r.width >= r.height) {
            doors
              ..moveTo(r.left + 0.2, cy)
              ..lineTo(r.right - 0.2, cy);
          } else {
            doors
              ..moveTo(cx, r.top + 0.2)
              ..lineTo(cx, r.bottom - 0.2);
          }
        case EntityKind.rack:
          final r = _r(f, 0.08);
          racks.addRect(r);
          rackEdges.addRect(r);
          rackBeams
            ..moveTo(r.left, r.top)
            ..lineTo(r.right, r.bottom)
            ..moveTo(r.left, r.bottom)
            ..lineTo(r.right, r.top);
        case EntityKind.chargingBay:
          charge.addRect(_r(f, 0.1));
          bolts
            ..moveTo(cx + 0.15, cy + 0.6)
            ..lineTo(cx - 0.2, cy)
            ..lineTo(cx + 0.2, cy)
            ..lineTo(cx - 0.15, cy - 0.6);
        case EntityKind.machine:
          final rid = p.recipe;
          final st = rid == null ? null : FactoryRecipes.byId(rid)?.station;
          final body =
              RRect.fromRectAndRadius(_r(f, 0.1), const Radius.circular(0.3));
          byStation.putIfAbsent(st, Path.new).addRRect(body);
          stationEdges.addRRect(body);
          // The output face: a bar on the side the machine faces.
          final half = (p.dir.isVertical ? f.w : f.h) / 2 - 0.4;
          final ex = cx + fx * (f.w / 2 - 0.25), ey = cy + fy * (f.h / 2 - 0.25);
          notches
            ..moveTo(ex + sx * half, ey + sy * half)
            ..lineTo(ex - sx * half, ey - sy * half);
        case EntityKind.aisle:
        case EntityKind.staging:
        case EntityKind.craneBay:
      }
    }
    c.drawPath(belts, _fill(_beltBody));
    chevrons.draw(c, _beltChevron, 0.07);
    zebra.draw(c, const Color(0xFFE0E0E0), 0.1);
    c.drawPath(chests, _fill(const Color(0xFF7A5A3A)));
    chestEdges.draw(c, const Color(0xFFC09060), 0.06);
    c.drawPath(recv, _fill(const Color(0xFF2E6B4A)));
    c.drawPath(ship, _fill(const Color(0xFF8A5A2E)));
    doors.draw(c, const Color(0xFFE8EEF4), 0.16);
    c.drawPath(racks, _fill(const Color(0xFF253A55)));
    rackEdges.draw(c, const Color(0xFF6A9AD0), 0.08);
    rackBeams.draw(c, const Color(0x806A9AD0), 0.05);
    c.drawPath(charge, _fill(const Color(0xFF1E4A4A)));
    bolts.draw(c, const Color(0xFF4FC3F7), 0.1);
    c.drawPath(arms, _fill(const Color(0xFF606C78)));
    c.drawPath(armLines, _fill(const Color(0xFFFFD54F)));
    c.drawPath(armPicks, _fill(kArmTakeColor));
    for (final e in byStation.entries) {
      c.drawPath(e.value, _fill(kStationColor[e.key] ?? const Color(0xFF555555)));
    }
    stationEdges.draw(c, const Color(0xFF0E1622), 0.1);
    notches.draw(c, const Color(0xFFE8EEF4), 0.18);
    return rec.endRecording();
  }
}

class FactoryFloorPainter extends CustomPainter {
  FactoryFloorPainter(this.c, this.cache) : super(repaint: c.frame);

  final FactoryEditorController c;
  final FloorLayerCache cache;

  /// Each handler's body as last painted, by handler id, in tile units
  /// (the square it covers; a crane's is its hook tile). Tests read it to
  /// pin where vehicles are drawn without a golden image.
  final Map<int, Rect> handlerRects = {};

  /// Each crane's bridge as last painted, by handler id, in tile units.
  final Map<int, Rect> bridgeRects = {};

  /// What the last frame drew for the edit previews, read by tests to pin
  /// the previews without golden images: filled arrowheads on the ghost,
  /// each arm ghost's (takes-from, drops-into) tiles, redirected-belt
  /// pieces, the area delete's target rects and label, and the unused-dock
  /// warning marks.
  int ghostArrows = 0;
  final List<(TilePos, TilePos)> armGhostEnds = [];
  int redirectGhosts = 0;
  final List<Rect> deletePreviewRects = [];
  String? deleteLabel;
  int unusedDockMarks = 0;

  /// The hover-delete outline last painted (X held, §10 item 12), in tile
  /// units; null when none was drawn.
  Rect? sweepRect;

  /// Port notches the last frame drew (placed machines and ghosts), and
  /// how many of them were lit as connected (§10 item 19).
  int portMarks = 0;
  int litPorts = 0;

  static final Paint _bg = _fill(kFactoryBg);
  static final Paint _grid = _stroke(const Color(0xFFFFFFFF), 0);
  static final Paint _gridFill = Paint();
  static final Paint _tint = Paint();
  static final Paint _lamp = Paint();
  static final Paint _dot = Paint();
  static final Paint _handlerRing = _stroke(const Color(0xFF05080F), 0.08);
  static final Paint _glyph = _stroke(const Color(0xFF05080F), 0.1);
  static final Paint _bridge = _fill(const Color(0xA0B388FF));
  static final Paint _bridgeEdge = _stroke(const Color(0xFFE0D0FF), 0.06);
  static final Paint _barBack = _fill(const Color(0xC0101820));
  static final Paint _bar = Paint();
  static final Paint _chargeRing = _stroke(const Color(0xFF4FC3F7), 0.12);
  static final Paint _pileEdge = _stroke(const Color(0xFFE8EEF4), 0.05);
  static final Paint _broken = _stroke(const Color(0xFFE53935), 0.18);
  static final Paint _select = _stroke(const Color(0xFF4FC3F7), 0.15);
  static final Paint _hover = _stroke(const Color(0x60FFFFFF), 0.06);
  /// The product tree's highlighted recipe: amber, thicker than the
  /// selection (0.15) so the two read apart when they land on one machine.
  static final Paint _highlight = _stroke(const Color(0xFFFFC107), 0.22);
  static final Paint _ghostOk = _fill(_okGhost);
  static final Paint _ghostBad = _fill(_badGhost);
  static final Paint _ghostEdge = _stroke(const Color(0xC0FFFFFF), 0.06);
  static final Paint _ghostRedirect = _fill(kRedirectGhost);
  static final Paint _ghostArrow = _fill(const Color(0xF0FFFFFF));
  static final Paint _armTake = _fill(kArmTakeColor.withValues(alpha: 0.45));
  static final Paint _armDrop = _fill(kArmDropColor.withValues(alpha: 0.45));
  static final Paint _deleteFill = _fill(kDeletePreview);
  static final Paint _deleteEdge = _stroke(const Color(0xFFFF5050), 0.12);
  static final Paint _unusedMark = _fill(const Color(0xFFFFB300));
  static final Paint _clearFill = _fill(const Color(0x4026C6DA));
  static final Paint _clearEdge = _stroke(const Color(0xFF26C6DA), 0.1);
  static final Paint _portPaint = Paint();

  /// The hover-delete outline: red, as wide as the selection ring so it
  /// reads at any zoom, and drawn through [_T] as a FILLED ring.
  static final Paint _sweepEdge = _stroke(kSweepOutline, 0.15);
  static final Paint _sweepFill = _fill(kSweepOutline.withValues(alpha: 0.18));
  static final Map<String, Paint> _itemPaints = {};
  static final Map<String, TextPainter> _labels = {};

  static Paint _itemPaint(String id) =>
      _itemPaints.putIfAbsent(id, () => _fill(itemColor(id)));

  static TextPainter _label(String s) => _labels.putIfAbsent(s, () {
        final tp = TextPainter(
          text: TextSpan(
              text: s,
              style: const TextStyle(
                  color: Color(0xFFE8EEF4),
                  fontSize: kLabelFont,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 2)])),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        return tp;
      });

  @override
  void paint(Canvas canvas, Size size) {
    final ix = c.index;
    cache.ensure(ix);
    final px = c.pxPerTile;
    final vis = c.visibleTiles;
    canvas.clipRect(Offset.zero & size);
    _T.rect(canvas, Offset.zero & size, _bg);
    canvas.save();
    canvas.translate(c.origin.dx, c.origin.dy);
    canvas.scale(px, -px);
    canvas.drawPicture(cache.floor);
    _paintGrid(canvas, vis, px);
    canvas.drawPicture(cache.entities);
    _paintMachines(canvas, ix, vis);
    _paintPorts(canvas, ix, vis);
    if (c.overlays.contains(FactoryOverlay.traffic)) _paintHeat(canvas, vis);
    if (px >= kDynamicMinPx) {
      _paintPiles(canvas, vis);
      _paintStuckPiles(canvas, vis);
      _paintBeltItems(canvas, ix, vis);
      _paintHandlers(canvas, ix, vis);
      _paintStaff(canvas, vis);
    }
    _paintUnusedDocks(canvas, ix, vis);
    _paintTrucks(canvas, ix);
    _paintSelection(canvas, ix);
    _paintDeletePreview(canvas);
    _paintSweep(canvas);
    _paintClearBox(canvas);
    _paintGhost(canvas);
    canvas.restore();
    if (px >= kLabelMinPx) _paintLabels(canvas, ix, vis, px);
    if (px >= kItemLabelMinPx) _paintItemLabels(canvas, ix, vis);
    if (px >= kPortLabelMinPx) _paintPortLabels(canvas, ix, vis);
    _paintEditLabels(canvas, px);
  }

  static final Paint _truckIn = _fill(const Color(0xFF5C8DB8));
  static final Paint _truckOut = _fill(const Color(0xFFB8925C));
  static final Paint _truckCab = _fill(const Color(0xFF2B3440));

  /// The truck backed up to each dock (§10 item 3): OUTSIDE the wall,
  /// behind the door, its cab at the far end. Filled rects only (see
  /// [_T]). Blue brings goods in, amber takes them away.
  void _paintTrucks(Canvas canvas, FloorLayoutIndex ix) {
    final sim = c.sim;
    final lg = sim is FactoryFloor ? sim.logistics : null;
    if (lg == null) return;
    for (final t in lg.trucks.values) {
      if (t.state != TruckState.docked) continue;
      final p = ix.byId(t.dock);
      if (p == null) continue;
      final b = truckBayOf(p);
      final r = Rect.fromLTWH(b.x0 + 0.15, b.y0 + 0.15, b.w - 0.3, b.h - 0.3);
      _T.rect(canvas, r, t.inbound ? _truckIn : _truckOut);
      const cab = 1.2;
      final c0 = switch (p.dir) {
        Dir4.east => Rect.fromLTWH(r.left, r.top, cab, r.height),
        Dir4.west => Rect.fromLTWH(r.right - cab, r.top, cab, r.height),
        Dir4.north => Rect.fromLTWH(r.left, r.top, r.width, cab),
        Dir4.south => Rect.fromLTWH(r.left, r.bottom - cab, r.width, cab),
      };
      _T.rect(canvas, c0, _truckCab);
    }
  }

  void _paintGrid(Canvas canvas, TileRect vis, double px) {
    final a = ((px - kGridMinPx) / kGridFadePx).clamp(0.0, 1.0) * kGridAlpha;
    if (a <= 0 || vis.w <= 0 || vis.h <= 0) return;
    _grid.color = Color.fromRGBO(255, 255, 255, a);
    // One filled path of hairline strips (one screen pixel wide), not a
    // stroke per line: see [_T].
    final w = 1 / px, h = w / 2;
    final path = Path();
    for (var x = vis.x0; x <= vis.x1; x++) {
      path.addRect(Rect.fromLTRB(x - h, vis.y0.toDouble(), x + h,
          vis.y1.toDouble()));
    }
    for (var y = vis.y0; y <= vis.y1; y++) {
      path.addRect(Rect.fromLTRB(vis.x0.toDouble(), y - h,
          vis.x1.toDouble(), y + h));
    }
    canvas.drawPath(path, _gridFill..color = _grid.color);
  }

  /// Status lamp on every machine; with an overlay on, the whole body is
  /// tinted by what that overlay asks.
  void _paintMachines(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    final power = c.overlays.contains(FactoryOverlay.power);
    final staff = c.overlays.contains(FactoryOverlay.staffing);
    final neck = c.overlays.contains(FactoryOverlay.bottleneck);
    var maxKw = 1.0;
    if (power) {
      for (final m in ix.machines) {
        final rid = m.recipe;
        final r = rid == null ? null : FactoryRecipes.byId(rid);
        if (r != null) maxKw = math.max(maxKw, r.powerKw * m.crew.powerMult);
      }
    }
    for (final m in ix.machines) {
      final f = m.footprint;
      if (!f.overlaps(vis)) continue;
      final s = c.sim.statusOf(m.id);
      final rect = Rect.fromLTWH(f.x0 + 0.1, f.y0 + 0.1, f.w - 0.2, f.h - 0.2);
      Color? tint;
      if (neck) {
        tint = switch (s) {
          MachineStatus.starved => const Color(0x90FF6B6B),
          MachineStatus.blocked => const Color(0x80FFD54F),
          MachineStatus.broken => const Color(0xA0E53935),
          MachineStatus.working => const Color(0x307FE0A0),
          _ => null,
        };
      }
      if (staff) {
        if (s == MachineStatus.unstaffed) {
          tint = const Color(0x90FF3030);
        } else if (m.crew.workers > 0) {
          tint = const Color(0x407FE0A0);
        } else {
          tint = const Color(0x404FC3F7);
        }
      }
      if (power) {
        if (s == MachineStatus.unpowered) {
          tint = const Color(0x90B388FF);
        } else {
          final rid = m.recipe;
          final r = rid == null ? null : FactoryRecipes.byId(rid);
          final kw = r == null ? 0.0 : r.powerKw * m.crew.powerMult;
          tint = Color.fromRGBO(255, 213, 79, 0.15 + 0.6 * kw / maxKw);
        }
      }
      if (tint != null) {
        _tint.color = tint;
        _T.rect(canvas, rect, _tint);
      }
      _lamp.color = kStatusColor[s]!;
      _T.circle(canvas, Offset(f.x0 + 0.5, f.y1 - 0.5), 0.28, _lamp);
      // A broken-down station is crossed out whatever the overlay: it
      // needs a technician, and that should read from across the hall.
      if (s == MachineStatus.broken) {
        _T.line(canvas, rect.topLeft, rect.bottomRight, _broken);
        _T.line(canvas, rect.bottomLeft, rect.topRight, _broken);
      }
    }
  }

  /// Every visible machine's port notches (§10 item 19): filled strips via
  /// [_T], green inputs, orange outputs, the white hand port, an open port
  /// dimmed and a connected one in full.
  void _paintPorts(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    portMarks = 0;
    litPorts = 0;
    for (final m in ix.machines) {
      if (!m.footprint.overlaps(vis)) continue;
      _drawMarks(canvas, portMarksOf(m, ix));
    }
  }

  void _drawMarks(Canvas canvas, List<PortMark> marks) {
    for (final mark in marks) {
      _portPaint.color = mark.color;
      _T.rect(canvas, mark.rect, _portPaint);
      portMarks++;
      if (mark.connected) litPorts++;
    }
  }

  /// Zoomed in, each used input and output notch names its slot's item.
  void _paintPortLabels(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    for (final m in ix.machines) {
      if (!m.footprint.overlaps(vis)) continue;
      for (final mark in portMarksOf(m, ix)) {
        if (mark.port.role == PortRole.hand) continue;
        final i = mark.label.indexOf(': ');
        if (i < 0 || mark.label.endsWith('unused')) continue;
        final tp = _label(mark.label.substring(i + 2));
        final c0 = mark.rect.center;
        final at = c.tileToLocal(c0.dx, c0.dy);
        tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  void _paintHeat(Canvas canvas, TileRect vis) {
    final heat = c.heat;
    final max = c.heatMax;
    if (max <= 0 || heat.isEmpty) return;
    const k = kHeatCellTiles;
    final cx0 = vis.x0 ~/ k, cx1 = math.min(c.heatW, (vis.x1 + k - 1) ~/ k);
    final cy0 = vis.y0 ~/ k, cy1 = math.min(c.heatH, (vis.y1 + k - 1) ~/ k);
    for (var cy = cy0; cy < cy1; cy++) {
      for (var cx = cx0; cx < cx1; cx++) {
        final v = heat[cy * c.heatW + cx];
        if (v <= 0) continue;
        final t = math.sqrt(v / max);
        _tint.color = Color.fromRGBO(255, (200 * (1 - t)).round(), 40, 0.15 + 0.5 * t);
        _T.rect(canvas, 
            Rect.fromLTWH((cx * k).toDouble(), (cy * k).toDouble(),
                k.toDouble(), k.toDouble()),
            _tint);
      }
    }
  }

  void _paintBeltItems(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    for (final b in c.sim.beltItems) {
      if (!vis.contains(b.tile)) continue;
      final d = ix.beltDirAt(b.tile) ?? Dir4.east;
      final t = b.progress - 0.5;
      _T.circle(canvas, 
          Offset(b.tile.x + 0.5 + d.dx * t, b.tile.y + 0.5 + d.dy * t),
          0.2,
          _itemPaint(b.item));
    }
  }

  /// Goods on the open floor: a stack in the item's colour per (tile,
  /// item), several items on one tile side by side.
  void _paintPiles(Canvas canvas, TileRect vis) {
    TilePos? at;
    var n = 0;
    for (final p in c.sim.piles) {
      if (!vis.contains(p.tile)) continue;
      n = p.tile == at ? n + 1 : 0;
      at = p.tile;
      final o = (n % 3) * 0.28;
      final r = Rect.fromLTWH(p.tile.x + 0.1 + o, p.tile.y + 0.1, 0.5, 0.5);
      _T.rect(canvas, r, _itemPaint(p.item));
      _T.rect(canvas, r, _pileEdge);
    }
  }

  /// An amber warning triangle in the corner of every pile nothing could
  /// take (no store with room), as filled geometry (§10 item 17).
  void _paintStuckPiles(Canvas canvas, TileRect vis) {
    for (final t in c.stuckPiles) {
      if (!vis.contains(t)) continue;
      final x = t.x.toDouble(), y = t.y.toDouble();
      canvas.drawPath(
          Path()
            ..moveTo(x + 0.6, y + 0.62)
            ..lineTo(x + 0.98, y + 0.62)
            ..lineTo(x + 0.79, y + 0.98)
            ..close(),
          _unusedMark);
    }
  }

  /// The Clear tool's drag box: a teal wash with a filled edge ring.
  void _paintClearBox(Canvas canvas) {
    final r = c.clearRect;
    if (r == null) return;
    final box = Rect.fromLTWH(
        r.x0.toDouble(), r.y0.toDouble(), r.w.toDouble(), r.h.toDouble());
    _T.rect(canvas, box, _clearFill);
    _T.rect(canvas, box, _clearEdge);
  }

  /// 2-3 letter names on belt items and piles at close zoom, screen space.
  void _paintItemLabels(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    for (final b in c.sim.beltItems) {
      if (!vis.contains(b.tile)) continue;
      final d = ix.beltDirAt(b.tile) ?? Dir4.east;
      final t = b.progress - 0.5;
      final tp = _label(itemAbbrev(b.item));
      final at = c.tileToLocal(
          b.tile.x + 0.5 + d.dx * t, b.tile.y + 0.5 + d.dy * t);
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }
    TilePos? at;
    var n = 0;
    for (final p in c.sim.piles) {
      if (!vis.contains(p.tile)) continue;
      n = p.tile == at ? n + 1 : 0;
      at = p.tile;
      final o = (n % 3) * 0.28;
      final ctr = c.tileToLocal(p.tile.x + 0.35 + o, p.tile.y + 0.35);
      final tp = _label('${itemAbbrev(p.item)}${p.count > 1 ? p.count : ''}');
      tp.paint(canvas, ctr - Offset(tp.width / 2, tp.height / 2));
    }
  }

  /// Hired operators (sky) and technicians (amber), §10 item 20: a small
  /// filled dot with a dark ring, a white core when pinned. Smaller than a
  /// handler walker's dot so the two read apart; several at one post fan
  /// out by id.
  void _paintStaff(Canvas canvas, TileRect vis) {
    final sim = c.sim;
    if (sim is! FactoryStaffedSim) return;
    final seen = <(int, int), int>{};
    for (final v in (sim as FactoryStaffedSim).staff) {
      if (v.x < vis.x0 - 1 || v.x > vis.x1 + 1) continue;
      if (v.y < vis.y0 - 1 || v.y > vis.y1 + 1) continue;
      final key = (v.x.round(), v.y.round());
      final n = seen[key] = (seen[key] ?? -1) + 1;
      final at = Offset(v.x + 0.5 + (n % 3 - 1) * 0.3 * (n > 0 ? 1 : 0),
          v.y + 0.5 + (n ~/ 3) * 0.3);
      _dot.color = v.role == StaffRole.operator
          ? kOperatorColor
          : kTechnicianColor;
      _T.circle(canvas, at, 0.24, _dot);
      _T.circle(canvas, at, 0.24, _handlerRing);
      if (v.pinned) {
        _dot.color = const Color(0xFFFFFFFF);
        _T.circle(canvas, at, 0.09, _dot);
      }
    }
  }

  void _paintHandlers(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    handlerRects.clear();
    bridgeRects.clear();
    for (final h in c.sim.handlers) {
      final sq = handlerSquare(h);
      if (sq.right < vis.x0 - 1 || sq.left > vis.x1 + 1) continue;
      if (sq.bottom < vis.y0 - 1 || sq.top > vis.y1 + 1) continue;
      handlerRects[h.id] = sq;
      final col = kHandlerColor[h.kind]!;
      _dot.color = col;
      final at = sq.center;
      switch (h.kind) {
        case HandlerKind.onFoot:
          // A person: a dot a little smaller than the tile.
          _T.circle(canvas, at, 0.34, _dot);
          _T.circle(canvas, at, 0.34, _handlerRing);
        case HandlerKind.palletJack:
          // A jack: a diamond (its tiller and tines read as a point).
          final d = Path()
            ..moveTo(at.dx, at.dy + 0.42)
            ..lineTo(at.dx + 0.42, at.dy)
            ..lineTo(at.dx, at.dy - 0.42)
            ..lineTo(at.dx - 0.42, at.dy)
            ..close();
          canvas.drawPath(d, _dot);
          (_SP()
                ..moveTo(at.dx, at.dy + 0.42)
                ..lineTo(at.dx + 0.42, at.dy)
                ..lineTo(at.dx, at.dy - 0.42)
                ..lineTo(at.dx - 0.42, at.dy)
                ..close())
              .draw(canvas, _handlerRing.color, _handlerRing.strokeWidth);
        case HandlerKind.forklift:
          // A forklift: a body filling most of its square, a mast bar and
          // two forks out the front (+x).
          final body = Rect.fromCenter(
              center: at - Offset(sq.width * 0.1, 0),
              width: sq.width * 0.62,
              height: sq.height * 0.7);
          _T.rrect(canvas, 
              RRect.fromRectAndRadius(body, const Radius.circular(0.15)),
              _dot);
          _T.rrect(canvas, 
              RRect.fromRectAndRadius(body, const Radius.circular(0.15)),
              _handlerRing);
          final fx = body.right;
          _T.line(canvas, Offset(fx, body.top), Offset(fx, body.bottom), _glyph);
          for (final fy in [at.dy - sq.height * 0.18, at.dy + sq.height * 0.18]) {
            _T.line(canvas, 
                Offset(fx, fy), Offset(sq.right - 0.08, fy), _glyph);
          }
        case HandlerKind.agv:
          // An AGV: a low square deck with a sensor ring.
          final body = sq.deflate(sq.width * 0.16);
          _T.rect(canvas, body, _dot);
          _T.rect(canvas, body, _handlerRing);
          _T.circle(canvas, at, body.width * 0.22, _glyph);
        case HandlerKind.crane:
          // A crane: its bridge spans the bay at the hook's place, the hook
          // a square under it.
          final bay = ix.craneBayAt(
              TilePos((h.x + 0.5).floor(), (h.y + 0.5).floor()));
          if (bay != null) {
            final br = craneBridge(h, bay.footprint);
            bridgeRects[h.id] = br;
            _T.rect(canvas, br.deflate(0.08), _bridge);
            _T.rect(canvas, br.deflate(0.08), _bridgeEdge);
          }
          final hook = sq.deflate(0.22);
          _T.rect(canvas, hook, _dot);
          _T.rect(canvas, hook, _handlerRing);
      }
      final item = h.carrying;
      if (item != null) {
        _T.rect(canvas, 
            Rect.fromCenter(center: at, width: 0.42, height: 0.36),
            _itemPaint(item));
      }
      final b = h.battery;
      if (b != null) {
        // The charge bar under the vehicle; a ring while it charges.
        final bar = Rect.fromLTWH(sq.left + 0.15, sq.top + 0.05,
            sq.width - 0.3, 0.18);
        _T.rect(canvas, bar, _barBack);
        _bar.color = batteryColor(b);
        _T.rect(canvas, 
            Rect.fromLTWH(bar.left, bar.top, bar.width * b.clamp(0.0, 1.0),
                bar.height),
            _bar);
        if (h.state == HandlerState.charging) {
          _T.rect(canvas, sq.deflate(0.04), _chargeRing);
        }
      }
    }
  }

  void _paintSelection(Canvas canvas, FloorLayoutIndex ix) {
    final h = c.hover;
    if (h != null && c.tool != FactoryTool.place) {
      _T.rect(canvas, 
          Rect.fromLTWH(h.x.toDouble(), h.y.toDouble(), 1, 1), _hover);
    }
    final hr = c.highlightRecipe;
    if (hr != null) {
      for (final m in ix.machines) {
        if (m.recipe != hr) continue;
        final f = m.footprint;
        // Outset past the selection ring (0.1) so both stay visible.
        _T.rect(
            canvas,
            Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(), f.w.toDouble(),
                    f.h.toDouble())
                .inflate(0.3),
            _highlight);
      }
    }
    final id = c.selectedId;
    if (id == null) return;
    final p = ix.byId(id);
    if (p == null) return;
    final f = p.footprint;
    _T.rect(canvas, 
        Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(), f.w.toDouble(),
                f.h.toDouble())
            .inflate(0.1),
        _select);
  }

  /// The placement preview. Every directed piece gets a FILLED arrowhead
  /// (the playtest's bare facing line didn't read), a redirected belt is
  /// tinted apart from a new one, and an arm's ghost tints the tile it
  /// takes from and the tile it drops into (§10 item 1).
  void _paintGhost(Canvas canvas) {
    ghostArrows = 0;
    armGhostEnds.clear();
    redirectGhosts = 0;
    final arrows = Path();
    for (final g in c.ghost) {
      final f = g.rect;
      final r = Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(), f.w.toDouble(),
          f.h.toDouble());
      final redirect = g.redirects != null;
      if (redirect) redirectGhosts++;
      _T.rect(
          canvas,
          r,
          !g.check.ok
              ? _ghostBad
              : redirect
                  ? _ghostRedirect
                  : _ghostOk);
      _T.rect(canvas, r, _ghostEdge);
      final p = g.placement;
      if (kSpannedKinds.contains(p.kind)) continue;
      final cx = r.center.dx, cy = r.center.dy;
      final fx = p.dir.dx.toDouble(), fy = p.dir.dy.toDouble();
      final reach = (p.dir.isVertical ? f.h : f.w) / 2;
      addArrow(
          arrows,
          Offset(cx - fx * reach * 0.55, cy - fy * reach * 0.55),
          Offset(cx + fx * reach * 0.95, cy + fy * reach * 0.95),
          shaft: 0.14,
          headLen: math.min(0.45, reach),
          headWidth: 0.55);
      ghostArrows++;
      // A machine ghost shows its ports before it lands, lit where the
      // layout it would join already connects them.
      if (p.kind == EntityKind.machine) _drawMarks(canvas, portMarksOf(p, c.index));
      if (p.kind == EntityKind.arm) {
        final from = TilePos(p.pos.x - p.dir.dx, p.pos.y - p.dir.dy);
        final to = p.pos.step(p.dir);
        armGhostEnds.add((from, to));
        _T.rect(canvas, _tileRect(from).deflate(0.06), _armTake);
        _T.rect(canvas, _tileRect(to).deflate(0.06), _armDrop);
      }
    }
    canvas.drawPath(arrows, _ghostArrow);
  }

  static Rect _tileRect(TilePos t) =>
      Rect.fromLTWH(t.x.toDouble(), t.y.toDouble(), 1, 1);

  /// The Delete tool's area drag: every target tinted red and the box
  /// outlined (§10 item 9). The counts are drawn as a label afterwards.
  void _paintDeletePreview(Canvas canvas) {
    deletePreviewRects.clear();
    final box = c.deleteRect;
    if (box == null) return;
    for (final p in c.deleteTargets) {
      final f = p.footprint;
      final r = Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(),
          f.w.toDouble(), f.h.toDouble());
      deletePreviewRects.add(r);
      _T.rect(canvas, r, _deleteFill);
    }
    _T.rect(
        canvas,
        Rect.fromLTWH(box.x0.toDouble(), box.y0.toDouble(), box.w.toDouble(),
            box.h.toDouble()),
        _deleteEdge);
  }

  /// While X is held, a small red outline under the cursor (§10 item 12):
  /// the "eraser" the player is sweeping with. Around the footprint of what
  /// X would remove there, else around the hover tile itself. A solid is
  /// removed the instant the sweep reaches it, so most of the time the ring
  /// sits on the tile just cleared, which is exactly the feedback wanted:
  /// X is live, and this is where it bites.
  void _paintSweep(Canvas canvas) {
    sweepRect = null;
    if (!c.sweeping) return;
    final h = c.hover;
    if (h == null) return;
    final p = c.sweepTarget;
    final Rect r;
    if (p == null) {
      r = _tileRect(h).deflate(0.08);
    } else {
      final f = p.footprint;
      r = Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(), f.w.toDouble(),
              f.h.toDouble())
          .inflate(0.08);
      _T.rect(canvas, r, _sweepFill);
    }
    sweepRect = r;
    _T.rect(canvas, r, _sweepEdge);
  }

  /// A warning mark on every receiving dock whose item no machine here
  /// consumes (§10 item 6): a filled amber triangle in its corner.
  void _paintUnusedDocks(Canvas canvas, FloorLayoutIndex ix, TileRect vis) {
    unusedDockMarks = 0;
    final marks = Path();
    for (final d in ix.unusedDocks) {
      final f = d.footprint;
      if (!f.overlaps(vis)) continue;
      unusedDockMarks++;
      final x = f.x1 - 0.5, y = f.y1 - 0.1;
      marks
        ..moveTo(x, y)
        ..lineTo(x + 0.42, y - 0.72)
        ..lineTo(x - 0.42, y - 0.72)
        ..close();
    }
    if (unusedDockMarks > 0) canvas.drawPath(marks, _unusedMark);
  }

  /// Screen-space words for the ghost and the delete preview: "take" and
  /// "drop" on an arm's two tiles, the area delete's counts.
  void _paintEditLabels(Canvas canvas, double px) {
    deleteLabel = null;
    final box = c.deleteRect;
    if (box != null) {
      final s = c.deleteSummary;
      deleteLabel = s;
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: const TextStyle(
                color: Color(0xFFFFB0B0),
                fontSize: kLabelFont,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 3)])),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final at = c.tileToLocal(box.x0.toDouble(), box.y1.toDouble());
      tp.paint(canvas, at - Offset(0, tp.height + 2));
      tp.dispose();
    }
    if (px < kLabelMinPx) return;
    for (final (from, to) in armGhostEnds) {
      for (final (t, s) in [(from, 'take'), (to, 'drop')]) {
        final tp = _label(s);
        final at = c.tileCenterLocal(t);
        tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  void _paintLabels(
      Canvas canvas, FloorLayoutIndex ix, TileRect vis, double px) {
    for (final m in ix.machines) {
      final f = m.footprint;
      if (!f.overlaps(vis)) continue;
      final rid = m.recipe;
      final r = rid == null ? null : FactoryRecipes.byId(rid);
      final text = r == null ? 'No recipe' : r.label;
      final tp = _label(text);
      final wPx = f.w * px;
      if (tp.width > wPx - 4) continue;
      final at = c.tileToLocal(f.x0 + f.w / 2, f.y0 + f.h / 2);
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
      if (r != null && f.h * px > tp.height * 2.6) {
        final st = _label(r.station.name);
        if (st.width <= wPx - 4) {
          st.paint(canvas, at + Offset(-st.width / 2, tp.height * 0.6));
        }
      }
    }
  }

  @override
  bool shouldRepaint(FactoryFloorPainter old) =>
      old.c != c || old.cache != cache;
}

/// Draws rects, rounded rects, circles, ovals and lines as TESSELLATED
/// filled paths.
///
/// On Windows the engine runs Impeller on GLES with its SDF shape renderer
/// ("OpenGLESSDF"), which anti-aliases those primitives with `fwidth`, and
/// `fwidth` overestimates ~10x there (memory: gles-fwidth-unusable). At a
/// floor's tile-unit scale every thin stroke smeared into a wide blur: the
/// grid turned the dark floor white, the hall wall drew a halo, and a
/// forklift's outlined body became a black blob. Filled paths are
/// tessellated, not SDF-shaded, so they draw true. A stroke becomes an
/// even-odd ring of its outer and inner outline; a line, a quad its width.
abstract final class _T {
  static bool _stroked(Paint p) => p.style == PaintingStyle.stroke;

  /// Half a stroke's width; a hairline (0) is drawn at a 20th of a tile.
  static double _half(Paint p) =>
      (p.strokeWidth <= 0 ? 0.05 : p.strokeWidth) / 2;

  static Paint _asFill(Paint p) => Paint()
    ..color = p.color
    ..shader = p.shader
    ..blendMode = p.blendMode
    ..isAntiAlias = p.isAntiAlias;

  static void rect(Canvas c, Rect r, Paint p) {
    if (!_stroked(p)) {
      c.drawPath(Path()..addRect(r), p);
      return;
    }
    final h = _half(p);
    c.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(r.inflate(h))
          ..addRect(r.deflate(h)),
        _asFill(p));
  }

  static void rrect(Canvas c, RRect r, Paint p) {
    if (!_stroked(p)) {
      c.drawPath(Path()..addRRect(r), p);
      return;
    }
    final h = _half(p);
    c.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRRect(r.inflate(h))
          ..addRRect(r.deflate(h)),
        _asFill(p));
  }

  static void oval(Canvas c, Rect r, Paint p) {
    if (!_stroked(p)) {
      c.drawPath(Path()..addOval(r), p);
      return;
    }
    final h = _half(p);
    c.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addOval(r.inflate(h))
          ..addOval(r.deflate(h)),
        _asFill(p));
  }

  static void circle(Canvas c, Offset at, double radius, Paint p) =>
      oval(c, Rect.fromCircle(center: at, radius: radius), p);

  static void line(Canvas c, Offset a, Offset b, Paint p) {
    final d = b - a;
    final len = d.distance;
    if (len <= 0) return;
    final h = _half(p);
    final n = Offset(-d.dy / len * h, d.dx / len * h);
    c.drawPath(
        Path()
          ..moveTo(a.dx + n.dx, a.dy + n.dy)
          ..lineTo(b.dx + n.dx, b.dy + n.dy)
          ..lineTo(b.dx - n.dx, b.dy - n.dy)
          ..lineTo(a.dx - n.dx, a.dy - n.dy)
          ..close(),
        _asFill(p));
  }
}

/// A stroke described as lines, rects and rounded rects, then drawn as
/// FILLED geometry: every segment a quad with square caps, every rect or
/// rounded rect a ring (outer minus inner). The path-stroke twin of [_T]:
/// on Windows the engine smears thin stroked paths into wide blurs (a
/// machine's output bar became a white slab beside it), and filled
/// tessellated geometry draws true.
class _SP {
  final List<(Offset, Offset)> _segs = [];
  final List<RRect> _rings = [];
  Offset? _last;
  Offset? _start;

  void moveTo(double x, double y) {
    _last = Offset(x, y);
    _start = _last;
  }

  void lineTo(double x, double y) {
    final p = Offset(x, y);
    final last = _last;
    if (last != null) _segs.add((last, p));
    _last = p;
  }

  void close() {
    final last = _last, start = _start;
    if (last != null && start != null && last != start) {
      _segs.add((last, start));
    }
    _last = start;
  }

  void addRect(Rect r) => _rings.add(RRect.fromRectAndRadius(r, Radius.zero));
  void addRRect(RRect r) => _rings.add(r);

  bool get isEmpty => _segs.isEmpty && _rings.isEmpty;

  /// Fills the outline [width] wide in [color].
  void draw(Canvas c, Color color, double width) {
    if (isEmpty || width <= 0) return;
    final h = width / 2;
    final quads = Path();
    for (final (a, b) in _segs) {
      final d = b - a;
      final len = d.distance;
      if (len <= 0) continue;
      final u = d / len;
      final n = Offset(-u.dy * h, u.dx * h);
      final a2 = a - u * h, b2 = b + u * h; // square caps close the joints
      quads
        ..moveTo(a2.dx + n.dx, a2.dy + n.dy)
        ..lineTo(b2.dx + n.dx, b2.dy + n.dy)
        ..lineTo(b2.dx - n.dx, b2.dy - n.dy)
        ..lineTo(a2.dx - n.dx, a2.dy - n.dy)
        ..close();
    }
    final paint = Paint()..color = color;
    if (_segs.isNotEmpty) c.drawPath(quads, paint);
    for (final r in _rings) {
      c.drawPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRRect(r.inflate(h))
            ..addRRect(r.deflate(h)),
          paint);
    }
  }
}
