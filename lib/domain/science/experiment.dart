// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

/// A science experiment a vessel can perform. Value object describing the
/// experiment type; the [ResearchLedger] tracks how much value remains in each
/// (experiment, situation) pair so repeats give diminishing returns
/// (situation-gated science).
class Experiment {
  final String id;

  /// Full science value when run fresh in a situation.
  final double baseValue;

  /// Fraction of the remaining value recovered each repeat (0..1). 0 means a
  /// situation is fully tapped after one run; 0.5 means each repeat yields half
  /// of what is left.
  final double diminishing;

  const Experiment({
    required this.id,
    required this.baseValue,
    this.diminishing = 0.25,
  });
}
