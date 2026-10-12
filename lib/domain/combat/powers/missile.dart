// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A silo's salvo as a real missile (docs/plans/combat.md §7O): the record
/// the world keeps of each one, from the order to the crater.
///
/// The combat phase asks for a shot (an operation's silo strike, or a point
/// the player picked) and hears back where it landed; the world's missile
/// flight spawns the salvo vessel on its Lambert arc, and detonates it at its
/// impact time. Saved with the registry, so a load resumes a salvo in the air.
library;

import '../../shared/vector3.dart';

/// A salvo's vessel ids start with this: what the renderer draws as a
/// missile and the surface-contact pass leaves to its own detonation.
const String kMissileIdPrefix = 'missile-';

/// What a salvo weighs (4 missiles), the warhead it carries, and how far
/// round a body it can reach (§7O defaults).
const double kMissileSalvoKg = 1600;
const double kMissileWarheadJ = 2e9;
const double kMissileMaxArcM = 2000e3;

/// What it razes: every building whose site centre is this close, and the
/// share of their people killed.
const double kMissileBlastM = 40;
const double kMissileDeathShare = 0.25;

/// Loyalty a colony of the player's loses to a strike on it.
const double kMissileOwnColonyCost = 0.1;

/// Where a shot is in its life: waiting for its colony to pay the missiles,
/// paid and waiting to fly, in the air, down (and not yet answered for), or
/// not to fly at all.
enum MissileState { unpaid, pending, flying, landed, failed }

class MissileShot {
  MissileShot({
    required this.id,
    required this.homeColonyId,
    required this.bodyId,
    required this.aimDir,
    this.opId,
    this.strikeSeq,
    this.state = MissileState.pending,
    this.launchEpochS = 0,
    this.impactEpochS = 0,
    this.aimBF,
    this.siloBF,
    this.why,
  });

  final int id;

  /// The colony whose silo fires it, and pays.
  final String homeColonyId;
  final String bodyId;

  /// Where it is aimed: a body-fixed unit direction (the ground there is
  /// sampled at launch).
  final Vector3 aimDir;

  /// The operation strike it is (its seq on that operation), or null for a
  /// strike on a point.
  final int? opId;
  final int? strikeSeq;

  MissileState state;

  /// World epochs it left the silo and lands, s.
  double launchEpochS;
  double impactEpochS;

  /// The aimed ground and the silo it left, body-fixed metres, fixed at
  /// launch.
  Vector3? aimBF;
  Vector3? siloBF;

  /// Why it could not fly.
  String? why;

  String get vesselId => '$kMissileIdPrefix$id';

  bool get done => state == MissileState.landed || state == MissileState.failed;

  static List<double> _v(Vector3 v) => [v.x, v.y, v.z];
  static Vector3? _readV(Object? j) =>
      j is List && j.length == 3 ? Vector3((j[0] as num).toDouble(), (j[1] as num).toDouble(), (j[2] as num).toDouble()) : null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'home': homeColonyId,
        'body': bodyId,
        'aim': _v(aimDir),
        if (opId != null) 'op': opId,
        if (strikeSeq != null) 'seq': strikeSeq,
        'state': state.name,
        if (launchEpochS != 0) 'launch': launchEpochS,
        if (impactEpochS != 0) 'impact': impactEpochS,
        if (aimBF != null) 'aimBF': _v(aimBF!),
        if (siloBF != null) 'siloBF': _v(siloBF!),
        if (why != null) 'why': why,
      };

  static MissileShot? fromJson(Object? j) {
    if (j is! Map) return null;
    final aim = _readV(j['aim']);
    if (aim == null || j['id'] is! num || j['home'] is! String || j['body'] is! String) return null;
    return MissileShot(
      id: (j['id'] as num).toInt(),
      homeColonyId: j['home'] as String,
      bodyId: j['body'] as String,
      aimDir: aim,
      opId: (j['op'] as num?)?.toInt(),
      strikeSeq: (j['seq'] as num?)?.toInt(),
      state: MissileState.values.where((s) => s.name == j['state']).firstOrNull ?? MissileState.pending,
      launchEpochS: (j['launch'] as num?)?.toDouble() ?? 0,
      impactEpochS: (j['impact'] as num?)?.toDouble() ?? 0,
      aimBF: _readV(j['aimBF']),
      siloBF: _readV(j['siloBF']),
      why: j['why'] as String?,
    );
  }
}
