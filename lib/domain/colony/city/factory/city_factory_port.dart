// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony side of [FactoryColonyPort]: how one plant's floor trades with
/// a `CitySim`'s stockpile for one colony tick
/// (docs/plans/factory-floors.md §3 "Coupling to the colony", "Reward").
///
/// `CitySim.advance` builds one per floor site per tick and hands it to
/// `FactoryFloors.stepAggregate`, which runs either the measured rates or the
/// live editor sim through it. Everything a floor moves crosses here, so the
/// colony's rules live here and nowhere in the floor:
///
/// * **Take is clipped to stock.** A floor never draws a commodity below
///   zero, the same floor the flat-rate path clamps to.
/// * **Give is clipped to the storage cap**, read ONCE per tick by the caller
///   (`stockCap` walks every storage building, too dear to ask per call) and
///   reports what actually landed, the ore-cap invariant of the city builder
///   notes: a full warehouse refuses goods, it doesn't silently grow.
/// * **The colony's production multipliers apply to what lands** (biome,
///   bounty, events), exactly as they do to a flat-rate plant's outputs, so a
///   template floor makes what the plant always made under a gold rush too.
/// * **The 1.5x reward cap is enforced here, per plant.** A designed floor may
///   beat its template, but the raw-input-equivalent value it ships (Earth
///   price x units, `earthPrice`) never exceeds 1.5x the spec's flat output
///   value. The allowance accrues per colony second into a small bank (a live
///   floor ships whole crates, ten units at a time, which a per-tick budget
///   would clip on every crate) and the bank is capped at
///   [kFloorValueBankSeconds] of capped output, so an idle week can't be
///   spent as one burst. Valued on raw-input-equivalent prices so a chain
///   split across plants can't stack caps by shipping intermediates.
/// * **Refunds are not output.** The aggregate stepper hands back input the
///   scarcest input made useless through `give`; a give of a commodity this
///   port took this tick, up to what it took, goes straight back to stock and
///   is neither valued against the cap nor multiplied.
library;

import '../economy/earth_market.dart';
import 'factory_colony_port.dart';

/// Upper bound on banked reward-cap allowance, in seconds of capped output.
/// A minute holds several crates of the slowest-packing template (a 10-board
/// electronics crate every ~17 s at the spec rate) so a live floor's lumps
/// are never clipped, yet a floor that sat idle can't later ship far above
/// the cap.
const double kFloorValueBankSeconds = 60;

/// The reward cap: a designed floor's shipped value per second may reach
/// this multiple of its template's (the spec's flat output value).
const double kFloorRewardCap = 1.5;

/// Raw-input-equivalent value per second of a flat [outputs] recipe
/// (commodity → units/s), at Earth prices.
double flatOutputValuePerS(Map<String, double> outputs) {
  var v = 0.0;
  for (final k in (outputs.keys.toList()..sort())) {
    v += outputs[k]! * earthPrice(k);
  }
  return v;
}

class CityFactoryPort implements FactoryColonyPort {
  CityFactoryPort({
    required this.stock,
    required this.stockCap,
    required this.powerShare,
    required this.staffingShare,
    required this.valueAllowance,
    this.outputMult = _one,
  });

  /// The colony's stockpile, written in place.
  final Map<String, double> stock;

  /// The colony's per-commodity storage cap this tick (cached by the caller).
  final double stockCap;

  @override
  final double powerShare;

  @override
  final double staffingShare;

  /// Remaining raw-input-equivalent value this plant may ship this tick
  /// (its banked reward-cap allowance). Read back after the step to bank the
  /// rest.
  double valueAllowance;

  /// The colony's multiplier on a produced commodity (biome x bounty x
  /// event), applied to what lands.
  final double Function(String commodity) outputMult;

  /// Units taken this tick, by commodity: what a give may hand back as a
  /// refund.
  final Map<String, double> _takenNow = {};

  /// Units refused by the reward cap this tick (diagnostics and tests).
  double clippedByCap = 0;

  double _have(String c) => stock[c] ?? 0;

  @override
  double take(String commodity, double units) {
    if (!(units > 0)) return 0;
    final have = _have(commodity);
    final got = units < have ? units : (have > 0 ? have : 0.0);
    if (got <= 0) return 0;
    stock[commodity] = have - got;
    _takenNow[commodity] = (_takenNow[commodity] ?? 0) + got;
    return got;
  }

  @override
  double give(String commodity, double units) {
    if (!(units > 0)) return 0;
    var accepted = 0.0;
    // A refund first: input this port drew this tick goes straight back.
    final refundable = _takenNow[commodity] ?? 0;
    if (refundable > 0) {
      final r = units < refundable ? units : refundable;
      stock[commodity] = _have(commodity) + r;
      _takenNow[commodity] = refundable - r;
      accepted += r;
      units -= r;
      if (units <= 1e-12) return accepted;
    }
    // The reward cap, on raw-input-equivalent value.
    final price = earthPrice(commodity);
    var allowed = units;
    if (price > 0) {
      final byValue = valueAllowance / price;
      if (byValue < allowed) {
        clippedByCap += allowed - (byValue > 0 ? byValue : 0);
        allowed = byValue > 0 ? byValue : 0;
      }
    }
    if (allowed <= 0) return accepted;
    // Storage: what lands is the floor's units times the colony's
    // multipliers, up to the room left under the cap.
    final mult = outputMult(commodity);
    if (!(mult > 0)) {
      // Made and lost (a crop under nuclear winter): the floor's units are
      // consumed, nothing lands.
      if (price > 0) valueAllowance -= allowed * price;
      return accepted + allowed;
    }
    final have = _have(commodity);
    final room = stockCap - have;
    if (!(room > 0)) return accepted;
    final want = allowed * mult;
    final put = want < room ? want : room;
    stock[commodity] = have + put;
    final used = put / mult;
    if (price > 0) valueAllowance -= used * price;
    return accepted + used;
  }
}

double _one(String _) => 1;
