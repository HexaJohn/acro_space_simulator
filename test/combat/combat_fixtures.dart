// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/objective.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:acro_space_simulator/domain/combat/resolver_tuning.dart';

/// A port-retaking operation built by hand: [troopers] in squads of 8 from
/// colony `src`, [holders] rebels on the port, and a militia pool.
Operation portOperation({
  int troopers = 16,
  int holders = 6,
  int armedMilitia = 0,
  int improvisedMilitia = 0,
  double kitDays = 3,
  double trooperMorale = 0.8,
  double holderMorale = 0.4,
  double holderQuality = 0.5,
  bool holderSquads = false,
  double portWidth = 24,
  int marchS = 300,
  int opId = 1,
  String target = 'colony-target',
  ResolverTuning tuning = const ResolverTuning(),
  bool sameBody = true,
}) {
  final formations = <Formation>[];
  var id = 0;
  var left = troopers;
  while (left > 0) {
    final n = left > 8 ? 8 : left;
    formations.add(Formation(
      id: id++,
      side: CombatSide.attacker,
      faction: Factions.player,
      kind: FormationKind.infantry,
      count: n,
      quality: 1.0,
      morale: trooperMorale,
      kitDays: kitDays,
      at: FormationAt.transit,
      homeColonyId: 'colony-src',
      homeSiteId: 'barracks-1',
    ));
    left -= n;
  }
  var hold = holders;
  while (hold > 0) {
    final n = holderSquads && hold > 8 ? 8 : hold;
    formations.add(Formation(
      id: id++,
      side: CombatSide.defender,
      faction: Factions.colony(target),
      kind: FormationKind.militia,
      count: n,
      quality: holderQuality,
      morale: holderMorale,
      at: 'port',
    ));
    hold -= n;
  }
  return Operation(
    id: opId,
    targetColonyId: target,
    goalId: 'port',
    lzId: 'lz',
    graph: ObjectiveGraph([
      Objective(
          id: 'port', kind: ObjectiveKind.port, value: 10, width: portWidth, control: -1),
      Objective(id: 'lz', kind: ObjectiveKind.lz, value: 2, width: 24, control: 1),
    ], [
      ObjectiveLink('lz', 'port', marchS),
    ]),
    formations: formations,
    militia: MilitiaPool(armed: armedMilitia, improvised: improvisedMilitia, morale: 0.6),
    defenderFaction: Factions.colony(target),
    sameBody: sameBody,
    tuning: tuning,
  );
}

/// Runs [op] until it resolves or [maxS] seconds pass, in [dt] ticks.
void runOp(Operation op, {double dt = 0.5, double maxS = 3000}) {
  var t = 0.0;
  while (!op.resolved && t < maxS) {
    op.advance(dt);
    t += dt;
  }
}
