import 'experiment.dart';
import 'tech_tree.dart';

/// Accumulates science from experiments and spends it unlocking [TechTree]
/// nodes. Aggregate root for the science context.
///
/// Diminishing returns: each (experiment, situation) pair remembers how much of
/// its value has already been harvested, so repeating an experiment in the same
/// situation yields progressively less — encouraging exploration of new
/// situations (a situation-gated science loop).
class ResearchLedger {
  double science;
  final TechTree tree;
  final Set<String> _unlocked = {};

  /// Fraction of each (experiment, situation) pair already harvested, 0..1.
  final Map<String, double> _harvested = {};

  ResearchLedger({this.science = 0, TechTree? tree})
      : tree = tree ?? TechTree(nodes: const []);

  Set<String> get unlocked => Set.unmodifiable(_unlocked);
  bool isUnlocked(String techId) => _unlocked.contains(techId);

  void addScience(double amount) => science += amount;

  /// Run [experiment] in [situation], bank the resulting science, and return
  /// how much was gained (after diminishing returns for repeats).
  double runExperiment(Experiment experiment, {required String situation}) {
    final key = '${experiment.id}@$situation';
    final harvested = _harvested[key] ?? 0.0; // fraction already taken
    final remainingFraction = 1.0 - harvested;
    if (remainingFraction <= 0) return 0;

    final gained = experiment.baseValue * remainingFraction;
    science += gained;

    // Advance the harvested fraction: first run takes the full remaining value;
    // subsequent runs take a [diminishing] slice of what's left.
    final taken = harvested == 0
        ? 1.0 - experiment.diminishing
        : remainingFraction * (1.0 - experiment.diminishing);
    _harvested[key] = (harvested + taken).clamp(0.0, 1.0);
    return gained;
  }

  /// Attempt to unlock a tech node: must exist, not already be unlocked, have
  /// all prerequisites met, and be affordable. Spends the science on success.
  bool unlock(String techId) {
    if (_unlocked.contains(techId)) return false;
    final node = tree.node(techId);
    if (node == null) return false;
    if (!node.requires.every(_unlocked.contains)) return false;
    if (science < node.cost) return false;

    science -= node.cost;
    _unlocked.add(techId);
    return true;
  }
}
