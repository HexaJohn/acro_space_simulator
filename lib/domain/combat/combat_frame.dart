// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a battle looks like at one instant (docs/plans/combat.md §7B): a pure
/// read of an [Operation] for whatever draws it.
///
/// Everything is in the target colony's east/north metres. Objectives carry
/// who holds them and how hard they are fought over; squads are placed at
/// their objective, spread round it so they do not sit on each other, or part
/// way along a march by the fraction of it walked — read from the operation's
/// own clock, sub-step included, so a march glides instead of stepping once a
/// second. Nothing here is saved or fed back: the battle is the operation.
library;

import 'dart:math' as math;

import 'base/base_modules.dart';
import 'formation.dart';
import 'lander.dart';
import 'objective.dart';
import 'operation.dart';
import 'resolver.dart';

/// An objective as drawn.
class ObjectiveMark {
  const ObjectiveMark({
    required this.id,
    required this.kind,
    required this.e,
    required this.n,
    required this.control,
    required this.contested,
    required this.heat,
    required this.isGoal,
  });
  final String id;
  final ObjectiveKind kind;
  final double e, n;

  /// −1 the other side's … +1 the player's: the attacker's, or in a fight
  /// the player defends (§7N) the defender's.
  final double control;

  /// Both sides are there and fighting.
  final bool contested;

  /// 0..1: how much of its width is in the fight — what scales the flashes.
  final double heat;

  /// The objective the operation is for.
  final bool isGoal;
}

/// A squad as drawn.
class SquadMark {
  const SquadMark({
    required this.id,
    required this.side,
    required this.kind,
    required this.count,
    required this.morale,
    required this.broken,
    required this.e,
    required this.n,
    this.toE,
    this.toN,
  });
  final int id;

  /// [CombatSide.attacker] for the player's side, as drawn: in a fight the
  /// player defends (§7N) the sides are drawn the other way round.
  final CombatSide side;
  final FormationKind kind;
  final int count;
  final double morale;
  final bool broken;
  final double e, n;

  /// Where a marching squad is headed; null for one standing.
  final double? toE, toN;

  bool get marching => toE != null;
}

/// A base module as drawn: round the LZ, in its ring (1b-i has no layout, so
/// a socket's place is its index on the ring).
class BaseMark {
  const BaseMark(this.kind, this.e, this.n, {this.building = false, this.outpost = false});
  final ModuleKind? kind; // null: the core, or an outpost's marker
  final double e, n;

  /// An outpost's marker (with [kind] null).
  final bool outpost;

  /// Still on the line.
  final bool building;
}

/// A lander as drawn: where it is coming down, and whether it is down yet.
class LanderMark {
  const LanderMark(this.e, this.n, this.state);
  final double e, n;
  final LanderState state;
}

/// A strike as drawn (§7E): a round coming in, or where one came down.
class StrikeMark {
  const StrikeMark(this.e, this.n, this.diameterM, {this.ageS = 0, this.inS});
  final double e, n;
  final double diameterM;

  /// Seconds since it landed (0 for one still coming in).
  final double ageS;

  /// Seconds until it lands; null once it has.
  final double? inS;

  bool get incoming => inS != null;
}

class CombatFrame {
  const CombatFrame({
    required this.opId,
    required this.targetColonyId,
    required this.phase,
    required this.objectives,
    required this.squads,
    required this.landers,
    this.base = const [],
    this.strikes = const [],
  });

  final int opId;
  final String targetColonyId;
  final OperationPhase phase;
  final List<ObjectiveMark> objectives;
  final List<SquadMark> squads;
  final List<LanderMark> landers;

  /// The forward base, core first; empty with none standing.
  final List<BaseMark> base;

  /// Orbital strikes: rounds in their last seconds, and every crater.
  final List<StrikeMark> strikes;

  /// A round is drawn coming in for its last this-many seconds.
  static const double incomingS = 6;

  /// Squads stand this far round their objective, m.
  static const double ringM = 24;

  /// The battle's centre and half-extent, m: what a camera frames.
  ({double e, double n, double radius}) get bounds {
    if (objectives.isEmpty) return (e: 0, n: 0, radius: 300);
    var minE = double.infinity, minN = double.infinity;
    var maxE = -double.infinity, maxN = -double.infinity;
    for (final o in objectives) {
      minE = math.min(minE, o.e);
      maxE = math.max(maxE, o.e);
      minN = math.min(minN, o.n);
      maxN = math.max(maxN, o.n);
    }
    final r = math.max(150.0, 0.5 * math.max(maxE - minE, maxN - minN));
    return (e: (minE + maxE) / 2, n: (minN + maxN) / 2, radius: r);
  }

  factory CombatFrame.of(Operation op) {
    final t = op.clock.steps + op.clock.accumulatedUs / 1e6;
    final step = op.clock.steps;
    final nodes = <String, Objective>{
      for (final o in op.graph.objectives) o.id: o,
    };
    final marks = <ObjectiveMark>[];
    for (final o in op.graph.objectives) {
      var att = 0.0, def = 0.0;
      for (final f in op.formations) {
        if (!f.presentAt(o.id, step)) continue;
        final s = formationStrength(f, op.tuning, armed: true);
        if (f.side == CombatSide.attacker) {
          att += s;
        } else {
          def += s;
        }
      }
      final contested = att > 0 && def > 0;
      marks.add(ObjectiveMark(
        id: o.id,
        kind: o.kind,
        e: o.e,
        n: o.n,
        control: op.defensive ? -o.control : o.control,
        contested: contested,
        heat: contested ? (math.min(att, def) / math.max(1e-9, o.width)).clamp(0.0, 1.0) : 0,
        isGoal: o.id == op.goalId,
      ));
    }

    // Where each squad stands: its slot round the objective, attackers on
    // one side and defenders on the other, in id order so nothing jitters.
    final slot = <int, int>{};
    final perNode = <String, int>{};
    for (final f in op.formations) {
      if (!f.alive) continue;
      final key = '${f.side.name}@${f.at}';
      slot[f.id] = perNode[key] ?? 0;
      perNode[key] = (perNode[key] ?? 0) + 1;
    }
    (double, double) standAt(Objective o, Formation f) {
      final k = slot[f.id] ?? 0;
      final side = f.side == CombatSide.attacker ? 0.0 : math.pi;
      final a = side + 0.6 + k * 0.55;
      final r = ringM * (1 + 0.35 * (k ~/ 5));
      return (o.e + r * math.cos(a), o.n + r * math.sin(a));
    }

    final squads = <SquadMark>[];
    final lz = nodes[op.lzId];
    for (final f in op.formations) {
      if (!f.alive) continue;
      final to = nodes[f.at];
      if (to == null) {
        // In transit or broken: a broken attacker is drawn back at the LZ, a
        // broken defender has gone to ground in the town, and a squad still
        // in the air is its lander's.
        if (f.broken && f.side == CombatSide.attacker && lz != null) {
          final p = standAt(lz, f);
          squads.add(_mark(f, p.$1, p.$2, flip: op.defensive));
        }
        continue;
      }
      final from = f.fromAt == null ? null : nodes[f.fromAt!];
      if (from != null && t < f.arriveStep && f.arriveStep > f.departStep) {
        final p = ((t - f.departStep) / (f.arriveStep - f.departStep)).clamp(0.0, 1.0);
        final dest = standAt(to, f);
        final orig = (from.e, from.n);
        squads.add(_mark(f, orig.$1 + (dest.$1 - orig.$1) * p, orig.$2 + (dest.$2 - orig.$2) * p,
            toE: dest.$1, toN: dest.$2, flip: op.defensive));
        continue;
      }
      final p = standAt(to, f);
      squads.add(_mark(f, p.$1, p.$2, flip: op.defensive));
    }

    final base = <BaseMark>[];
    final b = op.base;
    if (b != null && b.standing) {
      for (final s in b.sites) {
        if (s.razed) continue;
        final o = nodes[s.objectiveId];
        if (o == null) continue;
        // An outpost stands beside its objective, the core on the LZ.
        final isCore = identical(s, b.core) && !s.outpost;
        final cx = isCore ? o.e : o.e + 55, cy = isCore ? o.n : o.n + 35;
        (double, double) ring(SocketKind k, int i) {
          final r = k == SocketKind.module ? (s.outpost ? 22.0 : 45.0) : (s.outpost ? 34.0 : 75.0);
          final n = s.socketsOf(k);
          final a = 2 * math.pi * i / (n == 0 ? 1 : n) + (k == SocketKind.module ? math.pi / 2 : 0);
          return (cx + r * math.cos(a), cy + r * math.sin(a));
        }

        base.add(BaseMark(null, cx, cy, outpost: !isCore));
        for (final m in s.modules) {
          final p = ring(m.spec.socket, m.socket);
          base.add(BaseMark(m.kind, p.$1, p.$2));
        }
        for (final j in s.lines) {
          if (j == null || j.kind == null) continue;
          final p = ring(moduleSpec(j.kind!).socket, j.socket);
          base.add(BaseMark(j.kind, p.$1, p.$2, building: true));
        }
      }
    }
    final strikes = <StrikeMark>[
      for (final c in op.orbital.craters) StrikeMark(c.e, c.n, c.diameterM, ageS: t - c.step),
      for (final s in op.orbital.inFlight)
        if (nodes[s.objectiveId] case final o? when s.impactStep - t <= incomingS)
          StrikeMark(o.e, o.n, op.orbital.craterM, inS: math.max(0.0, s.impactStep - t)),
    ];
    return CombatFrame(
      opId: op.id,
      targetColonyId: op.targetColonyId,
      phase: op.phase,
      objectives: marks,
      base: base,
      strikes: strikes,
      squads: squads,
      landers: [
        if (lz != null)
          for (final l in op.landers)
            if (l.state != LanderState.departed) LanderMark(lz.e + l.offE, lz.n + l.offN, l.state)
      ],
    );
  }

  static SquadMark _mark(Formation f, double e, double n,
          {double? toE, double? toN, bool flip = false}) =>
      SquadMark(
        id: f.id,
        side: !flip
            ? f.side
            : (f.side == CombatSide.attacker ? CombatSide.defender : CombatSide.attacker),
        kind: f.kind,
        count: f.count,
        morale: f.morale,
        broken: f.broken,
        e: e,
        n: n,
        toE: toE,
        toN: toN,
      );
}
