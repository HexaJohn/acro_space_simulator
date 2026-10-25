// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A lookup over one revision of a floor's layout, for the editor
/// (docs/plans/factory-floors.md §4).
///
/// The editor asks "what is under this tile?" and "which way does the belt
/// on this tile run?" many times a frame, and a hall can hold thousands of
/// placements across 220k tiles. A linear scan per question would be fine
/// once and ruinous per pointer move, so the answers are indexed once per
/// `layoutRev` and thrown away on the next edit.
///
/// **Not a validity check.** Whether a placement is ALLOWED is the sim's
/// call alone — `FactoryFloorEditor.check`, the dry run of `place` — because
/// the sim knows rules this index never will (the colony's unlocks, spans,
/// whatever phase 6 adds). An earlier version mirrored the blueprint rules
/// here and drifted from the floor's; the ghost now asks the sim.
library;

import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/floor_blueprint.dart';

class FloorLayoutIndex {
  FloorLayoutIndex(this.blueprint, this.rev) {
    for (final p in blueprint.placements) {
      _byId[p.id] = p;
      if (kOverlayKinds.contains(p.kind)) {
        overlays.add(p);
        if (p.kind == EntityKind.craneBay) craneBays.add(p);
        continue;
      }
      if (p.kind == EntityKind.machine) machines.add(p);
      // A crossing is a belt tile with a walkway over it: it carries items
      // along its dir like any belt.
      if (p.kind == EntityKind.belt || p.kind == EntityKind.crossing) {
        _beltDir[p.pos.key] = p.dir;
      }
      final f = p.footprint;
      for (var y = f.y0; y < f.y1; y++) {
        for (var x = f.x0; x < f.x1; x++) {
          _solid[TilePos(x, y).key] = p.id;
        }
      }
    }
  }

  final FloorBlueprint blueprint;

  /// The `layoutRev` this index was built from.
  final int rev;

  /// Tile key → id of the solid placement covering it.
  final Map<int, int> _solid = {};
  final Map<int, Placement> _byId = {};
  final Map<int, Dir4> _beltDir = {};

  /// Floor markings (aisles, staging, crane bays), in placement order.
  final List<Placement> overlays = [];

  /// Crane bays, in placement order (a crane is drawn as a bridge across
  /// the bay it stands in).
  final List<Placement> craneBays = [];

  /// The crane bay covering [t], if any.
  Placement? craneBayAt(TilePos t) {
    for (final b in craneBays) {
      if (b.footprint.contains(t)) return b;
    }
    return null;
  }

  /// Machines, in placement order (the painter's per-frame status pass).
  final List<Placement> machines = [];

  HallSize get hall => blueprint.hall;

  Placement? byId(int id) => _byId[id];

  /// The solid placement on [t], if any.
  Placement? solidAt(TilePos t) {
    final id = _solid[t.key];
    return id == null ? null : _byId[id];
  }

  /// Which way the belt or crossing on [t] runs (null = no belt there).
  Dir4? beltDirAt(TilePos t) => _beltDir[t.key];

  Set<String>? _consumed;

  /// Items some machine on this floor takes as a recipe INPUT: the item
  /// picker's "used here" mark, and what a receiving dock is checked
  /// against (§10 item 6). Built on first ask, once per revision.
  Set<String> get consumedItems => _consumed ??= {
        for (final m in machines)
          ...?FactoryRecipes.byId(m.recipe ?? '')?.inputs.map((q) => q.item),
      };

  /// Receiving docks whose item no machine on the floor consumes: they
  /// unload goods nothing here will ever use (the playtest's crate dock
  /// feeding a bench that wanted loose boards). A dock with no item set is
  /// left out; it asks for nothing.
  late final List<Placement> unusedDocks = [
    for (final p in blueprint.placements)
      if (p.kind == EntityKind.receivingDock &&
          p.item != null &&
          !consumedItems.contains(p.item))
        p,
  ];

  /// Solid placements whose footprint overlaps [r], plus floor markings
  /// with [markings] (the Delete tool's area drag; Shift adds markings).
  List<Placement> overlapping(TileRect r, {bool markings = false}) => [
        for (final p in blueprint.placements)
          if ((markings || !kOverlayKinds.contains(p.kind)) &&
              p.footprint.overlaps(r))
            p,
      ];

  /// What a click on [t] means: the solid object first, else the topmost
  /// (last-placed) floor marking.
  Placement? hit(TilePos t) {
    final s = solidAt(t);
    if (s != null) return s;
    for (var i = overlays.length - 1; i >= 0; i--) {
      if (overlays[i].footprint.contains(t)) return overlays[i];
    }
    return null;
  }
}

/// Player-facing name of a placement kind (palette, inspector, the area
/// delete's counts).
String entityKindLabel(EntityKind k) => switch (k) {
      EntityKind.machine => 'Machine',
      EntityKind.belt => 'Belt',
      EntityKind.arm => 'Arm',
      EntityKind.chest => 'Chest',
      EntityKind.receivingDock => 'Receiving Dock',
      EntityKind.shippingDock => 'Shipping Dock',
      EntityKind.aisle => 'Aisle',
      EntityKind.crossing => 'Crossing',
      EntityKind.craneBay => 'Crane Bay',
      EntityKind.rack => 'Rack',
      EntityKind.chargingBay => 'Charging Bay',
      EntityKind.staging => 'Staging',
    };

/// Player-facing words for a refusal.
String refusalText(EditRefusal r) => switch (r) {
      EditRefusal.outOfHall => 'Outside the hall walls',
      EditRefusal.overlaps => 'Something is already there',
      EditRefusal.unknownRecipe => 'Pick a recipe first',
      EditRefusal.wrongKind => 'Not possible on that kind of object',
      EditRefusal.noSuchPlacement => 'Nothing there',
      EditRefusal.notAllowed => 'Not unlocked or not allowed here',
    };
