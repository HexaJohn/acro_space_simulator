// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The in-game "Recipe info" panel (docs/plans/factory-floors.md §10 item
/// 15): what goes into one item, without the whole chain.
///
/// **Why not the product tree.** The full tree ([ProductTreePanel]) solves
/// a plant for the player: every step from ore to missile, sized in
/// stations at any rate. The user's verdict from the playtest was that this
/// is "far too OP to have in game", so the tree is now a debug tool (the
/// dev entry, or `FactoryFloorScreen.debugTools`), and the game gets two
/// narrower answers instead, each still useful, neither a solution:
///
/// * **Components** — the recipe(s) that make the item, ONE level: inputs,
///   outputs, cycle time and station. Working out what makes each input is
///   the player's job (pick that input next).
/// * **Raw total** — the raw materials one unit costs in total, with NO
///   intermediate step shown. Computed by the product tree's own math
///   ([buildProductTree] + [summarizeProductTree], at 1 unit/s so the
///   per-second totals read as per-unit), and only the summary's raw map is
///   ever displayed: the tree it walks never reaches the widget tree.
///
/// Sits where the product tree does, as a SIBLING above the canvas row and
/// never inside the canvas's pointer [Listener] (an ancestor recognizer
/// steals clicks: memory flutter-gesture-button-filter). It has no text
/// field of its own; the item choice is the shared [SearchablePicker],
/// whose dialog keeps typing away from the editor's keys.
library;

import 'package:flutter/material.dart';

import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/product_tree.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';
import 'searchable_picker.dart';

/// Width of the panel, logical px: one recipe's "inputs → outputs" line at
/// the 13 px body size.
const double kRecipeInfoWidth = 380;

/// The two answers the panel gives (see the library doc).
enum RecipeInfoView { components, rawTotal }

String _itemLabel(String id) => FactoryItems.byId(id)?.label ?? id;

String _stationLabel(StationKind s) =>
    s.name[0].toUpperCase() + s.name.substring(1);

String _fmt(double v) => v >= 100
    ? v.toStringAsFixed(0)
    : v >= 10
        ? v.toStringAsFixed(1)
        : v >= 0.1
            ? v.toStringAsFixed(2)
            : v.toStringAsFixed(3);

String _groupLabel(ProductGroup g) => switch (g) {
      ProductGroup.good => 'GOODS',
      ProductGroup.packed => 'PACKED FOR SHIPPING',
      ProductGroup.intermediate => 'INTERMEDIATES',
    };

/// The raw materials one unit of [itemId] costs in total, by item id: the
/// product tree's raw summary at 1 unit/s. Nothing else of the tree is
/// returned, so a caller can't show the chain by accident.
Map<String, double> rawPerUnit(String itemId, {RecipeGraph? graph}) =>
    summarizeProductTree(buildProductTree(itemId, ratePerS: 1, graph: graph))
        .rawPerS;

/// The recipes that make [itemId] directly (one level), by id.
List<FactoryRecipe> directRecipes(String itemId, {RecipeGraph? graph}) =>
    (graph ?? RecipeGraph.catalog()).producersOf(itemId);

class RecipeInfoPanel extends StatefulWidget {
  const RecipeInfoPanel(
      {super.key, required this.c, required this.onClose, this.onItem});

  /// The editor: its floor seeds the default item (what the floor makes).
  final FactoryEditorController c;
  final VoidCallback onClose;

  /// Told the item shown: once when the panel opens, and on every pick. The
  /// tutorial's "Read the floor" step listens here.
  final ValueChanged<String>? onItem;

  @override
  State<RecipeInfoPanel> createState() => RecipeInfoPanelState();
}

class RecipeInfoPanelState extends State<RecipeInfoPanel> {
  late final RecipeGraph graph = RecipeGraph.catalog();
  late final List<String> catalog = graph.productCatalog();

  late String item = _defaultItem();
  RecipeInfoView view = RecipeInfoView.components;

  @override
  void initState() {
    super.initState();
    // After the frame: a listener may rebuild its own widgets.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onItem?.call(item);
    });
  }

  /// What this floor ships, if it ships a catalog good (the product tree's
  /// rule): the first good or pack a machine here makes, else the
  /// catalog's first.
  String _defaultItem() {
    final made = <String>{};
    for (final m in widget.c.index.machines) {
      final rid = m.recipe;
      final r = rid == null ? null : FactoryRecipes.byId(rid);
      if (r == null) continue;
      for (final o in r.outputs) {
        made.add(o.item);
      }
    }
    for (final id in catalog) {
      if (productGroupOf(id) != ProductGroup.intermediate &&
          made.contains(id)) {
        return id;
      }
    }
    return catalog.isEmpty ? '' : catalog.first;
  }

  void pick(String id) {
    setState(() => item = id);
    widget.onItem?.call(id);
  }

  void setView(RecipeInfoView v) => setState(() => view = v);

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('rinfo-panel'),
      color: AppTheme.panel,
      elevation: 8,
      child: Container(
        decoration: const BoxDecoration(
            border:
                Border(left: BorderSide(color: AppTheme.accent, width: 2))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
              child: Row(children: [
                const Icon(Icons.info_outline,
                    color: AppTheme.accent, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                    child: Text('RECIPE INFO', style: AppTheme.heading)),
                IconButton(
                  key: const Key('rinfo-close'),
                  tooltip: 'Close (Esc)',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close, color: AppTheme.text, size: 18),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: SearchablePicker<String>(
                key: const Key('rinfo-item'),
                title: 'Recipe info for…',
                selectedId: item,
                options: [
                  for (final id in catalog)
                    PickerOption(
                        value: id,
                        id: id,
                        label: _itemLabel(id),
                        group: _groupLabel(productGroupOf(id))),
                ],
                onChanged: pick,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Row(children: [
                ChoiceChip(
                  key: const Key('rinfo-tab-components'),
                  label: const Text('Components'),
                  selected: view == RecipeInfoView.components,
                  onSelected: (_) => setView(RecipeInfoView.components),
                ),
                const SizedBox(width: 6),
                ChoiceChip(
                  key: const Key('rinfo-tab-raw'),
                  label: const Text('Raw total'),
                  selected: view == RecipeInfoView.rawTotal,
                  onSelected: (_) => setView(RecipeInfoView.rawTotal),
                ),
              ]),
            ),
            const Divider(height: 1, color: AppTheme.panelLight),
            Expanded(
              child: view == RecipeInfoView.components
                  ? _components()
                  : _rawTotal(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _components() {
    final rs = directRecipes(item, graph: graph);
    String side(List<ItemQty> qs) => qs.isEmpty
        ? 'nothing'
        : qs.map((q) => '${q.count} ${_itemLabel(q.item)}').join(' + ');
    return ListView(
      key: const Key('rinfo-components'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        Text('What makes ${_itemLabel(item)}', style: AppTheme.heading),
        const SizedBox(height: 6),
        if (rs.isEmpty)
          const Text('No recipe makes it: a raw material, brought in.',
              key: Key('rinfo-no-recipe'), style: AppTheme.dim),
        for (final r in rs)
          Padding(
            key: Key('rinfo-recipe-${r.id}'),
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.label, style: AppTheme.body),
                Text('In:  ${side(r.inputs)}',
                    key: Key('rinfo-in-${r.id}'), style: AppTheme.mono),
                Text('Out: ${side(r.outputs)}',
                    key: Key('rinfo-out-${r.id}'), style: AppTheme.mono),
                Text('${_stationLabel(r.station)} · ${r.seconds}s a cycle',
                    key: Key('rinfo-station-${r.id}'),
                    style: AppTheme.dim.copyWith(fontSize: 11)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rawTotal() {
    final raw = rawPerUnit(item, graph: graph);
    return ListView(
      key: const Key('rinfo-raw'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        Text('Raw materials per ${_itemLabel(item)}',
            style: AppTheme.heading),
        const SizedBox(height: 2),
        const Text('In total, every step included; the steps are yours to '
            'work out.',
            style: AppTheme.dim),
        const SizedBox(height: 6),
        if (raw.isEmpty)
          const Text('—', style: AppTheme.dim),
        for (final e in raw.entries)
          Text('${_itemLabel(e.key).padRight(14)} ${_fmt(e.value)}',
              key: Key('rinfo-raw-${e.key}'), style: AppTheme.mono),
      ],
    );
  }
}
