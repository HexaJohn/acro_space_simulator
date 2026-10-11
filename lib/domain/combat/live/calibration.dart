// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The calibration harness (docs/plans/combat.md §7I; ref §8.9): the same
/// battle fought twice — once by the resolver alone, once live, AI against AI,
/// with every attacking squad owned by a playerless bubble — over a set of
/// seeds, and the two compared on win rate and the attackers' loss share.
///
/// The anti-Total-War rule: leaving a fight to auto-resolve must not change
/// its expected outcome. Pure and headless, no player, no renderer.
library;

import 'dart:math' as math;

import '../formation.dart';
import '../objective.dart';
import '../operation.dart';
import 'battle_raster.dart';
import 'live_battle.dart';
import 'nav_grid.dart';

class CalibrationRow {
  CalibrationRow(this.name, this.seeds, this.absWin, this.liveWin, this.absLoss, this.liveLoss);
  final String name;
  final int seeds;

  /// Share of seeds won, and the attackers' mean loss share (members killed
  /// or wounded over those raised), abstract and live.
  final double absWin, liveWin, absLoss, liveLoss;

  double get winGap => (liveWin - absWin).abs();
  double get lossGap => (liveLoss - absLoss).abs();

  /// Within ±[band] on both (absolute shares).
  bool passes(double band) => winGap <= band && lossGap <= band;

  @override
  String toString() =>
      '$name ($seeds seeds): win ${_p(absWin)} abstract / ${_p(liveWin)} live; '
      'attacker losses ${_p(absLoss)} / ${_p(liveLoss)}';

  static String _p(double v) => '${(v * 100).round()}%';
}

double _lossShare(Operation op) {
  var removed = 0;
  for (final f in op.formations) {
    if (f.side == CombatSide.attacker) removed += f.removed;
  }
  return op.attackerRaised == 0 ? 0 : removed / op.attackerRaised;
}

/// One battle by the resolver alone.
({bool won, double loss}) runAbstract(Operation op, {int maxS = 20000}) {
  for (var i = 0; i < maxS && !op.resolved; i++) {
    op.advance(1);
  }
  return (won: op.outcome == OperationOutcome.won, loss: _lossShare(op));
}

/// One battle live: once engaged, every attacking infantry squad is the
/// bubble's, sent objective by objective along the operation's path as the
/// resolver's own AI would send them; the bubble steps at [dt] and the
/// operation each whole second.
({bool won, double loss}) runLive(Operation op, {int maxS = 20000, double dt = 0.1}) {
  for (var i = 0; i < maxS && op.phase != OperationPhase.engaged && !op.resolved; i++) {
    op.advance(1);
  }
  if (op.resolved) return (won: op.outcome == OperationOutcome.won, loss: _lossShare(op));
  final lz = op.graph.byId(op.lzId)!, goal = op.graph.byId(op.goalId)!;
  final (ce, cn) = BattleRaster.centreFor(lz.e, lz.n, goal.e, goal.n, sideM: 2400);
  final raster = BattleRaster(ce, cn, sideM: 2400, cellM: 16);
  for (var k = 0; k < raster.radii.length; k++) {
    raster.put(k, 1737000);
  }
  final squads = [
    for (final f in op.formations)
      if (f.side == CombatSide.attacker && f.kind != FormationKind.emplacement && f.alive) f.id
  ];
  for (final id in squads) {
    op.liveSquad(id, own: true);
  }
  final live = LiveBattle(opId: op.id, seed: op.seed, playerFormationId: -1, playerless: true, squads: squads)
    ..nav = NavGrid(raster, const []);
  Objective? target;
  for (var s = 0; s < maxS && !op.resolved; s++) {
    // The next objective on the path the attackers do not hold.
    final route = op.path;
    var k = 1;
    while (k < route.length - 1 && (op.graph.byId(route[k])?.control ?? 1) >= op.tuning.holdingControl) {
      k++;
    }
    final next = op.graph.byId(route[math.min(k, route.length - 1)]);
    if (next != null && next.id != target?.id) {
      target = next;
      live.command(SquadOrder.attack, objectiveId: next.id);
    }
    for (var i = 0; i < (1 / dt).round(); i++) {
      live.sync(op, raster, target?.e ?? ce, target?.n ?? cn);
      live.step(dt, eye: (ce, cn, 1.7), aim: (1, 0, 0), trigger: false, reload: false);
      for (final id in live.casualties) {
        op.liveCasualty(id);
      }
      live.casualties.clear();
      for (final (id, at) in live.arrivals) {
        op.liveSquad(id, own: true, at: at);
      }
      live.arrivals.clear();
    }
    op.advance(1);
  }
  return (won: op.outcome == OperationOutcome.won, loss: _lossShare(op));
}

/// [build] the same battle per seed, fight it both ways, and compare.
CalibrationRow calibrate(String name, Operation Function(int seed) build, {int seeds = 8}) {
  var aw = 0, lw = 0;
  var al = 0.0, ll = 0.0;
  for (var s = 0; s < seeds; s++) {
    final a = runAbstract(build(s));
    final l = runLive(build(s));
    if (a.won) aw++;
    if (l.won) lw++;
    al += a.loss;
    ll += l.loss;
  }
  return CalibrationRow(name, seeds, aw / seeds, lw / seeds, al / seeds, ll / seeds);
}
