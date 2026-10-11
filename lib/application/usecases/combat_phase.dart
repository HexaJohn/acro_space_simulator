// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The world's combat phase: one owner, one clock (docs/plans/combat.md §7.4).
///
/// Runs once a tick, before the colonies, in a fixed order:
///   1. apply the combat commands the UI queued;
///   2. drain each colony's outbox (what changed there since its last tick);
///   3. step every operation on the operation clock;
///   4. report resolved operations back as colony writes;
///   5. run garrison supply.
/// Writes go into each colony's inbox, which the colony drains at the start of
/// its own phase — this tick, or when a frame-held colony's tick replays — so
/// a write lands in the colony's own order. Nothing here reads a colony during
/// a battle: launches take snapshots, and the rest arrives as events.
library;

import 'dart:math' as math;

import '../../domain/colony/city/city_loyalty.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/city_war.dart';
import '../../domain/combat/formation.dart';
import '../../domain/combat/launch/plan_operation.dart';
import '../../domain/combat/launch/snapshots.dart';
import '../../domain/combat/operation.dart';
import '../../domain/combat/operation_registry.dart';
import '../../domain/combat/resolver_tuning.dart';
import '../../domain/multiplayer/command.dart';

class CombatPhase {
  CombatPhase(this.registry, {this.tuning = const ResolverTuning()});

  final OperationRegistry registry;
  final ResolverTuning tuning;

  /// Supply runs to a garrison leave every this many operation days.
  static const double supplyEveryDays = 3;

  /// A supply run's flight, s: fixed, so its arrival never depends on warp.
  static const int supplyTransitS = 60;

  /// Loyalty every colony loses per player trooper killed: 0.01 per 10.
  static const double wearinessPerDead = 0.001;

  int get _dayUs => (tuning.daySec * 1e6).round();

  /// One tick of [tickDt] seconds over [cityList].
  void run(double tickDt, Iterable<CitySim> cityList) {
    final cities = [...cityList]..sort((a, b) => a.id.compareTo(b.id));
    final opDt = math.min(math.max(0.0, tickDt), 0.5);
    registry.clockUs += (opDt * 1e6).round();

    for (final c in registry.inbox.drain()) {
      _apply(c, cities);
    }
    for (final city in cities) {
      if (city.war.outbox.isEmpty) continue;
      final events = List<CombatEvent>.of(city.war.outbox);
      city.war.outbox.clear();
      for (final e in events) {
        _onEvent(city, e, cities);
      }
    }
    for (final op in registry.operations) {
      if (!op.resolved) op.advance(opDt);
    }
    for (final op in registry.operations) {
      if (op.resolved && !registry.reported.contains(op.id)) _report(op, cities);
    }
    _supply(cities);
    registry.trim();
  }

  CitySim? _find(List<CitySim> cities, String id) {
    for (final c in cities) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ---- 1. commands -------------------------------------------------------------

  void _apply(CombatCommand c, List<CitySim> cities) {
    switch (c) {
      case LaunchOperationCommand():
        _launch(c, cities);
      case WithdrawOperationCommand():
        registry.byId(c.operationId)?.withdraw();
      case WithdrawGarrisonCommand():
        _find(cities, c.colonyId)?.war.inbox.add(const GarrisonWithdrawWrite());
      case RestoreCharterCommand():
        _find(cities, c.colonyId)?.war.inbox.add(const RestoreCharterWrite());
      case OrderOperationCommand():
        final kind = OrderKind.values.where((k) => k.name == c.order).firstOrNull;
        if (kind != null) registry.byId(c.operationId)?.setOrder(kind, target: c.target);
      case ReinforceOperationCommand():
        _reinforce(c, cities);
    }
  }

  void _reinforce(ReinforceOperationCommand c, List<CitySim> cities) {
    final op = registry.byId(c.operationId);
    final target = op == null ? null : _find(cities, op.targetColonyId);
    if (op == null || op.resolved || target == null) {
      registry.lastRefusal = 'That operation is over.';
      return;
    }
    final sourceIds = <String>[];
    for (final d in c.draws) {
      if (!sourceIds.contains(d.colonyId)) sourceIds.add(d.colonyId);
    }
    sourceIds.sort();
    final sources = <SourceSnapshot>[];
    for (final id in sourceIds) {
      final s = _find(cities, id);
      if (s == null || s.loyalty.allegiance == Allegiance.independent) {
        registry.lastRefusal = 'A source colony takes no orders.';
        return;
      }
      sources.add(s.sourceSnapshot());
    }
    final planned = planReinforcements(
      op: op,
      targetBodyId: target.body.id.value,
      sources: sources,
      draws: [for (final d in c.draws) TrooperDraw(d.colonyId, d.siteId, d.count)],
      kitDays: c.kitDays,
    );
    if (planned.refusal case final why?) {
      registry.lastRefusal = why;
      return;
    }
    registry.lastRefusal = null;
    op.reinforce(planned.formations);
    for (final d in planned.debits) {
      _find(cities, d.colonyId)
          ?.war
          .inbox
          .add(DeployWrite(op.id, d.siteId, d.troopers, d.jobs, d.kit));
    }
  }

  void _launch(LaunchOperationCommand c, List<CitySim> cities) {
    final target = _find(cities, c.targetColonyId);
    if (target == null) {
      registry.lastRefusal = 'That colony no longer exists.';
      return;
    }
    if (registry.runningAgainst(target.id) != null) {
      registry.lastRefusal = 'An operation against ${target.name} is already under way.';
      return;
    }
    final sourceIds = <String>[];
    for (final d in c.draws) {
      if (!sourceIds.contains(d.colonyId)) sourceIds.add(d.colonyId);
    }
    sourceIds.sort();
    final sources = <SourceSnapshot>[];
    for (final id in sourceIds) {
      final s = _find(cities, id);
      if (s == null) {
        registry.lastRefusal = 'A source colony no longer exists.';
        return;
      }
      if (s.loyalty.allegiance == Allegiance.independent) {
        registry.lastRefusal = '${s.name} takes no orders.';
        return;
      }
      sources.add(s.sourceSnapshot());
    }
    final draws = [for (final d in c.draws) TrooperDraw(d.colonyId, d.siteId, d.count)];
    final snap = target.launchSnapshot();
    final planned = snap.independent
        ? planColonyAssault(
            operationId: registry.nextOperationId,
            target: snap,
            sources: sources,
            draws: draws,
            kitDays: c.kitDays,
            garrison: c.garrison,
            roe: Roe.values.where((r) => r.name == c.roe).firstOrNull ?? Roe.restrained,
            tuning: tuning,
          )
        : planPortRetake(
            operationId: registry.nextOperationId,
            target: snap,
            sources: sources,
            draws: draws,
            kitDays: c.kitDays,
            garrison: c.garrison,
            tuning: tuning,
          );
    final op = planned.operation;
    if (op == null) {
      registry.lastRefusal = planned.refusal;
      return;
    }
    registry.lastRefusal = null;
    registry.nextOperationId++;
    registry.operations.add(op);
    for (final d in planned.debits) {
      _find(cities, d.colonyId)
          ?.war
          .inbox
          .add(DeployWrite(op.id, d.siteId, d.troopers, d.jobs, d.kit));
    }
  }

  // ---- 2. events ---------------------------------------------------------------

  void _onEvent(CitySim city, CombatEvent e, List<CitySim> cities) {
    switch (e) {
      case StageChangedEvent():
        for (final op in registry.operations) {
          if (op.resolved) continue;
          if (op.targetColonyId == city.id) {
            if (op.kind == OperationKind.colonyAssault) {
              // It rejoined while the troopers were on their way (a petition
              // or terms accepted): nothing left to take.
              if (e.allegiance != Allegiance.independent) {
                op.endFromOutside(OperationOutcome.rejoined);
              }
            } else if (e.allegiance != Allegiance.colonial ||
                e.stage != LoyaltyStage.standoff) {
              // Independence, or the rebels stood down: either way the port
              // is not there to retake (combat.md §7.6).
              op.endFromOutside(OperationOutcome.overtaken);
            }
          } else if (e.allegiance == Allegiance.independent) {
            _desert(op, city);
          }
        }
      case SiteLostEvent():
        for (final op in registry.operations) {
          for (final f in op.formations) {
            if (f.homeColonyId == city.id && f.homeSiteId == e.siteId) f.homeSiteId = null;
          }
        }
      case GarrisonHomeEvent():
        _find(cities, e.homeColonyId)
            ?.war
            .inbox
            .add(TroopersHomeWrite(e.opId, null, alive: e.count, wounded: 0, dead: 0));
        for (final g in registry.garrisons) {
          if (g.targetColonyId == city.id && g.opId == e.opId) g.count -= e.count;
        }
        registry.garrisons.removeWhere(
            (g) => g.targetColonyId == city.id && (g.count <= 0 || e.expelled));
      case GarrisonSuppliedEvent():
        if (e.amounts.isNotEmpty) {
          registry.runs.add(SupplyRun(
              e.targetColonyId, e.amounts, registry.clockUs + supplyTransitS * 1000000));
        }
    }
  }

  /// A source colony broke away: its troopers go home to it, alive, and the
  /// fight goes on without them.
  void _desert(Operation op, CitySim home) {
    var alive = 0, wounded = 0, dead = 0;
    for (final f in op.formations) {
      if (f.side != CombatSide.attacker || f.homeColonyId != home.id) continue;
      alive += f.count;
      wounded += f.wounded;
      dead += f.dead;
      f.count = 0;
      f.wounded = 0;
      f.dead = 0;
    }
    if (alive + wounded + dead == 0) return;
    home.war.inbox.add(TroopersHomeWrite(op.id, null, alive: alive, wounded: wounded, dead: dead));
  }

  // ---- 4. reporting ------------------------------------------------------------

  void _report(Operation op, List<CitySim> cities) {
    registry.reported.add(op.id);
    final target = _find(cities, op.targetColonyId);
    final homes = op.attackerByHome();
    var garrisonFrom = '';
    var garrisonN = 0;
    if (op.outcome == OperationOutcome.won && target != null) {
      // The garrison comes from the home with the most survivors, so it has
      // one home to be paid from and to go back to.
      var best = -1;
      for (final h in homes) {
        if (h.alive > best) {
          best = h.alive;
          garrisonFrom = h.home;
        }
      }
      garrisonN = math.min(op.garrison, math.max(0, best));
      PortGarrison? g;
      if (garrisonN > 0) {
        // They hold with what they carry: the kit days the fight left them.
        var kitSum = 0.0, members = 0;
        for (final f in op.formations) {
          if (f.side == CombatSide.attacker && f.homeColonyId == garrisonFrom && f.alive) {
            kitSum += f.kitDays * f.count;
            members += f.count;
          }
        }
        final kitLeft = members == 0 ? 0.0 : kitSum / members;
        // What a garrison eats and fires: its home building's inputs, less the
        // guns — each trooper holds with the gun they carried in, and a
        // garrison that "needed" guns it never had went short on its first
        // tick and home a tenth a day.
        final upkeep = {
          for (final k in kWarCommodities)
            if (k != 'guns' && (op.garrisonKit[k] ?? 0) > 0) k: op.garrisonKit[k]!,
        };
        g = PortGarrison(
          opId: op.id,
          homeColonyId: garrisonFrom,
          count: garrisonN,
          perTrooperDay: upkeep,
          stock: {for (final k in kWarCommodities) if (upkeep[k] != null) k: upkeep[k]! * garrisonN * kitLeft},
          occupation: op.kind == OperationKind.colonyAssault,
        );
        // The first run leaves now: the garrison holds with whatever kit the
        // fight left it, often well under a day, and a first run three days
        // out arrived to a garrison already half gone home.
        registry.garrisons.add(GarrisonRecord(
          targetColonyId: target.id,
          homeColonyId: garrisonFrom,
          opId: op.id,
          count: garrisonN,
          perTrooperDay: Map.of(upkeep),
          nextRunUs: registry.clockUs,
        ));
      }
      if (op.kind == OperationKind.colonyAssault) {
        // The dead first, so the grievance it is occupied with counts them.
        final dead = op.defenderDead + op.civilianDead;
        if (dead > 0) target.war.inbox.add(WarDeadWrite(dead));
        if (g != null) target.war.inbox.add(OccupyWrite(g));
      } else {
        target.war.inbox.add(PortRetakenWrite(g));
      }
    } else if (op.outcome == OperationOutcome.lost && target != null) {
      target.war.inbox.add(op.kind == OperationKind.colonyAssault
          ? const AssaultRepulsedWrite()
          : const PortRepulsedWrite());
    }
    final won = op.outcome == OperationOutcome.won;
    if (target != null && !(won && op.kind == OperationKind.colonyAssault)) {
      final dead = op.defenderDead + op.civilianDead;
      if (dead > 0) target.war.inbox.add(WarDeadWrite(dead));
    }
    for (final h in homes) {
      final keep = h.home == garrisonFrom ? garrisonN : 0;
      _find(cities, h.home)?.war.inbox.add(TroopersHomeWrite(op.id, null,
          alive: math.max(0, h.alive - keep), wounded: h.wounded, dead: h.dead));
    }
    final dead = op.attackerDead;
    if (dead > 0) {
      for (final c in cities) {
        c.war.inbox.add(WarWearinessWrite(dead * wearinessPerDead));
      }
    }
  }

  // ---- 5. garrison supply ------------------------------------------------------

  void _supply(List<CitySim> cities) {
    for (final g in registry.garrisons) {
      if (registry.clockUs < g.nextRunUs) continue;
      g.nextRunUs += (supplyEveryDays * _dayUs).round();
      final home = _find(cities, g.homeColonyId);
      if (home == null) continue;
      home.war.inbox.add(GarrisonSupplyDebitWrite(g.targetColonyId, {
        for (final k in kWarCommodities)
          if ((g.perTrooperDay[k] ?? 0) > 0 && k != 'guns')
            k: g.perTrooperDay[k]! * g.count * supplyEveryDays,
      }));
    }
    if (registry.runs.isEmpty) return;
    final arrived = registry.runs.where((r) => registry.clockUs >= r.arriveUs).toList();
    for (final r in arrived) {
      _find(cities, r.targetColonyId)?.war.inbox.add(GarrisonResupplyWrite(r.amounts));
    }
    registry.runs.removeWhere((r) => registry.clockUs >= r.arriveUs);
  }
}
