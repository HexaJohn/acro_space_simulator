import 'dart:async';
import 'dart:typed_data';

import '../adapters/events/in_memory_event_bus.dart';
import '../adapters/repositories/in_memory_repositories.dart';
import '../adapters/repositories/in_memory_world_repositories.dart';
import '../adapters/wire/flatbuffer_codec.dart';
import '../application/ports/compute_port.dart';
import '../application/snapshot/world_snapshot.dart';
import '../application/usecases/advance_simulation_tick.dart';
import '../domain/multiplayer/command.dart';
import '../domain/orbits/soi_transition_service.dart';
import '../domain/science/research_ledger.dart';
import '../domain/science/tech_tree.dart';
import '../domain/shared/vector3.dart';
import '../domain/simulation/simulation_clock.dart';
import '../domain/vessel/vessel.dart';
import 'bridge/sim_bridge.dart';
import 'sample_world.dart';

/// The authoritative in-process simulation, owned at APP scope and running from
/// launch — no longer tied to the flight screen's lifecycle. It advances physics
/// on a fixed step, serves the world to an external renderer (Unreal) over
/// [bridge], and applies the commands that renderer sends back. The Flutter
/// flight view ([SimulationView]) OBSERVES the same repos, so flying in Flutter
/// and watching in Unreal are one and the same world.
///
/// Web-safe: [bridge] is the no-op stub there (no dart:io), so the sim still runs
/// purely in-process in the browser.
class SimEngine {
  SimEngine() {
    _build();
  }

  // ---- Owned simulation state (the flight view binds to these) ----
  late final SimulationClock clock;
  late final InMemoryVesselRepository vessels;
  late final StaticUniverseRepository universe;
  late final InMemoryEventBus events;
  late final InMemoryColonyRepository colonies;
  late final InMemoryDepositRepository deposits;
  late final InMemoryWeatherRepository weather;
  late final ResearchLedger research;
  late AdvanceSimulationTick advance;

  // Debug cheats. The HEADLESS engine idles REALISTIC (destruction on, fuel
  // burns); the flight view forces its dev cheats on while it's open and restores
  // these on exit, so a flight session can't leave the app-scoped sim permanently
  // cheated.
  bool disableOverheat = false;
  bool disableAeroStress = false;
  bool disableImpact = false;
  bool infiniteFuel = false;

  // ---- Engine bridge (serves the world to Unreal) ----
  final SimBridge bridge = createSimBridge();
  static const FlatBufferCodec _wire = FlatBufferCodec();
  StreamSubscription<Uint8List>? _commandSub;
  int _bridgeTick = 0;
  double _lastDescriptorAt = -2; // s; negative so the first publish carries them

  // ---- Fixed-step loop ----
  Timer? _timer;
  final Stopwatch _stopwatch = Stopwatch();
  double _accum = 0;
  double _wallLast = 0;
  bool _started = false;

  void _build() {
    final system = SampleWorld.realSystem();
    // Boot fleet: the demo Earth orbiter (the flight view injects an ascent craft
    // / traffic on top when it opens). ~3000 km up so it's clearly off the limb.
    vessels = InMemoryVesselRepository([
      SampleWorld.buildEarthOrbiter(altitude: 3000000),
    ]);
    universe = StaticUniverseRepository(system);
    events = InMemoryEventBus();
    colonies = InMemoryColonyRepository();
    deposits = InMemoryDepositRepository();
    weather = InMemoryWeatherRepository();
    research = ResearchLedger(
      tree: TechTree(
        nodes: const [
          TechNode(id: 'start', cost: 0),
          TechNode(id: 'generalRocketry', cost: 20, requires: ['start']),
        ],
      ),
    );
    clock = SimulationClock(warpFactor: 1, fixedStep: 0.02);
    rebuildAdvance();
  }

  /// (Re)build the tick use case from the current cheat flags. Call after a cheat
  /// toggle (the flight view's debug panel does).
  void rebuildAdvance() {
    advance = AdvanceSimulationTick(
      vessels: vessels,
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: colonies,
      deposits: deposits,
      weather: weather,
      research: research,
      disableOverheat: disableOverheat,
      disableAeroStress: disableAeroStress,
      disableImpact: disableImpact,
    );
  }

  /// Open the bridge and start the fixed-step loop. Idempotent — called once at
  /// app boot.
  void start({int port = 5800}) {
    if (_started) return;
    _started = true;
    unawaited(bridge.start(port: port));
    _commandSub = bridge.commandFrames.listen(_applyCommands);
    _stopwatch.start();
    _wallLast = 0;
    // ~60 Hz wall clock; the accumulator runs as many fixed steps as real time
    // accrued, so the sim rate stays independent of the timer's exact cadence.
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
  }

  void _tick() {
    final now = _stopwatch.elapsedMicroseconds / 1e6;
    final dt = now - _wallLast;
    _wallLast = now;

    if (infiniteFuel) {
      for (final v in vessels.all()) {
        for (final p in v.allParts) {
          for (final r in p.resources) {
            r.amount = r.capacity;
          }
        }
      }
    }

    // Run as many fixed steps as real time accrued; carry the leftover across
    // frames. Cap the backlog so a stall skips time instead of spiralling.
    _accum += dt;
    var steps = 0;
    while (_accum >= clock.fixedStep && steps < 200) {
      advance.execute(clock);
      _accum -= clock.fixedStep;
      steps++;
    }
    if (steps >= 200) _accum = 0;

    // The in-process consumers use push (subscribe); nothing drains the bus's
    // `recent` buffer, so clear it each tick to keep it from growing forever now
    // the engine runs for the whole app lifetime.
    events.clearRecent();

    // Serve the freshly-advanced world to a connected renderer. Gated on
    // hasClients so capture+encode cost is zero when nothing's attached. Static
    // body descriptors are sticky engine-side, so ship them only ~1 Hz.
    if (bridge.hasClients) {
      final sendDescriptors = (now - _lastDescriptorAt) >= 1.0;
      if (sendDescriptors) _lastDescriptorAt = now;
      final world = WorldSnapshot.capture(
        _bridgeTick++,
        vessels,
        system: universe.current(),
        epoch: clock.epoch,
        colonies: colonies,
        includeDescriptors: sendDescriptors,
      );
      bridge.publish(_wire.encodeWorld(world));
    }
  }

  /// Apply a CommandFrame from the connected renderer (Unreal) to the live repos.
  /// Local serve path: the single connected renderer is trusted (no ownership
  /// gate), mirroring [ApplyCommands]'s per-command handling.
  void _applyCommands(Uint8List frame) {
    final CommandBatch batch;
    try {
      batch = _wire.decodeCommands(frame);
    } catch (_) {
      return; // ignore a malformed/foreign frame rather than crash the loop
    }
    for (final cmd in batch.commands) {
      switch (cmd) {
        case SetThrottleCommand(:final vesselId, :final throttle):
          final v = vessels.byId(VesselId(vesselId));
          if (v != null) {
            v.setThrottle(throttle);
            vessels.save(v);
          }
        case SeparateStageCommand(:final vesselId):
          final v = vessels.byId(VesselId(vesselId));
          if (v != null && v.separateStage()) vessels.save(v);
        case SetAttitudeCommand(
            :final vesselId,
            :final headingX,
            :final headingY,
            :final headingZ
          ):
          final v = vessels.byId(VesselId(vesselId));
          if (v != null) {
            v.targetFacing = Vector3(headingX, headingY, headingZ);
            vessels.save(v);
          }
        case PlaceBuildingCommand():
        case ReportTerrainHeightCommand():
          break; // colony/terrain intent not served on this path
      }
    }
  }

  // Ref-count of injected craft ids so an id shared across two overlapping flight
  // sessions (route pop->push) isn't yanked out from under the new one: the craft
  // is only removed when the LAST injector detaches.
  final Map<VesselId, int> _injectedRefs = {};

  /// Add a vessel to the live sim (e.g. an ascent craft chosen at flight entry).
  /// Idempotent by id (won't duplicate); ref-counted for safe removal.
  void injectVessel(Vessel v) {
    _injectedRefs.update(v.id, (n) => n + 1, ifAbsent: () => 1);
    if (vessels.byId(v.id) == null) vessels.save(v);
  }

  /// Drop a previously [injectVessel]ed craft. Removes it only when its last
  /// injector detaches (matching ref-count), so overlapping sessions are safe.
  void removeVessel(VesselId id) {
    final remaining = (_injectedRefs[id] ?? 1) - 1;
    if (remaining <= 0) {
      _injectedRefs.remove(id);
      vessels.remove(id);
    } else {
      _injectedRefs[id] = remaining;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    unawaited(_commandSub?.cancel());
    unawaited(bridge.stop());
    _started = false;
  }
}

/// App-scoped singleton, created + started in main() so the sim is live from
/// boot. The flight view reads this rather than building its own sim.
SimEngine? _instance;
SimEngine get simEngine => _instance ??= SimEngine();
