// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../../application/ports/repositories.dart';
import '../../domain/mining/resource_deposit.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/vessel.dart';

/// In-memory adapters implementing the application's repository ports. Good for
/// a single-process game and tests; a persistence/network adapter implements
/// the same interfaces later without touching use cases.

class InMemoryVesselRepository implements VesselRepository {
  final Map<VesselId, Vessel> _store = {};

  InMemoryVesselRepository([Iterable<Vessel> seed = const []]) {
    for (final v in seed) {
      _store[v.id] = v;
    }
  }

  @override
  Vessel? byId(VesselId id) => _store[id];

  @override
  Iterable<Vessel> all() => _store.values;

  @override
  void save(Vessel vessel) => _store[vessel.id] = vessel;

  @override
  void remove(VesselId id) => _store.remove(id);
}

class StaticUniverseRepository implements UniverseRepository {
  StarSystem system;
  StaticUniverseRepository(this.system);

  @override
  StarSystem current() => system;

  /// Swap a body in-place (debug/terraforming re-skin). The presenter reads
  /// `current()` each frame, so the next render picks up the change.
  void replaceBody(CelestialBody body) => system = system.withBody(body);
}

class InMemoryDepositRepository implements DepositRepository {
  final Map<String, ResourceDeposit> _store;

  InMemoryDepositRepository([Iterable<ResourceDeposit> seed = const []])
      : _store = {for (final d in seed) d.id: d};

  @override
  Iterable<ResourceDeposit> all() => _store.values;

  @override
  ResourceDeposit? byId(String id) => _store[id];
}
