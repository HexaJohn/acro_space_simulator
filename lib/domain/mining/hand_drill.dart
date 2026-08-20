// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../terrain/terrain_brush.dart';

/// A hand-held excavation tool: the walker's drill.
///
/// Where [DepositExcavation] carves a quarry that a *deposit's* lifetime
/// extraction earns, this carves wherever the operator points. Same two
/// invariants, for the same reasons:
///
///  * **Brushes are earned in quanta, and each swallows the last.** A
///    subtracted sphere at a fixed centre absorbs every smaller sphere there,
///    so a bore that grows through [stepRadiusM] increments leaves at most
///    [maxRadiusM] / [stepRadiusM] brushes behind — not one per frame. The
///    edit list is replayed in order, hashed into the snapshot fingerprint and
///    shipped to clients, so per-frame brushes would be ruinous.
///  * **The compact record is the bore, not the brush list.** A [DrillBore] is
///    a centre and a volume; its brushes are a pure function of those. Saving
///    the bores and re-emitting on load reproduces the same holes.
///
/// The drill deliberately does NOT credit ore. It returns the volume it moved
/// ([DrillTick.excavatedM3]) and leaves crediting to a caller that knows what
/// the ground there is made of.
class HandDrill {
  const HandDrill({
    this.removalRateM3PerS = 0.6,
    this.stepRadiusM = 0.25,
    this.maxRadiusM = 3.0,
    this.reachM = 4.0,
    this.newBoreDistanceM = 1.0,
  });

  /// Ground removed per second of held trigger, cubic metres. 0.6 m³/s digs a
  /// person-sized hollow in about ten seconds — slow enough to feel like work,
  /// fast enough to see the ground move.
  final double removalRateM3PerS;

  /// Bore radius growth that earns one brush. The granularity knob: smaller
  /// steps mean smoother growth and more brushes per hole.
  final double stepRadiusM;

  /// Radius at which a bore is worked out and stops growing. Bounds both the
  /// hole and the brush count; dig wider by moving and starting a new bore.
  final double maxRadiusM;

  /// How far in front of the eye the drill bites, metres.
  ///
  /// Arm's length plus a step, NOT arm's length. The ray starts at the EYE and
  /// the operator aims by looking, so even digging at their own boots is 1.7 m
  /// straight down and more at any natural angle — a 2.5 m reach missed the
  /// ground entirely whenever the view was tilted off the local vertical, and
  /// the tool simply did nothing with the trigger held.
  final double reachM;

  /// Aim drift that abandons the current bore and starts a new one, metres.
  final double newBoreDistanceM;

  /// Brushes per bore once it is worked out.
  int get maxBrushesPerBore => (maxRadiusM / stepRadiusM).floor();

  /// Where the drill bites: the first point along the aim ray that is inside
  /// the ground, or null when the operator is pointing at nothing within
  /// [reachM] (at the sky, or across a valley).
  ///
  /// A march rather than a radial projection: pointing at a cliff FACE has to
  /// bite the face, and "project the aim point down to the ground" would
  /// instead dig a dimple out of the plateau above it. [steps] samples over
  /// the reach is enough at arm's length — the bore is metres wide.
  Vector3? contact({
    required Vector3 eyeBF,
    required Vector3 aimDirBF,
    required double Function(Vector3 posBF) groundRadiusAt,
    int steps = 12,
  }) {
    if (steps <= 0) return null;
    final dir = aimDirBF.normalized;
    for (var i = 1; i <= steps; i++) {
      final p = eyeBF + dir * (reachM * i / steps);
      if (p.length <= groundRadiusAt(p)) return p;
    }
    return null;
  }

  /// Advance one frame of held trigger against the bore at [aimBF].
  ///
  /// Pass the previous tick's [bore] back in; a null bore, or an aim that has
  /// drifted past [newBoreDistanceM], starts a fresh one. The returned brushes
  /// must be recorded in order.
  DrillTick drill({
    DrillBore? bore,
    required Vector3 aimBF,
    required double dt,
    required int tick,
  }) {
    if (!dt.isFinite || dt <= 0) {
      return DrillTick(bore: bore, brushes: const [], excavatedM3: 0);
    }
    var b = bore;
    if (b == null || (aimBF - b.centreBF).length > newBoreDistanceM) {
      b = DrillBore(centreBF: aimBF);
    }

    final before = b.volumeM3;
    b.volumeM3 = math.min(b.volumeM3 + removalRateM3PerS * dt, _maxVolumeM3);
    final moved = b.volumeM3 - before;

    final earned = math.min(maxBrushesPerBore, (b.radiusM / stepRadiusM).floor());
    if (earned <= b.carvedSteps) {
      return DrillTick(bore: b, brushes: const [], excavatedM3: moved);
    }
    final brushes = <TerrainBrush>[];
    for (var s = b.carvedSteps + 1; s <= earned; s++) {
      brushes.add(TerrainBrush.sphere(
        centreBF: b.centreBF,
        radiusM: s * stepRadiusM,
        tick: tick,
      ));
    }
    b.carvedSteps = earned;
    return DrillTick(bore: b, brushes: brushes, excavatedM3: moved);
  }

  double get _maxVolumeM3 => 4 / 3 * math.pi * maxRadiusM * maxRadiusM * maxRadiusM;

  /// The brush a SAVED bore re-emits on load — one sphere at its worked size,
  /// which is all the intermediate quanta ever added up to.
  TerrainBrush restoreBrush(DrillBore bore, {required int tick}) =>
      TerrainBrush.sphere(
        centreBF: bore.centreBF,
        radiusM: bore.carvedSteps * stepRadiusM,
        tick: tick,
      );
}

/// One hole the drill is working, in the body-fixed frame. Mutable: the view
/// hands the same bore back each frame while the trigger is held.
class DrillBore {
  DrillBore({
    required this.centreBF,
    this.volumeM3 = 0,
    this.carvedSteps = 0,
  });

  final Vector3 centreBF;

  /// Ground removed here so far, cubic metres.
  double volumeM3;

  /// Quanta already turned into brushes — the resume point, exactly like
  /// `ResourceDeposit.carvedQuanta`.
  int carvedSteps;

  /// Radius of a ball holding [volumeM3].
  double get radiusM => math.pow(volumeM3 * 3 / (4 * math.pi), 1 / 3.0).toDouble();
}

/// What one frame of drilling produced.
class DrillTick {
  const DrillTick({
    required this.bore,
    required this.brushes,
    required this.excavatedM3,
  });

  /// The bore to hand back next frame (null only if nothing was drilled).
  final DrillBore? bore;

  /// Newly earned brushes, in order. Usually empty — a brush is earned only
  /// when the bore grows through a whole [HandDrill.stepRadiusM].
  final List<TerrainBrush> brushes;

  /// Ground removed this frame, cubic metres. For a caller that wants to turn
  /// spoil into ore.
  final double excavatedM3;
}
