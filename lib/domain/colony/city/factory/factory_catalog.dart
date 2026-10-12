// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The built-in items and recipes every floor can use
/// (docs/plans/factory-floors.md §3 "Recipes", §8).
///
/// The item and recipe TABLES are open registries (`FactoryItems`,
/// `FactoryRecipes`) so later tracks can add their own chains without
/// editing a shared const list. That makes "is the catalog loaded?" a real
/// question: a floor loaded from a save, a template, the editor's palette and
/// a test all need the same recipes present before they read a machine's
/// footprint. [ensureFactoryCatalog] is the one answer — idempotent, cheap
/// after the first call, and safe to call from anywhere.
///
/// The Steel Mill chain (phase 1), as a mass balance per second at the
/// spec's 2 ore/s (`city_building_spec.dart` Steel Mill):
///
///     2 ore ──smelt──► 1.5 pig iron ──cast──► 0.5 billet ──roll──► 1.5 steel
///             └──────► 0.5 slag ──tube press──► 0.4 tubes
///
/// then packers put steel and tubes into crates of ten. Slag is not waste:
/// pressing it into tubes is the byproduct loop the plan's Reward section
/// names, and it is why the mill ships nothing but steel and tubes. Craft
/// times are tuned so the template's MANUAL stations (speed 0.6) run at
/// ~80% of capacity at the spec rate — enough slack that the docks, not a
/// machine, set the template's rate, and room for a designer to do better.
library;

import 'factory_item.dart';
import 'factory_recipe.dart';

/// Recipe ids of the Steel Mill chain. Saved on machines: never rename.
class SteelRecipes {
  SteelRecipes._();

  static const smelt = FactoryRecipe(
    id: 'steel:smelt',
    label: 'Smelt Ore',
    station: StationKind.smelter,
    inputs: [ItemQty('ore', 4)],
    outputs: [ItemQty('pigIron', 3), ItemQty('slag', 1)],
    // 4 s at speed 1: a manual smelter (6.7 s) takes 0.6 ore/s, so two per
    // line cover a 1 ore/s dock with 20% to spare.
    seconds: 4,
    // An electric smelting furnace's draw for a ~1 t/s line, order of
    // magnitude; integration calibrates against the spec's powerDraw.
    powerKw: 800,
  );

  static const cast = FactoryRecipe(
    id: 'steel:cast',
    label: 'Cast Billet',
    station: StationKind.furnace,
    inputs: [ItemQty('pigIron', 3)],
    outputs: [ItemQty('steelBillet', 1)],
    // 2 s: a manual furnace (3.3 s) casts 0.3 billet/s against 0.25 needed.
    seconds: 2,
    powerKw: 300,
  );

  static const roll = FactoryRecipe(
    id: 'steel:roll',
    label: 'Roll Steel',
    station: StationKind.mill,
    inputs: [ItemQty('steelBillet', 1)],
    outputs: [ItemQty('steel', 3)],
    // 2 s: matches the furnace, one mill per furnace.
    seconds: 2,
    powerKw: 250,
  );

  static const tube = FactoryRecipe(
    id: 'steel:tube',
    label: 'Press Slag Tubes',
    station: StationKind.press,
    inputs: [ItemQty('slag', 5)],
    outputs: [ItemQty('tubes', 4)],
    // 5 s: one manual press (8.3 s) eats 0.6 slag/s, over twice a line's
    // 0.25 — the press idles, the walkers clearing it are the real limit.
    seconds: 5,
    powerKw: 120,
  );

  static const packSteel = FactoryRecipe(
    id: 'steel:packSteel',
    label: 'Crate Steel',
    station: StationKind.packer,
    inputs: [ItemQty('steel', 10)],
    outputs: [ItemQty('crate:steel', 1)],
    // 6 s: a manual packer (10 s) crates 1 steel/s against 0.75 per line.
    seconds: 6,
    powerKw: 15,
  );

  static const packTubes = FactoryRecipe(
    id: 'steel:packTubes',
    label: 'Crate Tubes',
    station: StationKind.packer,
    inputs: [ItemQty('tubes', 10)],
    outputs: [ItemQty('crate:tubes', 1)],
    // 12 s: one manual packer (20 s) crates 0.5 tubes/s against 0.4.
    seconds: 12,
    powerKw: 15,
  );

  static const all = [smelt, cast, roll, tube, packSteel, packTubes];
}

/// Items the catalog adds beyond `FactoryItems`' provisional table. The
/// Steel Mill chain needs none of its own yet; later chains append here.
const List<FactoryItem> kCatalogItems = [];

bool _loaded = false;

/// Registers the built-in items and recipes. Idempotent: the registries
/// accept the identical const object twice, and the flag skips the work.
void ensureFactoryCatalog() {
  if (_loaded) return;
  for (final i in kCatalogItems) {
    FactoryItems.register(i);
  }
  for (final r in SteelRecipes.all) {
    FactoryRecipes.register(r);
  }
  _loaded = true;
}
