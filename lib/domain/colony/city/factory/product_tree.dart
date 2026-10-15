// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The product tree: what it takes to make a good, all the way back to the
/// ground (docs/plans/factory-floors.md §3 "Recipes").
///
/// Every plant chain registers its recipes in one open table
/// (`FactoryRecipes`), and chains feed each other: the Missile Plant cuts
/// the Steel Mill's tubes, the Electronics Plant stamps its steel. Nothing
/// on a single floor shows that whole flow, so a designer asking "what do I
/// need for 0.15 missiles a second?" had to read seven template files. This
/// answers it from the recipe graph alone:
///
///     missiles 0.15/s ─checkout─► round ─integrate─┬► airframe ─weld─► segment ─cut─► tubes ─press─► slag ─smelt─► ore
///                                                 ├► motor ─cast─► motor kit ─kit─► rocket parts ─…
///                                                 └► guidance ─build─► board ─kit─► electronics ─…─► steel ─…─► ore
///
/// The arithmetic is a plain steady-state mass balance: a node wanting `r`
/// items/s from a recipe that makes `out` of them a craft runs `r / out`
/// crafts/s, and so wants `crafts × in` of each input; a station of mode `m`
/// finishes `speedMult / seconds` crafts/s, so the node needs
/// `crafts × seconds / speedMult` of them. It deliberately ignores what a
/// floor can actually do (handling, belts, staffing): that is the measure's
/// job (`factory_measure.dart`). The tree is the BUDGET a layout is then
/// judged against.
///
/// Pure and deterministic: every map is walked in sorted order, ties are
/// broken by id, and there is no RNG or clock, so two builds of the same
/// tree are identical (a test pins it) and the UI never reshuffles rows.
library;

import '../city_building_spec.dart';
import '../commodity.dart';
import 'factory_catalog.dart';
import 'factory_handling.dart';
import 'factory_item.dart';
import 'factory_recipe.dart';

/// What kind of end a tree branch has.
enum ProductLeaf {
  /// Not a leaf: a recipe makes it, and the node has children.
  none,

  /// No recipe makes it, but a colony building does (a mine's ore, a
  /// farm's food): the ground the chain stands on.
  raw,

  /// Neither a recipe nor any colony building makes it: the colony can only
  /// buy it in (at the spaceport, or from another colony).
  importOnly,

  /// The item is already being made further up THIS branch (a chain that
  /// loops, e.g. unpacking a crate the same plant packed). Recursing would
  /// never end, so the branch stops and says so.
  cycle,
}

/// A colony building type that runs a factory chain: the recipe id prefix
/// (`'<plantType>:'`) names it, with one historical exception, the Steel
/// Mill, whose recipes predate the convention and use `'steel:'`.
const Map<String, String> _kPrefixToPlantType = {'steel': 'steelmill'};

/// Fallback badge colour for a chain prefix no colony building claims (a
/// test's synthetic recipes, a track not yet wired into `kUtilCatalog`):
/// the editor's neutral grey-blue, so it reads as "unknown plant".
const int _kUnknownPlantArgb = 0xFF8499AE;

/// The colony building a recipe belongs to.
class ProductPlant {
  const ProductPlant(this.type, this.label, this.colorArgb);

  /// `CityBuildingSpec.type` (or the raw prefix when no building claims it).
  final String type;
  final String label;

  /// The building's own map colour, so the tree's badges match the colony.
  final int colorArgb;

  @override
  bool operator ==(Object other) => other is ProductPlant && other.type == type;

  @override
  int get hashCode => type.hashCode;
}

/// The plant [recipeId] runs in, from its `'<prefix>:'`; null when the id
/// has no prefix.
ProductPlant? plantOfRecipe(String recipeId) {
  final i = recipeId.indexOf(':');
  if (i <= 0) return null;
  final prefix = recipeId.substring(0, i);
  final type = _kPrefixToPlantType[prefix] ?? prefix;
  for (final s in kUtilCatalog) {
    if (s.type == type) return ProductPlant(type, s.label, s.colorArgb);
  }
  return ProductPlant(type, prefix, _kUnknownPlantArgb);
}

/// A byproduct a node's recipe throws off at the node's craft rate.
class ProductByproduct {
  const ProductByproduct({
    required this.item,
    required this.ratePerS,
    required this.consumers,
    required this.consumedInTree,
  });

  final String item;

  /// Items/s made alongside the node's product.
  final double ratePerS;

  /// Recipe ids anywhere in the catalog that take it (sorted): "this slag
  /// is not waste, a tube press eats it".
  final List<String> consumers;

  /// True when some step of THIS tree takes it as an input, so a plant
  /// running the whole tree could feed it back instead of buying it in
  /// (the raw totals stay GROSS: crediting it is a layout's choice).
  final bool consumedInTree;

  ProductByproduct _withConsumed(bool v) => ProductByproduct(
      item: item, ratePerS: ratePerS, consumers: consumers, consumedInTree: v);
}

/// One step of a product tree: an item at a required rate, and how it is
/// made.
class ProductNode {
  const ProductNode({
    required this.path,
    required this.item,
    required this.ratePerS,
    required this.leaf,
    this.recipe,
    this.craftsPerS = 0,
    this.plant,
    this.byproducts = const [],
    this.alternatives = const [],
    this.children = const [],
    this.colonySources = const [],
  });

  /// Where the node sits: item ids from the root joined by '>' (unique in a
  /// tree, stable across rebuilds). The key a recipe choice is stored under.
  final String path;

  final String item;

  /// Items/s this step must make.
  final double ratePerS;

  final ProductLeaf leaf;

  /// The recipe chosen to make it; null for a leaf.
  final FactoryRecipe? recipe;

  /// Crafts/s of [recipe] needed.
  final double craftsPerS;

  /// The plant [recipe] belongs to.
  final ProductPlant? plant;

  final List<ProductByproduct> byproducts;

  /// Other recipes that make [item], best first (the choice rule's order).
  final List<FactoryRecipe> alternatives;

  /// One per input of [recipe], in the recipe's input order.
  final List<ProductNode> children;

  /// For a [ProductLeaf.raw] leaf: labels of the colony buildings whose flat
  /// outputs supply [item]'s commodity, catalog order (e.g. Mine, Quarry).
  final List<String> colonySources;

  FactoryItem? get def => FactoryItems.byId(item);
  String get label => def?.label ?? Commodity.name(item);
  LoadClass? get loadClass => def?.loadClass;

  /// The colony commodity the item counts as at a dock.
  String get commodity => def?.commodity ?? item;

  /// [ratePerS] in units of [commodity] (a steel crate is ten steel).
  double get commodityPerS => ratePerS * (def?.commodityUnits ?? 1);

  /// Stations of [mode] needed to keep up, fractional (0 for a leaf).
  double machinesFor(MachineMode mode) {
    final r = recipe;
    if (r == null) return 0;
    return craftsPerS * r.seconds / mode.speedMult;
  }

  /// Whole stations of [mode]: a fraction of a machine is still a machine.
  /// The tiny epsilon keeps an exact 2.0000000001 from becoming 3.
  int machinesCeil(MachineMode mode) {
    final m = machinesFor(mode);
    return m <= 0 ? 0 : (m - 1e-9).ceil();
  }

  bool get isLeaf => leaf != ProductLeaf.none;

  ProductNode _copy(
          {List<ProductByproduct>? byproducts, List<ProductNode>? children}) =>
      ProductNode(
          path: path,
          item: item,
          ratePerS: ratePerS,
          leaf: leaf,
          recipe: recipe,
          craftsPerS: craftsPerS,
          plant: plant,
          byproducts: byproducts ?? this.byproducts,
          alternatives: alternatives,
          children: children ?? this.children,
          colonySources: colonySources);

  /// Every node, depth first, parents before children.
  Iterable<ProductNode> walk() sync* {
    yield this;
    for (final c in children) {
      yield* c.walk();
    }
  }
}

/// How a good is grouped in the product picker.
enum ProductGroup {
  /// A colony commodity (steel, missiles …): what a player thinks in.
  good,

  /// A colony good packed for a dock (crates, totes, cylinder packs).
  packed,

  /// A plant's own intermediate (pig iron, shell segment …).
  intermediate,
}

/// Which picker group [itemId] belongs to.
ProductGroup productGroupOf(String itemId) {
  if (Commodity.label.containsKey(itemId)) return ProductGroup.good;
  final d = FactoryItems.byId(itemId);
  if (d != null && d.isCrate) return ProductGroup.packed;
  return ProductGroup.intermediate;
}

/// The recipe table as a graph: who makes an item, who takes it.
class RecipeGraph {
  RecipeGraph(Iterable<FactoryRecipe> recipes) {
    final sorted = recipes.toList()..sort((a, b) => a.id.compareTo(b.id));
    for (final r in sorted) {
      for (final o in r.outputs) {
        final l = _producers.putIfAbsent(o.item, () => []);
        if (!l.contains(r)) l.add(r);
      }
      for (final i in r.inputs) {
        final l = _consumers.putIfAbsent(i.item, () => []);
        if (!l.contains(r)) l.add(r);
      }
    }
  }

  /// Every registered recipe, every plant chain included.
  factory RecipeGraph.catalog() {
    ensureFactoryCatalog();
    return RecipeGraph(FactoryRecipes.table.values);
  }

  // Lists are filled in recipe-id order, so they are sorted by construction.
  final Map<String, List<FactoryRecipe>> _producers = {};
  final Map<String, List<FactoryRecipe>> _consumers = {};

  /// Recipes listing [item] among their outputs, by id.
  List<FactoryRecipe> producersOf(String item) =>
      List.unmodifiable(_producers[item] ?? const <FactoryRecipe>[]);

  /// Recipes taking [item] as an input, by id.
  List<FactoryRecipe> usedIn(String item) =>
      List.unmodifiable(_consumers[item] ?? const <FactoryRecipe>[]);

  /// Every item some recipe makes: colony goods first (in the stockpile
  /// panel's order), then packs, then intermediates (each by label, then
  /// id), so the picker leads with what a player actually ships.
  List<String> productCatalog() {
    final ids = _producers.keys.toList();
    int groupRank(String id) => productGroupOf(id).index;
    int goodRank(String id) {
      final i = Commodity.ordered.indexOf(id);
      return i < 0 ? Commodity.ordered.length : i;
    }

    String label(String id) => FactoryItems.byId(id)?.label ?? id;
    ids.sort((a, b) {
      final g = groupRank(a).compareTo(groupRank(b));
      if (g != 0) return g;
      if (productGroupOf(a) == ProductGroup.good) {
        final o = goodRank(a).compareTo(goodRank(b));
        if (o != 0) return o;
      }
      final l = label(a).compareTo(label(b));
      return l != 0 ? l : a.compareTo(b);
    });
    return ids;
  }
}

/// Recipes consuming [itemId] (the "used in" view), by id.
List<FactoryRecipe> usedIn(String itemId, {RecipeGraph? graph}) =>
    (graph ?? RecipeGraph.catalog()).usedIn(itemId);

/// Every item some recipe makes, finished goods first
/// ([RecipeGraph.productCatalog]).
List<String> productCatalog({RecipeGraph? graph}) =>
    (graph ?? RecipeGraph.catalog()).productCatalog();

/// Labels of colony buildings whose flat outputs include [commodity]:
/// hand-placed ones (`kUtilCatalog`) in catalog order, then grown zones
/// (`kZoneSpecs`, kind then density order). Labels de-duplicated.
List<String> colonySourcesOf(String commodity) {
  final out = <String>[];
  void add(CityBuildingSpec s) {
    if ((s.outputs[commodity] ?? 0) > 0 && !out.contains(s.label)) {
      out.add(s.label);
    }
  }

  kUtilCatalog.forEach(add);
  final kinds = kZoneSpecs.keys.toList()..sort();
  for (final k in kinds) {
    final tiers = kZoneSpecs[k]!;
    for (final d in Density.values) {
      final s = tiers[d];
      if (s != null) add(s);
    }
  }
  return out;
}

/// True when [r] only UNDOES a pack of [item] (crate:steel → 10 steel): an
/// unpacker is how a plant receives goods, not how the good is made, and
/// following it walks straight back into the packer that filled the crate.
bool _isUnpack(FactoryRecipe r, String item) {
  for (final q in r.inputs) {
    final d = FactoryItems.byId(q.item);
    if (d != null && d.isCrate && d.commodity == item) return true;
  }
  return false;
}

/// The producers of [item], best first. THE CHOICE RULE:
///
/// 1. A real making step before an unpack ([_isUnpack]): the tree is about
///    where a good comes FROM, and an unpack's answer ("a crate of it")
///    only loops.
/// 2. A recipe that does not take an item already on this branch: the same
///    loop one step removed.
/// 3. The parent step's own plant chain ([parentPlant]): a plant that makes
///    its own intermediate is the flow the template draws.
/// 4. Otherwise the lowest recipe id (deterministic, stable as chains are
///    added, since ids never change).
///
/// The rest become the node's alternatives, in the same order.
List<FactoryRecipe> _ranked(List<FactoryRecipe> producers, String item,
    String? parentPlant, Set<String> onPath) {
  int score(FactoryRecipe r) {
    var s = 0;
    if (_isUnpack(r, item)) s += 4;
    if (r.inputs.any((q) => onPath.contains(q.item))) s += 2;
    if (parentPlant == null || plantOfRecipe(r.id)?.type != parentPlant) {
      s += 1;
    }
    return s;
  }

  final scored = [for (final r in producers) (score(r), r)];
  scored.sort((a, b) {
    final c = a.$1.compareTo(b.$1);
    return c != 0 ? c : a.$2.id.compareTo(b.$2.id);
  });
  return [for (final e in scored) e.$2];
}

/// Builds the tree for [itemId] at [ratePerS] items/s.
///
/// [recipeChoices] maps a node's [ProductNode.path] to a recipe id the
/// player picked for it (from that node's alternatives); a choice that no
/// longer makes the item is ignored. [graph] defaults to every registered
/// recipe (tests pass a synthetic one).
ProductNode buildProductTree(String itemId,
    {double ratePerS = 1,
    Map<String, String> recipeChoices = const {},
    RecipeGraph? graph}) {
  final g = graph ?? RecipeGraph.catalog();
  final onPath = <String>{};

  ProductNode build(String item, double rate, String path, String? parent) {
    if (onPath.contains(item)) {
      return ProductNode(
          path: path, item: item, ratePerS: rate, leaf: ProductLeaf.cycle);
    }
    final producers = g.producersOf(item);
    if (producers.isEmpty) {
      final d = FactoryItems.byId(item);
      final sources = colonySourcesOf(d?.commodity ?? item);
      return ProductNode(
          path: path,
          item: item,
          ratePerS: rate,
          leaf: sources.isEmpty ? ProductLeaf.importOnly : ProductLeaf.raw,
          colonySources: sources);
    }
    final ranked = _ranked(producers, item, parent, onPath);
    var chosen = ranked.first;
    final want = recipeChoices[path];
    if (want != null) {
      for (final r in ranked) {
        if (r.id == want) chosen = r;
      }
    }
    var outQty = 0;
    for (final o in chosen.outputs) {
      if (o.item == item) outQty += o.count;
    }
    final crafts = rate / outQty;
    final byproducts = <ProductByproduct>[];
    for (final o in chosen.outputs) {
      if (o.item == item) continue;
      byproducts.add(ProductByproduct(
          item: o.item,
          ratePerS: crafts * o.count,
          consumers: [for (final r in g.usedIn(o.item)) r.id],
          consumedInTree: false));
    }
    final plant = plantOfRecipe(chosen.id);
    onPath.add(item);
    final children = [
      for (final q in chosen.inputs)
        build(q.item, crafts * q.count, '$path>${q.item}', plant?.type),
    ];
    onPath.remove(item);
    return ProductNode(
        path: path,
        item: item,
        ratePerS: rate,
        leaf: ProductLeaf.none,
        recipe: chosen,
        craftsPerS: crafts,
        plant: plant,
        byproducts: byproducts,
        alternatives: [for (final r in ranked) if (!identical(r, chosen)) r],
        children: children);
  }

  final raw = build(itemId, ratePerS, itemId, null);

  // Second pass: which byproducts does this very tree take back in?
  final consumed = <String>{};
  for (final n in raw.walk()) {
    final r = n.recipe;
    if (r == null) continue;
    for (final q in r.inputs) {
      consumed.add(q.item);
    }
  }
  ProductNode mark(ProductNode n) => n._copy(
      byproducts: [
        for (final b in n.byproducts) b._withConsumed(consumed.contains(b.item))
      ],
      children: [for (final c in n.children) mark(c)]);
  return mark(raw);
}

/// The whole flow at a glance: what goes in at the bottom, what machines it
/// takes, and which plants are involved.
class ProductTreeSummary {
  const ProductTreeSummary({
    required this.rawPerS,
    required this.machines,
    required this.plants,
    required this.cycles,
  });

  /// Raw and import-only leaf items/s, summed over the tree, by item id.
  /// GROSS: byproducts the tree could recycle are not credited.
  final Map<String, double> rawPerS;

  /// Whole stations per station kind and mode (each node's own ceiling,
  /// summed: two recipes never share a machine), station enum order.
  final Map<StationKind, Map<MachineMode, int>> machines;

  /// Plants involved, by first appearance (depth first from the root).
  final List<ProductPlant> plants;

  /// Cycle leaves in the tree (a branch the tree had to cut short).
  final int cycles;
}

/// Totals over [root].
ProductTreeSummary summarizeProductTree(ProductNode root) {
  final raw = <String, double>{};
  final machines = <StationKind, Map<MachineMode, int>>{};
  final plants = <ProductPlant>[];
  var cycles = 0;
  for (final n in root.walk()) {
    switch (n.leaf) {
      case ProductLeaf.raw:
      case ProductLeaf.importOnly:
        raw[n.item] = (raw[n.item] ?? 0) + n.ratePerS;
      case ProductLeaf.cycle:
        cycles++;
      case ProductLeaf.none:
        final r = n.recipe!;
        final m = machines.putIfAbsent(r.station, () => {});
        for (final mode in MachineMode.values) {
          m[mode] = (m[mode] ?? 0) + n.machinesCeil(mode);
        }
        final p = n.plant;
        if (p != null && !plants.contains(p)) plants.add(p);
    }
  }
  final rawKeys = raw.keys.toList()..sort();
  return ProductTreeSummary(
    rawPerS: {for (final k in rawKeys) k: raw[k]!},
    machines: {
      for (final s in StationKind.values) s: ?machines[s],
    },
    plants: plants,
    cycles: cycles,
  );
}
