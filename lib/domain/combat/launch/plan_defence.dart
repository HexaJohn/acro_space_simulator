// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Fights the player defends (docs/plans/combat.md §7N): an occupied colony
/// rising against its garrison, and a rival raiding a colonial neighbour.
///
/// The same resolver with the sides' roles swapped: the rebels or raiders are
/// the attacker, gathering at the colony's edge and coming for its Seat; the
/// player's troopers, or the neighbour's own people, defend it. Abstract only:
/// no base, no landers, no live bubble. Pure, like `plan_operation.dart`.
library;

import 'dart:math' as math;

import '../defender_sizing.dart';
import '../formation.dart';
import '../objective.dart';
import '../operation.dart';
import '../resolver_tuning.dart';
import 'plan_operation.dart';
import 'snapshots.dart';

/// Days of kit a rising or a raid fights with: they are at home, or near it,
/// and never run out over a fight.
const double kDefenceKitDays = 99;

/// The fewest raiders worth sending, and the share of its militia a rival
/// sends (§7N).
const int kRaidMinParty = 4;
const double kRaidShare = 1 / 3;

/// The fewest who make a rising (§7N): under this many, the colony grumbles
/// and the garrison holds without a fight.
const int kRisingMinMilitia = 3;

/// Resolve a colony's people defend their homes from raiders with: whatever
/// they think of the player, the raiders are worse.
const double kHomeResolve = 0.5;

/// Where a rising gathers: in town, this far out from the Seat. Raiders come
/// from an LZ [kLzDistanceM] out, as the player's troopers would.
const double kRisingGatherM = 150;

/// A two-node ground for a defensive fight: the Seat, and the place [outM]
/// out from it, away from the colony centre, where the rebels or raiders
/// gather; null with no Seat.
ObjectiveGraph? _seatAndEdge(LaunchSnapshot target, {required double fDef, required double outM}) {
  ObjectiveSite? seat;
  for (final o in target.objectives) {
    if (o.kind == 'seat') seat = o;
  }
  if (seat == null) return null;
  final far = lzFrom(seat.e, seat.n);
  final k = outM / kLzDistanceM;
  final edge = (seat.e + (far.$1 - seat.e) * k, seat.n + (far.$2 - seat.n) * k);
  final dx = edge.$1 - seat.e, dy = edge.$2 - seat.n;
  final march = math.max(kMinMarchS, (math.sqrt(dx * dx + dy * dy) / kInfantryMarchMps).round());
  return ObjectiveGraph([
    Objective(
      id: 'seat',
      kind: ObjectiveKind.seat,
      value: kObjectiveValue['seat']!,
      width: Objective.widthFor(seat.areaM2),
      fDef: fDef,
      control: -1,
      e: seat.e,
      n: seat.n,
      siteId: seat.siteId,
    ),
    Objective(id: 'lz', kind: ObjectiveKind.lz, value: 2, width: 24, control: 1, e: edge.$1, n: edge.$2),
  ], [
    ObjectiveLink('lz', 'seat', march),
  ]);
}

/// [armed] and [improvised] fighters as attacking squads of [faction] from
/// [home], ids from [nextId].
List<Formation> _attackers(int armed, int improvised, String faction, String home, double morale,
    {required int nextId}) {
  final out = <Formation>[];
  for (final (n, q) in [for (final n in evenSquads(armed)) (n, 0.5), for (final n in evenSquads(improvised)) (n, 0.3)]) {
    out.add(Formation(
      id: nextId++,
      side: CombatSide.attacker,
      faction: faction,
      kind: FormationKind.militia,
      count: n,
      quality: q,
      morale: morale,
      kitDays: kDefenceKitDays,
      at: FormationAt.transit,
      homeColonyId: home,
    ));
  }
  return out;
}

/// Plans the rising of the occupied colony [target] against its garrison
/// (§7N): its militia against [troopers] of the player's from [garrisonHome]
/// at the Seat, [turrets] of them crewing the post's turrets.
PlannedOperation planUprising({
  required int operationId,
  required LaunchSnapshot target,
  required int garrisonOpId,
  required String garrisonHome,
  required int troopers,
  int turrets = 0,
  ResolverTuning tuning = const ResolverTuning(),
}) {
  if (troopers <= 0) return const PlannedOperation(null, [], 'There is no garrison to rise against.');
  final graph = _seatAndEdge(target, fDef: kBuildingFortification, outM: kRisingGatherM);
  if (graph == null) return const PlannedOperation(null, [], 'It has no Seat to fight over.');
  final r = colonyResolve(
      severity: target.severity, mood: target.mood, wish: target.wish, hunger: target.hunger);
  final militia = militiaRaised(population: target.population, resolve: r);
  if (militia < kRisingMinMilitia) return const PlannedOperation(null, [], 'Too few turned out to rise.');
  final armed = militiaArmed(militia: militia, gunsInStock: target.gunsInStock);
  final formations = _attackers(armed, militia - armed, Factions.colony(target.colonyId), target.colonyId,
      militiaMorale(r),
      nextId: 0);
  var nextId = formations.length;
  // The post's turrets, two of the garrison to each; the rest as squads.
  final crewed = math.min(turrets, troopers ~/ 2);
  for (var i = 0; i < crewed; i++) {
    formations.add(Formation(
      id: nextId++,
      side: CombatSide.defender,
      faction: Factions.player,
      kind: FormationKind.emplacement,
      counterClass: CounterClass.empHmg,
      count: 2,
      quality: 1.0,
      morale: 0.8,
      at: 'seat',
      homeColonyId: garrisonHome,
    ));
  }
  for (final n in evenSquads(troopers - 2 * crewed)) {
    formations.add(Formation(
      id: nextId++,
      side: CombatSide.defender,
      faction: Factions.player,
      kind: FormationKind.infantry,
      count: n,
      quality: 1.0,
      morale: 0.8,
      at: 'seat',
      homeColonyId: garrisonHome,
    ));
  }
  final op = Operation(
    id: operationId,
    targetColonyId: target.colonyId,
    goalId: 'seat',
    lzId: 'lz',
    kind: OperationKind.uprising,
    airless: target.airless,
    counters: kCounters,
    shelterCover: target.shelterCover,
    graph: graph,
    formations: formations,
    militia: MilitiaPool(),
    defenderFaction: Factions.player,
    // They are in town already: at the edge on the first step.
    phase: OperationPhase.transit,
    phaseEndsStep: 0,
    tuning: tuning,
  )..garrisonOpId = garrisonOpId;
  return PlannedOperation(op, const [], null);
}

/// The raiding party a rival of [population] sends (§7N): a third of its
/// militia, or none when that is under [kRaidMinParty].
int raidParty({required double population, required double resolve}) {
  final militia = militiaRaised(population: population, resolve: resolve);
  if (militia < kRaidMinParty) return 0;
  return math.max(kRaidMinParty, (militia * kRaidShare).floor());
}

/// Plans the rival [raider]'s raid on its colonial neighbour [target]
/// (§7N): a party of its militia against the target's barracks troopers,
/// gun emplacements and townsfolk.
PlannedOperation planRaid({
  required int operationId,
  required LaunchSnapshot target,
  required LaunchSnapshot raider,
  ResolverTuning tuning = const ResolverTuning(),
}) {
  final graph = _seatAndEdge(target, fDef: kBuildingFortification, outM: kLzDistanceM);
  if (graph == null) return const PlannedOperation(null, [], 'It has nothing to raid.');
  final rr = colonyResolve(
      severity: raider.severity, mood: raider.mood, wish: raider.wish, hunger: raider.hunger);
  final party = raidParty(population: raider.population, resolve: rr);
  if (party <= 0) return const PlannedOperation(null, [], 'Too few to raid.');
  final armed = math.min(party, militiaArmed(militia: party, gunsInStock: raider.gunsInStock));
  final formations = _attackers(armed, party - armed, Factions.rival(raider.colonyId), raider.colonyId,
      militiaMorale(rr),
      nextId: 0);
  var nextId = formations.length;
  final home = Factions.colony(target.colonyId);
  for (final n in evenSquads(target.regulars)) {
    formations.add(Formation(
      id: nextId++,
      side: CombatSide.defender,
      faction: home,
      kind: FormationKind.regular,
      count: n,
      quality: 0.8,
      morale: 0.5 + 0.3 * kHomeResolve,
      at: 'seat',
    ));
  }
  for (final g in target.emplacements) {
    formations.add(Formation(
      id: nextId++,
      side: CombatSide.defender,
      faction: home,
      kind: FormationKind.emplacement,
      counterClass: CounterClass.empHmg,
      count: g.crew,
      quality: 0.8,
      morale: 0.6,
      at: 'seat',
    ));
  }
  final militia = militiaRaised(population: target.population, resolve: kHomeResolve);
  final townArmed = militiaArmed(militia: militia, gunsInStock: target.gunsInStock);
  final op = Operation(
    id: operationId,
    targetColonyId: target.colonyId,
    goalId: 'seat',
    lzId: 'lz',
    kind: OperationKind.raid,
    airless: target.airless,
    counters: kCounters,
    shelterCover: target.shelterCover,
    graph: graph,
    formations: formations,
    militia: MilitiaPool(armed: townArmed, improvised: militia - townArmed, morale: militiaMorale(kHomeResolve)),
    defenderFaction: home,
    sameBody: true,
    // Across the plain in half a day, like any crossing on one body.
    phase: OperationPhase.transit,
    phaseEndsStep: (tuning.transitDaysSameBody * tuning.daySec).round(),
    tuning: tuning,
  );
  return PlannedOperation(op, const [], null);
}
