// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../application/ports/world_repositories.dart';
import '../../domain/autonomy/cargo_schedule.dart';
import '../../domain/colony/colony.dart';
import '../../domain/megastructure/megastructure.dart';
import '../../domain/terrain/terrain_brush.dart';
import '../../domain/terrain/terrain_edits.dart';
import '../../domain/universe/celestial_body.dart';
import '../../domain/weather/weather_system.dart';

class InMemoryColonyRepository implements ColonyRepository {
  final Map<String, Colony> _store;

  InMemoryColonyRepository([Iterable<Colony> seed = const []])
      : _store = {for (final c in seed) c.id: c};

  @override
  Iterable<Colony> all() => _store.values;

  @override
  Colony? byId(String id) => _store[id];

  @override
  void save(Colony colony) => _store[colony.id] = colony;
}

class InMemoryWeatherRepository implements WeatherRepository {
  final Map<BodyId, WeatherSystem> _byBody;

  InMemoryWeatherRepository([Iterable<WeatherSystem> seed = const []])
      : _byBody = {for (final w in seed) w.body: w};

  @override
  WeatherSystem? forBody(BodyId body) => _byBody[body];

  @override
  Iterable<WeatherSystem> all() => _byBody.values;

  @override
  void save(WeatherSystem system) => _byBody[system.body] = system;
}

/// No-weather adapter: every body is calm. Lets the tick run without a weather
/// model wired in.
class NullWeatherRepository implements WeatherRepository {
  const NullWeatherRepository();
  @override
  WeatherSystem? forBody(BodyId body) => null;
  @override
  Iterable<WeatherSystem> all() => const [];
  @override
  void save(WeatherSystem system) {}
}

class InMemoryMegastructureRepository implements MegastructureRepository {
  final Map<String, Megastructure> _store;

  InMemoryMegastructureRepository([Iterable<Megastructure> seed = const []])
      : _store = {for (final m in seed) m.id: m};

  @override
  Iterable<Megastructure> all() => _store.values;

  @override
  void save(Megastructure structure) => _store[structure.id] = structure;
}

class InMemoryCargoScheduleRepository implements CargoScheduleRepository {
  final Map<String, CargoSchedule> _store;

  InMemoryCargoScheduleRepository([Iterable<CargoSchedule> seed = const []])
      : _store = {for (final s in seed) s.id: s};

  @override
  Iterable<CargoSchedule> all() => _store.values;

  @override
  void save(CargoSchedule schedule) => _store[schedule.id] = schedule;
}

/// Deformable-terrain store. Lists are created lazily on a body's first edit,
/// so an untouched world holds nothing and every terrain lookup takes the
/// pristine analytic path.
class InMemoryTerrainEditsRepository implements TerrainEditsRepository {
  InMemoryTerrainEditsRepository(
      [Map<BodyId, Iterable<TerrainBrush>> seed = const {}]) {
    for (final e in seed.entries) {
      _byBody[e.key] = TerrainEdits.of(e.value);
    }
  }

  final Map<BodyId, TerrainEdits> _byBody = {};

  @override
  TerrainEdits? forBody(BodyId body) => _byBody[body];

  @override
  void record(BodyId body, TerrainBrush brush) =>
      (_byBody[body] ??= TerrainEdits()).add(brush);

  @override
  Iterable<MapEntry<BodyId, TerrainEdits>> all() => _byBody.entries;
}
