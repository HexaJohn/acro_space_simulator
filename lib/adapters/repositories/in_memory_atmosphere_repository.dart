// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../application/ports/world_repositories.dart';
import '../../domain/planetary/planet_atmosphere.dart';
import '../../domain/universe/star_system.dart';

/// Every body's gas inventory, held in memory for one world.
///
/// Seeded EAGERLY from the system as it is built, not lazily from whatever the
/// body says the first time a colony asks: the inventory's reference is the
/// body's reference air, and a body that had been re-skinned (the debug
/// nuke/terraform tools) or republished before first use would otherwise seed
/// a "reference" that is nothing of the kind.
class InMemoryAtmosphereRepository implements AtmosphereRepository {
  InMemoryAtmosphereRepository([Iterable<PlanetAtmosphere> seed = const []]) {
    for (final s in seed) {
      _store[s.bodyId] = s;
    }
  }

  /// An inventory for every body in [system] that can hold a sky: every
  /// world with reference air, and (since escape, phase 2) every airless
  /// rocky one, seeded empty — gas vented there leaks away rather than
  /// vanishing on the spot. Not the star or the giants.
  factory InMemoryAtmosphereRepository.seeded(StarSystem system) =>
      InMemoryAtmosphereRepository([
        for (final b in system.all) ?PlanetAtmosphere.seed(b),
      ]);

  final Map<String, PlanetAtmosphere> _store = {};
  List<PlanetAtmosphere>? _ordered;

  @override
  PlanetAtmosphere? forBody(String bodyId) => _store[bodyId];

  @override
  Iterable<PlanetAtmosphere> all() => _ordered ??= [
        for (final id in (_store.keys.toList()..sort())) _store[id]!,
      ];

  @override
  void save(PlanetAtmosphere state) {
    if (identical(_store[state.bodyId], state)) return;
    _store[state.bodyId] = state;
    _ordered = null;
  }
}
