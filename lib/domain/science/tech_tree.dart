/// A node in the technology tree: a research unlock with a science [cost] and
/// optional prerequisite node ids. Value object.
class TechNode {
  final String id;
  final double cost;
  final List<String> requires;

  const TechNode({
    required this.id,
    required this.cost,
    this.requires = const [],
  });
}

/// The technology tree — the set of [TechNode]s and their prerequisite graph.
/// Pure reference data; the [ResearchLedger] tracks which are unlocked.
class TechTree {
  final Map<String, TechNode> _nodes;

  TechTree({required Iterable<TechNode> nodes})
      : _nodes = {for (final n in nodes) n.id: n};

  TechNode? node(String id) => _nodes[id];
  Iterable<TechNode> get all => _nodes.values;

  /// Nodes whose prerequisites are all in [unlocked] (available to research).
  Iterable<TechNode> available(Set<String> unlocked) => _nodes.values.where(
        (n) => !unlocked.contains(n.id) &&
            n.requires.every(unlocked.contains),
      );
}
