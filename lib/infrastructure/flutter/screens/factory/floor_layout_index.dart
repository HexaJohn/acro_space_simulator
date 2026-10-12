// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A lookup over one revision of a floor's layout, for the editor
/// (docs/plans/factory-floors.md §4).
///
/// The editor asks three questions many times a frame — "what is under this
/// tile?", "would this ghost fit?", "which way does the belt on this tile
/// run?" — and a hall can hold thousands of placements across 220k tiles. A
/// linear scan per question would be fine once and ruinous per pointer move,
/// so the answers are indexed once per `layoutRev` and thrown away on the
/// next edit.
///
/// [check] mirrors `FloorBlueprint.validate`'s rules (in the hall, known
/// recipe, solids never overlap, floor markings may) so the ghost preview
/// agrees with what the sim will accept. The sim still has the last word:
/// a refusal from `place` is shown even when the preview said yes.
library;

import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/floor_blueprint.dart';

/// The verdict on a would-be placement: null [refusal] = it fits.
class LayoutCheck {
  const LayoutCheck.ok()
      : refusal = null,
        otherId = null;
  const LayoutCheck.refused(this.refusal, [this.otherId]);

  final EditRefusal? refusal;

  /// The placement in the way, for [EditRefusal.overlaps].
  final int? otherId;

  bool get ok => refusal == null;
}

class FloorLayoutIndex {
  FloorLayoutIndex(this.blueprint, this.rev) {
    for (final p in blueprint.placements) {
      _byId[p.id] = p;
      if (kOverlayKinds.contains(p.kind)) {
        overlays.add(p);
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

  /// Would [p] be accepted as it stands? [pending] holds tile keys already
  /// claimed by earlier tiles of the same gesture (a belt run being laid).
  LayoutCheck check(Placement p, {Set<int>? pending}) {
    if (p.kind == EntityKind.machine) {
      final r = p.recipe;
      if (r == null || FactoryRecipes.byId(r) == null) {
        return const LayoutCheck.refused(EditRefusal.unknownRecipe);
      }
    }
    final f = p.footprint;
    if (!hall.rect.containsRect(f)) {
      return const LayoutCheck.refused(EditRefusal.outOfHall);
    }
    if (kOverlayKinds.contains(p.kind)) return const LayoutCheck.ok();
    for (var y = f.y0; y < f.y1; y++) {
      for (var x = f.x0; x < f.x1; x++) {
        final k = TilePos(x, y).key;
        final other = _solid[k];
        if (other != null) {
          return LayoutCheck.refused(EditRefusal.overlaps, other);
        }
        if (pending != null && pending.contains(k)) {
          return const LayoutCheck.refused(EditRefusal.overlaps);
        }
      }
    }
    return const LayoutCheck.ok();
  }
}

/// Player-facing words for a refusal.
String refusalText(EditRefusal r) => switch (r) {
      EditRefusal.outOfHall => 'Outside the hall walls',
      EditRefusal.overlaps => 'Something is already there',
      EditRefusal.unknownRecipe => 'Pick a recipe first',
      EditRefusal.wrongKind => 'Not possible on that kind of object',
      EditRefusal.noSuchPlacement => 'Nothing there',
      EditRefusal.notAllowed => 'Not allowed here',
    };
