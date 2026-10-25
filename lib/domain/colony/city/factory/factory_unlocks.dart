// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a colony has unlocked for its factory floors
/// (docs/plans/factory-floors.md phase 4: "automation unlocked by milestone
/// or research").
///
/// A young colony moves freight by hand and with pallet jacks, and crews
/// its stations manually or with one operator; forklifts, cranes, AGVs and
/// lights-out stations come later. The floor refuses to HIRE, SET A MODE or
/// PLACE anything locked (`EditRefusal.notAllowed`), and its editor's ghost
/// preview (`check`) says so before the click.
///
/// Unlocks gate NEW purchases only: revoking one (a save from another
/// colony, a research loss) never fires a crane already on the floor or
/// re-crews a running station, and letting go of a locked handler is always
/// allowed. Built-in templates may use any kind — they are the colony's
/// default plants, not player purchases.
///
/// **Inventions** (docs/plans/dynamic-markets.md phase 2): a good not yet
/// invented for the colony ([uninvented], `economy/learning.dart`) can be
/// neither made nor used, so a machine may not be placed with, or set to, a
/// recipe that makes or consumes one (`EditRefusal.notAllowed`;
/// [recipeRefusal] gives the reason in words). Like the other unlocks it
/// gates new choices only: a recipe already on the floor keeps running.
///
/// **Not saved in the floor's JSON.** The colony owns its milestones and
/// research and supplies the unlocks whenever it builds or loads a floor;
/// the sandbox editor and every test default to [FactoryUnlocks.all]. Wave 3
/// maps colony milestones and research onto these sets.
library;

import '../commodity.dart';
import 'factory_entities.dart';
import 'factory_handling.dart';
import 'factory_item.dart';
import 'factory_recipe.dart';

class FactoryUnlocks {
  const FactoryUnlocks({
    required this.handlers,
    required this.modes,
    this.uninvented = const {},
  });

  /// Handler kinds the floor may hire.
  final Set<HandlerKind> handlers;

  /// Station modes the floor may set or place.
  final Set<MachineMode> modes;

  /// Commodities not invented for the colony yet: no recipe may make or use
  /// one. Empty (everything exists) in the sandbox and by default.
  final Set<String> uninvented;

  /// Everything: the sandbox and test default.
  static const FactoryUnlocks all = FactoryUnlocks(
    handlers: {
      HandlerKind.onFoot,
      HandlerKind.palletJack,
      HandlerKind.forklift,
      HandlerKind.crane,
      HandlerKind.agv,
    },
    modes: {MachineMode.manual, MachineMode.assisted, MachineMode.automated},
  );

  /// A new colony: hands and pallet jacks, manual and assisted stations.
  static const FactoryUnlocks starter = FactoryUnlocks(
    handlers: {HandlerKind.onFoot, HandlerKind.palletJack},
    modes: {MachineMode.manual, MachineMode.assisted},
  );

  bool allowsHandler(HandlerKind k) => handlers.contains(k);

  /// The first uninvented commodity [recipeId] makes or uses, or null. A
  /// packed item counts as the commodity it holds (`crate:missiles` is
  /// missiles); a chain's own intermediates are never uninvented.
  String? uninventedIn(String recipeId) {
    if (uninvented.isEmpty) return null;
    final r = FactoryRecipes.byId(recipeId);
    if (r == null) return null;
    for (final q in [...r.outputs, ...r.inputs]) {
      final c = FactoryItems.byId(q.item)?.commodity ?? q.item;
      if (uninvented.contains(c)) return c;
    }
    return null;
  }

  /// Whether a machine may be given [recipeId] ([uninventedIn]).
  bool allowsRecipe(String recipeId) => uninventedIn(recipeId) == null;

  /// Why [recipeId] is refused, in words, or null when it isn't.
  String? recipeRefusal(String recipeId) {
    final c = uninventedIn(recipeId);
    return c == null ? null : '${Commodity.name(c)} is not invented yet';
  }
  bool allowsMode(MachineMode m) => modes.contains(m);

  /// Whether [p] may be placed: a machine's crew mode must be unlocked, a
  /// crane bay needs cranes and a charging bay needs a battery vehicle
  /// (forklift or AGV). Belts, arms, docks, aisles and the rest are always
  /// buildable.
  bool allowsPlacement(Placement p) => switch (p.kind) {
    EntityKind.machine =>
      allowsMode(p.crew) && (p.recipe == null || allowsRecipe(p.recipe!)),
    EntityKind.craneBay => allowsHandler(HandlerKind.crane),
    EntityKind.chargingBay =>
      allowsHandler(HandlerKind.forklift) || allowsHandler(HandlerKind.agv),
    _ => true,
  };
}
