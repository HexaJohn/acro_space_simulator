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
import '../../domain/colony/city/parcel.dart' show Vec2;
import '../../domain/combat/base/base_modules.dart';
import '../../domain/combat/formation.dart';
import '../../domain/combat/lander.dart';
import '../../domain/combat/launch/plan_operation.dart';
import '../../domain/combat/launch/snapshots.dart';
import '../../domain/combat/operation.dart';
import '../../domain/combat/operation_registry.dart';
import '../../domain/combat/powers/orbital.dart';
import '../../domain/combat/powers/overhead.dart';
import '../../domain/combat/powers/sky.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/terrain/impact_scaling.dart';
import '../../domain/combat/resolver_tuning.dart';
import '../../domain/multiplayer/command.dart';

class CombatPhase {
  CombatPhase(this.registry, {this.tuning = const ResolverTuning(), this.landers = false});

  final OperationRegistry registry;
  final ResolverTuning tuning;

  /// Fly the squads down as real troop landers where the target's body has
  /// no air (docs/plans/combat.md §7B). Off where no world flies them — a
  /// test of the colonies alone, a host without vessels — and landing is
  /// abstract.
  final bool landers;

  bool _landersFor(CitySim target) => landers && !target.body.hasAtmosphere;

  /// Supply runs to a garrison leave every this many operation days.
  static const double supplyEveryDays = 3;

  /// A supply run's flight, s: fixed, so its arrival never depends on warp.
  static const int supplyTransitS = 60;

  /// Loyalty every colony loses per player trooper killed: 0.01 per 10.
  static const double wearinessPerDead = 0.001;

  int get _dayUs => (tuning.daySec * 1e6).round();

  /// The flying world, read at this tick's end (§7E); null where no world
  /// flies — orbital support then has nothing to see.
  CombatSky? _sky;

  /// One tick of [tickDt] seconds over [cityList].
  void run(double tickDt, Iterable<CitySim> cityList, {CombatSky? sky}) {
    _sky = sky;
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
    _watchSky(cities);
    for (final op in registry.operations) {
      if (!op.resolved) op.advance(opDt);
      for (final v in op.orbital.fired) {
        registry.spendRound(v);
      }
      op.orbital.fired.clear();
    }
    _postBaseRuns(cities);
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
        final op = registry.byId(c.operationId);
        if (c.order == 'charge') {
          if (op != null && c.target != null) registry.lastRefusal = op.charge(c.target!);
          break;
        }
        final kind = OrderKind.values.where((k) => k.name == c.order).firstOrNull;
        if (kind != null) op?.setOrder(kind, target: c.target);
      case CommanderPowerCommand():
        final op = registry.byId(c.operationId);
        registry.lastRefusal = c.power == 'orbitalStrike'
            ? (c.target == null ? 'Strike where?' : op?.strike(c.target!))
            : op?.power(c.power, objectiveId: c.target);
      case LiveCasualtiesCommand():
        final op = registry.byId(c.operationId);
        for (final id in c.formationIds) {
          op?.liveCasualty(id);
        }
      case AssignOrbitalSupportCommand():
        registry.lastRefusal = _assign(c, cities);
      case ArmVesselCommand():
        registry.lastRefusal = _arm(c, cities);
      case ReinforceOperationCommand():
        _reinforce(c, cities);
      case BaseOrderCommand():
        final op = registry.byId(c.operationId);
        final b = op?.base;
        if (op == null || b == null || op.resolved) break;
        final kind = ModuleKind.values.where((k) => k.name == c.module).firstOrNull;
        final ring = SocketKind.values.where((r) => r.name == c.ring).firstOrNull;
        final site = c.site ?? 0;
        switch (c.action) {
          case 'build':
            if (kind != null) {
              b.orderBuild(kind, c.socket ?? b.firstFree(moduleSpec(kind).socket) ?? -1, site: site);
            }
          case 'cancel':
            b.cancelJob(site: site, line: c.socket ?? 0);
          case 'demolish':
            if (ring != null && c.socket != null) b.demolish(op, ring, c.socket!, site: site);
          case 'formSquad':
            b.formSquad(op);
          case 'upgrade':
            final t = BaseTier.values.where((x) => x.name == c.value).firstOrNull;
            if (t != null) b.orderUpgrade(t);
          case 'outpost':
            if (c.value != null) b.orderOutpost(op, c.value!);
          case 'doctrine':
            final d = Doctrine.values.where((x) => x.name == c.value).firstOrNull;
            if (d != null) b.doctrine = d;
          case 'spareCore':
            if (c.value != null) registry.lastRefusal = b.orderSpareCore(op, c.value!);
        }
    }
  }

  // ---- orbital support (§7E) -----------------------------------------------------

  /// Every operation an assigned vessel is overhead of, refreshed at the
  /// tick's end; a vessel that left (gone, landed, out of the SOI) is
  /// unassigned with a notice. Rounds aboard are handed in for the steps.
  void _watchSky(List<CitySim> cities) {
    final sky = _sky;
    if (sky != null && registry.loadout.isNotEmpty) {
      registry.loadout.removeWhere((r) => sky.nameOf(r.vesselId) == null);
    }
    for (final op in registry.operations) {
      final o = op.orbital;
      if (op.resolved || !o.any) continue;
      final target = _find(cities, op.targetColonyId);
      final centre = o.centreBF;
      if (sky == null || target == null || centre == null) continue;
      final bodyId = target.body.id.value;
      final ground = sky.toInertial(bodyId, centre);
      for (final v in [...o.assigned]) {
        final at = sky.positionAbout(v.id, bodyId);
        if (at == null) {
          o.unassign(v.id);
          o.notices.add('Orbital support lost: ${v.name} has left the battle.');
          continue;
        }
        final seen = overheadOf(at, ground);
        v
          ..strike = seen.strike
          ..recon = seen.recon
          ..slantM = seen.slantM;
        o.roundsAboard[v.id] = registry.roundsAboard(v.id);
      }
    }
  }

  String? _assign(AssignOrbitalSupportCommand c, List<CitySim> cities) {
    final op = registry.byId(c.operationId);
    if (op == null || op.resolved) return 'That operation is over.';
    if (!c.assign) {
      op.orbital.unassign(c.vesselId);
      return null;
    }
    final sky = _sky;
    final target = _find(cities, op.targetColonyId);
    if (sky == null || target == null) return 'Nothing flies here.';
    if (!sky.isPlayers(c.vesselId)) return 'Only your own vessels can be assigned.';
    for (final o in registry.operations) {
      if (o.landers.any((l) => l.vesselId == c.vesselId)) return 'That is a troop lander.';
      if (!o.resolved && o.orbital.byId(c.vesselId) != null) {
        return 'It is already assigned to an operation.';
      }
    }
    if (sky.positionAbout(c.vesselId, target.body.id.value) == null) {
      return 'It must be in flight about ${target.body.name}.';
    }
    op.orbital.assign(c.vesselId, sky.nameOf(c.vesselId) ?? c.vesselId);
    return null;
  }

  String? _arm(ArmVesselCommand c, List<CitySim> cities) {
    final sky = _sky;
    final colony = _find(cities, c.colonyId);
    if (sky == null || colony == null) return 'Nothing flies here.';
    if (c.rounds <= 0) return null;
    if (!sky.isPlayers(c.vesselId)) return 'Only your own vessels can be armed.';
    final a = colony.loyalty.allegiance;
    if (a != Allegiance.colonial && a != Allegiance.occupied) return '${colony.name} takes no orders.';
    if (!sky.landedAtPad(c.vesselId, c.colonyId)) return 'Land it on one of ${colony.name}\'s pads first.';
    colony.war.inbox.add(ArmDebitWrite(c.vesselId, c.rounds, kRoundSteel, kRoundElectronics));
    return null;
  }

  /// The battle's centre on the ground, the crater a round digs there, and
  /// the buildings near the objectives (§7E): read once, at launch.
  void _orbitalAtLaunch(Operation op, CitySim target, LaunchSnapshot snap) {
    final objs = op.graph.objectives;
    if (objs.isEmpty) return;
    var e = 0.0, n = 0.0;
    for (final o in objs) {
      e += o.e;
      n += o.n;
    }
    final body = target.body;
    final bf = target.localToBodyFixed(Vec2(e / objs.length, n / objs.length), bodyRadiusM: body.radius);
    op.orbital
      ..centreBF = Vector3(bf.x, bf.y, bf.z)
      ..craterM = craterForImpact(
                kineticEnergyJ: kineticEnergy(kRoundMassKg, kRoundSpeedMs),
                surfaceGravityMs2: body.mu / (body.radius * body.radius))
            ?.diameterM ??
        op.orbital.craterM;
    for (final f in snap.obstacles) {
      final near = objs.any((o) {
        final dx = o.e - f.$1, dy = o.n - f.$2;
        return dx * dx + dy * dy < (300 + f.$3) * (300 + f.$3);
      });
      if (near) op.orbital.footprints.add(f);
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
    if (_landersFor(target)) {
      op.landers.addAll(
          packLanders(op.id, planned.formations, firstIndex: op.landers.length));
    }
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
    const d = BaseManifest();
    final manifest = c.withBase
        ? BaseManifest(
            materiel: c.baseMateriel,
            support: c.baseSupport,
            fuel: c.baseFuel ?? d.fuel,
            medicine: c.baseMedicine ?? d.medicine,
            steel: c.baseSteel ?? d.steel,
            electronics: c.baseElectronics ?? d.electronics,
            spareCore: c.baseSpareCore,
            doctrine: Doctrine.values.where((v) => v.name == c.baseDoctrine).firstOrNull ?? d.doctrine,
          )
        : null;
    final planned = snap.independent
        ? planColonyAssault(
            operationId: registry.nextOperationId,
            target: snap,
            sources: sources,
            draws: draws,
            kitDays: c.kitDays,
            garrison: c.garrison,
            roe: Roe.values.where((r) => r.name == c.roe).firstOrNull ?? Roe.restrained,
            base: manifest,
            tuning: tuning,
          )
        : planPortRetake(
            operationId: registry.nextOperationId,
            target: snap,
            sources: sources,
            draws: draws,
            kitDays: c.kitDays,
            garrison: c.garrison,
            base: manifest,
            tuning: tuning,
          );
    final op = planned.operation;
    if (op == null) {
      registry.lastRefusal = planned.refusal;
      return;
    }
    registry.lastRefusal = null;
    registry.nextOperationId++;
    _orbitalAtLaunch(op, target, snap);
    if (_landersFor(target)) {
      op.landers.addAll(packLanders(
          op.id, [for (final f in op.formations) if (f.side == CombatSide.attacker) f]));
    }
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
      case BaseRunShippedEvent():
        final op = registry.byId(e.opId);
        final b = op?.base;
        if (op != null && b != null && !op.resolved) {
          final transit = (op.sameBody ? tuning.transitDaysSameBody : tuning.transitDaysOtherBody) *
              tuning.daySec;
          b.runShipped(e.runId, (e.materiel * 100).round(),
              [for (final v in e.stock) (v * 100).round()], op.clock.steps + transit.round());
        } else if (e.materiel > 0 || e.stock.any((v) => v > 0)) {
          // Shipped to an operation already over: the goods go back.
          city.war.inbox.add(BaseGoodsWrite(e.materiel, e.stock));
        }
      case ArmedEvent():
        registry.loadRounds(e.vesselId, e.paid, registry.clockUs + kArmLoadS * 1000000);
        if (e.paid < e.asked) {
          registry.lastRefusal = '${city.name} could pay for ${e.paid} of ${e.asked} rounds '
              '($kRoundSteel steel and $kRoundElectronics electronics each).';
        }
      case GarrisonSuppliedEvent():
        if (e.amounts.isNotEmpty) {
          registry.runs.add(SupplyRun(
              e.targetColonyId, e.amounts, registry.clockUs + supplyTransitS * 1000000));
        }
    }
  }

  /// A forward base's supply runs, asked for this tick, go to its lead
  /// source as debits; the source answers with what it shipped (§7C).
  void _postBaseRuns(List<CitySim> cities) {
    for (final op in registry.operations) {
      final b = op.base;
      if (b == null || op.resolved) continue;
      for (final r in b.runs) {
        if (r.posted) continue;
        r.posted = true;
        _find(cities, b.homeColonyId)?.war.inbox.add(BaseRunDebitWrite(
            op.id, r.id, r.materielC / 100, [for (final v in r.stockC) v / 100]));
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
    // A base's support staff — the reserve, crews, and those fighting as
    // turrets or a formed squad — are reported with the base, under their
    // own deployed entry.
    final homes = op.attackerByHome(exceptSite: op.base == null ? null : kSupportSite);
    var garrisonFrom = '';
    var garrisonN = 0;
    // Support staff who stay on as the post's turret crews (§7D).
    var postCrew = 0;
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
        final stock = {
          for (final k in kWarCommodities) if (upkeep[k] != null) k: upkeep[k]! * garrisonN * kitLeft
        };
        // The post (§7D): a base still standing leaves the garrison its kit,
        // and a won assault keeps its crewed turrets, crews and all, when the
        // base and the garrison share a home.
        final b = op.base;
        var postTurrets = 0;
        if (b != null && b.standing && !b.overrun) {
          for (var i = 0; i < kBaseGoods.length && i < b.stockC.length; i++) {
            final k = kBaseGoods[i];
            if (stock[k] == null || b.stockC[i] <= 0) continue;
            stock[k] = stock[k]! + b.stockC[i] / 100;
            b.stockC[i] = 0;
          }
          if (op.kind == OperationKind.colonyAssault && b.homeColonyId == garrisonFrom) {
            for (final f in b.turretCrews(op)) {
              if (f.count < kTurretCrew) continue;
              postTurrets++;
              postCrew += f.count;
            }
          }
        }
        g = PortGarrison(
          opId: op.id,
          homeColonyId: garrisonFrom,
          count: garrisonN + postCrew,
          perTrooperDay: upkeep,
          stock: stock,
          occupation: op.kind == OperationKind.colonyAssault,
          turrets: postTurrets,
        );
        // The first run leaves now: the garrison holds with whatever kit the
        // fight left it, often well under a day, and a first run three days
        // out arrived to a garrison already half gone home.
        registry.garrisons.add(GarrisonRecord(
          targetColonyId: target.id,
          homeColonyId: garrisonFrom,
          opId: op.id,
          count: garrisonN + postCrew,
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
    _reportBase(op, target, cities, postCrew: postCrew);
    final dead = op.attackerDead;
    if (dead > 0) {
      for (final c in cities) {
        c.war.inbox.add(WarWearinessWrite(dead * wearinessPerDead));
      }
    }
  }

  /// The base at the end (§7C): its support staff home; what is left struck
  /// and shipped home — or, overrun or abandoned, half the target's.
  void _reportBase(Operation op, CitySim? target, List<CitySim> cities, {int postCrew = 0}) {
    final b = op.base;
    if (b == null) return;
    final home = _find(cities, b.homeColonyId);
    final fighting = op.fromSite(kSupportSite);
    home?.war.inbox.add(TroopersHomeWrite(op.id, kSupportSite,
        alive: b.supportAlive + fighting.alive - postCrew,
        wounded: b.supportWounded + fighting.wounded,
        dead: b.supportDead + fighting.dead));
    // What is still the base's: stock, Materiel unpacked and not, and runs
    // shipped but not yet landed.
    var m = b.materielC + b.palletsC;
    final stock = List<int>.of(b.stockC);
    for (final r in b.runs) {
      if (r.arriveStep < 0) continue;
      m += r.materielC;
      for (var i = 0; i < stock.length; i++) {
        stock[i] += r.stockC[i];
      }
    }
    List<double> d(List<int> c) => [for (final v in c) v / 100];
    if (b.overrun) {
      if (b.capturedMaterielC > 0 || b.capturedStockC.any((v) => v > 0)) {
        target?.war.inbox.add(BaseGoodsWrite(b.capturedMaterielC / 100, d(b.capturedStockC)));
      }
    } else if (op.outcome == OperationOutcome.lost && b.standing) {
      // Abandoned: the target takes half; the rest is lost.
      target?.war.inbox.add(BaseGoodsWrite(m / 200, [for (final v in stock) v / 200]));
    } else {
      home?.war.inbox.add(BaseGoodsWrite(m / 100, d(stock)));
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
