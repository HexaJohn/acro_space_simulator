// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/autonomy/cargo_schedule.dart';
import '../../domain/colony/colony.dart';
import '../../domain/megastructure/megastructure.dart';
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
