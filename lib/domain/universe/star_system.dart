// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

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

  /// A new system with [body] replacing the one of the same id (others kept),
  /// or added at the end if the system has no such body.
  ///
  /// The replacement keeps its SLOT. Terraforming republishes a body every
  /// time its air moves, and a replace that moved the body to the end would
  /// make [all]'s order depend on which world was terraformed last — order
  /// that SOI scans, snapshots and the wire all iterate in.
  StarSystem withBody(CelestialBody body) => StarSystem(
        name: name,
        rootStar: rootStar,
        bodies: [
          for (final b in _bodies.values) b.id == body.id ? body : b,
          if (!_bodies.containsKey(body.id)) body,
        ],
      );

  CelestialBody? parentOf(CelestialBody b) =>
      b.parent == null ? null : _bodies[b.parent!];

  /// Direct satellites of [id].
  Iterable<CelestialBody> childrenOf(BodyId id) =>
      _bodies.values.where((b) => b.parent == id);
}
