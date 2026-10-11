// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Orbital support (docs/plans/combat.md §7E; ref §10A.12): the vessels
/// assigned to an operation, the strike queued, the rounds in flight and the
/// craters they leave. State on the operation, saved with it; the vessels
/// themselves are read by the combat phase through [CombatSky], never here.
library;

import 'dart:math' as math;

import '../../shared/vector3.dart';

/// A round's mass and speed: a 250 kg rod arriving at 3 km/s.
const double kRoundMassKg = 250;
const double kRoundSpeedMs = 3000;

/// A round's cost, per round, from the colony that arms the vessel.
const int kRoundSteel = 25;
const int kRoundElectronics = 5;

/// Loading, s: rounds paid for are aboard this long after.
const int kArmLoadS = 60;

/// One vessel fires at most once a minute.
const int kVesselCooldownS = 60;

/// Struck defenders are pinned for this long, firing at [kPinnedFire].
const int kPinnedS = 20;
const double kPinnedFire = 0.5;

/// Morale a strike costs every defender formation where it lands.
const double kStrikeMorale = 0.15;

/// At most this many craters a battle.
const int kMaxCraters = 16;

/// The uplink mast's draw while support is assigned, and the support staff
/// it keeps back.
const double kUplinkKw = 8;
const int kUplinkCrew = 2;

/// Flight time, s: 10 s plus the slant at 3 km/s.
int strikeFlightS(double slantM) => (10 + slantM / kRoundSpeedMs).round();

/// Circular error probable, m.
double strikeCepM(double slantM) => 5 + 5e-5 * slantM;

/// A vessel assigned to an operation, and what the last tick saw of it.
class AssignedVessel {
  AssignedVessel(this.id, this.name,
      {this.strike = false, this.recon = false, this.slantM = 0, this.readyStep = 0});

  final String id;
  final String name;

  /// Overhead at the last tick end (§7E): saved, so a load needs no vessel
  /// state from a boundary already past.
  bool strike;
  bool recon;
  double slantM;

  /// When it may fire again.
  int readyStep;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (strike) 'strike': true,
        if (recon) 'recon': true,
        if (slantM != 0) 'slant': slantM,
        if (readyStep != 0) 'ready': readyStep,
      };

  factory AssignedVessel.fromJson(Map<String, dynamic> j) => AssignedVessel(
        j['id'] as String,
        j['name'] as String? ?? j['id'] as String,
        strike: j['strike'] == true,
        recon: j['recon'] == true,
        slantM: (j['slant'] as num?)?.toDouble() ?? 0,
        readyStep: (j['ready'] as num?)?.toInt() ?? 0,
      );
}

/// A round on its way down.
class StrikeInFlight {
  StrikeInFlight(this.seq, this.vesselId, this.objectiveId, this.impactStep, this.slantM);
  final int seq;
  final String vesselId;
  final String objectiveId;
  final int impactStep;
  final double slantM;

  Map<String, dynamic> toJson() =>
      {'seq': seq, 'v': vesselId, 'at': objectiveId, 'impact': impactStep, 'slant': slantM};

  factory StrikeInFlight.fromJson(Map<String, dynamic> j) => StrikeInFlight(
        (j['seq'] as num).toInt(),
        j['v'] as String,
        j['at'] as String,
        (j['impact'] as num).toInt(),
        (j['slant'] as num).toDouble(),
      );
}

/// Where a round came down: the crater it left, keyed by content (§7E) so a
/// crater dug after a save is neither doubled by an in-session load nor lost
/// by a restart.
class StrikeCrater {
  StrikeCrater(this.seq, this.e, this.n, this.diameterM, this.step, {this.brush = false});
  final int seq;

  /// Colony-local metres, quantised to 0.5 m.
  final double e, n;
  final double diameterM;

  /// The step it landed (the effects fade from it).
  final int step;

  /// Clear of every building: drawn into the world's terrain.
  final bool brush;

  String key(int opId) =>
      '$opId:$seq:${(e * 2).round()}:${(n * 2).round()}:${(diameterM * 10).round()}';

  Map<String, dynamic> toJson() =>
      {'seq': seq, 'e': e, 'n': n, 'd': diameterM, 'step': step, if (brush) 'brush': true};

  factory StrikeCrater.fromJson(Map<String, dynamic> j) => StrikeCrater(
        (j['seq'] as num).toInt(),
        (j['e'] as num).toDouble(),
        (j['n'] as num).toDouble(),
        (j['d'] as num).toDouble(),
        (j['step'] as num?)?.toInt() ?? 0,
        brush: j['brush'] == true,
      );
}

class OrbitalSupport {
  OrbitalSupport({
    List<AssignedVessel>? assigned,
    this.queued,
    List<StrikeInFlight>? inFlight,
    List<StrikeCrater>? craters,
    List<(String, int)>? pinned,
    this.nextSeq = 0,
    this.craterM = 13,
    this.centreBF,
    List<(double, double, double)>? footprints,
  })  : assigned = assigned ?? [],
        inFlight = inFlight ?? [],
        craters = craters ?? [],
        pinned = pinned ?? [],
        footprints = footprints ?? [];

  /// In id order.
  final List<AssignedVessel> assigned;

  /// The objective a strike is queued on: it fires at the first chance.
  String? queued;

  final List<StrikeInFlight> inFlight;
  final List<StrikeCrater> craters;

  /// (objective id, the step its defenders stop being pinned).
  final List<(String, int)> pinned;
  int nextSeq;

  bool pinnedAt(String objectiveId, int t) => pinned.any((p) => p.$1 == objectiveId && t < p.$2);

  void pin(String objectiveId, int until) {
    pinned
      ..removeWhere((p) => p.$1 == objectiveId)
      ..add((objectiveId, until))
      ..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// A round's crater diameter on this body, m (from `craterForImpact`): set
  /// at launch.
  double craterM;

  /// The battle's centre, body-fixed (m), where "overhead" is judged: set at
  /// launch.
  Vector3? centreBF;

  /// Buildings near the objectives (east, north, radius m): a crater that
  /// touches one leaves no world brush.
  final List<(double, double, double)> footprints;

  /// Rounds aboard each assigned vessel, handed in by the combat phase
  /// before each tick's steps; not saved.
  final Map<String, int> roundsAboard = {};

  /// Vessels that fired a round this tick, drained by the combat phase.
  final List<String> fired = [];

  /// Notices for the player ("Orbital support lost: …"), drained by the UI.
  final List<String> notices = [];

  bool get any => assigned.isNotEmpty;

  AssignedVessel? byId(String id) {
    for (final v in assigned) {
      if (v.id == id) return v;
    }
    return null;
  }

  void assign(String id, String name) {
    if (byId(id) != null) return;
    assigned
      ..add(AssignedVessel(id, name))
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  void unassign(String id) => assigned.removeWhere((v) => v.id == id);

  /// The vessel that would fire at [t], or null: overhead, armed, rested.
  AssignedVessel? ready(int t) {
    for (final v in assigned) {
      if (!v.strike || t < v.readyStep) continue;
      if ((roundsAboard[v.id] ?? 0) - fired.where((f) => f == v.id).length <= 0) continue;
      return v;
    }
    return null;
  }

  bool get isEmpty =>
      assigned.isEmpty && queued == null && inFlight.isEmpty && craters.isEmpty && nextSeq == 0;

  Map<String, dynamic> toJson() => {
        if (assigned.isNotEmpty) 'assigned': [for (final v in assigned) v.toJson()],
        if (queued != null) 'queued': queued,
        if (inFlight.isNotEmpty) 'inFlight': [for (final s in inFlight) s.toJson()],
        if (craters.isNotEmpty) 'craters': [for (final c in craters) c.toJson()],
        if (pinned.isNotEmpty) 'pinned': [for (final p in pinned) [p.$1, p.$2]],
        if (nextSeq != 0) 'seq': nextSeq,
        'craterM': craterM,
        if (centreBF case final c?) 'centre': [c.x, c.y, c.z],
        if (footprints.isNotEmpty) 'feet': [for (final f in footprints) [f.$1, f.$2, f.$3]],
      };

  factory OrbitalSupport.fromJson(Map<String, dynamic>? j) {
    if (j == null) return OrbitalSupport();
    final c = j['centre'] as List?;
    return OrbitalSupport(
      assigned: [
        for (final v in (j['assigned'] as List? ?? const []))
          AssignedVessel.fromJson((v as Map).cast<String, dynamic>())
      ],
      queued: j['queued'] as String?,
      inFlight: [
        for (final s in (j['inFlight'] as List? ?? const []))
          StrikeInFlight.fromJson((s as Map).cast<String, dynamic>())
      ],
      craters: [
        for (final s in (j['craters'] as List? ?? const []))
          StrikeCrater.fromJson((s as Map).cast<String, dynamic>())
      ],
      pinned: [
        for (final p in (j['pinned'] as List? ?? const []))
          ((p as List)[0] as String, (p[1] as num).toInt())
      ],
      nextSeq: (j['seq'] as num?)?.toInt() ?? 0,
      craterM: (j['craterM'] as num?)?.toDouble() ?? 13,
      centreBF: c == null
          ? null
          : Vector3((c[0] as num).toDouble(), (c[1] as num).toDouble(), (c[2] as num).toDouble()),
      footprints: [
        for (final f in (j['feet'] as List? ?? const []))
          (
            ((f as List)[0] as num).toDouble(),
            (f[1] as num).toDouble(),
            (f[2] as num).toDouble()
          )
      ],
    );
  }
}

/// Area casualties a round inflicts on a formation of [count] (ref
/// §10A.12): members spread 50 m² each, so a formation's own spread
/// against the scatter decides how many it catches.
double strikeAreaCasualties(int count, double diameterM, double cepM, {required bool cover}) {
  if (count <= 0) return 0;
  final rf = math.sqrt(count * 50 / math.pi);
  final hit = math.pi * diameterM * diameterM / 50 * (cover ? 0.6 : 1.0);
  final spread = math.min(1.0, (rf / cepM) * (rf / cepM));
  return math.min(0.4 * count, hit) * spread;
}

/// The chance a round destroys the emplacement it was aimed at.
double strikeKillChance(double diameterM, double cepM) =>
    0.8 * math.min(1.0, (diameterM / cepM) * (diameterM / cepM));
