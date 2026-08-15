// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The WORLD behind the flight view: its repositories, its clock, and the tick
/// that advances them.
///
/// Pulled out of `_SimulationViewState` because none of it is a widget concern.
/// A screen decides what to draw and which button was pressed; what exists in
/// the world, and how it advances, outlives any screen that happens to be
/// looking at it — which is the same reasoning that moved the colony sim into
/// the domain, applied one layer up.
///
/// Practical payoff: the composition root is now readable in one screen of
/// code instead of being interleaved with camera state and gesture handling,
/// and it can be constructed headlessly in a test without pumping a widget.
library;

import '../../adapters/events/in_memory_event_bus.dart';
import '../../adapters/repositories/in_memory_repositories.dart';
import '../../adapters/repositories/in_memory_world_repositories.dart';
import '../../application/ports/compute_port.dart';
import '../../application/usecases/advance_simulation_tick.dart';
import '../../domain/orbits/soi_transition_service.dart';
import '../../domain/science/research_ledger.dart';
import '../../domain/science/tech_tree.dart';
import '../../domain/simulation/domain_event.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/universe/star_system.dart';
import '../../domain/vessel/vessel.dart';

/// Debug cheats that change how the tick is built.
///
/// Grouped into a value rather than passed as five booleans because they are
/// always set and read together, and because rebuilding the tick has to be
/// all-or-nothing — a half-applied set of cheats is a world that behaves
/// differently from the one the panel says you are in.
class FlightCheats {
  const FlightCheats({
    this.disableOverheat = true,
    this.disableAeroStress = true,
    this.disableCraftDestruction = true,
    this.disableCrater = false,
  });

  final bool disableOverheat;
  final bool disableAeroStress;
  final bool disableCraftDestruction;
  final bool disableCrater;

  FlightCheats copyWith({
    bool? disableOverheat,
    bool? disableAeroStress,
    bool? disableCraftDestruction,
    bool? disableCrater,
  }) =>
      FlightCheats(
        disableOverheat: disableOverheat ?? this.disableOverheat,
        disableAeroStress: disableAeroStress ?? this.disableAeroStress,
        disableCraftDestruction:
            disableCraftDestruction ?? this.disableCraftDestruction,
        disableCrater: disableCrater ?? this.disableCrater,
      );
}

class FlightSession {
  /// Build a world from a starting [system] and [fleet].
  FlightSession({
    required StarSystem system,
    required Iterable<Vessel> fleet,
    FlightCheats cheats = const FlightCheats(),
    void Function(DomainEvent)? onEvent,
  })  : universe = StaticUniverseRepository(system),
        vessels = InMemoryVesselRepository(fleet),
        _cheats = cheats {
    if (onEvent != null) events.subscribe(onEvent);
    rebuildTick();
  }

  final StaticUniverseRepository universe;
  final InMemoryVesselRepository vessels;
  final InMemoryEventBus events = InMemoryEventBus();
  final InMemoryColonyRepository colonies = InMemoryColonyRepository();
  final InMemoryDepositRepository deposits = InMemoryDepositRepository();
  final InMemoryWeatherRepository weather = InMemoryWeatherRepository();

  /// City-builder colonies this world owns. A colony registered here keeps
  /// running whether or not its screen is mounted.
  final InMemoryCityRepository cities = InMemoryCityRepository();

  /// Crater/excavation state. Persists across tick rebuilds — the cheat
  /// toggles rebuild the tick, and dropping this would erase every crater
  /// already dug.
  final InMemoryTerrainEditsRepository terrainEdits =
      InMemoryTerrainEditsRepository();

  final ResearchLedger research = ResearchLedger(
    tree: TechTree(
      nodes: const [
        TechNode(id: 'start', cost: 0),
        TechNode(id: 'generalRocketry', cost: 20, requires: ['start']),
      ],
    ),
  );

  /// Dev start: 1x warp on a 50 Hz fixed step.
  final SimulationClock clock =
      SimulationClock(warpFactor: 1, fixedStep: 0.02);

  late AdvanceSimulationTick advance;

  FlightCheats _cheats;
  FlightCheats get cheats => _cheats;

  set cheats(FlightCheats value) {
    _cheats = value;
    rebuildTick();
  }

  /// (Re)build the tick from the current cheat flags.
  void rebuildTick() {
    advance = AdvanceSimulationTick(
      vessels: vessels,
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: colonies,
      cities: cities,
      deposits: deposits,
      weather: weather,
      research: research,
      terrainEdits: terrainEdits,
      disableOverheat: _cheats.disableOverheat,
      disableAeroStress: _cheats.disableAeroStress,
      disableCraftDestruction: _cheats.disableCraftDestruction,
      disableCrater: _cheats.disableCrater,
    );
  }

  /// Advance the world one fixed step.
  void step() => advance.execute(clock);
}
