import '../../application/ports/world_repositories.dart';
import '../../domain/autonomy/cargo_schedule.dart';
import '../../domain/colony/colony.dart';
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

class InMemoryCargoScheduleRepository implements CargoScheduleRepository {
  final Map<String, CargoSchedule> _store;

  InMemoryCargoScheduleRepository([Iterable<CargoSchedule> seed = const []])
      : _store = {for (final s in seed) s.id: s};

  @override
  Iterable<CargoSchedule> all() => _store.values;

  @override
  void save(CargoSchedule schedule) => _store[schedule.id] = schedule;
}
