// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
