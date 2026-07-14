// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
