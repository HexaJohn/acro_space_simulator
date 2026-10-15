// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The product tree panel: the full flow from raw material to any finished
/// good, beside the floor that makes part of it
/// (lib/domain/colony/city/factory/product_tree.dart).
///
/// A floor shows ONE plant's machines; a missile needs four plants and a
/// mine. The panel answers "what do I need to make this, and how many
/// stations?" for any product at any rate, so a designer can size a line
/// before laying it, and see which other plants (and colony buildings) it
/// leans on.
///
/// **Where it sits.** The screen stacks it over the right of the canvas
/// area as a SIBLING of the canvas's pointer [Listener], never inside it:
/// an ancestor pan recognizer would steal the panel's clicks (memory:
/// flutter-gesture-button-filter). A sibling on top wins the hit test
/// outright.
///
/// **Keys.** The editor binds bare letters (R rotates, Del deletes) on a
/// [Focus] ABOVE this panel, so a key typed into the search box would
/// otherwise bubble up and rotate or delete on the floor (and, inside a
/// colony, on into the colony view's own bindings). The panel's [Focus]
/// therefore stops every key from bubbling past it ([KeyEventResult.
/// skipRemainingHandlers], which still lets the platform deliver the typed
/// text), and closes on Esc. Stopping the bubble would also cut the text
/// field off from the app-level editing shortcuts (Backspace, arrows,
/// select-all live in `WidgetsApp`'s [DefaultTextEditingShortcuts], far
/// above), so a copy of them sits INSIDE the panel, below the stop.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/product_tree.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';

/// Width of the panel, logical px: wide enough for a row's recipe, plant
/// badge and machine counts on two lines at the 13 px body size, and still
/// leaving most of a 1280 px window's canvas visible beside it.
const double kProductTreeWidth = 480;

/// Indent per tree level, logical px. A missile tree is ~11 levels deep;
/// 14 px a level keeps the deepest label inside the panel.
const double _kIndent = 14;

/// Most rows the picker's match list shows before it scrolls, as a height:
/// eight rows at ~30 px, enough to browse a group without hiding the tree.
const double _kPickerMaxHeight = 240;

/// The target rate a fresh tree is built for, items/s: one a second is the
/// scale the colony specs are written at (a few tenths to a couple per
/// second), and an easy number to scale in one's head.
const double kDefaultTreeRate = 1.0;

String _fmt(double v) => v >= 100
    ? v.toStringAsFixed(0)
    : v >= 10
        ? v.toStringAsFixed(1)
        : v >= 0.1
            ? v.toStringAsFixed(2)
            : v.toStringAsFixed(3);

String _itemLabel(String id) => FactoryItems.byId(id)?.label ?? id;

String _stationLabel(StationKind s) =>
    s.name[0].toUpperCase() + s.name.substring(1);

String _groupLabel(ProductGroup g) => switch (g) {
      ProductGroup.good => 'GOODS',
      ProductGroup.packed => 'PACKED FOR SHIPPING',
      ProductGroup.intermediate => 'INTERMEDIATES',
    };

/// "M 4 · A 2 · Auto 2": stations needed per crew mode, rounded up.
String machinesText(ProductNode n) =>
    'M ${n.machinesCeil(MachineMode.manual)} · '
    'A ${n.machinesCeil(MachineMode.assisted)} · '
    'Auto ${n.machinesCeil(MachineMode.automated)}';

class ProductTreePanel extends StatefulWidget {
  const ProductTreePanel({super.key, required this.c, required this.onClose});

  /// The editor: its floor seeds the default product, and its highlight
  /// outlines the machines running the selected step's recipe.
  final FactoryEditorController c;
  final VoidCallback onClose;

  @override
  State<ProductTreePanel> createState() => ProductTreePanelState();
}

class ProductTreePanelState extends State<ProductTreePanel> {
  /// Built once per panel: the catalog is registered before any floor opens
  /// and never shrinks while one is open.
  late final RecipeGraph graph = RecipeGraph.catalog();
  late final List<String> catalog = graph.productCatalog();

  late String item = _defaultItem();
  double rate = kDefaultTreeRate;

  /// Node path → recipe id the player switched it to.
  final Map<String, String> choices = {};

  /// Paths whose children are hidden (everything starts expanded).
  final Set<String> collapsed = {};
  String? selectedPath;
  bool usedInTab = false;

  late ProductNode tree;
  late ProductTreeSummary summary;

  final FocusNode _panelFocus = FocusNode(debugLabel: 'product-tree');
  final FocusNode _searchFocus = FocusNode(debugLabel: 'product-search');
  final TextEditingController _search = TextEditingController();
  final TextEditingController _rate =
      TextEditingController(text: kDefaultTreeRate.toStringAsFixed(1));
  bool _rateBad = false;

  @override
  void initState() {
    super.initState();
    _rebuild();
    _searchFocus.addListener(_onSearchFocus);
    // Take the keyboard so Esc closes at once, before anything is clicked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelFocus.requestFocus();
    });
  }

  void _onSearchFocus() => setState(() {});

  @override
  void dispose() {
    _searchFocus.removeListener(_onSearchFocus);
    _panelFocus.dispose();
    _searchFocus.dispose();
    _search.dispose();
    _rate.dispose();
    super.dispose();
  }

  /// What this floor ships, if it ships a catalog good: the first good or
  /// pack (catalog order) that a machine on the floor makes. A blank hall,
  /// or a floor of intermediates only, opens on the catalog's first good.
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

  void _rebuild() {
    tree = buildProductTree(item,
        ratePerS: rate, recipeChoices: choices, graph: graph);
    summary = summarizeProductTree(tree);
  }

  /// Switches the whole panel to [id]: choices and folding belong to the
  /// old tree's paths.
  void pick(String id) {
    setState(() {
      item = id;
      choices.clear();
      collapsed.clear();
      selectedPath = null;
      _search.clear();
      _rebuild();
    });
    widget.c.setHighlightRecipe(null);
    _panelFocus.requestFocus();
  }

  void _setRate(String s) {
    final v = double.tryParse(s.trim());
    setState(() {
      // A rate must be a positive number; anything else keeps the last good
      // tree and marks the field. (Tested on `v` directly, never through a
      // bool local: memory aot-promotion-miscompile.)
      if (v == null || v <= 0 || v.isInfinite || v.isNaN) {
        _rateBad = true;
      } else {
        _rateBad = false;
        rate = v;
        _rebuild();
      }
    });
  }

  void chooseRecipe(String path, String recipeId) {
    setState(() {
      choices[path] = recipeId;
      // A new recipe means new children: forget folds below this node.
      collapsed.removeWhere((p) => p.startsWith('$path>'));
      _rebuild();
    });
    if (selectedPath == path) widget.c.setHighlightRecipe(recipeId);
  }

  void _select(ProductNode n) {
    setState(() => selectedPath = n.path);
    widget.c.setHighlightRecipe(n.recipe?.id);
  }

  void expandAll() => setState(collapsed.clear);

  /// Folds every branch below the root, so the root's direct inputs are the
  /// overview.
  void collapseAll() => setState(() {
        collapsed
          ..clear()
          ..addAll([
            for (final n in tree.walk())
              if (n.children.isNotEmpty && n.path != tree.path) n.path
          ]);
      });

  void _toggle(String path) => setState(() {
        if (!collapsed.remove(path)) collapsed.add(path);
      });

  ProductNode? get _selectedNode {
    final p = selectedPath;
    if (p == null) return null;
    for (final n in tree.walk()) {
      if (n.path == p) return n;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    // Never let a key reach the editor's (or the colony's) bindings above.
    return KeyEventResult.skipRemainingHandlers;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _panelFocus,
      onKeyEvent: _onKey,
      child: DefaultTextEditingShortcuts(
        child: Material(
          key: const Key('ptree-panel'),
          color: AppTheme.panel,
          elevation: 8,
          child: Container(
            decoration: const BoxDecoration(
                border: Border(
                    left: BorderSide(color: AppTheme.accent, width: 2))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(),
                _picker(),
                _rateRow(),
                _tabs(),
                const Divider(height: 1, color: AppTheme.panelLight),
                Expanded(child: usedInTab ? _usedIn() : _treeList()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
        child: Row(children: [
          const Icon(Icons.account_tree, color: AppTheme.accent, size: 18),
          const SizedBox(width: 8),
          const Expanded(
              child: Text('PRODUCT TREE', style: AppTheme.heading)),
          IconButton(
            key: const Key('ptree-close'),
            tooltip: 'Close (Esc)',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: AppTheme.text, size: 18),
          ),
        ]),
      );

  /// A searchable picker: the field filters the catalog, and while it has
  /// focus (or text) the matches list under it, grouped goods first.
  Widget _picker() {
    final q = _search.text.trim().toLowerCase();
    final open = _searchFocus.hasFocus || q.isNotEmpty;
    final matches = [
      for (final id in catalog)
        if (q.isEmpty ||
            id.toLowerCase().contains(q) ||
            _itemLabel(id).toLowerCase().contains(q))
          id
    ];
    final rows = <Widget>[];
    ProductGroup? last;
    for (final id in matches) {
      final g = productGroupOf(id);
      if (g != last) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Text(_groupLabel(g),
              style: AppTheme.dim.copyWith(fontSize: 10)),
        ));
        last = g;
      }
      rows.add(InkWell(
        key: Key('ptree-pick-$id'),
        onTap: () => pick(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(_itemLabel(id),
              style: AppTheme.body.copyWith(
                  color: id == item ? AppTheme.accent : AppTheme.text)),
        ),
      ));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('Product  ', style: AppTheme.dim),
          Expanded(
            child: Text(_itemLabel(item),
                key: const Key('ptree-selected'),
                overflow: TextOverflow.ellipsis,
                style: AppTheme.title
                    .copyWith(color: AppTheme.accent, fontSize: 15)),
          ),
        ]),
        TextField(
          key: const Key('ptree-search'),
          controller: _search,
          focusNode: _searchFocus,
          style: AppTheme.body,
          decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search products…',
              hintStyle: AppTheme.dim,
              prefixIcon: Icon(Icons.search, size: 16)),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (matches.isNotEmpty) pick(matches.first);
          },
        ),
        if (open)
          Container(
            key: const Key('ptree-matches'),
            constraints: const BoxConstraints(maxHeight: _kPickerMaxHeight),
            color: AppTheme.panelLight,
            child: matches.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No product matches', style: AppTheme.dim))
                : ListView(shrinkWrap: true, children: rows),
          ),
      ]),
    );
  }

  Widget _rateRow() {
    final d = FactoryItems.byId(item);
    final units = d != null && d.isCrate
        ? '= ${_fmt(rate * d.commodityUnits)} ${_itemLabel(d.commodity)}/s'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Row(children: [
        const Text('Target  ', style: AppTheme.dim),
        SizedBox(
          width: 72,
          child: TextField(
            key: const Key('ptree-rate'),
            controller: _rate,
            style: AppTheme.mono.copyWith(
                color: _rateBad ? AppTheme.danger : AppTheme.text),
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true),
            onChanged: _setRate,
          ),
        ),
        const SizedBox(width: 6),
        Text('${_itemLabel(item)}/s', style: AppTheme.dim),
        if (units != null) ...[
          const SizedBox(width: 6),
          Flexible(
              child: Text(units,
                  key: const Key('ptree-units'),
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.dim)),
        ],
      ]),
    );
  }

  Widget _tabs() => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 4, 4),
        child: Row(children: [
          ChoiceChip(
            key: const Key('ptree-tab-tree'),
            label: const Text('Tree'),
            selected: !usedInTab,
            onSelected: (_) => setState(() => usedInTab = false),
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            key: const Key('ptree-tab-usedin'),
            label: const Text('Used in'),
            selected: usedInTab,
            onSelected: (_) => setState(() => usedInTab = true),
          ),
          const Spacer(),
          if (!usedInTab) ...[
            IconButton(
              key: const Key('ptree-expand-all'),
              tooltip: 'Expand all',
              onPressed: expandAll,
              icon: const Icon(Icons.unfold_more, color: AppTheme.text,
                  size: 18),
            ),
            IconButton(
              key: const Key('ptree-collapse-all'),
              tooltip: 'Collapse all',
              onPressed: collapseAll,
              icon: const Icon(Icons.unfold_less, color: AppTheme.text,
                  size: 18),
            ),
          ],
        ]),
      );

  // ---- Tree -------------------------------------------------------------

  Widget _treeList() {
    final rows = <Widget>[];
    void add(ProductNode n, int depth) {
      rows.add(_row(n, depth));
      if (collapsed.contains(n.path)) return;
      for (final ch in n.children) {
        add(ch, depth + 1);
      }
    }

    add(tree, 0);
    return ListView(
      key: const Key('ptree-list'),
      padding: const EdgeInsets.only(bottom: 16),
      children: [...rows, _summary()],
    );
  }

  Widget _plantBadge(ProductPlant p) => Container(
        key: Key('ptree-plant-${p.type}'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Color(p.colorArgb).withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Color(p.colorArgb)),
        ),
        child: Text(p.label,
            style: TextStyle(color: Color(p.colorArgb), fontSize: 10)),
      );

  Widget _chip(String text, Color color, {Key? key, String? tooltip}) {
    final w = Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.panelLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 11)),
    );
    return tooltip == null ? w : Tooltip(message: tooltip, child: w);
  }

  Widget _row(ProductNode n, int depth) {
    final r = n.recipe;
    final selected = n.path == selectedPath;
    final hasKids = n.children.isNotEmpty;
    final d = n.def;
    final units = d != null && d.isCrate
        ? '  (${_fmt(n.commodityPerS)} ${_itemLabel(d.commodity)}/s)'
        : '';
    final details = <Widget>[];
    switch (n.leaf) {
      case ProductLeaf.raw:
        details.add(_chip('raw · from ${n.colonySources.join(', ')}',
            AppTheme.accent2, key: Key('ptree-raw-${n.path}')));
      case ProductLeaf.importOnly:
        details.add(_chip('import only', AppTheme.warn,
            key: Key('ptree-import-${n.path}')));
      case ProductLeaf.cycle:
        details.add(_chip('↻ cycle: made further up this branch',
            AppTheme.warn, key: Key('ptree-cycle-${n.path}')));
      case ProductLeaf.none:
        details.add(Text(
            '${r!.label} · ${_stationLabel(r.station)} · ${machinesText(n)}',
            key: Key('ptree-recipe-${n.path}'),
            style: AppTheme.dim.copyWith(fontSize: 11)));
        for (final b in n.byproducts) {
          details.add(_chip(
              '+${_fmt(b.ratePerS)} ${_itemLabel(b.item)}/s'
              '${b.consumedInTree ? ' ↻ used in tree' : ''}',
              b.consumedInTree ? AppTheme.accent2 : AppTheme.textDim,
              key: Key('ptree-byproduct-${n.path}-${b.item}'),
              tooltip: b.consumers.isEmpty
                  ? 'Byproduct: nothing takes it (waste)'
                  : 'Byproduct, taken by ${b.consumers.join(', ')}'));
        }
        if (n.alternatives.isNotEmpty) details.add(_altMenu(n));
        if (selected) {
          final here = widget.c.machinesRunning(r.id);
          details.add(_chip('$here on this floor',
              here > 0 ? const Color(0xFFFFC107) : AppTheme.textDim,
              key: const Key('ptree-here')));
        }
    }
    return InkWell(
      key: Key('ptree-row-${n.path}'),
      onTap: () => _select(n),
      child: Container(
        color: selected ? AppTheme.panelLight : null,
        padding: EdgeInsets.fromLTRB(4 + depth * _kIndent, 3, 8, 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 22,
            child: hasKids
                ? InkWell(
                    key: Key('ptree-toggle-${n.path}'),
                    onTap: () => _toggle(n.path),
                    child: Icon(
                        collapsed.contains(n.path)
                            ? Icons.chevron_right
                            : Icons.expand_more,
                        size: 18,
                        color: AppTheme.textDim),
                  )
                : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                        '${n.label}  ${_fmt(n.ratePerS)}/s$units',
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.body.copyWith(
                            fontWeight: depth == 0
                                ? FontWeight.bold
                                : FontWeight.normal)),
                  ),
                  if (n.plant case final p?) ...[
                    const SizedBox(width: 6),
                    _plantBadge(p),
                  ],
                ]),
                const SizedBox(height: 2),
                Wrap(spacing: 4, runSpacing: 2, children: details),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// The alternatives chip: other recipes that make this node's item; picking
  /// one rebuilds this branch on it.
  Widget _altMenu(ProductNode n) => PopupMenuButton<String>(
        key: Key('ptree-alt-${n.path}'),
        tooltip: 'Other ways to make ${n.label}',
        color: AppTheme.panelLight,
        onSelected: (id) => chooseRecipe(n.path, id),
        itemBuilder: (_) => [
          for (final r in n.alternatives)
            PopupMenuItem<String>(
              key: Key('ptree-alt-${n.path}-${r.id}'),
              value: r.id,
              child: Text(
                  '${r.label} · ${plantOfRecipe(r.id)?.label ?? '?'}',
                  style: AppTheme.body),
            ),
        ],
        child: _chip(
            '${n.alternatives.length} other '
            'recipe${n.alternatives.length == 1 ? '' : 's'} ▾',
            AppTheme.accent),
      );

  Widget _summary() {
    final s = summary;
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
          child: Text(t, style: AppTheme.heading.copyWith(fontSize: 12)),
        );
    return Column(
      key: const Key('ptree-summary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 18, color: AppTheme.panelLight),
        head('RAW INPUTS (gross, per second)'),
        if (s.rawPerS.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('—', style: AppTheme.dim)),
        for (final e in s.rawPerS.entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
            child: Text(
                '${_itemLabel(e.key).padRight(14)} ${_fmt(e.value)}/s  '
                '${_rawSource(e.key)}',
                key: Key('ptree-raw-total-${e.key}'),
                style: AppTheme.mono),
          ),
        if (s.cycles > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('${s.cycles} branch(es) loop back on themselves',
                style: AppTheme.dim.copyWith(color: AppTheme.warn)),
          ),
        head('MACHINES (manual · assisted · automated)'),
        for (final e in s.machines.entries)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
            child: Text(
                '${_stationLabel(e.key).padRight(10)} '
                '${e.value[MachineMode.manual]} · '
                '${e.value[MachineMode.assisted]} · '
                '${e.value[MachineMode.automated]}',
                key: Key('ptree-machines-${e.key.name}'),
                style: AppTheme.mono),
          ),
        head('PLANTS INVOLVED'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(spacing: 6, runSpacing: 4, children: [
            for (final p in s.plants) _plantBadge(p),
          ]),
        ),
      ],
    );
  }

  String _rawSource(String id) {
    final d = FactoryItems.byId(id);
    final src = colonySourcesOf(d?.commodity ?? id);
    return src.isEmpty ? 'import only' : 'from ${src.join(', ')}';
  }

  // ---- Used in ----------------------------------------------------------

  Widget _usedIn() {
    final id = _selectedNode?.item ?? item;
    final users = graph.usedIn(id);
    String side(List<ItemQty> qs) =>
        qs.map((q) => '${q.count} ${_itemLabel(q.item)}').join(' + ');
    return ListView(
      key: const Key('ptree-usedin-list'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        Text('${_itemLabel(id)} is used in',
            key: const Key('ptree-usedin-title'), style: AppTheme.heading),
        const SizedBox(height: 6),
        if (users.isEmpty)
          const Text('Nothing takes it: a finished good, or waste.',
              style: AppTheme.dim),
        for (final r in users)
          InkWell(
            key: Key('ptree-used-${r.id}'),
            // Following a use opens ITS product's tree: walk the flow
            // downstream as easily as up.
            onTap: () {
              final out = r.outputs.isEmpty ? null : r.outputs.first.item;
              if (out == null) return;
              usedInTab = false;
              pick(out);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                        child: Text(r.label,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.body)),
                    if (plantOfRecipe(r.id) case final p?) ...[
                      const SizedBox(width: 6),
                      _plantBadge(p),
                    ],
                  ]),
                  Text(
                      '${side(r.inputs)} → ${side(r.outputs)} · '
                      '${_stationLabel(r.station)} ${r.seconds}s',
                      style: AppTheme.dim.copyWith(fontSize: 11)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
