// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/autonomy/cargo_schedule.dart';
import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/colony.dart';
import '../../domain/megastructure/megastructure.dart';
import '../../domain/terrain/terrain_brush.dart';
import '../../domain/terrain/terrain_edits.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/weather/weather_system.dart';

/// Ports for the gameplay-systems state the subsystem tick reads/writes.
/// Separated from the core [repositories.dart] so the motion-only tick can be
/// constructed without them.

abstract class ColonyRepository {
  Iterable<Colony> all();
  Colony? byId(String id);
  void save(Colony colony);
}

/// The city-builder colonies the world owns.
///
/// Separate from [ColonyRepository] because [CitySim] is a live, mutable
/// aggregate the tick advances in place — there is no save-back step, and
/// nothing outside it may hold a divergent copy. A colony registered here keeps
/// running whether or not its screen is mounted, which is the whole point of
/// moving it out of the widget.
abstract class CityRepository {
  Iterable<CitySim> all();
  CitySim? byId(String id);
  void add(CitySim city);
  void remove(String id);
}

/// Empty default so a tick can be built with no colonies.
class NullCityRepository implements CityRepository {
  const NullCityRepository();
  @override
  Iterable<CitySim> all() => const [];
  @override
  CitySim? byId(String id) => null;
  @override
  void add(CitySim city) {}
  @override
  void remove(String id) {}
}

abstract class WeatherRepository {
  /// Weather over a body, or null if the body has none.
  WeatherSystem? forBody(BodyId body);

  /// All weather systems (one per atmospheric body) — for the evolution tick.
  Iterable<WeatherSystem> all();

  void save(WeatherSystem system);
}

abstract class CargoScheduleRepository {
  Iterable<CargoSchedule> all();
  void save(CargoSchedule schedule);
}

abstract class MegastructureRepository {
  Iterable<Megastructure> all();
  void save(Megastructure structure);
}

/// Terrain deformations per body — impact craters now, excavation later.
///
/// Unlike [TerrainHeights] (a render-reconciliation cache that physics never
/// reads), these edits DO change the collision surface: they move
/// `CelestialBody.terrainGroundRadius`. That makes them authoritative
/// simulation state — part of the determinism fingerprint, replicated to
/// clients, and never writable by a renderer.
abstract class TerrainEditsRepository {
  /// The edit list for [body], or null when it has never been deformed. Null
  /// rather than an empty list so the pristine path stays allocation-free.
  TerrainEdits? forBody(BodyId body);

  /// Append [brush] to [body]'s edits, creating the list on first deformation.
  void record(BodyId body, TerrainBrush brush);

  /// Every deformed body, for snapshotting and persistence.
  Iterable<MapEntry<BodyId, TerrainEdits>> all();
}

/// Non-deformable adapter: impacts leave no mark. The default, so a tick can be
/// built without terrain deformation wired in.
class NullTerrainEditsRepository implements TerrainEditsRepository {
  const NullTerrainEditsRepository();
  @override
  TerrainEdits? forBody(BodyId body) => null;
  @override
  void record(BodyId body, TerrainBrush brush) {}
  @override
  Iterable<MapEntry<BodyId, TerrainEdits>> all() => const [];
}

/// Empty default so a tick can run without any megaprojects.
class NullMegastructureRepository implements MegastructureRepository {
  const NullMegastructureRepository();
  @override
  Iterable<Megastructure> all() => const [];
  @override
  void save(Megastructure structure) {}
}

/// Empty default so a tick can be built without logistics. Defined in the
/// application layer (not adapters) so use cases can default to it without
/// violating the dependency rule.
class NullCargoScheduleRepository implements CargoScheduleRepository {
  const NullCargoScheduleRepository();
  @override
  Iterable<CargoSchedule> all() => const [];
  @override
  void save(CargoSchedule schedule) {}
}
