// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The battle drawn over the colony (docs/plans/combat.md §7B): a command
/// overlay, projected from the battle's colony-local metres onto the screen.
///
/// Objective rings coloured by who holds them, a flag on the one the
/// operation is for; squads as pips sized by their count, hollow when broken;
/// an arrow ahead of every march; flashes where the two sides meet, as many
/// as the fight is hot; landers as chevrons until they are down. Not
/// depth-tested — it is the commander's map laid over the ground, not part of
/// the scene — and it reads only a [CombatFrame], so it draws exactly what the
/// operation holds.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../domain/combat/base/base_modules.dart';
import '../../../../domain/combat/combat_frame.dart';
import '../../../../domain/combat/formation.dart';
import '../../../../domain/combat/lander.dart';
import '../../../../domain/combat/objective.dart';
import '../app_theme.dart';

/// Projects a colony-local point to the screen, or null off it.
typedef ColonyProject = Offset? Function(double e, double n);

/// Pixels per metre on the ground at a colony-local point.
typedef ColonyScale = double Function(double e, double n);

const Color kAttackerColour = AppTheme.accent2;
const Color kDefenderColour = AppTheme.danger;

/// −1 red … 0 amber … +1 the attacker's.
Color controlColour(double c) => c < 0
    ? Color.lerp(AppTheme.warn, kDefenderColour, (-c).clamp(0.0, 1.0))!
    : Color.lerp(AppTheme.warn, kAttackerColour, c.clamp(0.0, 1.0))!;

String objectiveLabel(ObjectiveKind k) => switch (k) {
      ObjectiveKind.lz => 'LZ',
      ObjectiveKind.port => 'Port',
      ObjectiveKind.seat => 'Seat',
      ObjectiveKind.lifeSupport => 'Life support',
      ObjectiveKind.power => 'Power',
      ObjectiveKind.depot => 'Depot',
      ObjectiveKind.airfield => 'Airfield',
    };

class BattleOverlayPainter extends CustomPainter {
  BattleOverlayPainter({
    required this.frame,
    required this.project,
    required this.scale,
    required this.timeS,
    this.selected = const [],
    this.marquee,
  });

  /// Squads selected in the command view (§7J), and the box being dragged.
  final List<int> selected;
  final Rect? marquee;

  final CombatFrame frame;
  final ColonyProject project;
  final ColonyScale scale;

  /// Wall time, s: what the flashes twinkle on.
  final double timeS;

  /// Objective ring radius on the ground, m.
  static const double ringM = 34;

  @override
  void paint(Canvas canvas, Size size) {
    for (final o in frame.objectives) {
      _objective(canvas, o);
    }
    for (final s in frame.squads) {
      if (s.marching) _arrow(canvas, s);
    }
    for (final s in frame.squads) {
      _squad(canvas, s);
    }
    for (final o in frame.objectives) {
      if (o.contested) _flashes(canvas, o);
    }
    for (final l in frame.landers) {
      _lander(canvas, l);
    }
    for (final m in frame.base) {
      _module(canvas, m);
    }
    for (final s in frame.strikes) {
      _strike(canvas, s);
    }
    for (final s in frame.squads) {
      if (!selected.contains(s.id)) continue;
      final at = project(s.e, s.n);
      if (at == null) continue;
      canvas.drawCircle(
          at,
          9 + 1.6 * math.sqrt(s.count.toDouble()),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white);
    }
    final m = marquee;
    if (m != null) {
      canvas.drawRect(m, Paint()..color = Colors.white.withValues(alpha: 0.08));
      canvas.drawRect(
          m,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.white70);
    }
  }

  /// A round coming in (a bright streak dropping onto its aim), the blast
  /// when it lands, and the scorch it leaves (§7E).
  void _strike(Canvas canvas, StrikeMark s) {
    final at = project(s.e, s.n);
    if (at == null) return;
    final perM = scale(s.e, s.n);
    final r = math.max(3.0, perM * s.diameterM / 2);
    if (s.incoming) {
      final k = 1 - s.inS! / CombatFrame.incomingS;
      final top = at.translate(0, -(1 - k) * 260 - 12);
      canvas.drawLine(
          top,
          at.translate(0, -(1 - k) * 260 * 0.4),
          Paint()
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..shader = ui.Gradient.linear(top, at, [
              Colors.white.withValues(alpha: 0),
              const Color(0xFFFFF2C0),
            ]));
      canvas.drawCircle(
          at,
          r * (0.6 + 0.4 * k),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = AppTheme.warn.withValues(alpha: 0.5 + 0.5 * k));
      return;
    }
    canvas.drawCircle(at, r, Paint()..color = const Color(0xFF15110E).withValues(alpha: 0.7));
    if (s.ageS < 4) {
      final k = s.ageS / 4;
      canvas.drawCircle(
          at,
          r + perM * 40 * k,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4 * (1 - k) + 1
            ..color = const Color(0xFFFFB347).withValues(alpha: 1 - k));
      canvas.drawCircle(at, r * (1.4 - 0.4 * k),
          Paint()..color = const Color(0xFFFFF2C0).withValues(alpha: (1 - k) * 0.9));
    }
  }

  void _module(Canvas canvas, BaseMark m) {
    final at = project(m.e, m.n);
    if (at == null) return;
    final c = kAttackerColour.withValues(alpha: m.building ? 0.35 : 0.9);
    final side = m.kind == null ? 14.0 : (m.kind == ModuleKind.turret ? 8.0 : 10.0);
    final rect = Rect.fromCenter(center: at, width: side, height: side);
    if (m.kind == ModuleKind.turret) {
      final p = Path()
        ..moveTo(at.dx, at.dy - side / 2)
        ..lineTo(at.dx + side / 2, at.dy + side / 2)
        ..lineTo(at.dx - side / 2, at.dy + side / 2)
        ..close();
      canvas.drawPath(p, Paint()..color = c);
    } else {
      canvas.drawRect(rect, Paint()..color = m.building ? c : c.withValues(alpha: 0.75));
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = m.kind == null ? 2 : 1
            ..color = Colors.black54);
    }
    if (m.kind == null) {
      final tp = TextPainter(
        text: TextSpan(
          text: m.outpost ? 'Outpost' : 'Base',
          style: AppTheme.mono.copyWith(
              fontSize: 10, color: Colors.white, shadows: const [Shadow(blurRadius: 3)]),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at + Offset(-tp.width / 2, side / 2 + 2));
    }
  }

  double _px(double e, double n, double metres, {double min = 4, double max = 120}) =>
      (scale(e, n) * metres).clamp(min, max);

  void _objective(Canvas canvas, ObjectiveMark o) {
    final at = project(o.e, o.n);
    if (at == null) return;
    final r = _px(o.e, o.n, ringM, min: 9, max: 90);
    final c = o.kind == ObjectiveKind.lz ? kAttackerColour : controlColour(o.control);
    canvas.drawCircle(at, r, Paint()..color = c.withValues(alpha: 0.16));
    canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = o.isGoal ? 3 : 2
          ..color = c.withValues(alpha: 0.9));
    if (o.kind != ObjectiveKind.lz) {
      // Control as an arc: how much of the ring is the attacker's.
      final share = ((o.control + 1) / 2).clamp(0.0, 1.0);
      canvas.drawArc(
          Rect.fromCircle(center: at, radius: r + 4),
          -math.pi / 2,
          2 * math.pi * share,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = kAttackerColour.withValues(alpha: 0.85));
    }
    if (o.contested) {
      final pulse = 0.5 + 0.5 * math.sin(timeS * 6);
      canvas.drawCircle(
          at,
          r + 8 + 4 * pulse,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = AppTheme.warn.withValues(alpha: 0.35 + 0.4 * pulse));
    }
    final label = '${o.isGoal ? '⚑ ' : ''}${objectiveLabel(o.kind)}';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: AppTheme.mono.copyWith(
            fontSize: 11, color: Colors.white, shadows: const [Shadow(blurRadius: 3)]),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at + Offset(-tp.width / 2, -r - tp.height - 6));
  }

  void _arrow(Canvas canvas, SquadMark s) {
    final a = project(s.e, s.n), b = project(s.toE!, s.toN!);
    if (a == null || b == null) return;
    final d = b - a;
    final len = d.distance;
    if (len < 6) return;
    final c = (s.side == CombatSide.attacker ? kAttackerColour : kDefenderColour)
        .withValues(alpha: 0.75);
    final p = Paint()
      ..color = c
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    // Dashed: a march, not a road.
    const dash = 7.0, gap = 5.0;
    final u = d / len;
    for (var x = 0.0; x < len - 8; x += dash + gap) {
      canvas.drawLine(a + u * x, a + u * math.min(x + dash, len - 8), p);
    }
    final n = Offset(-u.dy, u.dx);
    final head = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo((b - u * 10 + n * 5).dx, (b - u * 10 + n * 5).dy)
      ..lineTo((b - u * 10 - n * 5).dx, (b - u * 10 - n * 5).dy)
      ..close();
    canvas.drawPath(head, Paint()..color = c);
  }

  void _squad(Canvas canvas, SquadMark s) {
    final at = project(s.e, s.n);
    if (at == null) return;
    final c = s.side == CombatSide.attacker ? kAttackerColour : kDefenderColour;
    final r = 3.0 + 1.6 * math.sqrt(s.count.toDouble());
    if (s.kind == FormationKind.emplacement) {
      final rect = Rect.fromCenter(center: at, width: r * 2, height: r * 2);
      canvas.drawRect(rect, Paint()..color = c.withValues(alpha: s.broken ? 0.3 : 0.9));
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.black54);
      return;
    }
    if (s.broken) {
      canvas.drawCircle(
          at,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = c.withValues(alpha: 0.7));
      return;
    }
    canvas.drawCircle(at, r, Paint()..color = c.withValues(alpha: 0.35 + 0.6 * s.morale));
    canvas.drawCircle(
        at,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black54);
  }

  /// Muzzle flashes and blasts round a fought-over objective: as many as the
  /// fight is hot, each a few frames long, placed by a hash of the objective
  /// and the time so they twinkle rather than crawl.
  void _flashes(Canvas canvas, ObjectiveMark o) {
    final n = 3 + (o.heat * 9).round();
    final frameT = (timeS * 9).floor();
    for (var i = 0; i < n; i++) {
      final h = _hash(o.id.hashCode ^ (frameT * 7919 + i * 104729));
      if (h % 3 == 0) continue; // dark this frame
      final a = (h & 0xffff) / 0xffff * 2 * math.pi;
      final d = ((h >> 16) & 0xff) / 0xff * ringM * 1.1;
      final e = o.e + d * math.cos(a), nn = o.n + d * math.sin(a);
      final at = project(e, nn);
      if (at == null) continue;
      final big = h % 11 == 0; // now and then a blast, not a shot
      final r = big ? 7.0 : 2.5;
      canvas.drawCircle(
          at,
          r * 2.2,
          Paint()
            ..color = (big ? Colors.orange : Colors.yellow).withValues(alpha: 0.25)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(at, r, Paint()..color = Colors.white.withValues(alpha: 0.9));
    }
  }

  static int _hash(int x) {
    var h = x & 0x7fffffff;
    h = ((h >> 16) ^ h) * 0x45d9f3b & 0x7fffffff;
    h = ((h >> 16) ^ h) * 0x45d9f3b & 0x7fffffff;
    return (h >> 16) ^ h;
  }

  void _lander(Canvas canvas, LanderMark l) {
    final at = project(l.e, l.n);
    if (at == null) return;
    final c = kAttackerColour;
    switch (l.state) {
      case LanderState.pending:
      case LanderState.descending:
        // A chevron pointing down, bobbing: coming in.
        final y = at.dy - 18 - 4 * math.sin(timeS * 4);
        final p = Path()
          ..moveTo(at.dx - 7, y - 6)
          ..lineTo(at.dx, y)
          ..lineTo(at.dx + 7, y - 6);
        canvas.drawPath(
            p,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..color = c);
        canvas.drawCircle(
            at,
            5,
            Paint()
              ..style = PaintingStyle.stroke
              ..color = c.withValues(alpha: 0.6));
      case LanderState.landed:
        canvas.drawRect(Rect.fromCenter(center: at, width: 8, height: 8),
            Paint()..color = c.withValues(alpha: 0.8));
      case LanderState.lost:
        final p = Paint()
          ..strokeWidth = 2
          ..color = kDefenderColour;
        canvas.drawLine(at + const Offset(-5, -5), at + const Offset(5, 5), p);
        canvas.drawLine(at + const Offset(-5, 5), at + const Offset(5, -5), p);
      case LanderState.departed:
        break;
    }
  }

  @override
  bool shouldRepaint(BattleOverlayPainter old) => true;
}
