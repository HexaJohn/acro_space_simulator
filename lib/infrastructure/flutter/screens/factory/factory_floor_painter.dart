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
/// Tile space is y-up (north is up the screen) to match the floor's +y
/// running away from the yard; labels are drawn after the transform is
/// popped, in screen pixels, so text never mirrors.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import 'factory_editor_controller.dart';
import 'floor_layout_index.dart';

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

/// Label font size, logical px.
const double kLabelFont = 11;

/// Colors.
const Color kFactoryBg = Color(0xFF070B12);
const Color _hallFloor = Color(0xFF1A212A);
const Color _hallWall = Color(0xFF5E6E80);
const Color _beltBody = Color(0xFF39424D);
const Color _beltChevron = Color(0xFF9AA8B6);
const Color _okGhost = Color(0x707FE0A0);
const Color _badGhost = Color(0x80FF6B6B);

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

const Map<MachineStatus, Color> kStatusColor = {
  MachineStatus.working: Color(0xFF7FE0A0),
  MachineStatus.starved: Color(0xFFFFD54F),
  MachineStatus.blocked: Color(0xFFFF6B6B),
  MachineStatus.unstaffed: Color(0xFFFF8C66),
  MachineStatus.unpowered: Color(0xFFB388FF),
  MachineStatus.idle: Color(0xFF8499AE),
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
    c.drawRect(hallRect, _fill(_hallFloor));
    final aisle = Path(), staging = Path(), bay = Path(), rails = Path();
    for (final p in ix.overlays) {
      final r = _r(p.footprint);
      switch (p.kind) {
        case EntityKind.aisle:
          aisle.addRect(r);
        case EntityKind.staging:
          staging.addRect(r);
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
    c.drawPath(aisle, _stroke(const Color(0x90FFD54F), 0.08));
    c.drawPath(staging, _fill(const Color(0x284FC3F7)));
    c.drawPath(staging, _stroke(const Color(0x704FC3F7), 0.08));
    c.drawPath(bay, _fill(const Color(0x22FF8C66)));
    c.drawPath(rails, _stroke(const Color(0xB0FF8C66), 0.18));
    c.drawRect(hallRect.inflate(0.25), _stroke(_hallWall, 0.5));
    return rec.endRecording();
  }

  ui.Picture _recordEntities(FloorLayoutIndex ix) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final belts = Path(), chevrons = Path(), zebra = Path();
    final chests = Path(), recv = Path(), ship = Path(), doors = Path();
    final racks = Path(), rackBeams = Path(), charge = Path(), bolts = Path();
    final arms = Path(), armLines = Path();
    final byStation = <StationKind?, Path>{};
    final notches = Path();
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
          arms.addOval(Rect.fromCircle(center: Offset(cx, cy), radius: 0.28));
          armLines
            ..moveTo(cx - fx * 0.45, cy - fy * 0.45)
            ..lineTo(cx + fx * 0.45, cy + fy * 0.45)
            ..moveTo(cx + fx * 0.45 + sx * 0.18, cy + fy * 0.45 + sy * 0.18)
            ..lineTo(cx + fx * 0.45 - sx * 0.18, cy + fy * 0.45 - sy * 0.18);
        case EntityKind.chest:
          chests.addRect(_r(f, 0.12));
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
          byStation.putIfAbsent(st, Path.new).addRRect(RRect.fromRectAndRadius(
              _r(f, 0.1), const Radius.circular(0.3)));
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
    c.drawPath(chevrons, _stroke(_beltChevron, 0.07));
    c.drawPath(zebra, _stroke(const Color(0xFFE0E0E0), 0.1));
    c.drawPath(chests, _fill(const Color(0xFF7A5A3A)));
    c.drawPath(chests, _stroke(const Color(0xFFC09060), 0.06));
    c.drawPath(recv, _fill(const Color(0xFF2E6B4A)));
    c.drawPath(ship, _fill(const Color(0xFF8A5A2E)));
    c.drawPath(doors, _stroke(const Color(0xFFE8EEF4), 0.16));
    c.drawPath(racks, _fill(const Color(0xFF253A55)));
    c.drawPath(racks, _stroke(const Color(0xFF6A9AD0), 0.08));
    c.drawPath(rackBeams, _stroke(const Color(0x806A9AD0), 0.05));
    c.drawPath(charge, _fill(const Color(0xFF1E4A4A)));
    c.drawPath(bolts, _stroke(const Color(0xFF4FC3F7), 0.1));
    c.drawPath(arms, _fill(const Color(0xFF606C78)));
    c.drawPath(armLines, _stroke(const Color(0xFFFFD54F), 0.12));
    for (final e in byStation.entries) {
      c.drawPath(e.value, _fill(kStationColor[e.key] ?? const Color(0xFF555555)));
      c.drawPath(e.value, _stroke(const Color(0xFF0E1622), 0.1));
    }
    c.drawPath(notches, _stroke(const Color(0xFFE8EEF4), 0.18));
    return rec.endRecording();
  }
}

class FactoryFloorPainter extends CustomPainter {
  FactoryFloorPainter(this.c, this.cache) : super(repaint: c.frame);

  final FactoryEditorController c;
  final FloorLayerCache cache;

  static final Paint _bg = _fill(kFactoryBg);
  static final Paint _grid = _stroke(const Color(0xFFFFFFFF), 0);
  static final Paint _tint = Paint();
  static final Paint _lamp = Paint();
  static final Paint _dot = Paint();
  static final Paint _handlerRing = _stroke(const Color(0xFF05080F), 0.08);
  static final Paint _select = _stroke(const Color(0xFF4FC3F7), 0.15);
  static final Paint _hover = _stroke(const Color(0x60FFFFFF), 0.06);
  static final Paint _ghostOk = _fill(_okGhost);
  static final Paint _ghostBad = _fill(_badGhost);
  static final Paint _ghostEdge = _stroke(const Color(0xC0FFFFFF), 0.06);
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
    canvas.drawRect(Offset.zero & size, _bg);
    canvas.save();
    canvas.translate(c.origin.dx, c.origin.dy);
    canvas.scale(px, -px);
    canvas.drawPicture(cache.floor);
    _paintGrid(canvas, vis, px);
    canvas.drawPicture(cache.entities);
    _paintMachines(canvas, ix, vis);
    if (c.overlays.contains(FactoryOverlay.traffic)) _paintHeat(canvas, vis);
    if (px >= kDynamicMinPx) {
      _paintBeltItems(canvas, ix, vis);
      _paintHandlers(canvas, vis);
    }
    _paintSelection(canvas, ix);
    _paintGhost(canvas);
    canvas.restore();
    if (px >= kLabelMinPx) _paintLabels(canvas, ix, vis, px);
  }

  void _paintGrid(Canvas canvas, TileRect vis, double px) {
    final a = ((px - kGridMinPx) / kGridFadePx).clamp(0.0, 1.0) * kGridAlpha;
    if (a <= 0 || vis.w <= 0 || vis.h <= 0) return;
    _grid.color = Color.fromRGBO(255, 255, 255, a);
    for (var x = vis.x0; x <= vis.x1; x++) {
      canvas.drawLine(Offset(x.toDouble(), vis.y0.toDouble()),
          Offset(x.toDouble(), vis.y1.toDouble()), _grid);
    }
    for (var y = vis.y0; y <= vis.y1; y++) {
      canvas.drawLine(Offset(vis.x0.toDouble(), y.toDouble()),
          Offset(vis.x1.toDouble(), y.toDouble()), _grid);
    }
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
          MachineStatus.starved => const Color(0x80FFD54F),
          MachineStatus.blocked => const Color(0x90FF6B6B),
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
        canvas.drawRect(rect, _tint);
      }
      _lamp.color = kStatusColor[s]!;
      canvas.drawCircle(Offset(f.x0 + 0.5, f.y1 - 0.5), 0.28, _lamp);
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
        canvas.drawRect(
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
      canvas.drawCircle(
          Offset(b.tile.x + 0.5 + d.dx * t, b.tile.y + 0.5 + d.dy * t),
          0.2,
          _itemPaint(b.item));
    }
  }

  void _paintHandlers(Canvas canvas, TileRect vis) {
    for (final h in c.sim.handlers) {
      if (h.x < vis.x0 - 1 || h.x > vis.x1 + 1) continue;
      if (h.y < vis.y0 - 1 || h.y > vis.y1 + 1) continue;
      final r = h.kind == HandlerKind.crane
          ? 0.6
          : h.kind == HandlerKind.forklift
              ? 0.5
              : 0.36;
      _dot.color = kHandlerColor[h.kind]!;
      final at = Offset(h.x, h.y);
      canvas.drawCircle(at, r, _dot);
      canvas.drawCircle(at, r, _handlerRing);
      final item = h.carrying;
      if (item != null) {
        canvas.drawRect(
            Rect.fromCenter(center: at + const Offset(0, 0.45), width: 0.5,
                height: 0.4),
            _itemPaint(item));
      }
    }
  }

  void _paintSelection(Canvas canvas, FloorLayoutIndex ix) {
    final h = c.hover;
    if (h != null && c.tool != FactoryTool.place) {
      canvas.drawRect(
          Rect.fromLTWH(h.x.toDouble(), h.y.toDouble(), 1, 1), _hover);
    }
    final id = c.selectedId;
    if (id == null) return;
    final p = ix.byId(id);
    if (p == null) return;
    final f = p.footprint;
    canvas.drawRect(
        Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(), f.w.toDouble(),
                f.h.toDouble())
            .inflate(0.1),
        _select);
  }

  void _paintGhost(Canvas canvas) {
    for (final g in c.ghost) {
      final f = g.rect;
      final r = Rect.fromLTWH(f.x0.toDouble(), f.y0.toDouble(), f.w.toDouble(),
          f.h.toDouble());
      canvas.drawRect(r, g.check.ok ? _ghostOk : _ghostBad);
      canvas.drawRect(r, _ghostEdge);
      final p = g.placement;
      if (kSpannedKinds.contains(p.kind)) continue;
      final cx = r.center.dx, cy = r.center.dy;
      final fx = p.dir.dx.toDouble(), fy = p.dir.dy.toDouble();
      canvas.drawLine(Offset(cx, cy),
          Offset(cx + fx * (f.w / 2), cy + fy * (f.h / 2)), _ghostEdge);
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
