import 'celestial_body.dart';

/// The tree of celestial bodies for a saved game. Immutable reference data;
/// the simulation never mutates it, only queries it.
class StarSystem {
  final String name;
  final BodyId rootStar;
  final Map<BodyId, CelestialBody> _bodies;

  StarSystem({
    required this.name,
    required this.rootStar,
    required Iterable<CelestialBody> bodies,
  }) : _bodies = {for (final b in bodies) b.id: b};

  CelestialBody? body(BodyId id) => _bodies[id];

  CelestialBody require(BodyId id) {
    final b = _bodies[id];
    if (b == null) throw StateError('Unknown body $id');
    return b;
  }

  Iterable<CelestialBody> get all => _bodies.values;

  /// A new system with [body] replacing the one of the same id (others kept).
  /// Used by debug/terraforming tools that re-skin a body at runtime.
  StarSystem withBody(CelestialBody body) => StarSystem(
        name: name,
        rootStar: rootStar,
        bodies: [
          for (final b in _bodies.values) if (b.id != body.id) b,
          body,
        ],
      );

  CelestialBody? parentOf(CelestialBody b) =>
      b.parent == null ? null : _bodies[b.parent!];

  /// Direct satellites of [id].
  Iterable<CelestialBody> childrenOf(BodyId id) =>
      _bodies.values.where((b) => b.parent == id);
}
