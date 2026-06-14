/// Categories of city service a building can provide. Coverage of each type
/// across a city's population drives [happiness]. The "required" set is what
/// every citizen needs; gaps drag happiness down.
enum ServiceType {
  safety, // police / security
  health, // clinic / hospital
  leisure, // parks / entertainment
  education,
  water,
}

/// Service types every city needs to keep citizens content. Education/water are
/// bonuses; safety/health/leisure are the core trio.
const Set<ServiceType> requiredServices = {
  ServiceType.safety,
  ServiceType.health,
  ServiceType.leisure,
};
