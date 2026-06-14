/// A science experiment a vessel can perform. Value object describing the
/// experiment type; the [ResearchLedger] tracks how much value remains in each
/// (experiment, situation) pair so repeats give diminishing returns — the KSP
/// science model.
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
