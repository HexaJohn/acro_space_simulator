// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The forward base (docs/plans/combat.md §7C): operation state, never a
/// colony building.
///
/// It stands at the operation's landing zone. Its core deploys once the
/// squads are down, and from then on it steps with the battle, in the same 1 s
/// steps on the same clock: Materiel unpacked from pallets, power shared out,
/// one build line worked, turrets fed, the squads near it resupplied, supply
/// runs asked for and landed. What it builds comes from what was shipped — ore
/// from the lead source colony, the support staff who crew it, their kit — and
/// what is left goes home when the operation ends. An unwatched operation
/// builds the same base a watched one does: the doctrine is the truth when
/// nobody is looking, and the player's orders go ahead of it.
library;

import '../formation.dart';
import '../objective.dart';
import '../operation.dart';
import 'base_modules.dart';

/// A built module in a socket.
class BaseModule {
  BaseModule({required this.kind, required this.socket, this.crew = 0, this.formationId});

  final ModuleKind kind;

  /// Its index in its ring ([ModuleSpec.socket]).
  final int socket;

  /// Support staff working it.
  int crew;

  /// A turret's emplacement formation.
  int? formationId;

  ModuleSpec get spec => moduleSpec(kind);
  bool get crewed => crew >= spec.crew;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'socket': socket,
        if (crew != 0) 'crew': crew,
        if (formationId != null) 'f': formationId,
      };

  factory BaseModule.fromJson(Map<String, dynamic> j) => BaseModule(
        kind: ModuleKind.values.byName(j['kind'] as String),
        socket: (j['socket'] as num).toInt(),
        crew: (j['crew'] as num?)?.toInt() ?? 0,
        formationId: (j['f'] as num?)?.toInt(),
      );
}

/// A build under way on the line.
class BuildJob {
  BuildJob(this.kind, this.socket, this.remainingS, this.paidC);
  final ModuleKind kind;
  final int socket;
  int remainingS;

  /// What was paid for it, centi-units: half comes back if it is cancelled.
  final int paidC;

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'socket': socket, 'left': remainingS, 'paid': paidC};
  factory BuildJob.fromJson(Map<String, dynamic> j) => BuildJob(
        ModuleKind.values.byName(j['kind'] as String),
        (j['socket'] as num).toInt(),
        (j['left'] as num).toInt(),
        (j['paid'] as num).toInt(),
      );
}

/// A supply run asked for: posted to the lead source, then landing.
class BaseRun {
  BaseRun({
    required this.id,
    required this.materielC,
    required this.stockC,
    this.posted = false,
    this.arriveStep = -1,
  });
  final int id;

  /// What was asked for, then — once the source answers — what it shipped.
  int materielC;
  final List<int> stockC; // in [kBaseStock] order
  bool posted;

  /// When it lands; −1 until the source has shipped it.
  int arriveStep;

  Map<String, dynamic> toJson() => {
        'id': id,
        'm': materielC,
        'stock': List<int>.of(stockC),
        if (posted) 'posted': true,
        if (arriveStep >= 0) 'at': arriveStep,
      };
  factory BaseRun.fromJson(Map<String, dynamic> j) => BaseRun(
        id: (j['id'] as num).toInt(),
        materielC: (j['m'] as num).toInt(),
        stockC: [for (final v in (j['stock'] as List)) (v as num).toInt()],
        posted: j['posted'] == true,
        arriveStep: (j['at'] as num?)?.toInt() ?? -1,
      );
}

/// A player's order, waiting for the line.
class BuildOrder {
  const BuildOrder(this.kind, this.socket);
  final ModuleKind kind;
  final int socket;
  Map<String, dynamic> toJson() => {'kind': kind.name, 'socket': socket};
  factory BuildOrder.fromJson(Map<String, dynamic> j) =>
      BuildOrder(ModuleKind.values.byName(j['kind'] as String), (j['socket'] as num).toInt());
}

/// What the base did, for the drawer and the notices.
enum BaseEventKind { deployed, built, overrun, coreLost }

class ForwardBase {
  ForwardBase({
    required this.homeColonyId,
    required this.materielC,
    required this.palletsC,
    required this.support,
    required this.stockC,
    required this.gates,
    int? reserve,
    this.deployed = false,
    this.deployAtStep = -1,
    this.lost = false,
    this.overrun = false,
    this.supportDead = 0,
    this.supportWounded = 0,
    this.overrunHeldS = 0,
    this.nextRunStep = -1,
    this.nextRunId = 1,
    this.capturedMaterielC = 0,
    List<int>? capturedStockC,
    this.resupplyCarry = 0,
  })  : reserve = reserve ?? support,
        capturedStockC = capturedStockC ?? List<int>.filled(kBaseStock.length, 0);

  /// The lead source: Materiel, support staff and supply runs come from it,
  /// and what is left goes home to it.
  final String homeColonyId;

  int materielC;
  int palletsC;

  /// Support staff shipped, and the unassigned of them: the LZ reserve.
  final int support;
  int reserve;
  int supportDead;
  int supportWounded;

  /// Ammo, guns, rations, in [kBaseStock] order, centi-units.
  final List<int> stockC;

  /// The source buildings the modules' home gates read, at launch.
  final List<String> gates;

  bool deployed;

  /// When the core deploys: −1 until the squads are down.
  int deployAtStep;

  /// The core was lost with its lander; the operation fights base-less.
  bool lost;

  /// Overrun: everything at the LZ lost.
  bool overrun;
  int overrunHeldS;

  final List<BaseModule> modules = [];
  BuildJob? job;
  final List<BuildOrder> queue = [];

  int nextRunStep;
  int nextRunId;
  final List<BaseRun> runs = [];

  /// Half of an overrun base's stock, the target's to take at the end.
  int capturedMaterielC;
  final List<int> capturedStockC;

  /// Fractional resupply carried between steps, in kit-member-seconds.
  double resupplyCarry;

  /// The preview has no colony to ask: its runs land as asked.
  bool autoShip = false;

  /// Things that happened, newest last, for the host to announce (not saved).
  final List<(BaseEventKind, String)> events = [];

  bool get standing => deployed && !lost && !overrun;

  int stockOf(String k) => stockC[kBaseStock.indexOf(k)];

  /// Takes up to [c] of [k]; returns what it got.
  int _take(String k, int c) {
    final i = kBaseStock.indexOf(k);
    final got = c < stockC[i] ? c : stockC[i];
    stockC[i] -= got;
    return got;
  }

  bool hasGate(String? g) => g == null || gates.contains(g);

  int countOf(ModuleKind k) {
    var n = 0;
    for (final m in modules) {
      if (m.kind == k) n++;
    }
    if (job?.kind == k) n++;
    return n;
  }

  int socketsOf(SocketKind s) =>
      s == SocketKind.module ? kFirebaseModuleSockets : kFirebaseTurretSockets;

  bool socketFree(SocketKind s, int socket) {
    if (socket < 0 || socket >= socketsOf(s)) return false;
    for (final m in modules) {
      if (m.spec.socket == s && m.socket == socket) return false;
    }
    final j = job;
    if (j != null && moduleSpec(j.kind).socket == s && j.socket == socket) return false;
    return true;
  }

  int? firstFree(SocketKind s) {
    for (var i = 0; i < socketsOf(s); i++) {
      if (socketFree(s, i)) return i;
    }
    return null;
  }

  int get crewAssigned {
    var n = 0;
    for (final m in modules) {
      n += m.crew;
    }
    return n;
  }

  double get powerSupply => standing ? kCorePowerKw : 0;

  double get powerDemand {
    var d = 0.0;
    for (final m in modules) {
      if (m.crewed) d += m.spec.powerKw;
    }
    return d;
  }

  /// What every running module runs at: supply over demand, in 64ths.
  double get powerRatio {
    final d = powerDemand;
    if (d <= 0) return 1;
    final r = powerSupply / d;
    return r >= 1 ? 1 : (r * 64).floor() / 64;
  }

  int get padsOnline {
    var n = 0;
    for (final m in modules) {
      if (m.kind == ModuleKind.supplyPad && m.crewed) n++;
    }
    return n;
  }

  bool get podOnline =>
      modules.any((m) => m.kind == ModuleKind.barracksPod && m.crewed);

  /// The LZ's extra attacker fortification from the base: the core, and each
  /// turret standing there.
  double fAttBonus(String objectiveId, String lzId) {
    if (!standing || objectiveId != lzId) return 0;
    var b = kCoreFortification;
    for (final m in modules) {
      if (m.kind == ModuleKind.turret) b += kTurretFortification;
    }
    return b;
  }

  /// The LZ's value to a defender: a grown base is worth raiding.
  double lzValue() => 1 + 0.15 * modules.length;

  /// Unpack rate, centi-units a second.
  int get unpackC =>
      ((kCoreUnpackC + kPadUnpackC * padsOnline) * powerRatio).floor();

  /// The supply-run interval, steps.
  int runIntervalS(double daySec) {
    final pads = padsOnline > 2 ? 2 : padsOnline;
    return (kRunIntervalDays * daySec / (1 + 0.5 * pads)).round();
  }

  // ---- orders --------------------------------------------------------------

  /// Why [kind] cannot be ordered into [socket] now, or null.
  String? whyNot(ModuleKind kind, int socket) {
    final s = moduleSpec(kind);
    if (!standing) return lost || overrun ? 'The base is gone.' : 'The base has not deployed.';
    if (!hasGate(s.gate)) return '${s.label} needs a source colony with ${_gateLabel(s.gate!)}.';
    if (countOf(kind) >= s.max) return 'The base has all the ${s.label.toLowerCase()}s it can use.';
    if (!socketFree(s.socket, socket)) return 'That socket is taken.';
    return null;
  }

  static String _gateLabel(String g) => switch (g) {
        'spaceport' => 'a Spaceport',
        'gunfactory' => 'an Arms Factory',
        'barracks' => 'a Barracks',
        _ => g,
      };

  /// The player orders [kind] built in [socket]: it goes ahead of the
  /// doctrine, on the next free line.
  bool orderBuild(ModuleKind kind, int socket) {
    if (whyNot(kind, socket) != null) return false;
    for (final o in queue) {
      if (moduleSpec(o.kind).socket == moduleSpec(kind).socket && o.socket == socket) return false;
    }
    queue.add(BuildOrder(kind, socket));
    return true;
  }

  /// Cancels the build under way: half its Materiel comes back.
  void cancelJob() {
    final j = job;
    if (j == null) return;
    materielC += j.paidC ~/ 2;
    job = null;
  }

  /// Demolishes the module in [socket] of ring [s]: half its Materiel back,
  /// its crew to the reserve. The landing turret (turret socket 0) is the
  /// core's and stays.
  void demolish(Operation op, SocketKind s, int socket) {
    if (s == SocketKind.turret && socket == 0) return;
    final i = modules.indexWhere((m) => m.spec.socket == s && m.socket == socket);
    if (i < 0) return;
    final m = modules.removeAt(i);
    materielC += m.spec.materiel * 50;
    _releaseCrew(op, m);
  }

  /// Forms up to 8 of the LZ reserve into a squad: support staff given a gun
  /// each from the base's stock, at quality 0.7. Needs a barracks pod.
  int formSquad(Operation op) {
    if (!standing || !podOnline) return 0;
    var n = reserve < 8 ? reserve : 8;
    final guns = stockOf('guns') ~/ 100;
    if (guns < n) n = guns;
    if (n <= 0) return 0;
    reserve -= n;
    _take('guns', n * 100);
    op.addAttacker(Formation(
      id: op.nextFormationId,
      side: CombatSide.attacker,
      faction: Factions.player,
      kind: FormationKind.infantry,
      count: n,
      quality: 0.7,
      morale: 0.7,
      kitDays: 1,
      at: op.lzId,
      arriveStep: op.clock.steps,
      homeColonyId: homeColonyId,
      homeSiteId: 'support',
    ));
    return n;
  }

  // ---- the step --------------------------------------------------------------

  /// One operation step. Called while the operation is engaged (and in the
  /// crossing, so a core that lands with the first lander deploys on time).
  void step(Operation op, int t) {
    if (lost || overrun) return;
    if (!deployed) {
      if (deployAtStep < 0 || t < deployAtStep) return;
      _deploy(op, t);
    }
    // Runs that have landed.
    for (final r in runs) {
      if (r.arriveStep >= 0 && t >= r.arriveStep) {
        palletsC += r.materielC;
        for (var i = 0; i < kBaseStock.length; i++) {
          stockC[i] += r.stockC[i];
        }
        r.arriveStep = -2; // landed
      }
    }
    runs.removeWhere((r) => r.arriveStep == -2);
    // Unpack.
    if (palletsC > 0) {
      final u = unpackC < palletsC ? unpackC : palletsC;
      palletsC -= u;
      materielC += u;
    }
    _crew();
    _line(op, t);
    _turrets(op, t);
    _resupply(op, t);
    _askForRuns(op, t);
    _overrunCheck(op);
  }

  void _deploy(Operation op, int t) {
    deployed = true;
    // The landing turret rides in the core: online at once if crewed.
    final m = BaseModule(kind: ModuleKind.turret, socket: 0);
    modules.add(m);
    _crew();
    _turretFormation(op, m, t);
    nextRunStep = t + runIntervalS(op.tuning.daySec);
    events.add((BaseEventKind.deployed, 'The base core is down and the landing turret is up.'));
  }

  /// Hands the reserve out to modules short of crew, in socket order.
  void _crew() {
    for (final m in modules) {
      if (reserve <= 0) return;
      final need = m.spec.crew - m.crew;
      if (need <= 0) continue;
      final give = need < reserve ? need : reserve;
      m.crew += give;
      reserve -= give;
    }
  }

  void _releaseCrew(Operation op, BaseModule m) {
    final fid = m.formationId;
    if (fid != null) {
      final f = op.formationById(fid);
      if (f != null) {
        reserve += f.count;
        f.count = 0;
      }
    } else {
      reserve += m.crew;
    }
    m.crew = 0;
  }

  void _turretFormation(Operation op, BaseModule m, int t) {
    if (m.kind != ModuleKind.turret || m.formationId != null) return;
    final f = Formation(
      id: op.nextFormationId,
      side: CombatSide.attacker,
      faction: Factions.player,
      kind: FormationKind.emplacement,
      counterClass: CounterClass.empHmg,
      count: m.crew,
      quality: 0.8,
      morale: 0.8,
      kitDays: stockOf('ammo') > 0 ? 3 : 0,
      at: op.lzId,
      arriveStep: t,
      homeColonyId: homeColonyId,
      homeSiteId: 'support',
    );
    op.addAttacker(f);
    m.formationId = f.id;
    // The crew are the formation's members now, not the module's.
  }

  void _line(Operation op, int t) {
    final j = job;
    if (j != null) {
      j.remainingS -= 1;
      if (j.remainingS > 0) return;
      job = null;
      final m = BaseModule(kind: j.kind, socket: j.socket);
      modules.add(m);
      _crew();
      if (m.kind == ModuleKind.turret) _turretFormation(op, m, t);
      events.add((BaseEventKind.built, '${m.spec.label} built.'));
      return;
    }
    // A player's order first, then the doctrine.
    BuildOrder? next;
    var fromQueue = false;
    while (queue.isNotEmpty && next == null) {
      final o = queue.removeAt(0);
      if (whyNot(o.kind, o.socket) == null) {
        next = o;
        fromQueue = true;
      }
    }
    if (next == null && autoBuild) next = _doctrinePick();
    if (next == null) return;
    final s = moduleSpec(next.kind);
    final cost = s.materiel * 100;
    if (materielC < cost) {
      // Waits for Materiel: a player's order keeps its place at the head of
      // the queue; the doctrine simply asks again next step.
      if (fromQueue) queue.insert(0, next);
      return;
    }
    materielC -= cost;
    job = BuildJob(next.kind, next.socket, s.buildS, cost);
  }

  /// The doctrine builds when nobody orders (Manual turns it off, 1b-ii).
  bool autoBuild = true;

  /// The Balanced doctrine (1b-i): pad, pod, turret, a second pad — each when
  /// its gate, a socket, crew and power allow.
  BuildOrder? _doctrinePick() {
    // The landing turret is the first turret the list counts.
    final seen = <ModuleKind>[ModuleKind.turret];
    for (final k in kBalanced) {
      seen.add(k);
      final s = moduleSpec(k);
      if (!hasGate(s.gate) || countOf(k) >= s.max) continue;
      // The n-th mention of a kind is done once the base has n of it.
      if (countOf(k) >= seen.where((x) => x == k).length) continue;
      final socket = firstFree(s.socket);
      if (socket == null) continue;
      // Crew it can have, after the modules already standing.
      if (reserve < s.crew) continue;
      // Power: never push demand past what the core makes.
      if (powerDemand + s.powerKw > powerSupply + 1e-9) continue;
      return BuildOrder(k, socket);
    }
    return null;
  }

  /// The Balanced doctrine's list (1b-i), after the landing turret.
  static const List<ModuleKind> kBalanced = [
    ModuleKind.supplyPad,
    ModuleKind.barracksPod,
    ModuleKind.turret,
    ModuleKind.supplyPad,
  ];

  void _turrets(Operation op, int t) {
    final r = powerRatio;
    final lz = op.graph.byId(op.lzId);
    final engaged = lz != null &&
        op.formations.any((f) => f.side == CombatSide.defender && f.presentAt(lz.id, t));
    for (final m in modules) {
      if (m.kind != ModuleKind.turret) continue;
      final f = m.formationId == null ? null : op.formationById(m.formationId!);
      if (f == null) continue;
      if (!f.alive) continue;
      final burn = ((engaged ? kTurretAmmoEngaged : kTurretAmmoIdle) * f.count / 2 * 100).round();
      final got = _take('ammo', burn);
      // Out of ammo (or power): it fights at the no-ammo factor.
      f.kitDays = (got >= burn && r >= 0.35) ? 3 : 0;
      // Turrets never move and never rout off their guns.
      if (f.broken) f.broken = false;
    }
  }

  /// Squads at the LZ, or one link from it, refill kit toward three days.
  void _resupply(Operation op, int t) {
    final rations = stockOf('rations'), ammo = stockOf('ammo');
    if (rations <= 0 || ammo <= 0) return;
    for (final f in op.formations) {
      if (f.side != CombatSide.attacker || !f.alive) continue;
      if (f.kind == FormationKind.emplacement) continue;
      if (f.kitDays >= kResupplyToDays) continue;
      if (!f.presentAt(f.at, t)) continue;
      final near = f.at == op.lzId || op.graph.linked(f.at, op.lzId);
      if (!near) continue;
      final day = 1 / kResupplyDayS; // kit days this second
      final cR = (kRationsPerDay * day * f.count * 100).ceil();
      final cA = (kAmmoPerDay * day * f.count * 100).ceil();
      if (stockOf('rations') < cR || stockOf('ammo') < cA) return;
      _take('rations', cR);
      _take('ammo', cA);
      f.kitDays = (f.kitDays + day) > kResupplyToDays ? kResupplyToDays : f.kitDays + day;
    }
  }

  void _askForRuns(Operation op, int t) {
    if (nextRunStep < 0 || t < nextRunStep) return;
    nextRunStep = t + runIntervalS(op.tuning.daySec);
    // Kit for everyone ashore until the next run.
    var people = reserve + crewAssigned;
    for (final f in op.formations) {
      if (f.side == CombatSide.attacker && f.alive) people += f.count;
    }
    final days = runIntervalS(op.tuning.daySec) / op.tuning.daySec;
    final run = BaseRun(
      id: nextRunId++,
      materielC: kRunMateriel * 100,
      stockC: [
        (kAmmoPerDay * people * days * 100).round(),
        0,
        (kRationsPerDay * people * days * 100).round(),
      ],
    );
    if (autoShip) {
      run
        ..posted = true
        ..arriveStep = t + op.reinforcementDelaySteps;
    }
    runs.add(run);
  }

  /// The lead source answered run [id] with what it had: it lands
  /// [transitS] from [now].
  void runShipped(int id, int materielC, List<int> stockC, int arriveStep) {
    for (final r in runs) {
      if (r.id != id) continue;
      r.materielC = materielC;
      for (var i = 0; i < kBaseStock.length; i++) {
        r.stockC[i] = stockC[i];
      }
      r.arriveStep = arriveStep;
    }
  }

  void _overrunCheck(Operation op) {
    final lz = op.graph.byId(op.lzId);
    if (lz == null) return;
    overrunHeldS = lz.control <= -0.9 ? overrunHeldS + 1 : 0;
    if (overrunHeldS < 60) return;
    overrun = true;
    job = null;
    queue.clear();
    for (final m in modules) {
      final fid = m.formationId;
      if (fid != null) {
        final f = op.formationById(fid);
        if (f != null) f.removeMembers(f.count);
      } else {
        _lose(m.crew);
      }
      m.crew = 0;
    }
    modules.clear();
    _lose(reserve);
    reserve = 0;
    capturedMaterielC += (materielC + palletsC) ~/ 2;
    materielC = 0;
    palletsC = 0;
    for (var i = 0; i < kBaseStock.length; i++) {
      capturedStockC[i] += stockC[i] ~/ 2;
      stockC[i] = 0;
    }
    events.add((BaseEventKind.overrun, 'The base has been overrun.'));
  }

  /// [n] support staff lost: half dead, half wounded.
  void _lose(int n) {
    if (n <= 0) return;
    final dead = (n + 1) ~/ 2;
    supportDead += dead;
    supportWounded += n - dead;
  }

  /// The core went down with its lander.
  void loseCore() {
    if (deployed || lost) return;
    lost = true;
    _lose(reserve);
    reserve = 0;
    events.add((BaseEventKind.coreLost, 'The base core was lost with its lander.'));
  }

  /// Support staff alive and well at the end: the reserve and the crews of
  /// modules that are not formations (a turret's crew are its members).
  int get supportAlive {
    var n = reserve;
    for (final m in modules) {
      if (m.formationId == null) n += m.crew;
    }
    return n;
  }

  // ---- persistence -----------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'home': homeColonyId,
        'm': materielC,
        if (palletsC != 0) 'pallets': palletsC,
        'support': support,
        'reserve': reserve,
        if (supportDead != 0) 'sDead': supportDead,
        if (supportWounded != 0) 'sWounded': supportWounded,
        'stock': List<int>.of(stockC),
        'gates': List<String>.of(gates),
        if (deployed) 'deployed': true,
        if (deployAtStep >= 0) 'deployAt': deployAtStep,
        if (lost) 'lost': true,
        if (overrun) 'overrun': true,
        if (overrunHeldS != 0) 'overrunHeld': overrunHeldS,
        if (modules.isNotEmpty) 'modules': [for (final m in modules) m.toJson()],
        if (job != null) 'job': job!.toJson(),
        if (queue.isNotEmpty) 'queue': [for (final o in queue) o.toJson()],
        if (nextRunStep >= 0) 'nextRun': nextRunStep,
        'nextRunId': nextRunId,
        if (runs.isNotEmpty) 'runs': [for (final r in runs) r.toJson()],
        if (capturedMaterielC != 0) 'capM': capturedMaterielC,
        if (capturedStockC.any((v) => v != 0)) 'capStock': List<int>.of(capturedStockC),
        if (resupplyCarry != 0) 'carry': resupplyCarry,
      };

  factory ForwardBase.fromJson(Map<String, dynamic> j) {
    final b = ForwardBase(
      homeColonyId: j['home'] as String,
      materielC: (j['m'] as num).toInt(),
      palletsC: (j['pallets'] as num?)?.toInt() ?? 0,
      support: (j['support'] as num).toInt(),
      reserve: (j['reserve'] as num).toInt(),
      supportDead: (j['sDead'] as num?)?.toInt() ?? 0,
      supportWounded: (j['sWounded'] as num?)?.toInt() ?? 0,
      stockC: [for (final v in (j['stock'] as List)) (v as num).toInt()],
      gates: [for (final g in (j['gates'] as List)) g as String],
      deployed: j['deployed'] == true,
      deployAtStep: (j['deployAt'] as num?)?.toInt() ?? -1,
      lost: j['lost'] == true,
      overrun: j['overrun'] == true,
      overrunHeldS: (j['overrunHeld'] as num?)?.toInt() ?? 0,
      nextRunStep: (j['nextRun'] as num?)?.toInt() ?? -1,
      nextRunId: (j['nextRunId'] as num?)?.toInt() ?? 1,
      capturedMaterielC: (j['capM'] as num?)?.toInt() ?? 0,
      capturedStockC: j['capStock'] == null
          ? null
          : [for (final v in (j['capStock'] as List)) (v as num).toInt()],
      resupplyCarry: (j['carry'] as num?)?.toDouble() ?? 0,
    );
    for (final m in (j['modules'] as List? ?? const [])) {
      b.modules.add(BaseModule.fromJson((m as Map).cast<String, dynamic>()));
    }
    final job = j['job'];
    if (job is Map) b.job = BuildJob.fromJson(job.cast<String, dynamic>());
    for (final o in (j['queue'] as List? ?? const [])) {
      b.queue.add(BuildOrder.fromJson((o as Map).cast<String, dynamic>()));
    }
    for (final r in (j['runs'] as List? ?? const [])) {
      b.runs.add(BaseRun.fromJson((r as Map).cast<String, dynamic>()));
    }
    return b;
  }

  /// Labels for the drawer.
  static String socketLabel(SocketKind s, int i) =>
      s == SocketKind.module ? 'Module ${i + 1}' : (i == 0 ? 'Landing turret' : 'Turret ${i + 1}');
}

/// The base's line on an [Objective]: whether [objectiveId] is one link from
/// [lzId] (for resupply).
extension ObjectiveGraphLinks on ObjectiveGraph {
  bool linked(String a, String b) {
    for (final l in links) {
      if ((l.a == a && l.b == b) || (l.a == b && l.b == a)) return true;
    }
    return false;
  }
}
