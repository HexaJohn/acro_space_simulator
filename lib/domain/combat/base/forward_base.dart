// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The forward base (docs/plans/combat.md §7C, §7D): operation state, never a
/// colony building.
///
/// It stands at the operation's landing zone, and from 1b-ii also at
/// outposts beside objectives the attacker holds. Its core deploys once the
/// squads are down, and from then on it steps with the battle, in the same
/// 1 s steps on the same clock: Materiel unpacked from pallets, power shared
/// out, its lines worked, turrets fed, the workshop and hospital run, the
/// squads near it resupplied, supply runs asked for and landed. What it
/// builds comes from what was shipped — ore from the lead source colony, the
/// support staff who crew it, their kit — and what is left goes home when the
/// operation ends. An unwatched operation builds the same base a watched one
/// does: the doctrine is the truth when nobody is looking, and the player's
/// orders go ahead of it.
library;

import '../formation.dart';
import '../objective.dart';
import '../operation.dart';
import 'base_modules.dart';

/// A built module in a socket of a site.
class BaseModule {
  BaseModule({required this.kind, required this.socket, this.crew = 0, this.formationId});

  final ModuleKind kind;

  /// Its index in its ring ([ModuleSpec.socket]).
  final int socket;

  /// Support staff working it (a turret's crew are its formation's members).
  int crew;

  /// A turret's emplacement formation.
  int? formationId;

  ModuleSpec get spec => moduleSpec(kind);
  bool get crewed => formationId != null || crew >= spec.crew;

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

/// Work on a line: a module, a tier upgrade, or an outpost's opening.
class BuildJob {
  BuildJob({
    this.kind,
    this.upgrade,
    this.outpostAt,
    this.socket = 0,
    required this.remainingS,
    required this.paidC,
    this.paidSteelC = 0,
  });
  final ModuleKind? kind;
  final BaseTier? upgrade;

  /// The objective an outpost is opening beside.
  final String? outpostAt;
  final int socket;
  int remainingS;

  /// What was paid, centi-units: half comes back if it is cancelled.
  final int paidC;
  final int paidSteelC;

  String get label => kind != null
      ? moduleSpec(kind!).label
      : (upgrade != null ? '${tierSpec(upgrade!).label} upgrade' : 'Outpost');

  Map<String, dynamic> toJson() => {
        if (kind != null) 'kind': kind!.name,
        if (upgrade != null) 'upgrade': upgrade!.name,
        if (outpostAt != null) 'outpost': outpostAt,
        'socket': socket,
        'left': remainingS,
        'paid': paidC,
        if (paidSteelC != 0) 'paidSteel': paidSteelC,
      };
  factory BuildJob.fromJson(Map<String, dynamic> j) => BuildJob(
        kind: j['kind'] == null ? null : ModuleKind.values.byName(j['kind'] as String),
        upgrade: j['upgrade'] == null ? null : BaseTier.values.byName(j['upgrade'] as String),
        outpostAt: j['outpost'] as String?,
        socket: (j['socket'] as num?)?.toInt() ?? 0,
        remainingS: (j['left'] as num).toInt(),
        paidC: (j['paid'] as num).toInt(),
        paidSteelC: (j['paidSteel'] as num?)?.toInt() ?? 0,
      );
}

/// One place the base stands: the core's at the LZ, or an outpost.
class BaseSite {
  BaseSite({
    required this.objectiveId,
    this.outpost = false,
    this.tier = BaseTier.firebase,
    this.razeHeldS = 0,
    this.razed = false,
    List<BuildJob?>? lines,
    List<int>? blockedModules,
    List<int>? blockedTurrets,
  })  : lines = lines ?? [null],
        blockedModules = blockedModules ?? [],
        blockedTurrets = blockedTurrets ?? [];

  final String objectiveId;
  final bool outpost;
  BaseTier tier;
  final List<BaseModule> modules = [];

  /// Its build lines, each idle (null) or working.
  final List<BuildJob?> lines;
  int razeHeldS;
  bool razed;

  /// Socket indices with no room on the ground (the layout, §7D).
  final List<int> blockedModules;
  final List<int> blockedTurrets;

  bool blocked(SocketKind s, int i) =>
      (s == SocketKind.module ? blockedModules : blockedTurrets).contains(i);

  int get moduleSockets => outpost ? kOutpostModuleSockets : tierSpec(tier).moduleSockets;
  int get turretSockets => outpost ? kOutpostTurretSockets : tierSpec(tier).turretSockets;
  int socketsOf(SocketKind s) => s == SocketKind.module ? moduleSockets : turretSockets;
  int get lineCount => outpost ? 1 : tierSpec(tier).lines;

  /// Grows the lines to the tier's count.
  void fitLines() {
    while (lines.length < lineCount) {
      lines.add(null);
    }
  }

  Map<String, dynamic> toJson() => {
        'at': objectiveId,
        if (outpost) 'outpost': true,
        if (tier != BaseTier.firebase) 'tier': tier.name,
        if (modules.isNotEmpty) 'modules': [for (final m in modules) m.toJson()],
        'lines': [for (final l in lines) l?.toJson()],
        if (razeHeldS != 0) 'razeHeld': razeHeldS,
        if (razed) 'razed': true,
        if (blockedModules.isNotEmpty) 'blockedM': List<int>.of(blockedModules),
        if (blockedTurrets.isNotEmpty) 'blockedT': List<int>.of(blockedTurrets),
      };

  factory BaseSite.fromJson(Map<String, dynamic> j) {
    final s = BaseSite(
      objectiveId: j['at'] as String,
      outpost: j['outpost'] == true,
      tier: j['tier'] == null ? BaseTier.firebase : BaseTier.values.byName(j['tier'] as String),
      razeHeldS: (j['razeHeld'] as num?)?.toInt() ?? 0,
      razed: j['razed'] == true,
      lines: [
        for (final l in (j['lines'] as List? ?? const [null]))
          l == null ? null : BuildJob.fromJson((l as Map).cast<String, dynamic>())
      ],
      blockedModules: [for (final v in (j['blockedM'] as List? ?? const [])) (v as num).toInt()],
      blockedTurrets: [for (final v in (j['blockedT'] as List? ?? const [])) (v as num).toInt()],
    );
    for (final m in (j['modules'] as List? ?? const [])) {
      s.modules.add(BaseModule.fromJson((m as Map).cast<String, dynamic>()));
    }
    return s;
  }
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
        'stock': _stockJson(stockC),
        if (posted) 'posted': true,
        if (arriveStep >= 0) 'at': arriveStep,
      };
  factory BaseRun.fromJson(Map<String, dynamic> j) => BaseRun(
        id: (j['id'] as num).toInt(),
        materielC: (j['m'] as num).toInt(),
        stockC: _stockRead(j['stock']),
        posted: j['posted'] == true,
        arriveStep: (j['at'] as num?)?.toInt() ?? -1,
      );
}

Map<String, int> _stockJson(List<int> c) => {
      for (var i = 0; i < kBaseStock.length; i++)
        if (c[i] != 0) kBaseStock[i]: c[i],
    };

List<int> _stockRead(Object? j) => [
      for (final k in kBaseStock) j is Map && j[k] is num ? (j[k] as num).toInt() : 0,
    ];

/// A player's order, waiting for a line at [site].
class BuildOrder {
  const BuildOrder({this.site = 0, this.kind, this.socket = 0, this.upgrade, this.outpostAt});
  final int site;
  final ModuleKind? kind;
  final int socket;
  final BaseTier? upgrade;
  final String? outpostAt;
  Map<String, dynamic> toJson() => {
        if (site != 0) 'site': site,
        if (kind != null) 'kind': kind!.name,
        'socket': socket,
        if (upgrade != null) 'upgrade': upgrade!.name,
        if (outpostAt != null) 'outpost': outpostAt,
      };
  factory BuildOrder.fromJson(Map<String, dynamic> j) => BuildOrder(
        site: (j['site'] as num?)?.toInt() ?? 0,
        kind: j['kind'] == null ? null : ModuleKind.values.byName(j['kind'] as String),
        socket: (j['socket'] as num?)?.toInt() ?? 0,
        upgrade: j['upgrade'] == null ? null : BaseTier.values.byName(j['upgrade'] as String),
        outpostAt: j['outpost'] as String?,
      );
}

/// Recovered wounded waiting in the LZ reserve, by where they came from.
class Recovered {
  Recovered(this.home, this.site, this.count);
  final String? home;
  final String? site;
  int count;
  Map<String, dynamic> toJson() =>
      {if (home != null) 'home': home, if (site != null) 'site': site, 'n': count};
  factory Recovered.fromJson(Map<String, dynamic> j) =>
      Recovered(j['home'] as String?, j['site'] as String?, (j['n'] as num).toInt());
}

/// What the base did, for the drawer and the notices.
enum BaseEventKind { deployed, built, overrun, coreLost, razed, outpostOpen, upgraded }

class ForwardBase {
  ForwardBase({
    required this.homeColonyId,
    required this.materielC,
    required this.palletsC,
    required this.support,
    required List<int> stockC,
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
    this.doctrine = Doctrine.balanced,
    this.spareCore = false,
    this.spareAt,
    this.spareDeployAtStep = -1,
    List<BaseSite>? sites,
  })  : reserve = reserve ?? support,
        stockC = _fit(stockC),
        capturedStockC = _fit(capturedStockC ?? const []),
        sites = sites ?? [];

  static List<int> _fit(List<int> c) =>
      [for (var i = 0; i < kBaseStock.length; i++) i < c.length ? c[i] : 0];

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

  /// Wounded the field hospital has recovered, waiting for the pod.
  final List<Recovered> recovered = [];

  /// Each commodity of [kBaseStock], centi-units.
  final List<int> stockC;

  /// The source buildings the home gates read, at launch.
  final List<String> gates;

  bool deployed;

  /// When the core deploys: −1 until the squads are down.
  int deployAtStep;

  /// The core was lost with its lander; the operation fights base-less
  /// unless a spare core is deployed.
  bool lost;

  /// Overrun: everything at the LZ lost.
  bool overrun;
  int overrunHeldS;

  /// The core's site first, then outposts.
  final List<BaseSite> sites;

  final List<BuildOrder> queue = [];

  /// The build list the base follows when nobody orders.
  Doctrine doctrine;

  int nextRunStep;
  int nextRunId;
  final List<BaseRun> runs = [];

  /// Half of an overrun base's stock, the target's to take at the end.
  int capturedMaterielC;
  final List<int> capturedStockC;

  /// A spare core waits aboard the transport (§7D); deployed at [spareAt].
  bool spareCore;
  String? spareAt;
  int spareDeployAtStep;

  /// The preview has no colony to ask: its runs land as asked.
  bool autoShip = false;

  /// The launch layout's blocked sockets for the core's ring (saved until
  /// the core deploys and carries them).
  List<int> layoutBlockedModules = const [];
  List<int> layoutBlockedTurrets = const [];

  /// Things that happened, newest last, for the host to announce (not saved).
  final List<(BaseEventKind, String)> events = [];

  BaseSite? get core => sites.isEmpty ? null : sites.first;

  bool get standing => deployed && !lost && !overrun && core != null;

  int stockOf(String k) => stockC[kBaseStock.indexOf(k)];

  int _take(String k, int c) {
    final i = kBaseStock.indexOf(k);
    final got = c < stockC[i] ? c : stockC[i];
    stockC[i] -= got;
    return got;
  }

  int get storesCount {
    var n = 0;
    for (final s in sites) {
      for (final m in s.modules) {
        if (m.kind == ModuleKind.stores) n++;
      }
    }
    return n;
  }

  /// What a stock (and the unpacked Materiel) holds at most.
  int get capC => kCapC + kStoresCapC * storesCount;

  bool hasGate(String? g) => g == null || gates.contains(g);

  int countOf(ModuleKind k) {
    var n = 0;
    for (final s in sites) {
      for (final m in s.modules) {
        if (m.kind == k) n++;
      }
      for (final l in s.lines) {
        if (l?.kind == k) n++;
      }
    }
    return n;
  }

  /// Every module with its site.
  Iterable<(BaseSite, BaseModule)> get allModules sync* {
    for (final s in sites) {
      for (final m in s.modules) {
        yield (s, m);
      }
    }
  }

  // ---- the core site's sockets (the 1b-i surface, still the common case) ----

  List<BaseModule> get modules => core?.modules ?? const [];
  BuildJob? get job => core == null || core!.lines.isEmpty ? null : core!.lines.first;
  int socketsOf(SocketKind s) => core?.socketsOf(s) ?? 0;
  bool socketFree(SocketKind s, int socket) => _socketFree(0, s, socket);
  int? firstFree(SocketKind s) => _firstFree(0, s);

  bool _socketFree(int site, SocketKind s, int socket) {
    if (site >= sites.length) return false;
    final x = sites[site];
    if (socket < 0 || socket >= x.socketsOf(s)) return false;
    if (x.blocked(s, socket)) return false;
    for (final m in x.modules) {
      if (m.spec.socket == s && m.socket == socket) return false;
    }
    for (final l in x.lines) {
      if (l != null && l.kind != null && moduleSpec(l.kind!).socket == s && l.socket == socket) {
        return false;
      }
    }
    for (final o in queue) {
      if (o.site == site && o.kind != null && moduleSpec(o.kind!).socket == s && o.socket == socket) {
        return false;
      }
    }
    return true;
  }

  int? _firstFree(int site, SocketKind s) {
    if (site >= sites.length) return null;
    for (var i = 0; i < sites[site].socketsOf(s); i++) {
      if (_socketFree(site, s, i)) return i;
    }
    return null;
  }

  int get crewAssigned {
    var n = 0;
    for (final (_, m) in allModules) {
      n += m.crew;
    }
    return n;
  }

  /// Whether a site's modules run: its site standing, and its objective not
  /// held by the defender.
  bool _siteRuns(Operation op, BaseSite s) {
    if (s.razed) return false;
    if (identical(s, core) && !standing) return false;
    final o = op.graph.byId(s.objectiveId);
    return o == null || (s.outpost && !identical(s, core) ? o.control > 0 : o.control >= 0);
  }

  bool _online(Operation op, BaseSite s, BaseModule m) => m.crewed && _siteRuns(op, s);

  /// Power made: the core's, and every running generator with fuel.
  double powerSupplyIn(Operation op) {
    if (!standing) return 0;
    var p = kCorePowerKw;
    for (final (s, m) in allModules) {
      if (m.kind == ModuleKind.generator && _online(op, s, m) && stockOf('fuel') > 0) {
        p += -m.spec.powerKw;
      }
    }
    return p;
  }

  /// Power wanted by every crewed module that draws it.
  double get powerDemand {
    var d = 0.0;
    for (final (_, m) in allModules) {
      if (m.crewed && m.spec.powerKw > 0) d += m.spec.powerKw;
    }
    return d;
  }

  /// For readers without the operation to hand: the core and every crewed
  /// generator, fuel or not.
  double get powerSupply {
    if (!standing) return 0;
    var p = kCorePowerKw;
    for (final (_, m) in allModules) {
      if (m.kind == ModuleKind.generator && m.crewed) p += -m.spec.powerKw;
    }
    return p;
  }

  double _ratio = 1;

  /// What every running module runs at: supply over demand, in 64ths.
  double get powerRatio => _ratio;

  void _power(Operation op) {
    final d = powerDemand;
    if (d <= 0) {
      _ratio = 1;
      return;
    }
    final r = powerSupplyIn(op) / d;
    _ratio = r >= 1 ? 1 : (r * 64).floor() / 64;
  }

  int get padsOnline {
    var n = 0;
    for (final m in modules) {
      if (m.kind == ModuleKind.supplyPad && m.crewed) n++;
    }
    return n;
  }

  bool get podOnline => allModules.any((e) => e.$2.kind == ModuleKind.barracksPod && e.$2.crewed);
  bool get hospitalOnline =>
      allModules.any((e) => e.$2.kind == ModuleKind.fieldHospital && e.$2.crewed);

  /// The extra attacker fortification the base gives at [objectiveId]: the
  /// core, its tier and turrets at the LZ; an outpost and its turret beside
  /// an objective.
  double fAttBonus(String objectiveId, String lzId) {
    var b = 0.0;
    for (final s in sites) {
      if (s.objectiveId != objectiveId || s.razed) continue;
      if (identical(s, core)) {
        if (!standing) continue;
        b += kCoreFortification + (s.outpost ? 0 : tierSpec(s.tier).fortification);
      } else if (s.modules.isNotEmpty) {
        b += kOutpostFortification;
      }
      for (final m in s.modules) {
        if (m.kind == ModuleKind.turret) b += kTurretFortification;
      }
    }
    return b;
  }

  /// The LZ's value to a defender: a grown base is worth raiding.
  double lzValue() => 1 + 0.15 * modules.length + 0.25 * (core?.tier.index ?? 0);

  /// What an outpost adds to its objective's value to the defender.
  double valueBonus(String objectiveId) {
    var v = 0.0;
    for (final s in sites) {
      if (s.outpost && !s.razed && s.objectiveId == objectiveId) v += 0.25 * s.modules.length;
    }
    return v;
  }

  /// Unpack rate, centi-units a second.
  int get unpackC => ((kCoreUnpackC + kPadUnpackC * padsOnline) * powerRatio).floor();

  /// The supply-run interval, steps.
  int runIntervalS(double daySec) {
    final pads = padsOnline > 2 ? 2 : padsOnline;
    return (kRunIntervalDays * daySec / (1 + 0.5 * pads)).round();
  }

  // ---- orders --------------------------------------------------------------

  /// Why [kind] cannot be ordered into [socket] at [site] now, or null.
  String? whyNot(ModuleKind kind, int socket, {int site = 0}) {
    final s = moduleSpec(kind);
    if (!standing) return lost || overrun ? 'The base is gone.' : 'The base has not deployed.';
    if (site >= sites.length || sites[site].razed) return 'That site is gone.';
    if (!hasGate(s.gate)) return '${s.label} needs a source colony with ${gateLabel(s.gate!)}.';
    if (countOf(kind) >= s.max) return 'The base has all the ${s.label.toLowerCase()}s it can use.';
    if (site < sites.length && sites[site].blocked(s.socket, socket)) return 'No room for this socket.';
    if (!_socketFree(site, s.socket, socket)) return 'That socket is taken.';
    return null;
  }

  /// Why the core cannot be upgraded to [tier] now, or null.
  String? whyNotUpgrade(BaseTier tier) {
    final c = core;
    if (!standing || c == null) return 'The base has not deployed.';
    if (c.outpost) return 'A spare core stays outpost-sized.';
    if (tier.index != c.tier.index + 1) return 'Upgrade one tier at a time.';
    final t = tierSpec(tier);
    if (!hasGate(t.gate)) return 'A ${t.label} needs a source colony with ${gateLabel(t.gate!)}.';
    if (c.lines.any((l) => l?.upgrade != null)) return 'An upgrade is already under way.';
    return null;
  }

  /// Why an outpost cannot open beside [objectiveId] now, or null.
  String? whyNotOutpost(Operation op, String objectiveId) {
    if (!standing) return 'The base has not deployed.';
    final o = op.graph.byId(objectiveId);
    if (o == null || o.kind == ObjectiveKind.lz) return 'Not an objective.';
    if (sites.any((s) => s.objectiveId == objectiveId && !s.razed)) return 'An outpost stands there.';
    if (sites.where((s) => s.outpost && !s.razed && !identical(s, core)).length >= kMaxOutposts) {
      return 'The base runs $kMaxOutposts outposts already.';
    }
    if (core!.lines.any((l) => l?.outpostAt == objectiveId)) return 'Already opening there.';
    if ((heldAt[o.id] ?? 0) < 60) return 'Hold it at 90% for a minute first.';
    return null;
  }

  /// Seconds the attacker has held each objective at ≥ 0.9, as a list of
  /// (objective, seconds) in graph order. Not saved: an outpost order after
  /// a load waits a minute more.
  final Map<String, int> heldAt = {};

  static String gateLabel(String g) => switch (g) {
        'spaceport' => 'a Spaceport',
        'gunfactory' => 'an Arms Factory',
        'barracks' => 'a Barracks',
        'hospital' => 'a Hospital',
        'base' => 'a Military Base',
        _ => g,
      };

  /// The player orders [kind] built in [socket] at [site]: it goes ahead of
  /// the doctrine, on the next free line there.
  bool orderBuild(ModuleKind kind, int socket, {int site = 0}) {
    if (whyNot(kind, socket, site: site) != null) return false;
    queue.add(BuildOrder(site: site, kind: kind, socket: socket));
    return true;
  }

  bool orderUpgrade(BaseTier tier) {
    if (whyNotUpgrade(tier) != null) return false;
    if (queue.any((o) => o.upgrade != null)) return false;
    queue.add(BuildOrder(upgrade: tier));
    return true;
  }

  bool orderOutpost(Operation op, String objectiveId) {
    if (whyNotOutpost(op, objectiveId) != null) return false;
    if (queue.any((o) => o.outpostAt == objectiveId)) return false;
    queue.add(BuildOrder(outpostAt: objectiveId));
    return true;
  }

  /// Cancels the work on [line] of [site]: half its price comes back.
  void cancelJob({int site = 0, int line = 0}) {
    if (site >= sites.length) return;
    final s = sites[site];
    if (line >= s.lines.length) return;
    final j = s.lines[line];
    if (j == null) return;
    materielC += j.paidC ~/ 2;
    stockC[kBaseStock.indexOf('steel')] += j.paidSteelC ~/ 2;
    s.lines[line] = null;
  }

  /// Demolishes the module in [socket] of ring [ring] at [site]: half its
  /// Materiel back, its crew to the reserve. The landing turret (the core's
  /// turret socket 0) stays.
  void demolish(Operation op, SocketKind ring, int socket, {int site = 0}) {
    if (site >= sites.length) return;
    if (site == 0 && ring == SocketKind.turret && socket == 0) return;
    final s = sites[site];
    final i = s.modules.indexWhere((m) => m.spec.socket == ring && m.socket == socket);
    if (i < 0) return;
    final m = s.modules.removeAt(i);
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

  /// Deploys the spare core at [objectiveId], an objective the attacker holds
  /// at ≥ 0.9: an outpost-sized base, 60 s from the order. Null, or why not.
  String? orderSpareCore(Operation op, String objectiveId) {
    if (!spareCore) return 'No spare core aboard.';
    if (standing) return 'The core still stands.';
    final o = op.graph.byId(objectiveId);
    if (o == null || o.control < 0.9) return 'Hold it at 90% first.';
    spareCore = false;
    spareAt = objectiveId;
    spareDeployAtStep = op.clock.steps + kSpareCoreDeployS;
    return null;
  }

  // ---- the step --------------------------------------------------------------

  /// One operation step, while it is engaged.
  void step(Operation op, int t) {
    if (spareAt != null && spareDeployAtStep >= 0 && t >= spareDeployAtStep) {
      _deploySpare(op, t);
    }
    if (lost || overrun) return;
    if (!deployed) {
      if (deployAtStep < 0 || t < deployAtStep) return;
      _deploy(op, t);
    }
    for (final o in op.graph.objectives) {
      heldAt[o.id] = o.control >= 0.9 ? (heldAt[o.id] ?? 0) + 1 : 0;
    }
    _arrivals(t);
    _power(op);
    if (palletsC > 0 && _siteRuns(op, core!)) {
      final room = capC - materielC;
      var u = unpackC < palletsC ? unpackC : palletsC;
      if (u > room) u = room < 0 ? 0 : room;
      palletsC -= u;
      materielC += u;
    }
    _crew();
    _generators(op);
    for (var i = 0; i < sites.length; i++) {
      final s = sites[i];
      if (s.razed) continue;
      s.fitLines();
      for (var l = 0; l < s.lines.length; l++) {
        _line(op, i, l, t);
      }
    }
    _turrets(op, t);
    final since = t - deployAtStep;
    if (since % kWorkshopBatchS == 0) _workshop(op);
    if (since % kHospitalCycleS == 0) _hospital(op);
    if (since % kPodCycleS == 0) _podForm(op, t);
    _resupply(op, t);
    _askForRuns(op, t);
    _clampStock();
    _overrunCheck(op);
    _razeCheck(op);
  }

  void _deploy(Operation op, int t) {
    deployed = true;
    if (sites.isEmpty) {
      sites.add(BaseSite(
          objectiveId: op.lzId,
          blockedModules: List<int>.of(layoutBlockedModules),
          blockedTurrets: List<int>.of(layoutBlockedTurrets)));
    }
    // The landing turret rides in the core: online at once if crewed.
    final m = BaseModule(kind: ModuleKind.turret, socket: 0);
    sites.first.modules.add(m);
    _crew();
    _turretFormation(op, sites.first, m, t);
    nextRunStep = t + runIntervalS(op.tuning.daySec);
    events.add((BaseEventKind.deployed, 'The base core is down and the landing turret is up.'));
  }

  void _deploySpare(Operation op, int t) {
    final at = spareAt!;
    spareAt = null;
    spareDeployAtStep = -1;
    lost = false;
    overrun = false;
    overrunHeldS = 0;
    deployed = true;
    // An outpost-sized base, standing where the spare came down.
    sites.insert(0, BaseSite(objectiveId: at, outpost: true));
    if (nextRunStep < 0) nextRunStep = t + runIntervalS(op.tuning.daySec);
    events.add((BaseEventKind.deployed, 'The spare core is down.'));
  }

  void _arrivals(int t) {
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
  }

  void _clampStock() {
    final cap = capC;
    for (var i = 0; i < stockC.length; i++) {
      if (stockC[i] > cap) stockC[i] = cap;
    }
  }

  /// Hands the reserve out to modules short of crew, site by site, in socket
  /// order.
  void _crew() {
    for (final (_, m) in allModules) {
      if (reserve <= 0) return;
      if (m.formationId != null) continue;
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

  void _turretFormation(Operation op, BaseSite s, BaseModule m, int t) {
    if (m.kind != ModuleKind.turret || m.formationId != null) return;
    // Its crew come from the reserve and become the formation's members.
    final n = m.crew;
    if (n <= 0) return;
    m.crew = 0;
    final f = Formation(
      id: op.nextFormationId,
      side: CombatSide.attacker,
      faction: Factions.player,
      kind: FormationKind.emplacement,
      counterClass: CounterClass.empHmg,
      count: n,
      quality: 0.8,
      morale: 0.8,
      kitDays: stockOf('ammo') > 0 ? 3 : 0,
      at: s.objectiveId,
      arriveStep: t,
      homeColonyId: homeColonyId,
      homeSiteId: 'support',
    );
    op.addAttacker(f);
    m.formationId = f.id;
  }

  void _generators(Operation op) {
    for (final (s, m) in allModules) {
      if (m.kind != ModuleKind.generator || !_online(op, s, m)) continue;
      _take('fuel', kGeneratorFuelC);
    }
  }

  void _line(Operation op, int site, int line, int t) {
    final s = sites[site];
    final j = s.lines[line];
    if (j != null) {
      // Construction needs no power, but a site the defender holds stops.
      if (!_siteRuns(op, s)) return;
      j.remainingS -= 1;
      if (j.remainingS > 0) return;
      s.lines[line] = null;
      _finish(op, site, j, t);
      return;
    }
    // A player's order for this site first, then the doctrine (at the core).
    BuildOrder? next;
    var fromQueue = -1;
    for (var i = 0; i < queue.length && next == null; i++) {
      final o = queue[i];
      if (o.site != site) continue;
      if (_orderValid(op, o)) {
        next = o;
        fromQueue = i;
      }
    }
    if (next == null && site == 0) next = _doctrinePick(op);
    if (next == null) return;
    final cost = _cost(next);
    if (materielC < cost.$1 || stockOf('steel') < cost.$2) return; // waits
    if (fromQueue >= 0) queue.removeAt(fromQueue);
    materielC -= cost.$1;
    _take('steel', cost.$2);
    s.lines[line] = BuildJob(
      kind: next.kind,
      upgrade: next.upgrade,
      outpostAt: next.outpostAt,
      socket: next.socket,
      remainingS: _buildS(next),
      paidC: cost.$1,
      paidSteelC: cost.$2,
    );
  }

  bool _orderValid(Operation op, BuildOrder o) {
    if (o.kind != null) {
      final s = moduleSpec(o.kind!);
      if (o.site >= sites.length || sites[o.site].razed) return false;
      if (!hasGate(s.gate) || countOf(o.kind!) >= s.max) return false;
      final x = sites[o.site];
      if (o.socket < 0 || o.socket >= x.socketsOf(s.socket)) return false;
      for (final m in x.modules) {
        if (m.spec.socket == s.socket && m.socket == o.socket) return false;
      }
      for (final l in x.lines) {
        if (l?.kind != null && moduleSpec(l!.kind!).socket == s.socket && l.socket == o.socket) {
          return false;
        }
      }
      return true;
    }
    if (o.upgrade != null) return whyNotUpgrade(o.upgrade!) == null;
    if (o.outpostAt != null) return whyNotOutpost(op, o.outpostAt!) == null;
    return false;
  }

  (int, int) _cost(BuildOrder o) {
    if (o.kind != null) {
      final s = moduleSpec(o.kind!);
      return (s.materiel * 100, s.steel * 100);
    }
    if (o.upgrade != null) {
      final t = tierSpec(o.upgrade!);
      return (t.materiel * 100, t.steel * 100);
    }
    return (kOutpostMateriel * 100, 0);
  }

  int _buildS(BuildOrder o) {
    if (o.kind != null) return moduleSpec(o.kind!).buildS;
    if (o.upgrade != null) return tierSpec(o.upgrade!).buildS;
    return kOutpostBuildS;
  }

  void _finish(Operation op, int site, BuildJob j, int t) {
    final s = sites[site];
    if (j.kind != null) {
      final m = BaseModule(kind: j.kind!, socket: j.socket);
      s.modules.add(m);
      _crew();
      if (m.kind == ModuleKind.turret) _turretFormation(op, s, m, t);
      events.add((BaseEventKind.built, '${m.spec.label} built.'));
    } else if (j.upgrade != null) {
      s.tier = j.upgrade!;
      s.fitLines();
      events.add((BaseEventKind.upgraded, 'The base is a ${tierSpec(s.tier).label} now.'));
    } else if (j.outpostAt != null) {
      sites.add(BaseSite(objectiveId: j.outpostAt!, outpost: true));
      events.add((BaseEventKind.outpostOpen, 'An outpost is open beside the ${j.outpostAt}.'));
    }
  }

  /// The doctrine's next pick for the core: the first list item whose gate,
  /// a socket, crew and power allow, or a generator when power would run
  /// short. A pick short of Materiel waits on its line.
  BuildOrder? _doctrinePick(Operation op) {
    final list = kDoctrines[doctrine] ?? const <DoctrineStep>[];
    // The landing turret is the first turret the list counts.
    final seen = <DoctrineStep>[DoctrineStep.turret];
    final c = core!;
    for (final step in list) {
      seen.add(step);
      final mentions = seen.where((x) => x == step).length;
      switch (step) {
        case DoctrineStep.station:
        case DoctrineStep.fortress:
          final tier = step == DoctrineStep.station ? BaseTier.station : BaseTier.fortress;
          if (c.tier.index >= tier.index) continue;
          if (whyNotUpgrade(tier) != null) continue;
          if (queue.any((o) => o.upgrade != null)) continue;
          return BuildOrder(upgrade: tier);
        case DoctrineStep.outpost:
          if (sites.any((x) => x.outpost && !x.razed && !identical(x, c))) continue;
          if (c.lines.any((l) => l?.outpostAt != null)) continue;
          for (final o in op.graph.objectives) {
            if (whyNotOutpost(op, o.id) == null) return BuildOrder(outpostAt: o.id);
          }
          continue;
        default:
          final k = moduleOfStep(step)!;
          final s = moduleSpec(k);
          if (!hasGate(s.gate) || countOf(k) >= s.max) continue;
          if (countOf(k) >= mentions) continue;
          if (k == ModuleKind.workshop && stockOf('steel') < 1000) continue;
          final socket = _firstFree(0, s.socket);
          if (socket == null) continue;
          if (reserve < s.crew) continue;
          if (s.powerKw > 0 && powerDemand + s.powerKw > powerSupply + 1e-9) {
            // A generator jumps the list when power would run short.
            final g = moduleSpec(ModuleKind.generator);
            final gs = _firstFree(0, SocketKind.module);
            if (gs != null &&
                reserve >= g.crew + s.crew &&
                stockOf('fuel') > 0 &&
                countOf(ModuleKind.generator) < g.max) {
              return BuildOrder(kind: ModuleKind.generator, socket: gs);
            }
            continue;
          }
          return BuildOrder(kind: k, socket: socket);
      }
    }
    return null;
  }

  void _turrets(Operation op, int t) {
    final r = powerRatio;
    for (final (s, m) in allModules) {
      if (m.kind != ModuleKind.turret) continue;
      final f = m.formationId == null ? null : op.formationById(m.formationId!);
      if (f == null || !f.alive) continue;
      final runs = _siteRuns(op, s);
      final engaged = op.formations
          .any((x) => x.side == CombatSide.defender && x.presentAt(s.objectiveId, t));
      final burn = ((engaged ? kTurretAmmoEngaged : kTurretAmmoIdle) * f.count / 2 * 100).round();
      final got = runs ? _take('ammo', burn) : 0;
      // Out of ammo, out of power, or its site held: it fights unsupplied.
      f.kitDays = (runs && got >= burn && r >= 0.35) ? 3 : 0;
      // Turrets never move and never rout off their guns.
      if (f.broken) f.broken = false;
      if (f.at == FormationAt.reserve) f.at = s.objectiveId;
    }
  }

  void _workshop(Operation op) {
    for (final (s, m) in allModules) {
      if (m.kind != ModuleKind.workshop || !_online(op, s, m) || powerRatio < 0.5) continue;
      if (stockOf('steel') < kWorkshopSteelC || stockOf('electronics') < kWorkshopElectronicsC) {
        continue;
      }
      _take('steel', kWorkshopSteelC);
      _take('electronics', kWorkshopElectronicsC);
      stockC[kBaseStock.indexOf('ammo')] += kWorkshopAmmoC;
      stockC[kBaseStock.indexOf('guns')] += kWorkshopGunsC;
    }
  }

  /// Every half day the field hospital takes in the wounded, who recover
  /// into the LZ reserve instead of going home.
  void _hospital(Operation op) {
    if (!hospitalOnline || powerRatio < 0.5) return;
    var patients = 0;
    for (final f in op.formations) {
      if (f.side == CombatSide.attacker) patients += f.wounded;
    }
    if (patients == 0) return;
    final need =
        (kMedicinePerPatientDay * patients * kHospitalCycleS / op.tuning.daySec * 100).ceil();
    if (stockOf('medicine') < need) return;
    _take('medicine', need);
    for (final f in op.formations) {
      if (f.side != CombatSide.attacker || f.wounded == 0) continue;
      _addRecovered(f.homeColonyId, f.homeSiteId, f.wounded);
      f.wounded = 0;
    }
  }

  /// Medevac (a power, §7D): the wounded at [objectiveId] to the hospital
  /// now. Returns how many.
  int medevac(Operation op, String objectiveId) {
    if (!hospitalOnline) return 0;
    var n = 0;
    for (final f in op.formations) {
      if (f.side != CombatSide.attacker || f.wounded == 0) continue;
      if (f.at != objectiveId) continue;
      _addRecovered(f.homeColonyId, f.homeSiteId, f.wounded);
      n += f.wounded;
      f.wounded = 0;
    }
    return n;
  }

  void _addRecovered(String? home, String? site, int n) {
    for (final r in recovered) {
      if (r.home == home && r.site == site) {
        r.count += n;
        return;
      }
    }
    recovered.add(Recovered(home, site, n));
  }

  int get recoveredTotal {
    var n = 0;
    for (final r in recovered) {
      n += r.count;
    }
    return n;
  }

  /// The pod forms recovered wounded into a squad, every 30 s, from 4 waiting.
  void _podForm(Operation op, int t) {
    if (!podOnline || powerRatio < 0.5) return;
    if (recoveredTotal < kPodMinimum) return;
    for (final r in recovered) {
      if (r.count <= 0) continue;
      final n = r.count < 8 ? r.count : 8;
      r.count -= n;
      op.addAttacker(Formation(
        id: op.nextFormationId,
        side: CombatSide.attacker,
        faction: Factions.player,
        kind: FormationKind.infantry,
        count: n,
        quality: 0.9,
        morale: 0.6,
        kitDays: 1,
        at: op.lzId,
        arriveStep: t,
        homeColonyId: r.home,
        homeSiteId: r.site,
      ));
      break;
    }
    recovered.removeWhere((r) => r.count <= 0);
  }

  /// Squads at a standing site's objective, or one link from the core's,
  /// refill kit toward three days.
  void _resupply(Operation op, int t) {
    if (stockOf('rations') <= 0 || stockOf('ammo') <= 0) return;
    final c = core!;
    for (final f in op.formations) {
      if (f.side != CombatSide.attacker || !f.alive) continue;
      if (f.kind == FormationKind.emplacement) continue;
      if (f.kitDays >= kResupplyToDays) continue;
      if (!f.presentAt(f.at, t)) continue;
      final near = f.at == c.objectiveId ||
          op.graph.linked(f.at, c.objectiveId) ||
          sites.any((s) => s.outpost && !s.razed && s.objectiveId == f.at);
      if (!near) continue;
      const day = 1 / kResupplyDayS; // kit days this second
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
    runs.add(_run(op, t, materiel: kRunMateriel));
  }

  BaseRun _run(Operation op, int t, {required int materiel, int? arriveIn}) {
    // Kit for everyone ashore until the next run, and the modules' upkeep.
    var people = reserve + crewAssigned + recoveredTotal;
    for (final f in op.formations) {
      if (f.side == CombatSide.attacker && f.alive) people += f.count;
    }
    final days = runIntervalS(op.tuning.daySec) / op.tuning.daySec;
    var gens = 0;
    for (final (_, m) in allModules) {
      if (m.kind == ModuleKind.generator) gens++;
    }
    final want = List<int>.filled(kBaseStock.length, 0);
    want[kBaseStock.indexOf('ammo')] = (kAmmoPerDay * people * days * 100).round();
    want[kBaseStock.indexOf('rations')] = (kRationsPerDay * people * days * 100).round();
    want[kBaseStock.indexOf('fuel')] = (gens * kGeneratorFuelC * days * op.tuning.daySec).round();
    if (hospitalOnline) want[kBaseStock.indexOf('medicine')] = (2 * days * 100).round();
    final run = BaseRun(id: nextRunId++, materielC: materiel * 100, stockC: want);
    if (autoShip) {
      run
        ..posted = true
        ..arriveStep = t + (arriveIn ?? op.reinforcementDelaySteps);
    }
    return run;
  }

  /// An emergency supply drop (a power, §7D): one extra run, landing half a
  /// day after the source ships it.
  void supplyDrop(Operation op) {
    runs.add(_run(op, op.clock.steps,
        materiel: kRunMateriel, arriveIn: (op.tuning.daySec * 0.5).round()));
  }

  /// The lead source answered run [id] with what it had: it lands at
  /// [arriveStep].
  void runShipped(int id, int materielC, List<int> stockC, int arriveStep) {
    for (final r in runs) {
      if (r.id != id) continue;
      r.materielC = materielC;
      for (var i = 0; i < kBaseStock.length && i < stockC.length; i++) {
        r.stockC[i] = stockC[i];
      }
      r.arriveStep = arriveStep;
    }
  }

  void _overrunCheck(Operation op) {
    final c = core;
    if (c == null || !standing) return;
    final lz = op.graph.byId(c.objectiveId);
    if (lz == null) return;
    overrunHeldS = lz.control <= -0.9 ? overrunHeldS + 1 : 0;
    if (overrunHeldS < 60) return;
    overrun = true;
    queue.clear();
    for (final s in sites) {
      _lose(op, s);
    }
    _loseCount(reserve);
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

  void _razeCheck(Operation op) {
    for (final s in sites) {
      if (!s.outpost || s.razed || identical(s, core)) continue;
      final o = op.graph.byId(s.objectiveId);
      if (o == null) continue;
      s.razeHeldS = o.control <= -0.9 ? s.razeHeldS + 1 : 0;
      if (s.razeHeldS < 60) continue;
      _lose(op, s);
      s.razed = true;
      events.add((BaseEventKind.razed, 'The outpost beside the ${s.objectiveId} was razed.'));
    }
  }

  /// A site's modules lost: turret crews hit as formations, other crews half
  /// dead, half wounded.
  void _lose(Operation op, BaseSite s) {
    for (final m in s.modules) {
      final fid = m.formationId;
      if (fid != null) {
        final f = op.formationById(fid);
        if (f != null) f.removeMembers(f.count);
      } else {
        _loseCount(m.crew);
      }
      m.crew = 0;
    }
    s.modules.clear();
    for (var i = 0; i < s.lines.length; i++) {
      s.lines[i] = null;
    }
  }

  void _loseCount(int n) {
    if (n <= 0) return;
    final dead = (n + 1) ~/ 2;
    supportDead += dead;
    supportWounded += n - dead;
  }

  /// The core went down with its lander.
  void loseCore() {
    if (deployed || lost) return;
    lost = true;
    _loseCount(reserve);
    reserve = 0;
    events.add((BaseEventKind.coreLost, 'The base core was lost with its lander.'));
  }

  /// Support staff alive and well at the end: the reserve and the crews of
  /// modules that are not formations (a turret's crew are its members).
  int get supportAlive {
    var n = reserve;
    for (final (_, m) in allModules) {
      if (m.formationId == null) n += m.crew;
    }
    return n;
  }

  /// Turrets standing: each counts toward an occupation's suppression.
  int get turretsStanding {
    var n = 0;
    for (final (_, m) in allModules) {
      if (m.kind == ModuleKind.turret) n++;
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
        'stock': _stockJson(stockC),
        'gates': List<String>.of(gates),
        if (deployed) 'deployed': true,
        if (deployAtStep >= 0) 'deployAt': deployAtStep,
        if (lost) 'lost': true,
        if (overrun) 'overrun': true,
        if (overrunHeldS != 0) 'overrunHeld': overrunHeldS,
        if (sites.isNotEmpty) 'sites': [for (final s in sites) s.toJson()],
        if (queue.isNotEmpty) 'queue': [for (final o in queue) o.toJson()],
        if (doctrine != Doctrine.balanced) 'doctrine': doctrine.name,
        if (nextRunStep >= 0) 'nextRun': nextRunStep,
        'nextRunId': nextRunId,
        if (runs.isNotEmpty) 'runs': [for (final r in runs) r.toJson()],
        if (capturedMaterielC != 0) 'capM': capturedMaterielC,
        if (capturedStockC.any((v) => v != 0)) 'capStock': _stockJson(capturedStockC),
        if (recovered.isNotEmpty) 'recovered': [for (final r in recovered) r.toJson()],
        if (spareCore) 'spare': true,
        if (spareAt != null) 'spareAt': spareAt,
        if (spareDeployAtStep >= 0) 'spareDeploy': spareDeployAtStep,
        if (layoutBlockedModules.isNotEmpty) 'layoutBlockedM': List<int>.of(layoutBlockedModules),
        if (layoutBlockedTurrets.isNotEmpty) 'layoutBlockedT': List<int>.of(layoutBlockedTurrets),
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
      stockC: _stockRead(j['stock']),
      gates: [for (final g in (j['gates'] as List)) g as String],
      deployed: j['deployed'] == true,
      deployAtStep: (j['deployAt'] as num?)?.toInt() ?? -1,
      lost: j['lost'] == true,
      overrun: j['overrun'] == true,
      overrunHeldS: (j['overrunHeld'] as num?)?.toInt() ?? 0,
      nextRunStep: (j['nextRun'] as num?)?.toInt() ?? -1,
      nextRunId: (j['nextRunId'] as num?)?.toInt() ?? 1,
      capturedMaterielC: (j['capM'] as num?)?.toInt() ?? 0,
      capturedStockC: j['capStock'] == null ? null : _stockRead(j['capStock']),
      doctrine: j['doctrine'] == null
          ? Doctrine.balanced
          : Doctrine.values.byName(j['doctrine'] as String),
      spareCore: j['spare'] == true,
      spareAt: j['spareAt'] as String?,
      spareDeployAtStep: (j['spareDeploy'] as num?)?.toInt() ?? -1,
      sites: [
        for (final s in (j['sites'] as List? ?? const []))
          BaseSite.fromJson((s as Map).cast<String, dynamic>())
      ],
    );
    for (final o in (j['queue'] as List? ?? const [])) {
      b.queue.add(BuildOrder.fromJson((o as Map).cast<String, dynamic>()));
    }
    for (final r in (j['runs'] as List? ?? const [])) {
      b.runs.add(BaseRun.fromJson((r as Map).cast<String, dynamic>()));
    }
    for (final r in (j['recovered'] as List? ?? const [])) {
      b.recovered.add(Recovered.fromJson((r as Map).cast<String, dynamic>()));
    }
    b.layoutBlockedModules = [for (final v in (j['layoutBlockedM'] as List? ?? const [])) (v as num).toInt()];
    b.layoutBlockedTurrets = [for (final v in (j['layoutBlockedT'] as List? ?? const [])) (v as num).toInt()];
    return b;
  }

  /// Labels for the drawer.
  static String socketLabel(SocketKind s, int i) =>
      s == SocketKind.module ? 'Module ${i + 1}' : (i == 0 ? 'Landing turret' : 'Turret ${i + 1}');
}

/// Whether two objectives are one link apart (for resupply).
extension ObjectiveGraphLinks on ObjectiveGraph {
  bool linked(String a, String b) {
    for (final l in links) {
      if ((l.a == a && l.b == b) || (l.a == b && l.b == a)) return true;
    }
    return false;
  }
}
