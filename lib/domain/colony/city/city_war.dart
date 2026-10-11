// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony at war: its side of an operation (docs/plans/combat.md §7).
///
/// The battle itself lives on the operation and never reads a colony after
/// launch. What a colony needs to know about the war is here: whose troopers
/// are away and from which building, who is wounded, who holds its retaken
/// port and what they eat. The operation writes into the colony through
/// [CityWarState.inbox] and hears back through [CityWarState.outbox]; both are
/// drained by the world tick, so a write lands in the colony's own tick order
/// even when the colony is frame-held.
library;

import 'dart:math' as math;

import '../../combat/launch/snapshots.dart';
import 'city_building_spec.dart';
import 'city_loyalty.dart';
import 'city_reclaim.dart';
import 'city_sim.dart';
import 'commodity.dart';
import 'independent_governor.dart';
import 'parcel.dart';
import 'site_access/site_envelope.dart';

/// Troopers away from one of this colony's buildings.
class DeployedTroopers {
  DeployedTroopers(this.opId, this.siteId, this.count, this.jobs);
  final int opId;
  final String siteId;
  int count;

  /// The building's jobs when they left: what the deployed share is of.
  final int jobs;

  Map<String, dynamic> toJson() =>
      {'op': opId, 'site': siteId, 'n': count, 'jobs': jobs};
  static DeployedTroopers? fromJson(Object? j) {
    if (j is! Map) return null;
    final op = j['op'], site = j['site'], n = j['n'], jobs = j['jobs'];
    if (op is! num || site is! String || n is! num || jobs is! num) return null;
    return DeployedTroopers(op.toInt(), site, n.toInt(), jobs.toInt());
  }
}

/// Wounded who cannot be sent again until [untilS] (colony time).
class WoundedTroopers {
  WoundedTroopers(this.count, this.untilS);
  final int count;
  final double untilS;
  Map<String, dynamic> toJson() => {'n': count, 'until': untilS};
}

/// The player's troopers holding this colony's retaken port. While they hold
/// it the rebels cannot seize it again; they eat from a stock they carried
/// in, refilled by supply runs, and go home a tenth a day when it runs out.
class PortGarrison {
  PortGarrison({
    required this.opId,
    required this.homeColonyId,
    required this.count,
    required this.perTrooperDay,
    required this.stock,
    this.unpaidS = 0,
    this.occupation = false,
    this.turrets = 0,
  });
  final int opId;
  final String homeColonyId;
  int count;

  /// What one trooper eats and fires per operation day.
  final Map<String, double> perTrooperDay;
  final Map<String, double> stock;

  /// Seconds the garrison has gone short.
  double unpaidS;

  /// It holds the whole colony (combat.md §7A), not just a retaken port.
  final bool occupation;

  /// A won assault's base turrets left standing as the garrison's post
  /// (§7D): each counts [kTurretTroopers] more toward suppression while two
  /// of the garrison still crew it.
  final int turrets;

  /// The troopers it sits on the colony with.
  int get suppressing => count + kTurretTroopers * math.min(turrets, count ~/ kTurretCrew);

  Map<String, dynamic> toJson() => {
        'op': opId,
        'home': homeColonyId,
        'n': count,
        'per': {for (final k in kWarCommodities) if (perTrooperDay[k] != null) k: perTrooperDay[k]},
        'stock': {for (final k in kWarCommodities) if (stock[k] != null) k: stock[k]},
        if (unpaidS != 0) 'unpaid': unpaidS,
        if (occupation) 'occ': true,
        if (turrets != 0) 'turrets': turrets,
      };

  static PortGarrison? fromJson(Object? j) {
    if (j is! Map) return null;
    Map<String, double> m(Object? v) => {
          if (v is Map)
            for (final k in kWarCommodities)
              if (v[k] is num) k: (v[k] as num).toDouble(),
        };
    final op = j['op'], home = j['home'], n = j['n'];
    if (op is! num || home is! String || n is! num) return null;
    return PortGarrison(
      opId: op.toInt(),
      homeColonyId: home,
      count: n.toInt(),
      perTrooperDay: m(j['per']),
      stock: m(j['stock']),
      unpaidS: (j['unpaid'] as num?)?.toDouble() ?? 0,
      occupation: j['occ'] == true,
      turrets: (j['turrets'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What a post's turret counts for, and the crew it needs.
const int kTurretTroopers = 2;
const int kTurretCrew = 2;

/// Resolve a beaten-off assault adds, and for how many loyalty days.
const double kResolveBoost = 0.2;
const double kResolveBoostDays = 10;

/// The deployed entry for a forward base's support staff: away from the
/// colony, but drawn from no building.
const String kSupportSite = 'support';

/// The share of its people a colony can spare as a base's support staff.
const double kSupportShare = 0.05;

/// The goods a base keeps, in its order (`kBaseStock`).
const List<String> kBaseGoods = [
  Commodity.ammo,
  Commodity.guns,
  Commodity.rations,
  Commodity.fuel,
  Commodity.medicine,
  Commodity.steel,
  Commodity.electronics,
];

/// What a war is fought with, in a fixed order.
const List<String> kWarCommodities = [
  Commodity.ammo,
  Commodity.fuel,
  Commodity.guns,
  Commodity.rations,
];

// ---- the inbox: what an operation does to a colony ---------------------------

/// A write from an operation into a colony, applied in the colony's own tick.
sealed class CombatWrite {
  const CombatWrite();
}

/// Troopers leave a building, taking their kit.
class DeployWrite extends CombatWrite {
  const DeployWrite(this.opId, this.siteId, this.troopers, this.jobs, this.kit);
  final int opId;
  final String siteId;
  final int troopers;
  final int jobs;
  final Map<String, double> kit;
}

/// Troopers come home: alive, wounded, and how many died.
class TroopersHomeWrite extends CombatWrite {
  const TroopersHomeWrite(this.opId, this.siteId,
      {required this.alive, required this.wounded, required this.dead});
  final int opId;
  final String? siteId;
  final int alive, wounded, dead;
}

/// The port was retaken; [garrison] (maybe none) now holds it.
class PortRetakenWrite extends CombatWrite {
  const PortRetakenWrite(this.garrison);
  final PortGarrison? garrison;
}

/// The attempt failed.
class PortRepulsedWrite extends CombatWrite {
  const PortRepulsedWrite();
}

/// The colony was taken: [garrison] holds it (combat.md §7A).
class OccupyWrite extends CombatWrite {
  const OccupyWrite(this.garrison);
  final PortGarrison garrison;
}

/// An independent colony beat an assault off: its resolve rises.
class AssaultRepulsedWrite extends CombatWrite {
  const AssaultRepulsedWrite();
}

/// The player restores an occupied colony's charter.
class RestoreCharterWrite extends CombatWrite {
  const RestoreCharterWrite();
}

/// Defenders and townsfolk killed in this colony.
class WarDeadWrite extends CombatWrite {
  const WarDeadWrite(this.dead);
  final int dead;
}

/// A supply run reached the garrison.
class GarrisonResupplyWrite extends CombatWrite {
  const GarrisonResupplyWrite(this.amounts);
  final Map<String, double> amounts;
}

/// The player brings the garrison home.
class GarrisonWithdrawWrite extends CombatWrite {
  const GarrisonWithdrawWrite();
}

/// Ship [amounts] to the garrison holding [targetColonyId]'s port: the
/// colony sends what it has and says what that was.
class GarrisonSupplyDebitWrite extends CombatWrite {
  const GarrisonSupplyDebitWrite(this.targetColonyId, this.amounts);
  final String targetColonyId;
  final Map<String, double> amounts;
}

/// A forward base's supply run (combat.md §7C): ship what you have of it.
class BaseRunDebitWrite extends CombatWrite {
  const BaseRunDebitWrite(this.opId, this.runId, this.materiel, this.stock);
  final int opId;
  final int runId;
  final double materiel;

  /// Ammo, guns, rations.
  final List<double> stock;
}

/// What a forward base had left, struck and shipped home — or, to a target,
/// what it captured.
class BaseGoodsWrite extends CombatWrite {
  const BaseGoodsWrite(this.materiel, this.stock);
  final double materiel;

  /// Ammo, guns, rations.
  final List<double> stock;
}

/// War weariness: the player's dead cost every colony's loyalty
/// (combat.md §7.6). Only a colony that takes the player's orders feels it.
class WarWearinessWrite extends CombatWrite {
  const WarWearinessWrite(this.loyaltyCost);
  final double loyaltyCost;
}

// ---- the outbox: what a colony tells the war ---------------------------------

sealed class CombatEvent {
  const CombatEvent();
}

/// Its allegiance or loyalty stage changed.
class StageChangedEvent extends CombatEvent {
  const StageChangedEvent(this.allegiance, this.stage);
  final Allegiance allegiance;
  final LoyaltyStage stage;
}

/// A base's supply run left: what the colony actually had to send.
class BaseRunShippedEvent extends CombatEvent {
  const BaseRunShippedEvent(this.opId, this.runId, this.materiel, this.stock);
  final int opId;
  final int runId;
  final double materiel;
  final List<double> stock;
}

/// A building troopers were drawn from is gone.
class SiteLostEvent extends CombatEvent {
  const SiteLostEvent(this.siteId);
  final String siteId;
}

/// A garrison supply run left: what the colony actually had to send.
class GarrisonSuppliedEvent extends CombatEvent {
  const GarrisonSuppliedEvent(this.targetColonyId, this.amounts);
  final String targetColonyId;
  final Map<String, double> amounts;
}

/// Garrison troopers went home (unpaid, or expelled), alive.
class GarrisonHomeEvent extends CombatEvent {
  const GarrisonHomeEvent(this.opId, this.homeColonyId, this.count, {this.expelled = false});
  final int opId;
  final String homeColonyId;
  final int count;
  final bool expelled;
}

/// A colony's war state.
class CityWarState {
  final List<DeployedTroopers> deployed = [];
  final List<WoundedTroopers> wounded = [];
  PortGarrison? garrison;

  /// [CitySim.colonyTimeS] until which a beaten-off assault hardens the
  /// colony's resolve (+[kResolveBoost]).
  double resolveBoostUntilS = 0;

  /// An occupation garrison is eating the colony's own stores this tick:
  /// what the mood pays for. Working state, not saved.
  bool requisitioning = false;

  /// Writes waiting for the colony's tick. Never saved: the world drains it
  /// before a save, and a save asserts it empty.
  final List<CombatWrite> inbox = [];

  /// Events waiting for the world. Never saved, likewise.
  final List<CombatEvent> outbox = [];

  // Edge detection for [StageChangedEvent]; not saved, so the first tick after
  // a load reads the restored state as already seen and posts nothing.
  Allegiance? _seenAllegiance;
  LoyaltyStage? _seenStage;

  int get deployedTotal {
    var n = 0;
    for (final d in deployed) {
      n += d.count;
    }
    return n;
  }

  bool get isEmpty =>
      deployed.isEmpty && wounded.isEmpty && garrison == null && resolveBoostUntilS == 0;

  Map<String, dynamic>? toJson() => isEmpty
      ? null
      : {
          if (deployed.isNotEmpty) 'deployed': [for (final d in deployed) d.toJson()],
          if (wounded.isNotEmpty) 'wounded': [for (final w in wounded) w.toJson()],
          if (garrison != null) 'garrison': garrison!.toJson(),
          if (resolveBoostUntilS != 0) 'boostUntil': resolveBoostUntilS,
        };

  void restore(Object? j) {
    deployed.clear();
    wounded.clear();
    garrison = null;
    resolveBoostUntilS = 0;
    if (j is! Map) return;
    resolveBoostUntilS = (j['boostUntil'] as num?)?.toDouble() ?? 0;
    for (final d in (j['deployed'] is List ? j['deployed'] as List : const [])) {
      final v = DeployedTroopers.fromJson(d);
      if (v != null) deployed.add(v);
    }
    for (final w in (j['wounded'] is List ? j['wounded'] as List : const [])) {
      if (w is Map && w['n'] is num && w['until'] is num) {
        wounded.add(WoundedTroopers((w['n'] as num).toInt(), (w['until'] as num).toDouble()));
      }
    }
    garrison = PortGarrison.fromJson(j['garrison']);
  }
}

/// The war's glue on the colony.
extension CityWar on CitySim {
  /// A grid building's site id.
  static String cellSite(int key) => 'cell:$key';

  /// What stands on [siteId], if anything.
  CityBuildingSpec? specAtSite(String siteId) {
    if (siteId.startsWith('cell:')) {
      final k = int.tryParse(siteId.substring(5));
      return k == null ? null : utils[k];
    }
    for (final (parcel, spec) in parcelBuiltLots()) {
      if (parcel.id == siteId) return spec;
    }
    return null;
  }

  /// The share of [siteId] still at work: 1 − the share of its staff away at
  /// war. Multiplies the site's utilisation in both aggregation loops, so its
  /// jobs, services and input draw all fall with it — a deployed trooper costs
  /// the colony what the same trooper costs idling in the barracks, moved,
  /// not added (combat.md §7.3). 1 everywhere when nobody is away.
  double siteFactorOf(String siteId) {
    final ds = war.deployed;
    if (ds.isEmpty) return 1.0;
    var away = 0, jobs = 0;
    for (final d in ds) {
      if (d.siteId != siteId) continue;
      away += d.count;
      jobs = math.max(jobs, d.jobs);
    }
    if (away == 0 || jobs <= 0) return 1.0;
    return (1 - away / jobs).clamp(0.0, 1.0);
  }

  /// Troopers away from the colony: they are residents, but they work no job.
  int get troopersAway => war.deployedTotal;

  /// Wounded still recovering.
  int get troopersRecovering {
    var n = 0;
    for (final w in war.wounded) {
      if (w.untilS > colonyTimeS) n += w.count;
    }
    return n;
  }

  // ---- launch snapshots ------------------------------------------------------

  /// Every building that can field troopers, in site id order.
  List<TrooperSource> trooperSources() {
    final out = <TrooperSource>[];
    void consider(String siteId, CityBuildingSpec s) {
      if (s.type != 'barracks' && s.type != 'base') return;
      String? why;
      for (final k in kWarCommodities) {
        final need = s.inputs[k];
        if (need != null && need > 0 && stockOf(k) <= 0) why ??= 'short of $k';
      }
      var away = 0;
      for (final d in war.deployed) {
        if (d.siteId == siteId) away += d.count;
      }
      final cap = (s.jobs * restThrottle * 0.5).floor();
      final avail = math.max(0, cap - away);
      out.add(TrooperSource(
        siteId: siteId,
        type: s.type,
        jobs: s.jobs,
        ready: why == null && avail > 0,
        available: why == null ? avail : 0,
        notReadyWhy: why ?? (avail > 0 ? null : 'every trooper is already away'),
        kitPerTrooperDay: {
          for (final k in kWarCommodities)
            if ((s.inputs[k] ?? 0) > 0) k: s.inputs[k]! * loyalty.tuning.daySec / s.jobs,
        },
      ));
    }

    for (final e in utils.entries) {
      if (isConnected(e.key)) consider(cellSite(e.key), e.value);
    }
    if (layout.parcels.isNotEmpty) {
      final net = parcelNetwork();
      for (final (parcel, s) in parcelBuiltLots()) {
        if (net.lotServed(parcel.id)) consider(parcel.id, s);
      }
    }
    out.sort((a, b) => a.siteId.compareTo(b.siteId));
    // Wounded cannot go: take them off the largest sources first.
    var recovering = troopersRecovering;
    if (recovering > 0) {
      for (var i = 0; i < out.length && recovering > 0; i++) {
        final s = out[i];
        final cut = math.min(recovering, s.available);
        if (cut == 0) continue;
        recovering -= cut;
        out[i] = TrooperSource(
          siteId: s.siteId,
          type: s.type,
          jobs: s.jobs,
          ready: s.available - cut > 0 && s.notReadyWhy == null,
          available: s.available - cut,
          kitPerTrooperDay: s.kitPerTrooperDay,
          notReadyWhy: s.available - cut > 0 ? s.notReadyWhy : 'its troopers are recovering',
        );
      }
    }
    return out;
  }

  /// This colony as a source of troopers.
  SourceSnapshot sourceSnapshot() {
    var supportAway = 0;
    for (final d in war.deployed) {
      if (d.siteId == kSupportSite) supportAway += d.count;
    }
    const gated = ['barracks', 'base', 'gunfactory', 'hospital', 'spaceport'];
    final have = <String>[];
    for (final (_, s) in buildingParcels()) {
      if (gated.contains(s.type) && !have.contains(s.type)) have.add(s.type);
    }
    have.sort();
    return SourceSnapshot(
      colonyId: id,
      name: name,
      bodyId: body.id.value,
      sources: trooperSources(),
      stock: {
        for (final k in kWarCommodities) k: stockOf(k),
        Commodity.ore: stockOf(Commodity.ore),
        Commodity.medicine: stockOf(Commodity.medicine),
        Commodity.steel: stockOf(Commodity.steel),
        Commodity.electronics: stockOf(Commodity.electronics),
      },
      supportAvailable: math.max(0, (population * kSupportShare).floor() - supportAway),
      buildings: have,
    );
  }

  /// This colony as the target, as it stands now.
  LaunchSnapshot launchSnapshot() {
    var portJobs = 0;
    Parcel? port;
    var portBest = -1;
    for (final (p, s) in landingPads()) {
      if (s.type != 'spaceport') continue;
      portJobs += s.jobs;
      if (s.jobs > portBest || (s.jobs == portBest && p.id.compareTo(port!.id) < 0)) {
        portBest = s.jobs;
        port = p;
      }
    }
    final portAt = port?.centroid;
    final colonial = loyalty.allegiance == Allegiance.colonial;
    final severity = colonial
        ? Grievance(
            neglectDays: loyalty.sinceAttendedS / loyalty.tuning.daySec,
            rebellion: rebellion,
            revolts: loyalty.revolts.length,
            desperation: loyalty.desperation,
          ).severity(loyalty.reclaim.tuning,
            revoltsToSecede: loyalty.tuning.revoltsToSecede)
        : (loyalty.reclaim.grievance ?? const Grievance())
            .severity(loyalty.reclaim.tuning, revoltsToSecede: loyalty.tuning.revoltsToSecede);
    final independent = loyalty.allegiance == Allegiance.independent;
    // What a base's sockets must keep clear of, and the pads an LZ keeps its
    // distance from (combat.md §7D).
    final obstacles = <(double, double, double)>[];
    final pads = <(double, double)>[];
    for (final (p, s) in _sitesInOrder()) {
      final c = p.centroid;
      final f = buildingFootprint(p, s);
      obstacles.add((c.e, c.n, 0.5 * math.sqrt(f.width * f.width + f.depth * f.depth)));
      if (s.siteKind == SiteKind.pad) pads.add((c.e, c.n));
    }
    var regulars = 0;
    final guns = <EmplacementSite>[];
    var sheltered = 0.0;
    if (independent) {
      for (final (parcel, s) in _sitesInOrder()) {
        final c = parcel.centroid;
        if (s.type == 'barracks' || s.type == 'base') {
          regulars += (s.jobs * restThrottle * 0.5).floor();
        } else if (s.type == 'gunemplacement') {
          guns.add(EmplacementSite(_siteIdOf(parcel.id), c.e, c.n, (s.jobs / 2).ceil()));
        }
        if (s.type == 'shelter' || s.type == 'bunker') sheltered += s.housing;
      }
    }
    return LaunchSnapshot(
      colonyId: id,
      bodyId: body.id.value,
      population: population,
      mood: happiness,
      hunger: (1 - foodSecurity).clamp(0.0, 1.0),
      severity: severity,
      wish: colonial ? 0 : loyalty.reclaim.pressure,
      spaceportJobs: portJobs,
      gunsInStock: stockOf(Commodity.guns).floor(),
      portSeized: loyalty.portSeized,
      portE: portAt?.e ?? 0,
      portN: portAt?.n ?? 0,
      independent: independent,
      objectives: independent ? assaultObjectives() : const [],
      regulars: regulars,
      emplacements: guns,
      shelterCover: population <= 0 ? 0 : (sheltered / population).clamp(0.0, 1.0),
      resolveBoost: colonyTimeS < war.resolveBoostUntilS ? kResolveBoost : 0,
      airless: !body.hasAtmosphere,
      obstacles: obstacles,
      pads: pads,
    );
  }

  /// A built site's war id: `cell:<key>` for a grid building (the parcel the
  /// grid derives for it is `cell-<key>`), else the parcel id.
  static String _siteIdOf(String parcelId) =>
      parcelId.startsWith('cell-') ? 'cell:${parcelId.substring(5)}' : parcelId;

  /// Every built site, in site id order.
  List<(Parcel, CityBuildingSpec)> _sitesInOrder() =>
      [...buildingParcels()]..sort((a, b) => a.$1.id.compareTo(b.$1.id));

  /// What an assault on this colony fights over (combat.md §7A): its Seat —
  /// the biggest civic building by jobs, nearest the centre on a tie; else
  /// the biggest building that is not homes; else its port — then its Port,
  /// Life support and Power, each only when it is a site not already picked.
  List<ObjectiveSite> assaultObjectives() {
    const civic = ['police', 'emergency', 'hospital', 'school', 'clinic'];
    final sites = _sitesInOrder();
    (Parcel, CityBuildingSpec)? best(bool Function(CityBuildingSpec) ok,
        double Function(CityBuildingSpec) size, List<String> taken) {
      (Parcel, CityBuildingSpec)? pick;
      for (final e in sites) {
        if (!ok(e.$2) || taken.contains(e.$1.id)) continue;
        if (pick == null) {
          pick = e;
          continue;
        }
        final a = size(e.$2), b = size(pick.$2);
        if (a > b ||
            (a == b && e.$1.centroid.length < pick.$1.centroid.length)) {
          pick = e;
        }
      }
      return pick;
    }

    final taken = <String>[];
    final out = <ObjectiveSite>[];
    void add(String kind, (Parcel, CityBuildingSpec)? e) {
      if (e == null) return;
      taken.add(e.$1.id);
      final c = e.$1.centroid;
      out.add(ObjectiveSite(
          kind: kind, siteId: _siteIdOf(e.$1.id), e: c.e, n: c.n, areaM2: e.$1.area));
    }

    final seat = best((s) => civic.contains(s.type), (s) => s.jobs.toDouble(), taken) ??
        best((s) => s.group != 'res' && s.jobs > 0, (s) => s.jobs.toDouble(), taken) ??
        best((s) => s.type == 'spaceport', (s) => s.jobs.toDouble(), taken);
    add('seat', seat);
    if (seat == null) return out;
    add('port', best((s) => s.type == 'spaceport', (s) => s.jobs.toDouble(), taken));
    add('lifeSupport', best(CitySim.isLifeSupport, (s) => s.jobs.toDouble(), taken));
    add('power', best((s) => s.powerOutput > 0, (s) => s.powerOutput, taken));
    return out;
  }

  // ---- the inbox ---------------------------------------------------------------

  /// Applies every waiting write, in order. The world calls this at the start
  /// of the colony's phase, before it advances.
  void drainCombatInbox() {
    if (war.inbox.isEmpty) return;
    final writes = List<CombatWrite>.of(war.inbox);
    war.inbox.clear();
    for (final w in writes) {
      applyCombatWrite(w);
    }
  }

  void applyCombatWrite(CombatWrite w) {
    switch (w) {
      case DeployWrite():
        war.deployed.add(DeployedTroopers(w.opId, w.siteId, w.troopers, w.jobs));
        // Kit, and a forward base's Materiel (ore).
        for (final k in const [
          ...kWarCommodities,
          Commodity.ore,
          Commodity.medicine,
          Commodity.steel,
          Commodity.electronics,
        ]) {
          final v = w.kit[k];
          if (v != null && v > 0) stock[k] = math.max(0.0, stockOf(k) - v);
        }
      case BaseRunDebitWrite():
        double ship(String k, double want) {
          if (want <= 0) return 0;
          final n = math.min(want, stockOf(k));
          if (n <= 0) return 0;
          stock[k] = stockOf(k) - n;
          return n;
        }
        final m = ship(Commodity.ore, w.materiel);
        final sent = [
          for (var i = 0; i < kBaseGoods.length; i++)
            ship(kBaseGoods[i], i < w.stock.length ? w.stock[i] : 0)
        ];
        war.outbox.add(BaseRunShippedEvent(w.opId, w.runId, m, sent));
      case BaseGoodsWrite():
        if (w.materiel > 0) stock[Commodity.ore] = stockOf(Commodity.ore) + w.materiel;
        for (var i = 0; i < kBaseGoods.length && i < w.stock.length; i++) {
          if (w.stock[i] > 0) stock[kBaseGoods[i]] = stockOf(kBaseGoods[i]) + w.stock[i];
        }
      case TroopersHomeWrite():
        // By count, not by operation: a garrison stays away after the rest
        // come home, and its members return later, a few at a time.
        var back = w.alive + w.wounded + w.dead;
        for (final d in war.deployed) {
          if (back <= 0) break;
          if (d.opId != w.opId || (w.siteId != null && d.siteId != w.siteId)) continue;
          final n = math.min(back, d.count);
          d.count -= n;
          back -= n;
        }
        war.deployed.removeWhere((d) => d.count <= 0);
        if (w.wounded > 0) {
          war.wounded.add(WoundedTroopers(w.wounded, colonyTimeS + 2 * loyalty.tuning.daySec));
        }
        if (w.dead > 0) recordWarDead(w.dead);
      case PortRetakenWrite():
        loyalty.releaseByForce();
        if (w.garrison != null && w.garrison!.count > 0) war.garrison = w.garrison;
        // Now, not at the next war tick: the loyalty step runs first in the
        // colony's tick, and would seize the port straight back.
        loyalty.garrisonHoldsPort = (war.garrison?.count ?? 0) > 0;
      case PortRepulsedWrite():
        loyalty.onForceRepulsed();
      case OccupyWrite():
        if (w.garrison.count <= 0) break;
        war.garrison = w.garrison;
        loyalty.occupy();
        // Its council's acts are its last independence's story.
        governorLog.clear();
      case AssaultRepulsedWrite():
        war.resolveBoostUntilS = colonyTimeS + kResolveBoostDays * loyalty.tuning.daySec;
        loyalty.onAssaultRepulsed();
      case RestoreCharterWrite():
        final g = war.garrison;
        if (g != null && g.occupation && loyalty.restoreCharter()) {
          war.outbox.add(GarrisonHomeEvent(g.opId, g.homeColonyId, g.count));
          war.garrison = null;
        }
      case WarDeadWrite():
        recordWarDead(w.dead, corpses: true);
        // Its people, killed by the player's troopers: a grievance it keeps.
        loyalty.warDead += w.dead;
        final gr = loyalty.reclaim.grievance;
        if (gr != null) loyalty.reclaim.grievance = gr.withWarDead(w.dead);
      case GarrisonWithdrawWrite():
        final g = war.garrison;
        if (g != null) {
          war.outbox.add(GarrisonHomeEvent(g.opId, g.homeColonyId, g.count));
          war.garrison = null;
          loyalty.garrisonHoldsPort = false;
          loyalty.garrisonHoldsColony = false;
          if (g.occupation) loyalty.withdrawOccupation();
        }
      case GarrisonSupplyDebitWrite():
        final sent = <String, double>{};
        for (final k in kWarCommodities) {
          final want = w.amounts[k] ?? 0;
          if (want <= 0) continue;
          final n = math.min(want, stockOf(k));
          if (n <= 0) continue;
          stock[k] = stockOf(k) - n;
          sent[k] = n;
        }
        war.outbox.add(GarrisonSuppliedEvent(w.targetColonyId, sent));
      case WarWearinessWrite():
        if (loyalty.allegiance == Allegiance.colonial) {
          loyalty.level = (loyalty.level - w.loyaltyCost).clamp(0.0, 1.0);
        }
      case GarrisonResupplyWrite():
        final g = war.garrison;
        if (g != null) {
          for (final k in kWarCommodities) {
            final v = w.amounts[k];
            if (v != null && v > 0) g.stock[k] = (g.stock[k] ?? 0) + v;
          }
        }
    }
  }

  /// What a garrison eats and fires over [dt]: from its own stock, and for an
  /// occupation garrison ([fromColony]) what that leaves short is
  /// requisitioned from the colony's stores, which costs the colony mood.
  /// Short of both, a tenth of it goes home a day.
  void _garrisonUpkeep(PortGarrison g, double dt, {required bool fromColony}) {
    final w = war;
    final day = loyalty.tuning.daySec;
    var short = false;
    for (final k in kWarCommodities) {
      final per = g.perTrooperDay[k] ?? 0;
      if (per <= 0) continue;
      final need = per * g.count * dt / day;
      final have = g.stock[k] ?? 0;
      if (have + 1e-12 >= need) {
        g.stock[k] = math.max(0.0, have - need);
        continue;
      }
      g.stock[k] = 0;
      var gap = need - have;
      if (fromColony && gap > 0) {
        final take = math.min(gap, stockOf(k));
        if (take > 0) {
          stock[k] = stockOf(k) - take;
          gap -= take;
          w.requisitioning = true;
        }
      }
      if (gap > 1e-12) short = true;
    }
    g.unpaidS = short ? g.unpaidS + dt : 0;
    if (g.unpaidS >= day) {
      final leave = math.max(1, (g.count * 0.1).round());
      g.count = math.max(0, g.count - leave);
      g.unpaidS -= day;
      w.outbox.add(GarrisonHomeEvent(g.opId, g.homeColonyId, leave));
      if (g.count == 0) w.garrison = null;
    }
  }

  /// [n] people of this colony killed in war, through the colony's own death
  /// write: the E8 ledger when citizens own the population, else the scalar.
  /// [corpses] when they died in town (defenders); troopers are buried where
  /// they fell.
  void recordWarDead(int n, {bool corpses = false}) {
    if (n <= 0) return;
    final ledger = agents.ownsPopulation ? agents.ledger : null;
    if (ledger != null) {
      ledger.addDeath(n.toDouble());
    } else {
      population = math.max(0.0, population - n);
    }
    if (corpses) this.corpses += n;
  }

  // ---- the colony's own tick ----------------------------------------------------

  /// The war's part of [CitySim.advance]: recovering wounded, the garrison's
  /// upkeep, the seizure guard, and the events the world needs.
  void warTick(double dt) {
    final w = war;
    if (w.wounded.isNotEmpty) w.wounded.removeWhere((x) => x.untilS <= colonyTimeS);
    final g = w.garrison;
    w.requisitioning = false;
    if (g != null && g.occupation) {
      if (!loyalty.occupied) {
        // The colony threw it out (the loyalty step ended the occupation):
        // home, alive.
        w.outbox.add(GarrisonHomeEvent(g.opId, g.homeColonyId, g.count, expelled: true));
        w.garrison = null;
      } else {
        _garrisonUpkeep(g, dt, fromColony: true);
      }
    } else if (g != null) {
      if (loyalty.allegiance != Allegiance.colonial || loyalty.stage != LoyaltyStage.standoff) {
        // Its job is done (the standoff ended), or it has nothing to hold
        // (the colony broke away): home, alive.
        w.outbox.add(GarrisonHomeEvent(g.opId, g.homeColonyId, g.count,
            expelled: loyalty.allegiance != Allegiance.colonial));
        w.garrison = null;
      } else {
        _garrisonUpkeep(g, dt, fromColony: false);
      }
    }
    final held = w.garrison;
    loyalty.garrisonHoldsPort = held != null && !held.occupation && held.count > 0;
    loyalty.garrisonHoldsColony = held != null && held.occupation && held.count > 0;
    // Edges the operation must hear about.
    final a = loyalty.allegiance, s = loyalty.stage;
    if (w._seenAllegiance != null && (a != w._seenAllegiance || s != w._seenStage)) {
      w.outbox.add(StageChangedEvent(a, s));
    }
    w._seenAllegiance = a;
    w._seenStage = s;
    if (w.deployed.isNotEmpty) {
      // Support staff come from no building, so none can be lost under them.
      bool lost(DeployedTroopers d) => d.siteId != kSupportSite && specAtSite(d.siteId) == null;
      for (final d in w.deployed) {
        if (lost(d)) w.outbox.add(SiteLostEvent(d.siteId));
      }
      // A lost site's troopers stay in the fight but no longer belong to it.
      w.deployed.removeWhere(lost);
    }
  }
}
