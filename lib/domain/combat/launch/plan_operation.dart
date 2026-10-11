// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Building an operation from launch snapshots: retaking a seized port
/// (docs/plans/combat.md §7.1, §7.3) or taking an independent colony (§7A).
///
/// Pure: snapshots and the player's choices in, an [Operation] and what each
/// source must hand over out. The caller debits the sources and launches.
library;

import 'dart:math' as math;

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

/// The attacking squads a set of draws makes, what each source hands over,
/// and the garrison's kit; or why they cannot go.
class _Draws {
  final List<Formation> formations = [];
  final List<SourceDebit> debits = [];
  int total = 0;
  int nextId = 0;
  Map<String, double>? garrisonKit;
  bool sameBody = true;
  String? refusal;
}

_Draws _drawAttackers(List<TrooperDraw> draws, List<SourceSnapshot> sources,
    String targetBodyId, double kitDays) {
  final out = _Draws();
  for (final d in draws) {
    if (d.count <= 0) continue;
    SourceSnapshot? src;
    for (final s in sources) {
      if (s.colonyId == d.colonyId) src = s;
    }
    if (src == null) return out..refusal = 'Unknown colony ${d.colonyId}.';
    TrooperSource? site;
    for (final s in src.sources) {
      if (s.siteId == d.siteId) site = s;
    }
    if (site == null || !site.ready) {
      return out..refusal = site?.notReadyWhy ?? 'That building cannot field troopers.';
    }
    if (d.count > site.available) {
      return out
        ..refusal = '${src.name} can field only ${site.available} from that building.';
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
        return out..refusal = '${src.name} is short of $k for that many troopers.';
      }
    }
    if (src.bodyId != targetBodyId) out.sameBody = false;
    out.garrisonKit ??= site.kitPerTrooperDay;
    out.debits.add(SourceDebit(src.colonyId, site.siteId, d.count, site.jobs, kit));
    for (final n in evenSquads(d.count)) {
      out.formations.add(Formation(
        id: out.nextId++,
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
    out.total += d.count;
  }
  if (out.total == 0) out.refusal = 'Choose some troopers.';
  return out;
}

/// [n] people as squads of at most 8, as even as they split: 9 is 5 and 4,
/// not 8 and a lone trooper who breaks the moment anyone shoots at him.
List<int> evenSquads(int n) {
  if (n <= 0) return const [];
  final squads = (n + 7) ~/ 8;
  return [for (var i = 0; i < squads; i++) n ~/ squads + (i < n % squads ? 1 : 0)];
}

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
  final drawn = _drawAttackers(draws, sources, target.bodyId, kitDays);
  if (drawn.refusal case final why?) return PlannedOperation(null, const [], why);
  if (garrison > drawn.total) {
    return const PlannedOperation(null, [], 'The garrison cannot outnumber the force.');
  }
  final formations = drawn.formations;
  var nextId = drawn.nextId;

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
    sameBody: drawn.sameBody,
    garrison: garrison,
    garrisonKit: drawn.garrisonKit,
    tuning: tuning,
  );
  return PlannedOperation(op, drawn.debits, null);
}

/// How much the defender cares about each objective (§7A): the Seat most.
const Map<String, double> kObjectiveValue = {
  'seat': 12,
  'port': 10,
  'lifeSupport': 8,
  'power': 6,
  'lz': 2,
};

/// Fortification a defender fights behind where a building stands.
const double kBuildingFortification = 1.3;

/// The shortest march between two objectives, s.
const int kMinMarchS = 60;

/// Plans taking the independent colony [target] with [draws] from [sources]
/// (docs/plans/combat.md §7A): its objectives from its buildings, its
/// defenders from its barracks, gun emplacements, port and townsfolk. A win
/// occupies it, so a garrison of at least one is part of the plan.
PlannedOperation planColonyAssault({
  required int operationId,
  required LaunchSnapshot target,
  required List<SourceSnapshot> sources,
  required List<TrooperDraw> draws,
  double kitDays = 3,
  int garrison = 2,
  Roe roe = Roe.restrained,
  ResolverTuning tuning = const ResolverTuning(),
}) {
  if (!target.independent) {
    return const PlannedOperation(null, [], 'It is not independent: it takes your orders.');
  }
  ObjectiveSite? seat;
  for (final o in target.objectives) {
    if (o.kind == 'seat') seat = o;
  }
  if (seat == null) {
    return const PlannedOperation(null, [], 'It has no buildings to take.');
  }
  final drawn = _drawAttackers(draws, sources, target.bodyId, kitDays);
  if (drawn.refusal case final why?) return PlannedOperation(null, const [], why);
  if (garrison < 1) {
    return const PlannedOperation(
        null, [], 'Holding a colony takes a garrison: leave at least one trooper.');
  }
  if (garrison > drawn.total) {
    return const PlannedOperation(null, [], 'The garrison cannot outnumber the force.');
  }
  final formations = drawn.formations;
  var nextId = drawn.nextId;

  // ---- the ground --------------------------------------------------------
  final ids = <String>[];
  final at = <String, (double, double)>{};
  final nodes = <Objective>[];
  for (final o in target.objectives) {
    if (at.containsKey(o.kind)) continue;
    ids.add(o.kind);
    at[o.kind] = (o.e, o.n);
    nodes.add(Objective(
      id: o.kind,
      kind: ObjectiveKind.values.byName(o.kind),
      value: kObjectiveValue[o.kind] ?? 4,
      width: o.kind == 'port' ? target.portWidth : Objective.widthFor(o.areaM2),
      fDef: kBuildingFortification,
      control: -1,
    ));
  }
  // The LZ: out from the port (else the seat), away from the colony centre,
  // past the impound radius of its pads.
  final anchor = at['port'] ?? at['seat']!;
  var de = anchor.$1, dn = anchor.$2;
  var len = math.sqrt(de * de + dn * dn);
  if (len < 1) {
    de = 1;
    dn = 0;
    len = 1;
  }
  at['lz'] = (anchor.$1 + de / len * kLzDistanceM, anchor.$2 + dn / len * kLzDistanceM);
  ids.add('lz');
  nodes.add(Objective(id: 'lz', kind: ObjectiveKind.lz, value: 2, width: 24, control: 1));
  double dist(String a, String b) {
    final p = at[a]!, q = at[b]!;
    final x = p.$1 - q.$1, y = p.$2 - q.$2;
    return math.sqrt(x * x + y * y);
  }

  int march(String a, String b) =>
      math.max(kMinMarchS, (dist(a, b) / kInfantryMarchMps).round());
  // Each node to its two nearest, ties by id; one link per pair.
  final sorted = [...ids]..sort();
  final links = <ObjectiveLink>[];
  bool linked(String a, String b) =>
      links.any((l) => (l.a == a && l.b == b) || (l.a == b && l.b == a));
  for (final a in sorted) {
    final others = [
      for (final b in sorted)
        if (b != a) b
    ]..sort((x, y) {
        final c = dist(a, x).compareTo(dist(a, y));
        return c != 0 ? c : x.compareTo(y);
      });
    for (final b in others.take(2)) {
      if (!linked(a, b)) {
        final pair = [a, b]..sort();
        links.add(ObjectiveLink(pair[0], pair[1], march(pair[0], pair[1])));
      }
    }
  }

  // ---- who defends it ----------------------------------------------------
  final r = (colonyResolve(
              severity: target.severity,
              mood: target.mood,
              wish: target.wish,
              hunger: target.hunger) +
          target.resolveBoost)
      .clamp(0.05, 0.95);
  final defender = Factions.colony(target.colonyId);
  final holders = portHolders(
      spaceportJobs: target.spaceportJobs, population: target.population, resolve: r);
  formations.add(Formation(
    id: nextId++,
    side: CombatSide.defender,
    faction: defender,
    kind: FormationKind.militia,
    count: holders,
    quality: 0.5,
    morale: 0.4,
    at: at.containsKey('port') ? 'port' : 'seat',
  ));
  for (final n in evenSquads(target.regulars)) {
    formations.add(Formation(
      id: nextId++,
      side: CombatSide.defender,
      faction: defender,
      kind: FormationKind.regular,
      count: n,
      quality: 0.8,
      morale: 0.5 + 0.3 * r,
      at: 'seat',
    ));
  }
  for (final g in target.emplacements) {
    // At the objective it stands nearest: a gun covers what is around it.
    var best = 'seat';
    var bestD = double.infinity;
    for (final id in sorted) {
      if (id == 'lz') continue;
      final p = at[id]!;
      final x = p.$1 - g.e, y = p.$2 - g.n;
      final d = x * x + y * y;
      if (d < bestD) {
        bestD = d;
        best = id;
      }
    }
    formations.add(Formation(
      id: nextId++,
      side: CombatSide.defender,
      faction: defender,
      kind: FormationKind.emplacement,
      counterClass: CounterClass.empHmg,
      count: g.crew,
      quality: 0.8,
      morale: 0.6,
      at: best,
    ));
  }
  final militia = militiaRaised(population: target.population, resolve: r);
  final armed = militiaArmed(militia: militia, gunsInStock: target.gunsInStock);
  final op = Operation(
    id: operationId,
    targetColonyId: target.colonyId,
    goalId: 'seat',
    lzId: 'lz',
    kind: OperationKind.colonyAssault,
    roe: roe,
    shelterCover: target.shelterCover,
    graph: ObjectiveGraph(nodes, links),
    formations: formations,
    militia: MilitiaPool(
      armed: armed,
      improvised: militia - armed,
      morale: militiaMorale(r),
    ),
    defenderFaction: defender,
    sameBody: drawn.sameBody,
    garrison: garrison,
    garrisonKit: drawn.garrisonKit,
    tuning: tuning,
  );
  return PlannedOperation(op, drawn.debits, null);
}
