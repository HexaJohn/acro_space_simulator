import '../simulation/epoch.dart';
import 'command.dart';
import 'player.dart';

/// A multiplayer game session: the set of players and the authoritative tick.
/// Aggregate root. The domain models *the rules of authority and validation*;
/// the actual networking (transport, encryption, matchmaking) is infrastructure
/// that drives this aggregate by feeding it command batches.
class Session {
  final String id;
  final Map<PlayerId, Player> _players;

  /// Authoritative simulation tick. Clients run ahead optimistically and
  /// reconcile against this.
  int authoritativeTick;
  Epoch epoch;

  Session({
    required this.id,
    required Iterable<Player> players,
    this.authoritativeTick = 0,
    this.epoch = Epoch.zero,
  }) : _players = {for (final p in players) p.id: p};

  Iterable<Player> get players => _players.values;
  Player? player(PlayerId id) => _players[id];

  /// Filter a batch to only the commands a player is actually allowed to issue.
  /// Rejects commands against unowned assets — the core multiplayer guard.
  List<SimCommand> validate(CommandBatch batch) {
    return batch.commands.where((c) {
      final p = _players[c.issuedBy];
      return p != null && p.owns(c.targetAssetId);
    }).toList();
  }

  void addPlayer(Player p) => _players[p.id] = p;
  void removePlayer(PlayerId id) => _players.remove(id);
}
