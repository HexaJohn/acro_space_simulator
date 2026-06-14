/// The road / utility network of a city: an undirected graph of nodes
/// (buildings, intersections, the depot/hub) connected by roads. A building can
/// only function if it is connected to the [hub] — disconnected buildings get
/// no service and shut down. Domain entity for the city context.
///
/// Reachability is plain BFS from the hub (the same flood used by the comms
/// relay network), so adding/removing roads dynamically re-wires the city.
class CityNetwork {
  /// The always-connected root node (depot / city centre / spaceport).
  final String hub;
  final Map<String, Set<String>> _adjacency = {};

  CityNetwork({required this.hub});

  void addRoad(String a, String b) {
    _adjacency.putIfAbsent(a, () => {}).add(b);
    _adjacency.putIfAbsent(b, () => {}).add(a);
  }

  void removeRoad(String a, String b) {
    _adjacency[a]?.remove(b);
    _adjacency[b]?.remove(a);
  }

  /// Every node reachable from the hub (the connected component containing it).
  Set<String> connectedSet() {
    final seen = <String>{hub};
    final frontier = <String>[hub];
    while (frontier.isNotEmpty) {
      final n = frontier.removeLast();
      for (final m in _adjacency[n] ?? const <String>{}) {
        if (seen.add(m)) frontier.add(m);
      }
    }
    return seen;
  }

  bool isConnected(String node) =>
      node == hub || connectedSet().contains(node);
}
