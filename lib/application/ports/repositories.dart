// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/mining/resource_deposit.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/vessel.dart';

/// Repository ports. The application depends on these *interfaces*; concrete
/// storage (in-memory now, persistence/network later) lives in adapters. This
/// is the Dependency Inversion seam — the domain never reaches outward.

abstract class VesselRepository {
  Vessel? byId(VesselId id);
  Iterable<Vessel> all();
  void save(Vessel vessel);
  void remove(VesselId id);
}

abstract class UniverseRepository {
  StarSystem current();

  /// Publish a new version of one body. The bodies themselves stay immutable
  /// reference values; what changes is which value the world hands out — the
  /// planetary-atmosphere phase republishes a body whose air its inventory
  /// has moved (docs/plans/terraforming.md §5.2), and everything that resolves
  /// bodies through [current] reads the new air from then on.
  void replaceBody(CelestialBody body);
}

abstract class DepositRepository {
  Iterable<ResourceDeposit> all();
  ResourceDeposit? byId(String id);
}
