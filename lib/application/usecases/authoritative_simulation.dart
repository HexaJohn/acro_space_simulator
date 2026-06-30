import '../../domain/multiplayer/command.dart';
import '../../domain/multiplayer/session.dart';
import '../../domain/simulation/simulation_clock.dart';
import '../../domain/universe/terrain_heights.dart';
import '../ports/repositories.dart';
import '../snapshot/world_snapshot.dart';
import 'advance_simulation_tick.dart';
import 'apply_commands.dart';

/// The authoritative multiplayer simulation loop.
///
/// Determinism contract: given the same initial state and the same ordered
/// command stream, two instances produce byte-identical [WorldSnapshot]
/// fingerprints. That is what lets clients run ahead optimistically and
/// reconcile, and lets the server be the single source of truth.
///
/// One [step]:
///   1. ingest command batches, validated by the [Session] (ownership),
///   2. apply them via [ApplyCommands] in a fixed order,
///   3. advance exactly one fixed tick via [AdvanceSimulationTick],
///   4. bump the authoritative tick counter.
///
/// No wall-clock, no randomness, no iteration over unordered structures that
/// could differ between runs — all the ingredients of determinism.
class AuthoritativeSimulation {
  final Session session;
  final ApplyCommands applyCommands;
  final AdvanceSimulationTick advance;
  final SimulationClock clock;
  final VesselRepository vessels;

  /// Render-side terrain heights (shared with [applyCommands]). Used only to
  /// place surface objects in the snapshot — never by the physics tick.
  final TerrainHeights terrain;

  AuthoritativeSimulation({
    required this.session,
    required this.applyCommands,
    required this.advance,
    required this.clock,
    required this.vessels,
    TerrainHeights? terrain,
  }) : terrain = terrain ?? TerrainHeights();

  void step(List<CommandBatch> batches) {
    // 1 + 2. Apply commands in a deterministic order: batch order, then the
    // sealed-command order within each batch (validation drops unowned ones).
    for (final batch in batches) {
      applyCommands.execute(session, batch);
    }

    // 3. Advance one authoritative tick.
    advance.execute(clock);

    // 4. Bump authoritative tick + epoch mirror.
    session.authoritativeTick++;
    session.epoch = clock.epoch;
  }

  WorldSnapshot snapshot() => WorldSnapshot.capture(
        session.authoritativeTick,
        vessels,
        system: advance.universe.current(),
        ephemeris: advance.ephemeris,
        epoch: clock.epoch,
        colonies: advance.colonies,
        terrain: terrain,
      );
}
