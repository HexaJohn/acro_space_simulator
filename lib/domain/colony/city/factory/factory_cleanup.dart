// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Cleaning goods off the open floor (docs/plans/factory-floors.md §10
/// item 17).
///
/// A floor pile is never permanent clutter. Besides the floor's own habit of
/// hauling any pile nothing consumes to a store, the player has three tools,
/// all on this additive surface (a view or editor that does not know it simply
/// keeps working; [FactoryFloor] is the one implementation):
///
/// * [clearPiles]: a "Clear" area order. Every pile in the box is hauled to
///   the nearest shipping dock, chest or staging area with room, as ordinary
///   move requests in the queue — even goods a hand-fed station would
///   otherwise claim.
/// * [disposePile]: "Dispose" one pile. Shipped out through a shipping dock
///   (a handler hauls it there and the dock books the commodity as shipped),
///   or, with `scrap`, destroyed on the spot in the sandbox and booked in
///   `FactoryLedger.scrapped` so conservation tests can account for it.
/// * [stuckPiles]: the piles nothing could take (no store or dock with room
///   for them), so the editor flags them instead of leaving them silently
///   stuck.
///
/// The orders are runtime-only: they are not saved, and a reload leaves the
/// piles to the floor's ordinary hauling.
library;

import 'factory_grid.dart';

abstract interface class FloorCleanup {
  /// Orders every pile inside [area] cleared. Returns how many piles it
  /// marked. Handlers haul them as ordinary move requests.
  int clearPiles(TileRect area);

  /// Disposes of the pile on [tile]: shipped through a shipping dock, or
  /// with [scrap] destroyed now (sandbox only; the caller decides). Returns
  /// whether a pile was there.
  bool disposePile(TilePos tile, {bool scrap = false});

  /// Tiles whose pile no store or dock has room for right now.
  Set<TilePos> get stuckPiles;
}
