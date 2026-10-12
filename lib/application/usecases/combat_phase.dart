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
import '../../domain/combat/combat_rng.dart';
import '../../domain/combat/formation.dart';
import '../../domain/combat/lander.dart';
import '../../domain/combat/launch/plan_defence.dart';
import '../../domain/combat/launch/plan_operation.dart';
import '../../domain/combat/launch/snapshots.dart';
import '../../domain/combat/operation.dart';
import '../../domain/combat/operation_registry.dart';
import '../../domain/combat/powers/air.dart';
import '../../domain/combat/powers/missile.dart';
import '../../domain/combat/powers/orbital.dart';
import '../../domain/combat/powers/overhead.dart';
import '../../domain/combat/powers/sky.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/terrain/impact_scaling.dart';
import '../../domain/combat/resolver_tuning.dart';
import '../../domain/multiplayer/command.dart';

class CombatPhase {
  CombatPhase(this.registry,
      {this.tuning = const ResolverTuning(), this.landers = false, this.missiles = false});

  final OperationRegistry registry;
  final ResolverTuning tuning;

  /// Fly the squads down as real troop landers where the target's body has
  /// no air (docs/plans/combat.md §7B). Off where no world flies them — a
  /// test of the colonies alone, a host without vessels — and landing is
  /// abstract.
  final bool landers;

  bool _landersFor(CitySim target) => landers && !target.body.hasAtmosphere;

  /// Fly silo salvos as real missiles (combat.md §7O). Off where no world
  /// flies them, and a silo strike is the abstract 60 s one.
  final bool missiles;

  /// Colonies a salvo coming down this close to the centre of are hit by it.
  static const double missileColonyReachM = 5000;

  /// Supply runs to a garrison leave every this many operation days.
  static const double supplyEveryDays = 3;

  /// A supply run's flight, s: fixed, so its arrival never depends on warp.
  static const int supplyTransitS = 60;

  /// Loyalty every colony loses per player trooper killed: 0.01 per 10.
  static const double wearinessPerDead = 0.001;

  /// A rival — an independent colony of at least [raidMinPopulation] — raids
  /// its nearest colonial neighbour once every [raidEveryDays] operation
  /// days, on a day of its own (combat.md §7N).
  static const int raidEveryDays = 10;
  static const double raidMinPopulation = 40;

  /// The rival [colonyId]'s own day in [raidEveryDays]: it raids on the
  /// operation days `d` where `(d + raidPhase) % raidEveryDays == 0`.
  static int raidPhase(String colonyId) =>
      (combatUnit(combatKey(colonyId), 0x52414944, 0) * raidEveryDays).floor();

  int get _dayUs => (tuning.daySec * 1e6).round();

  /// The flying world, read at this tick's end (§7E); null where no world
  /// flies — orbital support then has nothing to see.
  CombatSky? _sky;

  /// One tick of [tickDt] seconds over [cityList].
  void run(double tickDt, Iterable<CitySim> cityList, {CombatSky? sky}) {
    _sky = sky;
    final cities = [...cityList]..sort((a, b) => a.id.compareTo(b.id));
    final opDt = math.min(math.max(0.0, tickDt), 0.5);
    final beforeUs = registry.clockUs;
    registry.clockUs += (opDt * 1e6).round();

    for (final c in registry.inbox.drain()) {
      _apply(c, cities);
    }
    _answerMissiles(cities);
    for (final city in cities) {
      if (city.war.outbox.isEmpty) continue;
      final events = List<CombatEvent>.of(city.war.outbox);
      city.war.outbox.clear();
      for (final e in events) {
        _onEvent(city, e, cities);
      }
    }
    _raids(cities, beforeUs);
    _watchSky(cities);
    // Silo strikes asked for: the lead source pays its missiles (§7M).
    for (final op in registry.operations) {
      final a = op.air;
      final b = op.base;
      if (op.resolved || a.pendingSilo == null || a.siloPosted || b == null) continue;
      a.siloPosted = true;
      _find(cities, b.homeColonyId)?.war.inbox.add(SiloDebitWrite(op.id, a.pendingSilo!, kSiloMissiles));
    }
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

  /// The operation [c] is for, when it names one.
  static int? _opOf(CombatCommand c) => switch (c) {
        WithdrawOperationCommand() => c.operationId,
        OrderOperationCommand() => c.operationId,
        CommanderPowerCommand() => c.operationId,
        ReinforceOperationCommand() => c.operationId,
        BaseOrderCommand() => c.operationId,
        LiveCasualtiesCommand() => c.operationId,
        LiveSquadCommand() => c.operationId,
        SquadOrderCommand() => c.operationId,
        AssignOrbitalSupportCommand() => c.operationId,
        _ => null,
      };

  void _apply(CombatCommand c, List<CitySim> cities) {
    // Authority (§7N): an operation takes orders from its owner only.
    final opId = _opOf(c);
    final owned = opId == null ? null : registry.byId(opId);
    if (owned != null && !owned.ownedBy(c.issuedBy.value)) {
      registry.lastRefusal = 'That operation is not yours to order.';
      return;
    }
    if (owned != null && owned.defensive) {
      registry.lastRefusal = 'Your people are defending: there is nothing to order.';
      return;
    }
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
      case SquadOrderCommand():
        registry.lastRefusal = registry.byId(c.operationId)?.directSquads(c.formationIds, c.target);
      case LiveSquadCommand():
        registry.byId(c.operationId)?.liveSquad(c.formationId, own: c.own, at: c.at);
      case AssignOrbitalSupportCommand():
        registry.lastRefusal = _assign(c, cities);
      case ArmVesselCommand():
        registry.lastRefusal = _arm(c, cities);
      case MissileStrikeCommand():
        registry.lastRefusal = _missileStrike(c, cities);
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

  // ---- silo missiles (§7O) --------------------------------------------------------

  /// A strike on a point: [c]'s colony fires a salvo at it, once it has paid.
  String? _missileStrike(MissileStrikeCommand c, List<CitySim> cities) {
    if (!missiles) return 'Nothing flies here: no missile can be launched.';
    final home = _find(cities, c.colonyId);
    if (home == null) return 'That colony no longer exists.';
    final a = home.loyalty.allegiance;
    if (a != Allegiance.colonial && a != Allegiance.occupied) return '${home.name} takes no orders.';
    if (!home.buildingParcels().any((b) => b.$2.type == 'silo')) return '${home.name} has no Missile Silo.';
    if (home.body.id.value != c.bodyId) return 'A silo strikes only its own world.';
    if (registry.missiles.any((m) => m.homeColonyId == home.id && !m.done)) {
      return '${home.name}\'s silo already has a salvo in hand.';
    }
    final aim = Vector3(c.aim.$1, c.aim.$2, c.aim.$3);
    if (aim.length < 1e-9) return 'A strike on where?';
    final m = MissileShot(
      id: registry.nextMissileId++,
      homeColonyId: home.id,
      bodyId: c.bodyId,
      aimDir: aim.normalized,
      state: MissileState.unpaid,
    );
    registry.missiles.add(m);
    home.war.inbox.add(SiloDebitWrite(-1, 'free:${m.id}', kSiloMissiles));
    return null;
  }

  /// Salvos that landed, or could not fly, answered for (§7O): the battle
  /// they were aimed into, and every colony they came down in.
  void _answerMissiles(List<CitySim> cities) {
    for (final m in [...registry.missiles]) {
      if (m.state == MissileState.failed) {
        final op = m.opId == null ? null : registry.byId(m.opId!);
        if (op != null && m.strikeSeq != null) {
          op.missileLost(m.strikeSeq!, m.why ?? 'the salvo could not fly.');
        } else {
          registry.lastRefusal = 'The missile strike could not fly: ${m.why ?? 'no reason given.'}';
        }
        registry.missiles.remove(m);
        continue;
      }
      if (m.state != MissileState.landed) continue;
      registry.missiles.remove(m);
      final aim = m.aimBF;
      var answered = false;
      if (aim != null) {
        for (final c in cities) {
          if (c.body.id.value != m.bodyId) continue;
          final (e, n) = localOf(c, aim);
          if (e * e + n * n > missileColonyReachM * missileColonyReachM) continue;
          c.war.inbox.add(MissileStrikeWrite(e, n, kMissileBlastM, kMissileDeathShare));
          final running = registry.runningAgainst(c.id);
          if (running == null) continue;
          if (m.opId == running.id && m.strikeSeq != null) {
            running.missileLanded(m.strikeSeq!, e, n);
            answered = true;
          } else {
            running.pointStrike(e, n);
          }
        }
      }
      // Aimed into a battle at a colony no longer there to hit: settled.
      final op = m.opId == null ? null : registry.byId(m.opId!);
      if (!answered && op != null && m.strikeSeq != null) {
        op.missileLost(m.strikeSeq!, 'it came down away from the battle.');
      }
    }
  }

  /// [bf] (body-fixed) in [c]'s local east/north metres: the tangent-plane
  /// projection about its site.
  static (double, double) localOf(CitySim c, Vector3 bf) {
    final lat = c.cityLat * math.pi / 180, lon = c.cityLon * math.pi / 180;
    final east = Vector3(-math.sin(lon), math.cos(lon), 0);
    final up = Vector3(math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat));
    final north = up.cross(east);
    return (bf.dot(east), bf.dot(north));
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
    // The square is 1.2 km: walls within 900 m of an objective cover it.
    for (final f in snap.walls) {
      final near = objs.any((o) {
        final dx = o.e - f.$1, dy = o.n - f.$2;
        return dx * dx + dy * dy < (900 + f.$3) * (900 + f.$3);
      });
      if (near) op.orbital.walls.add(f);
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
    op.ownerId = c.issuedBy.value;
    op.air.rebelSilos = snap.rebelSilos;
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
          if (op.defensive) {
            // A rising ends with the occupation; a raid when its target is
            // no longer the player's, or its rival rejoins (§7N).
            if (op.targetColonyId == city.id) {
              final still = op.kind == OperationKind.uprising
                  ? e.allegiance == Allegiance.occupied
                  : e.allegiance == Allegiance.colonial;
              if (!still) op.endFromOutside(OperationOutcome.overtaken);
            } else if (op.raiderId == city.id && e.allegiance != Allegiance.independent) {
              op.endFromOutside(OperationOutcome.rejoined);
            }
            continue;
          }
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
      case SiloFiredEvent():
        if (e.opId < 0) {
          // A strike on a point (§7O): paid for, or not.
          final id = int.tryParse(e.objectiveId.replaceFirst('free:', ''));
          final m = registry.missiles.where((x) => x.id == id).firstOrNull;
          if (m != null && m.state == MissileState.unpaid) {
            if (e.fired) {
              m.state = MissileState.pending;
            } else {
              m
                ..state = MissileState.failed
                ..why = '${city.name} had not the $kSiloMissiles missiles.';
            }
          }
          break;
        }
        final op = registry.byId(e.opId);
        if (op != null && !op.resolved) {
          final target = _find(cities, op.targetColonyId);
          final flies = missiles && target != null && target.body.id == city.body.id;
          final aim = op.siloFired(e.objectiveId, ok: e.fired, flown: flies);
          if (aim != null && target != null) {
            registry.missiles.add(MissileShot(
              id: registry.nextMissileId++,
              homeColonyId: city.id,
              bodyId: target.body.id.value,
              aimDir: target.localToBodyFixed(Vec2(aim.e, aim.n), bodyRadiusM: target.body.radius).normalized,
              opId: op.id,
              strikeSeq: aim.seq,
            ));
          }
        }
      case ArmedEvent():
        registry.loadRounds(e.vesselId, e.paid, registry.clockUs + kArmLoadS * 1000000);
        if (e.paid < e.asked) {
          registry.lastRefusal = '${city.name} could pay for ${e.paid} of ${e.asked} rounds '
              '($kRoundSteel steel and $kRoundElectronics electronics each).';
        }
      case UprisingEvent():
        _rise(city, e);
      case PlunderedEvent():
        // Ore and rations, in the base goods' order (ammo, guns, rations).
        _find(cities, e.raiderId)?.war.inbox.add(BaseGoodsWrite(e.ore, [0, 0, e.rations]));
      case GarrisonSuppliedEvent():
        if (e.amounts.isNotEmpty) {
          registry.runs.add(SupplyRun(
              e.targetColonyId, e.amounts, registry.clockUs + supplyTransitS * 1000000));
        }
    }
  }

  // ---- defensive operations (§7N) -------------------------------------------------

  /// [city] has risen against its garrison: the rising is fought, once.
  void _rise(CitySim city, UprisingEvent e) {
    final running = registry.runningAgainst(city.id);
    if (running != null) {
      if (running.kind == OperationKind.uprising) city.war.inbox.add(UprisingFoughtWrite(running.id));
      return;
    }
    final planned = planUprising(
      operationId: registry.nextOperationId,
      target: city.launchSnapshot(defence: true),
      garrisonOpId: e.garrisonOpId,
      garrisonHome: e.homeColonyId,
      troopers: e.troopers,
      turrets: e.turrets,
      tuning: tuning,
    );
    final op = planned.operation;
    if (op == null) {
      // Nothing to fight over, or too few to fight: the garrison holds,
      // without a battle (found playing it: a colony of nobody rose every
      // quiet spell, a chip each time).
      city.war.inbox.add(const UprisingEndWrite(held: true, garrisonLost: 0, rebelDead: 0, fizzled: true));
      return;
    }
    registry.nextOperationId++;
    registry.operations.add(op);
    city.war.inbox.add(UprisingFoughtWrite(op.id));
  }

  /// Rivals raid on the day of their own that falls this tick, if one does.
  void _raids(List<CitySim> cities, int beforeUs) {
    final day = registry.clockUs ~/ _dayUs;
    if (day == beforeUs ~/ _dayUs) return;
    for (final r in cities) {
      if (r.loyalty.allegiance != Allegiance.independent || r.population < raidMinPopulation) continue;
      if ((day + raidPhase(r.id)) % raidEveryDays != 0) continue;
      if (registry.operations.any((o) => !o.resolved && o.raiderId == r.id)) continue;
      final target = _nearestColonial(r, cities);
      if (target == null || registry.runningAgainst(target.id) != null) continue;
      final planned = planRaid(
        operationId: registry.nextOperationId,
        target: target.launchSnapshot(defence: true),
        raider: r.launchSnapshot(),
        tuning: tuning,
      );
      final op = planned.operation;
      if (op == null) continue;
      registry.nextOperationId++;
      registry.operations.add(op);
    }
  }

  /// [r]'s nearest colonial neighbour on its own body, ties by id.
  CitySim? _nearestColonial(CitySim r, List<CitySim> cities) {
    final radius = r.body.radius;
    final at = r.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: radius);
    CitySim? best;
    var bestD = double.infinity;
    for (final c in cities) {
      if (c.id == r.id || c.body.id != r.body.id) continue;
      if (c.loyalty.allegiance != Allegiance.colonial) continue;
      final p = c.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: radius);
      final dx = p.x - at.x, dy = p.y - at.y, dz = p.z - at.z;
      final d = dx * dx + dy * dy + dz * dz;
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  /// A rising or a raid at its end: each side's dead to its home, and the
  /// colony told how it went.
  void _reportDefence(Operation op, List<CitySim> cities) {
    final target = _find(cities, op.targetColonyId);
    final taken = op.outcome == OperationOutcome.won;
    switch (op.kind) {
      case OperationKind.uprising:
        var dead = 0, wounded = 0;
        String? home;
        for (final f in op.formations) {
          if (f.side != CombatSide.defender) continue;
          dead += f.dead;
          wounded += f.wounded;
          home ??= f.homeColonyId;
        }
        final gOp = op.garrisonOpId;
        final lost = dead + wounded;
        if (home != null && gOp != null && lost > 0) {
          // Under the garrison's own operation, whose members they are.
          _find(cities, home)
              ?.war
              .inbox
              .add(TroopersHomeWrite(gOp, null, alive: 0, wounded: wounded, dead: dead));
          for (final g in registry.garrisons) {
            if (g.targetColonyId == op.targetColonyId && g.opId == gOp) g.count -= lost;
          }
          registry.garrisons.removeWhere((g) => g.count <= 0);
        }
        target?.war.inbox
            .add(UprisingEndWrite(held: !taken, garrisonLost: lost, rebelDead: op.attackerDead));
        if (dead > 0) {
          for (final c in cities) {
            c.war.inbox.add(WarWearinessWrite(dead * wearinessPerDead));
          }
        }
      case OperationKind.raid:
        final id = op.raiderId ?? '';
        final raider = _find(cities, id);
        final decided = taken ||
            op.outcome == OperationOutcome.lost ||
            op.outcome == OperationOutcome.ceasefire;
        if (decided || op.defenderDead > 0) {
          target?.war.inbox.add(RaidEndWrite(id, raider?.name ?? id, raided: taken, dead: op.defenderDead));
        }
        if (raider != null && op.attackerDead > 0) {
          raider.war.inbox.add(TroopersHomeWrite(op.id, null, alive: 0, wounded: 0, dead: op.attackerDead));
        }
      case OperationKind.portRetake:
      case OperationKind.colonyAssault:
        break;
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
    if (op.defensive) return;
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
    if (op.defensive) {
      _reportDefence(op, cities);
      return;
    }
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
    // Heavy rules raze what was fought over (§7L).
    final razed = op.razedSites;
    if (target != null && razed.isNotEmpty) target.war.inbox.add(WarRazeWrite(razed));
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
