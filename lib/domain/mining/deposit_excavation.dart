// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../terrain/dem_registry.dart';
import '../terrain/terrain_brush.dart';
import '../universe/celestial_body.dart';
import 'resource_deposit.dart';

/// Turns cumulative extraction at a [ResourceDeposit] into visible terrain
/// excavation: a stepped quarry pit that deepens and widens as ore comes out
/// of the ground. Domain service.
///
/// ## Derived, not recorded
///
/// The pit is a pure function of `deposit.extractedTotal`: every
/// [quantumUnits] extracted earns one more excavation "quantum", and quantum
/// `n` always produces the same [TerrainBrush] (same centre, radius, depth).
/// That is what lets saves persist ONE number per deposit instead of a brush
/// list — on load `carvedQuanta` starts at 0, the first tick re-emits every
/// earned quantum, and the terrain ends up byte-identical to the session that
/// saved it.
///
/// Each quantum is a fresh [TerrainBrush.steppedPit] over the same centre,
/// slightly larger than the last. Levelling brushes REPLACE the surface inside
/// their footprint rather than subtracting from it, so the new pit swallows
/// its predecessor and the composed surface only ever shows the latest, at the
/// cost of keeping the superseded brushes in the list — bounded by
/// [maxQuanta].
///
/// ## Sizing
///
/// The pit's excavated volume tracks the mined mass: `extractedTotal *
/// [unitMassKg]` of ore at [regolithDensity], multiplied by [spoilFactor]
/// because a real dig moves far more overburden than product (and because a
/// pit the exact size of the ore body would be invisible at game scale). The
/// pit keeps a fixed depth:radius aspect as it grows, so a worked-out deposit
/// reads as a broad terraced quarry, not a well shaft.
class DepositExcavation {
  const DepositExcavation({
    this.quantumUnits = 2500,
    this.maxQuanta = 24,
    this.unitMassKg = 1.0,
    this.regolithDensity = 1500,
    this.spoilFactor = 10,
    this.depthOverRadius = 0.45,
  });

  /// Extracted units per excavation step. One step = one appended brush, so
  /// this is the knob trading terrain-edit granularity against edit-list size.
  final double quantumUnits;

  /// Hard cap on quanta per deposit. Bounds the brush list for huge or
  /// INFINITE deposits (null reserves accumulate [ResourceDeposit
  /// .extractedTotal] forever); past the cap the ground stops changing.
  final int maxQuanta;

  /// kg per resource unit (matches the ore containers' unitMass).
  final double unitMassKg;

  /// Bulk density of the excavated ground, kg/m^3. Loose regolith, matching
  /// the tick's crater-scaling default.
  final double regolithDensity;

  /// Pit volume per volume of ore actually banked. Overburden, spoil, and
  /// honest game-scale visibility in one factor.
  final double spoilFactor;

  /// Pit depth as a fraction of its rim radius. Held constant as the pit
  /// grows: quarries get wider faster than they get deeper.
  final double depthOverRadius;

  /// The brushes newly earned by [deposit]'s extraction total — everything
  /// past `deposit.carvedQuanta`, which this ADVANCES to match. Empty when
  /// nothing new was earned or the body has no voxel terrain. The caller is
  /// responsible for recording every returned brush, in order.
  List<TerrainBrush> pendingBrushes({
    required ResourceDeposit deposit,
    required CelestialBody body,
    required int tick,
  }) {
    // Cheap gates FIRST — most deposits most ticks have earned nothing, and
    // building a terrain field can be expensive (or, for a DEM body whose
    // pyramid isn't loaded, a throw).
    final earned = math.min(
        maxQuanta, quantumUnits <= 0 ? 0 : deposit.extractedTotal ~/ quantumUnits);
    if (earned <= deposit.carvedQuanta) return const [];

    final terrain = body.terrain;
    if (terrain == null) return const [];
    // A DEM body whose pyramid isn't registered (headless test, early boot)
    // can't be sampled. Skip WITHOUT advancing carvedQuanta: the quanta stay
    // owed, and the pit appears on the first tick after the DEM loads.
    final demId = terrain.demBodyId;
    if (demId != null && !DemRegistry.contains(demId)) return const [];
    final field = body.terrainField;
    if (field == null) return const [];

    // Deposit site, body-fixed. Datum comes from the PRISTINE relief so the
    // pit geometry never depends on what else has been dug nearby — that
    // independence is what makes save-reconstruction exact.
    final cosLat = math.cos(deposit.latitude);
    final dir = Vector3(
      cosLat * math.cos(deposit.longitude),
      cosLat * math.sin(deposit.longitude),
      math.sin(deposit.latitude),
    );
    final datum = field.baseGroundRadiusAt(dir.x, dir.y, dir.z);
    final centre = dir * datum;

    final brushes = <TerrainBrush>[];
    for (var q = deposit.carvedQuanta + 1; q <= earned; q++) {
      final volume =
          q * quantumUnits * unitMassKg / regolithDensity * spoilFactor;
      // Stepped pit ~ a terraced cylinder at ~80% fill: V = 0.8*pi*r^2*d with
      // d = depthOverRadius*r, solved for r.
      final radius =
          math.pow(volume / (0.8 * math.pi * depthOverRadius), 1 / 3.0)
              .toDouble();
      brushes.add(TerrainBrush.steppedPit(
        centreBF: centre,
        radiusM: radius,
        datumRadiusM: datum,
        depthM: radius * depthOverRadius,
        benches: 4,
        falloffM: radius * 0.6,
        tick: tick,
      ));
    }
    deposit.carvedQuanta = earned;
    return brushes;
  }
}
