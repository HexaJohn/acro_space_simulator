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

import '../base/base_modules.dart';
import '../base/forward_base.dart';
import '../defender_sizing.dart';
import 'base_layout.dart';
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
    String targetBodyId, double kitDays,
    {int firstId = 0}) {
  final out = _Draws()..nextId = firstId;
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

/// Reinforcements for the running [op] (docs/plans/combat.md §7B): [draws]
/// from [sources] as fresh squads that land at its LZ a mustering and a
/// crossing from now, and what each source hands over; or why not.
({List<Formation> formations, List<SourceDebit> debits, String? refusal}) planReinforcements({
  required Operation op,
  required String targetBodyId,
  required List<SourceSnapshot> sources,
  required List<TrooperDraw> draws,
  double kitDays = 3,
}) {
  if (op.resolved) {
    return (formations: const [], debits: const [], refusal: 'That operation is over.');
  }
  final drawn = _drawAttackers(draws, sources, targetBodyId, kitDays, firstId: op.nextFormationId);
  if (drawn.refusal case final why?) {
    return (formations: const [], debits: const [], refusal: why);
  }
  final lands = op.clock.steps + op.reinforcementDelaySteps;
  for (final f in drawn.formations) {
    f.arriveStep = lands;
  }
  return (formations: drawn.formations, debits: drawn.debits, refusal: null);
}

/// What an operation ships to build a forward base (§7C).
class BaseManifest {
  const BaseManifest({
    this.materiel = 300,
    this.support = 10,
    this.fuel = 24,
    this.medicine = 10,
    this.steel = 0,
    this.electronics = 0,
    this.spareCore = false,
    this.doctrine = Doctrine.balanced,
  });

  /// Ore, whole units.
  final int materiel;

  /// Support staff.
  final int support;

  /// Shipped as far as the lead source has them (§7D).
  final int fuel, medicine, steel, electronics;

  /// A spare core aboard (100 Materiel more).
  final bool spareCore;
  final Doctrine doctrine;
}

/// Days of kit the support staff carry.
const double kSupportKitDays = 3;

/// Ammo the landing turret carries in, beyond the support staff's kit.
const int kLandingTurretAmmo = 60;

/// The forward base for [manifest], debited from the lead source — the one
/// most troopers come from (ties by id) — or why it cannot go.
({ForwardBase? base, SourceDebit? debit, String? refusal}) _planBase(
    BaseManifest manifest, List<SourceDebit> debits, List<SourceSnapshot> sources) {
  final ids = <String>[];
  final count = <int>[];
  for (final d in debits) {
    final i = ids.indexOf(d.colonyId);
    if (i < 0) {
      ids.add(d.colonyId);
      count.add(d.troopers);
    } else {
      count[i] += d.troopers;
    }
  }
  if (ids.isEmpty) return (base: null, debit: null, refusal: 'Choose some troopers.');
  var lead = 0;
  for (var i = 1; i < ids.length; i++) {
    if (count[i] > count[lead] || (count[i] == count[lead] && ids[i].compareTo(ids[lead]) < 0)) {
      lead = i;
    }
  }
  SourceSnapshot? src;
  for (final s in sources) {
    if (s.colonyId == ids[lead]) src = s;
  }
  if (src == null) return (base: null, debit: null, refusal: 'Unknown colony ${ids[lead]}.');
  final ore = src.stock['ore'] ?? 0;
  final materielAll = manifest.materiel + (manifest.spareCore ? kSpareCoreMateriel : 0);
  if (ore + 1e-9 < materielAll) {
    return (
      base: null,
      debit: null,
      refusal: '${src.name} has only ${ore.floor()} ore for the base.'
    );
  }
  if (manifest.support > src.supportAvailable) {
    return (
      base: null,
      debit: null,
      refusal: '${src.name} can spare only ${src.supportAvailable} support staff.'
    );
  }
  final rations = kRationsPerDay * manifest.support * kSupportKitDays;
  final ammo = kAmmoPerDay * manifest.support * kSupportKitDays + kLandingTurretAmmo;
  final guns = manifest.support.toDouble();
  // The rest goes as far as the source has it: none of it gates the launch.
  double upTo(String k, int want) => math.min(want.toDouble(), math.max(0.0, src!.stock[k] ?? 0));
  final fuel = upTo('fuel', manifest.fuel);
  final medicine = upTo('medicine', manifest.medicine);
  final steel = upTo('steel', manifest.steel);
  final electronics = upTo('electronics', manifest.electronics);
  // What this source already gives its troopers, plus the base's share.
  double already(String k) {
    var v = 0.0;
    for (final d in debits) {
      if (d.colonyId == src!.colonyId) v += d.kit[k] ?? 0;
    }
    return v;
  }

  for (final (k, need) in [('rations', rations), ('ammo', ammo), ('guns', guns)]) {
    if ((src.stock[k] ?? 0) + 1e-9 < already(k) + need) {
      return (base: null, debit: null, refusal: '${src.name} is short of $k for the base.');
    }
  }
  final gates = <String>[];
  for (final id in ids) {
    for (final s in sources) {
      if (s.colonyId != id) continue;
      for (final b in s.buildings) {
        if (!gates.contains(b)) gates.add(b);
      }
    }
  }
  gates.sort();
  final total = manifest.materiel * 100;
  final unpacked = total ~/ 4; // a quarter lands ready to build with
  return (
    base: ForwardBase(
      homeColonyId: src.colonyId,
      materielC: unpacked,
      palletsC: total - unpacked,
      support: manifest.support,
      stockC: [
        for (final k in kBaseStock)
          (switch (k) {
                    'ammo' => ammo,
                    'guns' => guns,
                    'rations' => rations,
                    'fuel' => fuel,
                    'medicine' => medicine,
                    'steel' => steel,
                    'electronics' => electronics,
                    _ => 0.0,
                  } *
                  100)
              .round(),
      ],
      gates: gates,
      spareCore: manifest.spareCore,
      doctrine: manifest.doctrine,
    ),
    debit: SourceDebit(src.colonyId, 'support', manifest.support, 0, {
      'ore': materielAll.toDouble(),
      'rations': rations,
      'ammo': ammo,
      'guns': guns,
      if (fuel > 0) 'fuel': fuel,
      if (medicine > 0) 'medicine': medicine,
      if (steel > 0) 'steel': steel,
      if (electronics > 0) 'electronics': electronics,
    }),
    refusal: null,
  );
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
  BaseManifest? base,
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
  final planned = base == null ? null : _planBase(base, drawn.debits, sources);
  if (planned?.refusal case final why?) return PlannedOperation(null, const [], why);

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
  final layout = layoutBase(
      anchorE: target.portE,
      anchorN: target.portN,
      distanceM: kLzDistanceM,
      obstacles: target.obstacles,
      pads: target.pads);
  final lz = (layout.e, layout.n);
  planned?.base
    ?..layoutBlockedModules = layout.blockedModules
    ..layoutBlockedTurrets = layout.blockedTurrets;
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
          control: -1,
          e: target.portE,
          n: target.portN),
      Objective(
          id: 'lz', kind: ObjectiveKind.lz, value: 2, width: 24, control: 1, e: lz.$1, n: lz.$2),
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
    base: planned?.base,
    tuning: tuning,
  );
  return PlannedOperation(op, [...drawn.debits, ?planned?.debit], null);
}

/// The LZ for an anchor at ([e], [n]): [kLzDistanceM] out from it, away from
/// the colony centre (east, for an anchor on the centre itself).
(double, double) lzFrom(double e, double n) {
  var de = e, dn = n;
  var len = math.sqrt(de * de + dn * dn);
  if (len < 1) {
    de = 1;
    dn = 0;
    len = 1;
  }
  return (e + de / len * kLzDistanceM, n + dn / len * kLzDistanceM);
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
  BaseManifest? base,
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
  final planned = base == null ? null : _planBase(base, drawn.debits, sources);
  if (planned?.refusal case final why?) return PlannedOperation(null, const [], why);

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
      e: o.e,
      n: o.n,
    ));
  }
  // The LZ: out from the port (else the seat), away from the colony centre,
  // past the impound radius of its pads.
  final anchor = at['port'] ?? at['seat']!;
  final layout = layoutBase(
      anchorE: anchor.$1,
      anchorN: anchor.$2,
      distanceM: kLzDistanceM,
      obstacles: target.obstacles,
      pads: target.pads);
  at['lz'] = (layout.e, layout.n);
  planned?.base
    ?..layoutBlockedModules = layout.blockedModules
    ..layoutBlockedTurrets = layout.blockedTurrets;
  ids.add('lz');
  nodes.add(Objective(
      id: 'lz',
      kind: ObjectiveKind.lz,
      value: 2,
      width: 24,
      control: 1,
      e: at['lz']!.$1,
      n: at['lz']!.$2));
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
    airless: target.airless,
    counters: kCounters,
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
    base: planned?.base,
    tuning: tuning,
  );
  return PlannedOperation(op, [...drawn.debits, ?planned?.debit], null);
}
