// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../adapters/presenters/craft_editor_camera.dart';
import '../../../../adapters/presenters/craft_editor_pick.dart';
import '../../../../domain/craft/attach_targets.dart';
import '../../../../domain/craft/craft_design.dart';
import '../../../../domain/parts/attach_node.dart';
import '../../../../domain/parts/part_def.dart';
import '../../../../domain/shared/vector3.dart';
import '../app_theme.dart';

/// Everything the craft editor's 2D overlay draws, as one immutable value.
///
/// A plain snapshot rather than a handful of painter constructor arguments for
/// two reasons. It gives the painter a single identity to diff in
/// [CustomPainter.shouldRepaint], so a build that changed nothing repaints
/// nothing; and it is buildable without a widget tree, which is what lets the
/// overlay be rendered against a solid background in a screenshot test with no
/// Impeller context anywhere in the process.
///
/// Every position in here is CRAFT-FRAME METRES. Nothing is pre-projected: the
/// painter runs [CraftEditorCamera.project] itself, so the overlay and the
/// rendered image agree by construction instead of by two call sites happening
/// to use the same camera.
class CraftEditorOverlay {
  const CraftEditorOverlay({
    required this.camera,
    required this.design,
    this.targets = const [],
    this.compatible = const {},
    this.hovered,
    this.hoveredPartId,
    this.seats = const [],
    this.cursor,
    this.selection = const {},
    this.selectionLabel,
    this.looseIds = const {},
    this.centreOfMass,
    this.thrustOrigin,
    this.thrustAxis,
    this.thrustOffAxisDeg,
    this.showNodes = true,
    this.showBalance = true,
    this.showStages = false,
    this.rootGhost = false,
    this.alternatives = 0,
    this.cycle = 0,
    this.edgeOn = false,
    this.hud = const [],
    this.blocked,
  });

  /// The pose every point in this snapshot is projected through. Its viewport
  /// must be the same [Size] the painter is handed, or the overlay lands
  /// somewhere the render does not.
  final CraftEditorCamera camera;

  final CraftDesign design;

  /// Open attach nodes to draw markers for, in any order — the painter sorts
  /// them by depth itself.
  final List<AttachTarget> targets;

  /// `(ownerInstanceId, nodeName)` of the targets the held part could actually
  /// mate to. Records rather than a concatenated key, so no separator can ever
  /// appear inside a node name and collide.
  final Set<(String, String)> compatible;

  /// The target a click would commit to right now. THE COMMITMENT DISPLAY: it
  /// is drawn bright, named in words, and joined to the cursor by a leader
  /// line, so an ambiguous pick costs a three-pixel correction rather than a
  /// placement the player has to notice and undo.
  final AttachTarget? hovered;

  /// The part a click would select right now, when nothing is held.
  final String? hoveredPartId;

  /// Every seat one click would fill under the current symmetry — [hovered]
  /// plus its ring siblings. Drawn as a dashed polyline with an `x4` badge so a
  /// four-way mount LOOKS like four before it is committed.
  final List<AttachTarget> seats;

  /// Where the pointer is, in viewport-local logical pixels, or null when it
  /// has left (or never entered, as on touch).
  final Offset? cursor;

  /// Instance ids drawn with a selection outline — the picked part AND its
  /// symmetry siblings, because they are what one action operates on.
  final Set<String> selection;

  /// The chip under the selection outline, e.g. `Eagle RCS Quad - S2 - x4`.
  final String? selectionLabel;

  /// Parts attached to nothing that are not the root. Outlined in [
  /// AppTheme.danger] dashes because they gate LAUNCH and are otherwise
  /// invisible: a loose part sits exactly where it was dropped and looks
  /// bolted on.
  final Set<String> looseIds;

  final Vector3? centreOfMass;

  /// Thrust application point and unit EXHAUST axis (the reaction is along
  /// `-thrustAxis`), from `CraftBalance.thrust`.
  final Vector3? thrustOrigin;
  final Vector3? thrustAxis;

  /// How far the thrust line misses the centre of mass, degrees. Past five the
  /// markers go [AppTheme.warn] and the HUD says so: an off-axis thrust line
  /// torques the craft every time the engine lights, and it is invisible in any
  /// numeric readout.
  final double? thrustOffAxisDeg;

  final bool showNodes;
  final bool showBalance;

  /// Stage badges are drawn only under the staging tool. They are the densest
  /// labels the overlay has and they mean nothing while a part is being aimed.
  final bool showStages;

  /// The design is empty and a part is held: the ghost stands on the pad at the
  /// craft origin and the overlay says so, because there is no target to hover
  /// and nothing else would explain what the click will do.
  final bool rootGhost;

  /// How many candidates were within the grab radius, from
  /// `PickedTarget.alternatives`. Anything above one earns the cycle hint.
  final int alternatives;

  /// Which of those candidates is currently chosen.
  final int cycle;

  /// The top candidates are within a couple of pixels of one another on the
  /// same ring — the axial view of a four-way mount, which is exactly where
  /// projection picking is blind. The HUD says to orbit rather than leaving the
  /// player to discover it by placing a part in the wrong place.
  final bool edgeOn;

  /// HUD lines, top-left, in order.
  final List<String> hud;

  /// The controller's refusal sentence, or null.
  final String? blocked;
}

/// The craft editor's 2D overlay: attach-node markers, the snap commitment, the
/// symmetry preview, selection outlines, balance markers, stage badges and the
/// HUD.
///
/// ## Why any of this is an overlay rather than scene geometry
///
/// The split rule for the whole editor is: anything that must be OCCLUDED is a
/// flutter_scene node, anything that must be LEGIBLE is painted here. A node
/// marker has to be a constant size on screen at every zoom, has to stay
/// visible when the node it belongs to is inside a hull, and has to be
/// clickable at 22 px whatever the craft is doing. A depth-tested 3D marker
/// fails all three: it shrinks to nothing when the player pulls back to see the
/// whole vehicle, and it disappears inside the very part it is attached to.
///
/// The consequence worth stating is that the editor stays completely usable
/// when no `.fsceneb` bake has loaded — procedural stand-ins under a fully
/// functional overlay — because picking is oriented-box arithmetic off
/// `PartDef.size` and never touches a mesh.
///
/// ## Painting order
///
/// Back to front, and markers within a pass are sorted by view depth
/// DESCENDING so the near ones land on top. There is no depth buffer here; the
/// order IS the depth test.
class CraftEditorPainter extends CustomPainter {
  const CraftEditorPainter(this.data);

  final CraftEditorOverlay data;

  /// Opacity of a far-side marker. Low enough to read as "behind", high enough
  /// that a player can still aim at it after orbiting a few degrees.
  static const double awayAlpha = 0.35;

  /// Two labels closer than this collapse to one. Stage badges on a four-way
  /// ring project within a few pixels of one another edge-on, and four
  /// overlapping `S2`s are less readable than one.
  static const double labelDeclutterPx = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = data.camera;
    if (size.width <= 0 || size.height <= 0) return;

    _paintLooseParts(canvas, cam);
    if (data.showNodes) _paintMarkers(canvas, cam);
    _paintSeats(canvas, cam);
    _paintSnap(canvas, cam);
    _paintSelection(canvas, cam);
    if (data.showBalance) _paintBalance(canvas, cam);
    if (data.showStages) _paintStages(canvas, cam);
    _paintHud(canvas, size);
  }

  // ---------------- attach-node markers ----------------

  void _paintMarkers(Canvas canvas, CraftEditorCamera cam) {
    final drawn = <_ProjectedMarker>[];
    for (final t in data.targets) {
      final m = _projectMarker(cam, t);
      if (m != null) drawn.add(m);
    }
    // Far to near: the painter has no depth buffer, so paint order is the only
    // depth test there is.
    drawn.sort((a, b) => b.depth.compareTo(a.depth));

    final hovered = data.hovered;
    for (final m in drawn) {
      final isHovered = hovered != null &&
          m.target.ownerInstanceId == hovered.ownerInstanceId &&
          m.target.nodeName == hovered.nodeName;
      final compatible =
          data.compatible.contains((m.target.ownerInstanceId, m.target.nodeName));
      var colour = compatible ? AppTheme.accent2 : AppTheme.textDim;
      if (m.away) colour = colour.withValues(alpha: awayAlpha);

      // A far-side or incompatible marker is an outline; a reachable one is
      // filled. The difference has to survive being 6 px across, which is why
      // it is fill versus stroke and not two similar hues.
      final filled = compatible && !m.away;
      if (m.target.kind == AttachKind.stack) {
        _stackMarker(canvas, m, colour, filled: filled);
      } else {
        _surfaceMarker(canvas, m, colour, filled: filled);
      }
      if (isHovered) {
        canvas.drawCircle(
          m.screen,
          m.radius + 5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = AppTheme.accent,
        );
      }
    }
  }

  /// A stack node: a ring, because the two parts butt together on a circle and
  /// the mate has no side to it.
  void _stackMarker(Canvas canvas, _ProjectedMarker m, Color colour,
      {required bool filled}) {
    canvas.drawCircle(
      m.screen,
      m.radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = colour,
    );
    if (filled) {
      canvas.drawCircle(
        m.screen,
        m.radius * 0.45,
        Paint()..color = colour.withValues(alpha: 0.85),
      );
    }
  }

  /// A surface node: a half disc opening along the projected outward normal, so
  /// the marker says which way OUT is before the part is committed. That is the
  /// one thing a ring cannot express, and a radial mount placed facing inward is
  /// the mistake it prevents.
  void _surfaceMarker(Canvas canvas, _ProjectedMarker m, Color colour,
      {required bool filled}) {
    final angle = math.atan2(m.normal.dy, m.normal.dx);
    final rect = Rect.fromCircle(center: m.screen, radius: m.radius);
    final path = Path()
      ..moveTo(m.screen.dx, m.screen.dy)
      ..arcTo(rect, angle - math.pi / 2, math.pi, false)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = filled ? colour.withValues(alpha: 0.85) : colour,
    );
    canvas.drawLine(
      m.screen,
      m.screen + m.normal * (m.radius + 4),
      Paint()
        ..strokeWidth = 1.4
        ..color = colour,
    );
  }

  _ProjectedMarker? _projectMarker(CraftEditorCamera cam, AttachTarget t) {
    final screen = cam.project(t.positionInCraft);
    if (screen == null) return null;
    final depth = cam.depthOf(t.positionInCraft);
    if (depth <= cam.nearM) return null;

    // The outward normal in SCREEN space, taken as the difference of two
    // projected points rather than by transforming the vector: that way it is
    // correct under perspective near the frame edge, where a linear transform
    // of the direction is visibly wrong.
    final tip = cam.project(t.positionInCraft + t.directionInCraft * 0.15);
    var normal = tip == null ? Offset.zero : tip - screen;
    normal = normal.distance < 1e-6
        ? const Offset(0, -1)
        : normal / normal.distance;

    return _ProjectedMarker(
      target: t,
      screen: screen,
      depth: depth,
      normal: normal,
      // Radius and facing both come from `CraftEditorPick`, which is what makes
      // the marker the player sees and the marker the pointer can hit ONE
      // circle. Two copies of these rules drift, and the visible symptom is a
      // full-size node in compatible colouring that ignores every click.
      radius: CraftEditorPick.markerRadiusPx(cam, t.size, depth),
      away: t.directionInCraft.dot(cam.viewDirTo(t.positionInCraft)) >
          CraftEditorPick.awayFacingDot,
    );
  }

  // ---------------- symmetry preview ----------------

  void _paintSeats(Canvas canvas, CraftEditorCamera cam) {
    if (data.seats.length < 2) return;
    final points = <Offset>[];
    for (final s in data.seats) {
      final p = cam.project(s.positionInCraft);
      if (p != null) points.add(p);
    }
    if (points.length < 2) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = AppTheme.accent2.withValues(alpha: 0.75);
    for (var i = 0; i < points.length; i++) {
      _dashedLine(canvas, points[i], points[(i + 1) % points.length], paint);
    }
    _label(
      canvas,
      'x${data.seats.length}',
      points.first + const Offset(10, -22),
      AppTheme.accent2,
    );
  }

  // ---------------- the commitment display ----------------

  void _paintSnap(Canvas canvas, CraftEditorCamera cam) {
    final t = data.hovered;
    if (t == null) return;
    final screen = cam.project(t.positionInCraft);
    if (screen == null) return;
    final depth = cam.depthOf(t.positionInCraft);
    if (depth <= cam.nearM) return;
    final radius = CraftEditorPick.markerRadiusPx(cam, t.size, depth);

    canvas.drawCircle(
      screen,
      radius + 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = AppTheme.accent,
    );

    // The leader line is what makes the choice legible when four markers are
    // within a few pixels: the eye follows it from the cursor to the one node
    // that is going to be used.
    final cursor = data.cursor;
    if (cursor != null && (cursor - screen).distance > radius + 4) {
      canvas.drawLine(
        cursor,
        screen,
        Paint()
          ..strokeWidth = 1.0
          ..color = AppTheme.accent.withValues(alpha: 0.6),
      );
    }

    final owner = data.design.partById(t.ownerInstanceId);
    final name = owner?.def.name ?? t.ownerInstanceId;
    _label(
      canvas,
      '$name > ${t.nodeName} - ${t.kind.name} ${t.size.toStringAsFixed(2)} m',
      screen + Offset(radius + 8, -8),
      AppTheme.text,
      background: true,
    );
  }

  // ---------------- selection and loose parts ----------------

  void _paintSelection(Canvas canvas, CraftEditorCamera cam) {
    if (data.selection.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = AppTheme.accent;

    Offset? anchor;
    for (final id in data.selection) {
      final part = data.design.partById(id);
      if (part == null) continue;
      // The true oriented box, NOT the screen-aligned rectangle the hit test
      // inflates: showing the player the box the picker uses would teach them
      // to distrust it, since it deliberately over-covers a rotated part.
      final corners = _boxCorners(cam, part);
      if (corners == null) continue;
      for (final e in _boxEdges) {
        canvas.drawLine(corners[e.$1], corners[e.$2], paint);
      }
      final centre = cam.project(part.position);
      if (centre != null && (anchor == null || centre.dy < anchor.dy)) {
        anchor = centre;
      }
    }
    final label = data.selectionLabel;
    if (label != null && anchor != null) {
      _label(canvas, label, anchor + const Offset(12, -26), AppTheme.accent,
          background: true);
    }
  }

  void _paintLooseParts(Canvas canvas, CraftEditorCamera cam) {
    if (data.looseIds.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = AppTheme.danger;
    for (final id in data.looseIds) {
      final part = data.design.partById(id);
      if (part == null) continue;
      final corners = _boxCorners(cam, part);
      if (corners == null) continue;
      for (final e in _boxEdges) {
        _dashedLine(canvas, corners[e.$1], corners[e.$2], paint);
      }
    }
  }

  /// The eight projected corners of a part's oriented box, or null when any of
  /// them is behind the near plane — a partly clipped outline reads as a
  /// rendering fault, and dropping the whole box for one frame does not.
  List<Offset>? _boxCorners(CraftEditorCamera cam, PlacedPart part) {
    final h = part.def.size * 0.5;
    final out = <Offset>[];
    for (final sz in const [-1.0, 1.0]) {
      for (final sy in const [-1.0, 1.0]) {
        for (final sx in const [-1.0, 1.0]) {
          final c = part.position +
              part.rotation.rotate(Vector3(sx * h.x, sy * h.y, sz * h.z));
          final s = cam.project(c);
          if (s == null) return null;
          out.add(s);
        }
      }
    }
    return out;
  }

  /// Edges of the corner order [_boxCorners] emits: x fastest, then y, then z.
  static const List<(int, int)> _boxEdges = [
    (0, 1), (1, 3), (3, 2), (2, 0), // -Z face
    (4, 5), (5, 7), (7, 6), (6, 4), // +Z face
    (0, 4), (1, 5), (2, 6), (3, 7), // risers
  ];

  // ---------------- balance ----------------

  void _paintBalance(Canvas canvas, CraftEditorCamera cam) {
    final off = data.thrustOffAxisDeg;
    final warn = off != null && off > 5.0;

    final com = data.centreOfMass;
    if (com != null) {
      final s = cam.project(com);
      if (s != null) _comMarker(canvas, s, warn);
    }

    final origin = data.thrustOrigin;
    final axis = data.thrustAxis;
    if (origin == null || axis == null) return;
    final s = cam.project(origin);
    if (s == null) return;
    // The exhaust axis drawn as a real line in the world, so the player sees
    // where the thrust actually points rather than a marker that could be
    // anywhere along it.
    final tail = cam.project(origin + axis * 3.0);
    final colour = warn ? AppTheme.warn : const Color(0xFFE060D0);
    if (tail != null) {
      canvas.drawLine(
        s,
        tail,
        Paint()
          ..strokeWidth = 1.4
          ..color = colour.withValues(alpha: 0.8),
      );
    }
    final cross = Paint()
      ..strokeWidth = 1.6
      ..color = colour;
    canvas.drawLine(s - const Offset(8, 0), s + const Offset(8, 0), cross);
    canvas.drawLine(s - const Offset(0, 8), s + const Offset(0, 8), cross);
    canvas.drawCircle(
      s,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = colour,
    );
  }

  /// The quartered yellow/black disc every vehicle balance diagram uses. Chosen
  /// over a coloured dot because it reads at 14 px against a hull of any
  /// brightness, which a single-hue marker does not.
  void _comMarker(Canvas canvas, Offset s, bool warn) {
    const r = 7.0;
    final rect = Rect.fromCircle(center: s, radius: r);
    final light = Paint()..color = warn ? AppTheme.warn : const Color(0xFFF5D34B);
    final dark = Paint()..color = const Color(0xFF10141B);
    for (var q = 0; q < 4; q++) {
      canvas.drawArc(rect, q * math.pi / 2, math.pi / 2, true,
          q.isEven ? light : dark);
    }
    canvas.drawCircle(
      s,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = warn ? AppTheme.warn : const Color(0xFFF5D34B),
    );
  }

  // ---------------- stage badges ----------------

  void _paintStages(Canvas canvas, CraftEditorCamera cam) {
    final placed = <Offset>[];
    final ordered = [...data.design.parts];
    // Near parts claim their label first, so decluttering drops the badge that
    // is behind rather than the one the player is looking at.
    ordered.sort((a, b) =>
        cam.depthOf(a.position).compareTo(cam.depthOf(b.position)));
    for (final p in ordered) {
      final s = cam.project(p.position);
      if (s == null) continue;
      if (placed.any((o) => (o - s).distance < labelDeclutterPx)) continue;
      placed.add(s);
      _label(canvas, 'S${p.stage}', s + const Offset(8, -8), AppTheme.warn,
          background: true);
    }
  }

  // ---------------- HUD ----------------

  void _paintHud(Canvas canvas, Size size) {
    var y = 10.0;
    for (final line in data.hud) {
      _label(canvas, line, Offset(10, y), AppTheme.text, background: true);
      y += 18;
    }
    if (data.rootGhost) {
      _label(canvas, 'ROOT - click anywhere to set it on the pad',
          Offset(10, y), AppTheme.accent2,
          background: true);
      y += 18;
    }
    if (data.alternatives > 1) {
      _label(
        canvas,
        '${data.alternatives} candidates - Tab to cycle '
        '(${data.cycle % data.alternatives + 1}/${data.alternatives})',
        Offset(10, y),
        AppTheme.textDim,
        background: true,
      );
      y += 18;
    }
    if (data.edgeOn) {
      // The honest residual of projection picking: looking straight down a
      // stack axis, a four-way ring is a few pixels wide and no ranking can
      // separate it. Saying so is better than letting the player find out by
      // placing a leg on the wrong side.
      _label(canvas, 'view is edge-on - orbit to disambiguate', Offset(10, y),
          AppTheme.warn,
          background: true);
      y += 18;
    }
    final blocked = data.blocked;
    if (blocked != null) {
      _label(canvas, blocked, Offset(10, y), AppTheme.danger, background: true);
    }
  }

  // ---------------- primitives ----------------

  void _label(Canvas canvas, String text, Offset at, Color colour,
      {bool background = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
            color: colour, fontSize: 11, fontFamily: 'monospace', height: 1.2),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (background) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(at.dx - 3, at.dy - 2, tp.width + 6, tp.height + 4),
          const Radius.circular(2),
        ),
        Paint()..color = AppTheme.bg.withValues(alpha: 0.72),
      );
    }
    tp.paint(canvas, at);
  }

  /// A dashed segment. Used for the symmetry polyline and the loose-part
  /// outline, both of which have to read as PROVISIONAL beside solid geometry.
  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint,
      {double dash = 5, double gap = 4}) {
    final total = (b - a).distance;
    if (total <= 0 || !total.isFinite) return;
    final step = (b - a) / total;
    var t = 0.0;
    while (t < total) {
      final end = math.min(t + dash, total);
      canvas.drawLine(a + step * t, a + step * end, paint);
      t = end + gap;
    }
  }

  /// Repaints whenever the snapshot object changes.
  ///
  /// The viewport assembles a fresh [CraftEditorOverlay] on every build, so in
  /// practice this is true on every build and the gate does its work one level
  /// up: the viewport only rebuilds on a pointer event, a key, or a controller
  /// notification, and each of those moves something in this picture. A
  /// field-by-field comparison would have to walk two sets, a design and twenty
  /// fields to save a repaint that almost never turns out to be redundant, so
  /// identity is the honest test — not a claim that the snapshot is cached.
  @override
  bool shouldRepaint(CraftEditorPainter old) => !identical(old.data, data);
}

/// One attach-node marker resolved to screen space for this frame.
class _ProjectedMarker {
  const _ProjectedMarker({
    required this.target,
    required this.screen,
    required this.depth,
    required this.normal,
    required this.radius,
    required this.away,
  });

  final AttachTarget target;
  final Offset screen;

  /// Planar view depth, metres — the sort key, because it is what the
  /// projection divides by and therefore what decides which marker is in front.
  final double depth;

  /// Unit outward normal in screen space, y down.
  final Offset normal;

  final double radius;

  /// The node faces away from the eye: it is on the far side of the hull.
  final bool away;
}
