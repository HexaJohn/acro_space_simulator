import '../../domain/mining/resource_deposit.dart';
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
}

abstract class DepositRepository {
  Iterable<ResourceDeposit> all();
  ResourceDeposit? byId(String id);
}
