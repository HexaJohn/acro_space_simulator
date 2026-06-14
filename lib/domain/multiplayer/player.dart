/// A participant in a multiplayer game. Domain identity for ownership and
/// command authority; network identity (sockets, auth tokens) lives in infra.
class PlayerId {
  final String value;
  const PlayerId(this.value);
  @override
  bool operator ==(Object other) => other is PlayerId && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => 'PlayerId($value)';
}

class Player {
  final PlayerId id;
  final String displayName;

  /// Vessels/colonies this player may command. The authoritative simulation
  /// rejects commands from a player against assets they don't own.
  final Set<String> ownedAssetIds;

  Player({
    required this.id,
    required this.displayName,
    Set<String>? ownedAssetIds,
  }) : ownedAssetIds = ownedAssetIds ?? {};

  bool owns(String assetId) => ownedAssetIds.contains(assetId);
}
