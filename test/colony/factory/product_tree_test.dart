// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/product_tree.dart';
import 'package:flutter_test/flutter_test.dart';

/// The product tree (lib/domain/colony/city/factory/product_tree.dart) is
/// the budget a designer lays a floor out against, so its arithmetic has to
/// agree with the numbers the templates were tuned to, and it has to stay
/// sane on the recipe graph's awkward corners: chains that span plants,
/// unpack/pack loops, and a player overriding a step's recipe.
void main() {
  ProductNode child(ProductNode n, String item) =>
      n.children.singleWhere((c) => c.item == item);

  /// The Steel Mill's spec is 2 ore → 1.5 steel + 0.4 tubes per second, and
  /// its chain was tuned to that balance (factory_catalog.dart). 0.15
  /// crates/s is 1.5 steel/s, so the tree must reach back to exactly the
  /// spec's 2 ore/s, through every intermediate, and name the slag the
  /// smelter throws off as food for the tube press.
  test('Steel Mill: 0.15 steel crates/s reaches 2.0 ore/s', () {
    final t = buildProductTree('crate:steel', ratePerS: 0.15);
    expect(t.recipe!.id, 'steel:packSteel');
    expect(t.commodityPerS, closeTo(1.5, 1e-9), reason: 'ten steel a crate');
    expect(t.plant!.label, 'Steel Mill');

    final steel = child(t, 'steel');
    expect(steel.ratePerS, closeTo(1.5, 1e-9));
    expect(steel.recipe!.id, 'steel:roll',
        reason: 'the mill rolls its steel; an unpack only loops back');
    expect(steel.alternatives.map((r) => r.id),
        containsAll(['electronics:unpack', 'gunfactory:saw']));

    final billet = child(steel, 'steelBillet');
    expect(billet.ratePerS, closeTo(0.5, 1e-9));
    final pig = child(billet, 'pigIron');
    expect(pig.ratePerS, closeTo(1.5, 1e-9));
    expect(pig.recipe!.id, 'steel:smelt');
    final ore = child(pig, 'ore');
    expect(ore.ratePerS, closeTo(2.0, 1e-9));
    expect(ore.leaf, ProductLeaf.raw);

    final slag = pig.byproducts.single;
    expect(slag.item, 'slag');
    expect(slag.ratePerS, closeTo(0.5, 1e-9));
    expect(slag.consumers, contains('steel:tube'));
    expect(slag.consumedInTree, isFalse,
        reason: 'a steel-only tree has no tube press in it');

    // Machines: smelt 0.5 crafts/s × 4 s = 2 station-seconds/s; a manual
    // smelter runs at 0.6, so 3.33 → 4 stations; assisted 2; automated
    // 1.54 → 2.
    expect(pig.machinesFor(MachineMode.manual), closeTo(2 / 0.6, 1e-9));
    expect(pig.machinesCeil(MachineMode.manual), 4);
    expect(pig.machinesCeil(MachineMode.assisted), 2);
    expect(pig.machinesCeil(MachineMode.automated), 2);

    final s = summarizeProductTree(t);
    expect(s.rawPerS.keys, ['ore']);
    expect(s.rawPerS['ore'], closeTo(2.0, 1e-9));
    expect(s.plants.map((p) => p.type), ['steelmill']);
    expect(s.machines.keys, containsAll(
        [StationKind.packer, StationKind.mill, StationKind.furnace,
         StationKind.smelter]));
  });

  /// A missile is the deepest chain in the game: it must pull in the Rocket
  /// Parts Factory, the Electronics Plant and the Steel Mill, label each,
  /// end at ore, and spot that the smelts the tube branches run for their
  /// slag throw off the pig iron the electronics branches cast, so those
  /// branches stop at "from byproduct of steel:smelt" instead of smelting
  /// again.
  test('missiles span several plants down to ore', () {
    final t = buildProductTree('missiles', ratePerS: 0.15);
    final s = summarizeProductTree(t);
    final types = s.plants.map((p) => p.type).toList();
    expect(types.first, 'missilefactory');
    expect(types, containsAll(
        ['missilefactory', 'rocketfactory', 'electronics', 'steelmill']));
    expect(s.plants.map((p) => p.label),
        containsAll(['Missile Plant', 'Electronics Plant', 'Steel Mill']));
    expect(s.rawPerS.keys, contains('ore'));
    expect(s.rawPerS['ore']!, greaterThan(0));
    expect(s.cycles, 0);

    final items = {for (final n in t.walk()) n.item};
    expect(items, containsAll(['rocketParts', 'electronics', 'tubes',
        'steel', 'slag', 'ore']));
    final consumed = [
      for (final n in t.walk())
        for (final b in n.byproducts)
          if (b.item == 'pigIron' && b.consumedInTree) b
    ];
    expect(consumed, isNotEmpty,
        reason: 'the tube branch smelts pig iron the electronics casts');
    final pigLeaves = [
      for (final n in t.walk())
        if (n.item == 'pigIron') n
    ];
    expect(pigLeaves, isNotEmpty);
    for (final n in pigLeaves) {
      expect(n.leaf, ProductLeaf.byproduct);
      expect(n.byproductOf, 'steel:smelt');
    }
  });

  /// The summary is the "machines by station kind" overview, so it must
  /// count the stations a plant would actually build. A missile tree rolls
  /// steel at two nodes (0.042 + 0.056 crafts/s, 2 s each: 0.39 mill-seconds
  /// a second at manual speed 0.6 = 0.65 mills) — ONE mill serves both,
  /// where rounding each node up first said two. The smelter runs at the
  /// tube branches only (0.5 + 0.3125 crafts/s × 4 s / 0.6 = 5.4 → 6); the
  /// pig iron the electronics branches need comes off those same smelts as a
  /// byproduct, so it adds no smelters of its own.
  test('summary shares stations between nodes running one recipe', () {
    final t = buildProductTree('missiles', ratePerS: 0.15);
    final rolls = [
      for (final n in t.walk())
        if (n.recipe?.id == 'steel:roll') n
    ];
    expect(rolls.length, greaterThan(1),
        reason: 'the test only means something if the recipe repeats');
    final s = summarizeProductTree(t);
    expect(s.machines[StationKind.mill]![MachineMode.manual], 1);
    expect(s.machines[StationKind.furnace]![MachineMode.manual], 1);
    expect(s.machines[StationKind.smelter]![MachineMode.manual], 6);
  });

  /// Same rule on a synthetic graph, so it does not hang on catalog tuning:
  /// two nodes each needing 0.3 of a press share one, while a DIFFERENT
  /// recipe on the same kind of station still needs its own.
  test('summary rounds per recipe, then adds recipes per station kind', () {
    const top = FactoryRecipe(
        id: 'x:top', label: 'Top', station: StationKind.assembler,
        inputs: [ItemQty('a', 1), ItemQty('b', 1)],
        outputs: [ItemQty('top', 1)], seconds: 1, powerKw: 1);
    const mkA = FactoryRecipe(
        id: 'x:a', label: 'A', station: StationKind.press,
        inputs: [ItemQty('p', 1)], outputs: [ItemQty('a', 1)],
        seconds: 1, powerKw: 1);
    const mkB = FactoryRecipe(
        id: 'x:b', label: 'B', station: StationKind.press,
        inputs: [ItemQty('p', 1)], outputs: [ItemQty('b', 1)],
        seconds: 1, powerKw: 1);
    const mkP = FactoryRecipe(
        id: 'x:p', label: 'P', station: StationKind.press,
        inputs: [ItemQty('ore', 1)], outputs: [ItemQty('p', 1)],
        seconds: 1, powerKw: 1);
    // 0.18 top/s: x:p runs twice at 0.18 crafts/s → 0.36/0.6 = 0.6 of a
    // manual press together (one), plus one each for x:a and x:b.
    final t = buildProductTree('top',
        ratePerS: 0.18, graph: RecipeGraph([top, mkA, mkB, mkP]));
    final s = summarizeProductTree(t);
    expect(s.machines[StationKind.press]![MachineMode.manual], 3);
  });

  /// A co-product the tree already makes must not be budgeted twice. The
  /// stamping press throws off one offcut per six chassis, exactly what
  /// the shield press needs; building a SECOND stamp node (and its whole
  /// steel → ore chain) for the offcut overstated ore and stations.
  test('a need met by an earlier byproduct is a leaf, not a second chain',
      () {
    final t = buildProductTree('electronics', ratePerS: 0.6);
    final offcut =
        t.walk().singleWhere((n) => n.item == 'electronics:offcut');
    expect(offcut.leaf, ProductLeaf.byproduct);
    expect(offcut.byproductOf, 'electronics:stamp');
    expect(offcut.children, isEmpty);
    final stamps = [
      for (final n in t.walk())
        if (n.recipe?.id == 'electronics:stamp') n
    ];
    expect(stamps.length, 1, reason: 'one stamping chain, not two');
    // Ore is then just the chassis steel's: 0.6 units/s takes 0.6
    // chassis/s → 0.1 stamp crafts/s → 0.5 steel/s → 2/3 ore/s at the
    // mill's 2 : 1.5 balance (the redundant offcut chain made it more).
    expect(summarizeProductTree(t).rawPerS['ore'], closeTo(2 / 3, 1e-9));
  });

  /// A raw leaf says where the colony gets it: ore from a Mine or Quarry.
  test('raw leaves name their colony sources', () {
    final t = buildProductTree('steel');
    final ore = t.walk().firstWhere((n) => n.item == 'ore');
    expect(ore.leaf, ProductLeaf.raw);
    expect(ore.colonySources, containsAll(['Mine', 'Quarry']));
    final food = buildProductTree('rations')
        .walk()
        .firstWhere((n) => n.item == 'food');
    expect(food.colonySources, contains('Farm'));
  });

  /// An item nothing in the catalog or the colony makes can only be
  /// imported; the tree must say so instead of pretending it is raw.
  test('import-only leaf', () {
    const r = FactoryRecipe(
        id: 'x:make', label: 'Make', station: StationKind.assembler,
        inputs: [ItemQty('unobtainium', 2)],
        outputs: [ItemQty('widget', 1)], seconds: 1, powerKw: 1);
    final t = buildProductTree('widget', graph: RecipeGraph([r]));
    expect(t.children.single.leaf, ProductLeaf.importOnly);
    expect(t.children.single.ratePerS, 2);
  });

  /// Chains may loop (a byproduct recycled into its own input). The tree
  /// must stop at the repeat and mark it, not recurse forever.
  test('cycle guard on a looping recipe set', () {
    const a = FactoryRecipe(
        id: 'x:a', label: 'A', station: StationKind.press,
        inputs: [ItemQty('b', 1), ItemQty('ore', 1)],
        outputs: [ItemQty('a', 1)], seconds: 1, powerKw: 1);
    const b = FactoryRecipe(
        id: 'x:b', label: 'B', station: StationKind.press,
        inputs: [ItemQty('a', 2)], outputs: [ItemQty('b', 1)],
        seconds: 1, powerKw: 1);
    final t = buildProductTree('a', graph: RecipeGraph([a, b]));
    final bn = child(t, 'b');
    final loop = child(bn, 'a');
    expect(loop.leaf, ProductLeaf.cycle);
    expect(loop.children, isEmpty);
    expect(summarizeProductTree(t).cycles, 1);
    expect(child(t, 'ore').leaf, ProductLeaf.raw);
  });

  /// Picking an alternative for one node rebuilds that branch under the new
  /// recipe and leaves the default alone everywhere else.
  test('switching a node to an alternative recipe', () {
    final def = buildProductTree('electronics');
    final steel =
        def.walk().firstWhere((n) => n.item == 'steel');
    expect(steel.recipe!.id, 'steel:roll');
    final alt = steel.alternatives
        .firstWhere((r) => r.id == 'electronics:unpack');

    final t = buildProductTree('electronics',
        recipeChoices: {steel.path: alt.id});
    final s2 = t.walk().firstWhere((n) => n.path == steel.path);
    expect(s2.recipe!.id, 'electronics:unpack');
    expect(s2.alternatives.map((r) => r.id), contains('steel:roll'));
    expect(s2.children.single.item, 'crate:steel');
    // A bogus choice is ignored: the default stands.
    final t3 = buildProductTree('electronics',
        recipeChoices: {steel.path: 'steel:smelt'});
    expect(t3.walk().firstWhere((n) => n.path == steel.path).recipe!.id,
        'steel:roll');
  });

  /// The UI must never reshuffle rows between two identical requests.
  test('builds are deterministic', () {
    String dump(ProductNode n) => [
          for (final x in n.walk())
            '${x.path}|${x.ratePerS}|${x.recipe?.id}|${x.leaf}|'
                '${x.alternatives.map((r) => r.id).join(',')}|'
                '${x.byproducts.map((b) => '${b.item}${b.consumedInTree}').join(',')}'
        ].join('\n');
    expect(dump(buildProductTree('missiles')),
        dump(buildProductTree('missiles')));
    expect(productCatalog(), productCatalog());
  });

  /// "Used in" lists every recipe taking an item, across plants.
  test('usedIn(steel)', () {
    final ids = usedIn('steel').map((r) => r.id).toList();
    expect(ids, containsAll(['steel:packSteel', 'electronics:stamp',
        'gunfactory:boreBarrel']));
    expect(ids, List.of(ids)..sort());
  });

  /// The picker leads with the goods a player ships, then their packs,
  /// then intermediates.
  test('product catalog orders finished goods first', () {
    final cat = productCatalog();
    expect(cat, containsAll(['missiles', 'crate:steel', 'pigIron']));
    final groups = cat.map(productGroupOf).toList();
    for (var i = 1; i < groups.length; i++) {
      expect(groups[i].index, greaterThanOrEqualTo(groups[i - 1].index));
    }
    expect(cat.indexOf('steel'), lessThan(cat.indexOf('crate:steel')));
    expect(cat.indexOf('crate:steel'), lessThan(cat.indexOf('pigIron')));
  });
}
