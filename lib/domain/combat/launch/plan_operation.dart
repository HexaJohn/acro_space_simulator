// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Building a port-retaking operation from launch snapshots
/// (docs/plans/combat.md §7.1, §7.3).
///
/// Pure: snapshots and the player's choices in, an [Operation] and what each
/// source must hand over out. The caller debits the sources and launches.
library;

import '../defender_sizing.dart';
import '../formation.dart';
import '../objective.dart';
import '../operation.dart';
import '../resolver_tuning.dart';
import 'snapshots.dart';

/// How many troopers to take from one building.
class TrooperDraw {
  const TrooperDraw(this.colonyId, this.siteId, this.count);
  final String colonyId;
  final String siteId;
  final int count;
}

/// What one building hands over at launch: its troopers and their kit.
class SourceDebit {
  const SourceDebit(this.colonyId, this.siteId, this.troopers, this.jobs, this.kit);
  final String colonyId;
  final String siteId;
  final int troopers;

  /// The building's jobs, so the colony can measure the deployed share.
  final int jobs;

  /// Commodity → amount taken from the colony's stock.
  final Map<String, double> kit;
}

/// A planned operation, or why it cannot launch.
class PlannedOperation {
  const PlannedOperation(this.operation, this.debits, this.refusal);
  final Operation? operation;
  final List<SourceDebit> debits;
  final String? refusal;
}

/// The LZ sits this far from the closed pads: past the 60 m impound radius,
/// with margin (reference §9.3).
const double kLzDistanceM = 450;

/// Infantry on the march, m/s.
const double kInfantryMarchMps = 1.4;

/// The commodities kit is made of, in a fixed order.
const List<String> kKitCommodities = ['ammo', 'fuel', 'guns', 'rations'];

/// Plans retaking [target]'s seized port with [draws] from [sources].
PlannedOperation planPortRetake({
  required int operationId,
  required LaunchSnapshot target,
  required List<SourceSnapshot> sources,
  required List<TrooperDraw> draws,
  double kitDays = 3,
  int garrison = 0,
  ResolverTuning tuning = const ResolverTuning(),
}) {
  if (!target.portSeized) {
    return const PlannedOperation(null, [], 'The spaceport is not held by rebels.');
  }
  final formations = <Formation>[];
  final debits = <SourceDebit>[];
  var nextId = 0;
  var total = 0;
  Map<String, double>? garrisonKit;
  var sameBody = true;
  for (final d in draws) {
    if (d.count <= 0) continue;
    SourceSnapshot? src;
    for (final s in sources) {
      if (s.colonyId == d.colonyId) src = s;
    }
    if (src == null) {
      return PlannedOperation(null, const [], 'Unknown colony ${d.colonyId}.');
    }
    TrooperSource? site;
    for (final s in src.sources) {
      if (s.siteId == d.siteId) site = s;
    }
    if (site == null || !site.ready) {
      return PlannedOperation(null, const [],
          site?.notReadyWhy ?? 'That building cannot field troopers.');
    }
    if (d.count > site.available) {
      return PlannedOperation(null, const [],
          '${src.name} can field only ${site.available} from that building.');
    }
    // One gun each, no gun no trooper; then the days of kit.
    final kit = <String, double>{};
    for (final k in kKitCommodities) {
      final need = k == 'guns'
          ? d.count.toDouble()
          : (site.kitPerTrooperDay[k] ?? 0) * d.count * kitDays;
      if (need > 0) kit[k] = need;
    }
    for (final k in kKitCommodities) {
      final need = kit[k] ?? 0;
      if (need > 0 && (src.stock[k] ?? 0) + 1e-9 < need) {
        return PlannedOperation(null, const [],
            '${src.name} is short of $k for that many troopers.');
      }
    }
    if (src.bodyId != target.bodyId) sameBody = false;
    garrisonKit ??= site.kitPerTrooperDay;
    debits.add(SourceDebit(src.colonyId, site.siteId, d.count, site.jobs, kit));
    // Squads of at most 8, as even as they split: 9 is 5 and 4, not 8 and a
    // lone trooper who breaks the moment anyone shoots at him.
    final squads = (d.count + 7) ~/ 8;
    for (var i = 0; i < squads; i++) {
      final n = d.count ~/ squads + (i < d.count % squads ? 1 : 0);
      formations.add(Formation(
        id: nextId++,
        side: CombatSide.attacker,
        faction: Factions.player,
        kind: site.type == 'base' ? FormationKind.regular : FormationKind.infantry,
        count: n,
        quality: 1.0,
        morale: site.type == 'base' ? 0.7 : 0.8,
        kitDays: kitDays,
        at: FormationAt.transit,
        homeColonyId: src.colonyId,
        homeSiteId: site.siteId,
      ));
    }
    total += d.count;
  }
  if (total == 0) {
    return const PlannedOperation(null, [], 'Choose some troopers.');
  }
  if (garrison > total) {
    return const PlannedOperation(null, [], 'The garrison cannot outnumber the force.');
  }

  final r = colonyResolve(
      severity: target.severity, mood: target.mood, wish: target.wish, hunger: target.hunger);
  final holders = portHolders(
      spaceportJobs: target.spaceportJobs, population: target.population, resolve: r);
  final militia = militiaRaised(population: target.population, resolve: r);
  final armed = militiaArmed(militia: militia, gunsInStock: target.gunsInStock);
  final defender = Factions.colony(target.colonyId);
  formations.add(Formation(
    id: nextId++,
    side: CombatSide.defender,
    faction: defender,
    kind: FormationKind.militia,
    count: holders,
    quality: 0.5,
    morale: 0.4,
    at: 'port',
  ));
  final marchS = (kLzDistanceM / kInfantryMarchMps).round();
  final op = Operation(
    id: operationId,
    targetColonyId: target.colonyId,
    goalId: 'port',
    lzId: 'lz',
    graph: ObjectiveGraph([
      Objective(
          id: 'port',
          kind: ObjectiveKind.port,
          value: 10,
          width: target.portWidth,
          fDef: target.portFortification,
          control: -1),
      Objective(id: 'lz', kind: ObjectiveKind.lz, value: 2, width: 24, control: 1),
    ], [
      ObjectiveLink('lz', 'port', marchS),
    ]),
    formations: formations,
    // The holders are the port's own staff and its first sympathisers; the
    // town's militia comes in waves behind them. Separate counts: a small
    // town with a big spaceport has more holders than militia, and reading
    // the waves as "militia less holders" would send none at all.
    militia: MilitiaPool(
      armed: armed,
      improvised: militia - armed,
      morale: militiaMorale(r),
    ),
    defenderFaction: defender,
    sameBody: sameBody,
    garrison: garrison,
    garrisonKit: garrisonKit,
    tuning: tuning,
  );
  return PlannedOperation(op, debits, null);
}
