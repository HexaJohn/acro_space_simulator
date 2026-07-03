import 'dart:typed_data';

import '../../adapters/events/in_memory_event_bus.dart';
import '../../adapters/repositories/in_memory_repositories.dart';
import '../../adapters/repositories/in_memory_world_repositories.dart';
import '../../adapters/wire/flatbuffer_codec.dart';
import '../../application/ports/compute_port.dart';
import '../../application/usecases/advance_simulation_tick.dart';
import '../../application/usecases/apply_commands.dart';
import '../../application/usecases/authoritative_simulation.dart';
import '../../domain/multiplayer/command.dart';
import '../../domain/multiplayer/player.dart';
import '../../domain/multiplayer/session.dart';
import '../../domain/orbits/soi_transition_service.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/universe/terrain_heights.dart';
import '../sample_world.dart';

/// The engine-bridge boundary: a flat, byte-in / byte-out wrapper around an
/// [AuthoritativeSimulation]. Everything crossing it is a FlatBuffer frame
/// (`wire/sim.fbs`), so an out-of-process host (a socket server, a shared-memory
/// ring, or an embedded VM) needs no knowledge of domain types.
///
///   * [submit]      — queue a CommandFrame (engine -> sim).
///   * [step]        — advance exactly one fixed authoritative tick.
///   * [frameBytes]  — the current world as a WorldFrame (sim -> engine).
///
/// Real-time pacing (accumulate wall time, run N fixed ticks) belongs to the
/// caller — the host deliberately ticks at the sim's fixed step and nothing
/// faster, to preserve determinism.
class SimHost {
  final AuthoritativeSimulation sim;
  final FlatBufferCodec codec;
  final List<CommandBatch> _inbox = [];

  SimHost(this.sim, {this.codec = const FlatBufferCodec()});

  /// Decode and queue a FlatBuffer CommandFrame. Drained on the next [step].
  void submit(Uint8List commandFrame) =>
      _inbox.add(codec.decodeCommands(commandFrame));

  /// Advance one fixed authoritative tick, draining all queued commands first.
  /// If [sim.step] throws, the queued commands are NOT dropped — they remain
  /// for the next tick. Commands submitted re-entrantly during the step are
  /// preserved (only the batches actually processed are removed).
  void step() {
    final batches = List<CommandBatch>.of(_inbox);
    sim.step(batches);
    _inbox.removeRange(0, batches.length);
  }

  /// How often (in ticks) to include the static body descriptors. They're sticky
  /// on the engine side (cached + joined by id), so re-sending ~once a second is
  /// plenty for a late-joining client; every other frame omits them.
  static const int descriptorEveryTicks = 20; // ~1 Hz at the default 20 Hz server

  /// The current world encoded as a FlatBuffer WorldFrame. Body descriptors
  /// (kind/atmosphere/composition) ride along only every [descriptorEveryTicks].
  Uint8List frameBytes() => codec.encodeWorld(
        sim.snapshot(
          includeDescriptors:
              sim.session.authoritativeTick % descriptorEveryTicks == 0,
        ),
      );

  int get tick => sim.session.authoritativeTick;

  /// A host over the bundled sample world (the real Solar System + a demo
  /// orbiter), owned by [owner]. Single-process convenience and the server's
  /// default.
  factory SimHost.sample({String owner = 'player-1'}) {
    final system = SampleWorld.realSystem();
    final vessel = SampleWorld.buildVessel(altitude: 400000);
    final vessels = InMemoryVesselRepository([vessel]);
    final colonies = InMemoryColonyRepository()..save(SampleWorld.buildColony());
    final terrain = TerrainHeights();
    final advance = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: colonies,
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );
    final session = Session(
      id: 'bridge',
      players: [
        Player(
          id: PlayerId(owner),
          displayName: 'Pilot',
          ownedAssetIds: {vessel.id.value},
        ),
      ],
    );
    final sim = AuthoritativeSimulation(
      session: session,
      applyCommands: ApplyCommands(vessels: vessels, terrain: terrain),
      advance: advance,
      clock: SimulationClock(warpFactor: 1, fixedStep: 1.0),
      vessels: vessels,
      terrain: terrain,
    );
    return SimHost(sim);
  }
}
