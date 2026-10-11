// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Air and missiles (docs/plans/combat.md §7M): gunship passes from an
/// Airfield, silo strikes from a Missile Silo, and the rebels' own silo
/// striking the base. State on the operation, saved with it.
library;

/// A gunship pass: its formation, and when it started and ends.
const int kGunshipPassS = 30;
const int kGunshipStrafeS = 15;
const double kGunshipStrafe = 1.33;
const int kGunshipFuelC = 6000;
const int kGunshipAmmoC = 6000;

/// Missiles a silo strike costs, its flight, and its scatter (as a slant
/// that gives the orbital strike's CEP of 30 m).
const int kSiloMissiles = 4;
const int kSiloFlightS = 60;
const double kSiloSlantM = 500e3;

/// Each crewed AA turret's chance to stop the rebels' missile, and the most
/// all of them can.
const double kAaIntercept = 0.4;
const double kAaInterceptMax = 0.9;

class AirSupport {
  AirSupport({
    this.gunshipReadyStep = 0,
    this.siloReadyStep = 0,
    List<(int, int, int)>? passes,
    this.pendingSilo,
    this.rebelSilos = 0,
    this.rebelNextStep = -1,
    this.rebelSeq = 0,
  }) : passes = passes ?? [];

  int gunshipReadyStep;
  int siloReadyStep;

  /// Gunship passes in the air: (formation, start step, end step).
  final List<(int, int, int)> passes;

  /// A silo strike asked for, waiting on the source to pay its missiles:
  /// the objective. The combat phase posts the debit and clears it.
  String? pendingSilo;
  bool siloPosted = false;

  /// The target's Missile Silos (from the launch), when they next fire, and
  /// how many have.
  int rebelSilos;
  int rebelNextStep;
  int rebelSeq;

  /// Notices for the player, drained by the UI.
  final List<String> notices = [];

  bool strafing(int formationId, int t) =>
      passes.any((p) => p.$1 == formationId && t < p.$2 + kGunshipStrafeS);

  bool get isEmpty =>
      gunshipReadyStep == 0 &&
      siloReadyStep == 0 &&
      passes.isEmpty &&
      pendingSilo == null &&
      rebelSilos == 0 &&
      rebelSeq == 0;

  Map<String, dynamic> toJson() => {
        if (gunshipReadyStep != 0) 'gunship': gunshipReadyStep,
        if (siloReadyStep != 0) 'silo': siloReadyStep,
        if (passes.isNotEmpty) 'passes': [for (final p in passes) [p.$1, p.$2, p.$3]],
        if (pendingSilo != null) 'pendingSilo': pendingSilo,
        if (siloPosted) 'siloPosted': true,
        if (rebelSilos != 0) 'rebelSilos': rebelSilos,
        if (rebelNextStep >= 0) 'rebelNext': rebelNextStep,
        if (rebelSeq != 0) 'rebelSeq': rebelSeq,
      };

  factory AirSupport.fromJson(Map<String, dynamic>? j) {
    if (j == null) return AirSupport();
    return AirSupport(
      gunshipReadyStep: (j['gunship'] as num?)?.toInt() ?? 0,
      siloReadyStep: (j['silo'] as num?)?.toInt() ?? 0,
      passes: [
        for (final p in (j['passes'] as List? ?? const []))
          (((p as List)[0] as num).toInt(), (p[1] as num).toInt(), (p[2] as num).toInt())
      ],
      pendingSilo: j['pendingSilo'] as String?,
      rebelSilos: (j['rebelSilos'] as num?)?.toInt() ?? 0,
      rebelNextStep: (j['rebelNext'] as num?)?.toInt() ?? -1,
      rebelSeq: (j['rebelSeq'] as num?)?.toInt() ?? 0,
    )..siloPosted = j['siloPosted'] == true;
  }
}
