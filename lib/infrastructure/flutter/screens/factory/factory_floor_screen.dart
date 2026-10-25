// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The factory floor editor (docs/plans/factory-floors.md §4, phase 2).
///
/// Open a plant and you get its hall from above: a palette of machines,
/// belts and handling gear on the left, the live floor in the middle, and the
/// inspector, handler roster and throughput readout on the right. The floor
/// keeps running while you edit — items ride belts and workers run their
/// trips — because watching a line jam is how a player learns where the
/// bottleneck is.
///
/// The screen works against [FactorySim] only: the real `FactoryFloor` in
/// the game and the dev entry, a recording fake in the tests. The default
/// [FactoryColonyPort] is the sandbox ([InfiniteColonyPort]) so a floor is
/// playable before colony integration.
///
/// **Who drives.** With [FactoryFloorScreen.drivesSim] (the sandbox) the
/// screen steps the floor every frame and shows speed controls. Inside a
/// colony the colony steps the floor and owns its period ledger, so the
/// screen is opened with `drivesSim: false`: it never steps, never takes
/// the ledger, hides the speed controls, and reads its throughput from the
/// floor's lifetime counters like it always does.
///
/// A header strip shows what the layout costs to build (`capexOf`, in ore,
/// by what it buys) and the hall's size in metres, because hall area and
/// kit are the price of every design choice on the floor.
///
/// Gesture layout (two real bugs in this repo shaped it): the canvas's
/// [Listener] wraps ONLY the canvas, beside the panels and never around
/// them, so a drag on the floor can't swallow a click on a panel; and it
/// filters buttons itself — primary edits (or pans empty floor with the
/// Select tool), middle pans, and the right button does nothing at all.
///
/// "Recipe info" in the header opens [RecipeInfoPanel] over the right of
/// the body: for one item, the recipes that make it (one level) or the raw
/// materials a unit costs in total, never the chain between (§10 item 15).
/// "Product tree" opens the full [ProductTreePanel] instead, and exists
/// only with [FactoryFloorScreen.debugTools]: the user judged the whole
/// solved chain too strong for the game. Both are stacked as SIBLINGS
/// above the canvas row (never inside the canvas [Listener]) for the same
/// reason, and keep their typing away from the floor's keys.
///
/// Every item and recipe choice (palette, inspector, Recipe info) is the
/// shared type-to-search [SearchablePicker] (§10 item 16).
///
/// Keys (docs/plans/factory-floors.md §10; the table is on
/// [FactoryEditorController.handleKey]): R / Shift+R rotate, Ctrl+Z /
/// Ctrl+Y undo and redo every edit (also the header's arrows), M cycles the
/// belt-and-aisle run shape (the chips under those tools), F flips an L,
/// Shift held straightens a run or adds floor markings to an area delete,
/// X held deletes whatever the cursor sweeps over (one undo step, §10 item
/// 12). None of them fire while a text field has the keyboard ([_typing]).
///
/// Given a [FactoryFloorScreen.scenario], the screen also hosts the
/// [TutorialPanel] card in the canvas area's top-left corner (again a
/// sibling above the canvas [Listener]), trades through the scenario's
/// supply port, and pulses the palette entry, roster row or header button
/// the current step's hint names. Without one, nothing changes.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../../domain/colony/city/factory/factory_capex.dart';
import '../../../../domain/colony/city/factory/factory_colony_port.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_scenario.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/factory_unlocks.dart';
import '../../../../domain/colony/city/factory/floor_blueprint.dart';
import '../../../../domain/colony/city/factory/product_tree.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';
import 'factory_floor_painter.dart';
import 'floor_item_overlays.dart';
import 'floor_layout_index.dart';
import 'product_tree_panel.dart';
import 'recipe_info_panel.dart';
import 'searchable_picker.dart';
import 'tutorial_panel.dart';

/// Width of the palette column, logical px.
const double kPaletteWidth = 212;

/// Width of the inspector / roster / readout column, logical px.
const double kSidePanelWidth = 280;

class FactoryFloorScreen extends StatefulWidget {
  const FactoryFloorScreen({
    super.key,
    required this.sim,
    this.port,
    this.title = 'Factory Floor',
    this.onSaveBlueprint,
    this.unlocks = FactoryUnlocks.all,
    this.drivesSim = true,
    this.onClose,
    this.scenario,
    this.debugTools = false,
  });

  /// Shows the debug-only tools: today the full product tree, which solves
  /// a whole production chain and is too strong for the game (§10 item 15;
  /// the game has Recipe info instead). The dev entry passes true; every
  /// game mode, the tutorial included, leaves it false.
  final bool debugTools;

  final FactorySim sim;

  /// A guided scenario on this floor: the tutorial card over the canvas
  /// and, unless [port] is given, the scenario's own supply port. Null (the
  /// default) is the plain editor, exactly as before.
  final FactoryScenario? scenario;

  /// What the back arrow does. Null pops the route the screen was pushed
  /// on. A host that shows the editor INSIDE its own view (the colony, so
  /// its ticker keeps running) passes its own close, which is also where
  /// the colony settles the edit (`CityFactories.closeFloor`).
  final VoidCallback? onClose;

  /// What the colony has unlocked, for DISPLAY: locked handler kinds and
  /// station modes are greyed. The sim enforces its own unlocks.
  final FactoryUnlocks unlocks;

  /// True (sandbox): the screen steps the floor. False: the colony does,
  /// and the screen only watches (never `step`, never `takeLedger`).
  final bool drivesSim;

  /// The colony the floor trades with; null = a sandbox
  /// ([InfiniteColonyPort]) created once by the screen's state and kept
  /// across rebuilds, so its dock tallies are not reset every frame.
  final FactoryColonyPort? port;
  final String title;

  /// Receives a COPY of the layout ("Save as blueprint"); hidden when null.
  final void Function(FloorBlueprint)? onSaveBlueprint;

  @override
  State<FactoryFloorScreen> createState() => FactoryFloorScreenState();
}

class FactoryFloorScreenState extends State<FactoryFloorScreen>
    with SingleTickerProviderStateMixin {
  /// The sandbox port used while the widget gives none (made once).
  InfiniteColonyPort? _sandbox;

  /// The scenario's runner (null: no scenario). It owns the scenario's
  /// supply port, which the floor trades through unless the host passed
  /// its own [FactoryFloorScreen.port] (a [ScenarioColonyPort] given that
  /// way becomes the runner's).
  late ScenarioRunner? runner = _newRunner();

  ScenarioRunner? _newRunner() {
    final s = widget.scenario;
    if (s == null) return null;
    final given = widget.port;
    return ScenarioRunner(s, port: given is ScenarioColonyPort ? given : null);
  }

  FactoryColonyPort get _port =>
      widget.port ?? runner?.port ?? (_sandbox ??= InfiniteColonyPort());

  late FactoryEditorController controller = _newController();

  FactoryEditorController _newController() => FactoryEditorController(
      widget.sim, _port,
      drivesSim: widget.drivesSim, unlocks: widget.unlocks);
  FloorLayerCache _cache = FloorLayerCache();
  final FocusNode _focus = FocusNode(debugLabel: 'factory-floor');
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  /// Static-layer builds so far (a test checks the cache holds).
  int get layerBuilds => _cache.builds;

  /// The product tree panel is showing (only ever with debugTools).
  bool treeOpen = false;

  /// The Recipe info panel is showing. It and the tree share the right of
  /// the body, so opening one closes the other.
  bool infoOpen = false;

  void openProductTree() {
    if (!widget.debugTools) return;
    setState(() {
      treeOpen = true;
      infoOpen = false;
    });
  }

  void openRecipeInfo() {
    if (treeOpen) controller.setHighlightRecipe(null);
    setState(() {
      infoOpen = true;
      treeOpen = false;
    });
  }

  void closeRecipeInfo() {
    if (!infoOpen) return;
    setState(() => infoOpen = false);
    _focus.requestFocus();
  }

  /// Closes the panel, drops its floor highlight, and hands the keyboard
  /// back to the editor (the panel held it).
  void closeProductTree() {
    if (!treeOpen) return;
    setState(() => treeOpen = false);
    controller.setHighlightRecipe(null);
    _focus.requestFocus();
  }

  /// The keyboard is in a text field somewhere under this screen (the
  /// product tree's search, a future name box). Typing an R or a Ctrl+Z
  /// there edits the TEXT; it must never rotate or undo on the floor. The
  /// product tree already swallows its own keys, but this guard holds for
  /// any field, so a new one can't reopen the bug.
  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (_typing()) {
      // X held as focus moved into a field: its key-up won't come here.
      controller.keyboardLost();
      return KeyEventResult.ignored;
    }
    // Esc closes the topmost thing first: an open panel, then the tool.
    if ((treeOpen || infoOpen) &&
        e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.escape) {
      treeOpen ? closeProductTree() : closeRecipeInfo();
      return KeyEventResult.handled;
    }
    return controller.handleKey(e)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    // Take the keyboard once mounted. `autofocus` alone is not enough when
    // the editor is shown inside a host that already holds focus (the
    // colony view's own key node): autofocus only fires in a scope with
    // nothing focused, and R / Del would then rotate and delete in the
    // world instead of on the floor.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  /// A new sim or port means a new floor: the controller (camera, selection,
  /// rate window, heat map) and the static-layer cache (keyed only by
  /// layoutRev, which two sims can share) both belong to the old one.
  /// New unlocks do NOT: a colony parent may build a fresh [FactoryUnlocks]
  /// on every rebuild, so they are swapped into the live controller.
  @override
  void didUpdateWidget(FactoryFloorScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.scenario, widget.scenario)) runner = _newRunner();
    if (identical(old.sim, widget.sim) &&
        identical(old.port, widget.port) &&
        identical(old.scenario, widget.scenario) &&
        old.drivesSim == widget.drivesSim) {
      controller.setUnlocks(widget.unlocks);
      return;
    }
    final oldController = controller, oldCache = _cache;
    controller = _newController();
    _cache = FloorLayerCache();
    // The frame being built may still hold the old painter; release the old
    // controller and pictures once it is out.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      oldController.dispose();
      oldCache.dispose();
    });
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    controller.tick(dt);
  }

  @override
  void dispose() {
    _ticker.dispose();
    controller.dispose();
    _cache.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (_, e) => _onKey(e),
          // Focus left the editor (a dialog, another panel): a held X's
          // key-up will go elsewhere, so close the sweep now.
          onFocusChange: (has) {
            if (!has) controller.keyboardLost();
          },
          child: Column(
            children: [
              _TopBar(
                  c: controller,
                  title: widget.title,
                  onBack: widget.onClose,
                  treeOpen: treeOpen,
                  infoOpen: infoOpen,
                  onProductTree: widget.debugTools
                      ? () => treeOpen ? closeProductTree() : openProductTree()
                      : null,
                  onRecipeInfo: () =>
                      infoOpen ? closeRecipeInfo() : openRecipeInfo(),
                  onSave: widget.onSaveBlueprint == null
                      ? null
                      : () => widget.onSaveBlueprint!(
                          widget.sim.blueprint.copy())),
              _CostStrip(c: controller),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                            width: kPaletteWidth,
                            child: _Palette(c: controller)),
                        Expanded(child: _canvas()),
                        SizedBox(
                            width: kSidePanelWidth,
                            child: _SidePanel(c: controller)),
                      ],
                    ),
                    // Above the canvas row, beside its Listener: see the
                    // library doc.
                    if (treeOpen)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: kProductTreeWidth,
                        child: ProductTreePanel(
                            c: controller,
                            onClose: closeProductTree,
                            onItem: runner?.noteProductTree),
                      ),
                    if (infoOpen)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 0,
                        width: kRecipeInfoWidth,
                        child: RecipeInfoPanel(
                            c: controller,
                            onClose: closeRecipeInfo,
                            onItem: runner?.noteRecipeInfo),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _canvas() {
    final c = controller;
    final run = runner;
    return LayoutBuilder(builder: (context, box) {
      c.setViewSize(box.biggest);
      return Stack(
        fit: StackFit.expand,
        children: [
          // MouseRegion only for its exit (no gesture arena): the cursor
          // leaving the floor clears the hover, so X over a panel deletes
          // nothing.
          MouseRegion(
            onExit: (_) => c.pointerExit(),
            child: Listener(
            key: const Key('factory-canvas'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              _focus.requestFocus();
              c.pointerDown(e.pointer, e.localPosition, e.buttons);
            },
            onPointerMove: (e) => c.pointerMove(e.pointer, e.localPosition),
            onPointerUp: (e) => c.pointerUp(e.pointer, e.localPosition),
            onPointerCancel: (e) => c.pointerCancel(e.pointer),
            onPointerHover: (e) => c.pointerHover(e.localPosition),
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                c.scroll(e.localPosition, e.scrollDelta.dy);
              }
            },
            child: RepaintBoundary(
              child: CustomPaint(
                painter: FactoryFloorPainter(c, _cache),
                size: Size.infinite,
              ),
            ),
          ),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) {
                  final m = c.message;
                  if (m == null) return const SizedBox.shrink();
                  return Container(
                    key: const Key('factory-message'),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: AppTheme.panelBox(border: AppTheme.warn),
                    child: Text(m,
                        style: AppTheme.body.copyWith(color: AppTheme.warn)),
                  );
                },
              ),
            ),
          ),
          // Item tooltip and legend: plain widgets above the canvas, never
          // inside its gesture layer (floor_item_overlays.dart).
          FloorHoverTip(c: c),
          FloorLegend(c: c),
          // Above the canvas Listener as a sibling, never inside it: see
          // tutorial_panel.dart. Only its own box takes clicks.
          if (run != null)
            Positioned(
              left: 8,
              top: 8,
              child: TutorialPanel(
                  key: const Key('tutorial'),
                  runner: run,
                  c: c,
                  maxHeight: box.maxHeight - 16),
            ),
        ],
      );
    });
  }
}

/// The tutorial hint a palette kind answers to (null: none points at it).
ScenarioHintTarget? _kindHint(EntityKind k) => switch (k) {
      EntityKind.receivingDock => ScenarioHintTarget.receivingDock,
      EntityKind.shippingDock => ScenarioHintTarget.shippingDock,
      EntityKind.belt => ScenarioHintTarget.belt,
      EntityKind.arm => ScenarioHintTarget.arm,
      EntityKind.craneBay => ScenarioHintTarget.craneBay,
      _ => null,
    };

/// The tutorial hint a roster row answers to.
ScenarioHintTarget? _handlerHint(HandlerKind k) => switch (k) {
      HandlerKind.onFoot => ScenarioHintTarget.walker,
      HandlerKind.palletJack => ScenarioHintTarget.palletJack,
      HandlerKind.crane => ScenarioHintTarget.crane,
      _ => null,
    };

bool _isHinted(FactoryEditorController c, ScenarioHintTarget? t) =>
    t != null && c.hinted(t);

String _kindLabel(EntityKind k) => entityKindLabel(k);

/// An item as the pickers name it: loose vs packed spelt out
/// ([FactoryItem.pickerLabel]), and "· used here" when a machine on this
/// floor takes it as an input (§10 item 6), so the right one of
/// "Electronics" and "Electronics ×10" is the obvious pick.
String _itemChoiceLabel(FactoryEditorController c, String id) {
  final it = FactoryItems.byId(id);
  final name = it?.pickerLabel ?? id;
  return c.index.consumedItems.contains(id) ? '$name · used here' : name;
}

/// The items a picker lists: those used on this floor first (what the
/// player most likely wants), then the rest by picker group (goods, packs,
/// intermediates) so each group's heading appears once, each by id.
List<String> _pickerItems(FactoryEditorController c) {
  final used = c.index.consumedItems;
  final ids = FactoryItems.table.keys.toList()..sort();
  final rest = ids.where((i) => !used.contains(i)).toList()
    ..sort((a, b) {
      final g = productGroupOf(a).index.compareTo(productGroupOf(b).index);
      return g != 0 ? g : a.compareTo(b);
    });
  return [...ids.where(used.contains), ...rest];
}

/// The picker id of "Any item" (no item id contains a space or a star).
const String kAnyItemOption = '*any';

/// The heading of the items a machine on this floor takes.
const String kUsedHereGroup = 'USED ON THIS FLOOR';

String _itemGroupLabel(ProductGroup g) => switch (g) {
      ProductGroup.good => 'GOODS',
      ProductGroup.packed => 'PACKED FOR SHIPPING',
      ProductGroup.intermediate => 'INTERMEDIATES',
    };

/// Every item as a [SearchablePicker] option ([_pickerItems] order),
/// headed "Any item" when [any] (an arm, chest or shipping dock may take
/// anything; a receiving dock must name what it brings in).
List<PickerOption<String?>> _itemOptions(FactoryEditorController c,
    {required bool any}) {
  final used = c.index.consumedItems;
  return [
    if (any)
      const PickerOption<String?>(
          value: null, id: kAnyItemOption, label: 'Any item'),
    for (final id in _pickerItems(c))
      PickerOption<String?>(
          value: id,
          id: id,
          label: _itemChoiceLabel(c, id),
          group: used.contains(id)
              ? kUsedHereGroup
              : _itemGroupLabel(productGroupOf(id))),
  ];
}

/// [recipes] as picker options, grouped by station, each with its
/// "inputs → outputs · time" line so the search result says what it does.
List<PickerOption<String>> _recipeOptions(List<FactoryRecipe> recipes) {
  String side(List<ItemQty> qs) =>
      qs.map((q) => '${q.count} ${q.def?.label ?? q.item}').join(' + ');
  final sorted = [...recipes]..sort((a, b) {
      final g = a.station.index.compareTo(b.station.index);
      return g != 0 ? g : a.id.compareTo(b.id);
    });
  return [
    for (final r in sorted)
      PickerOption<String>(
          value: r.id,
          id: r.id,
          label: r.label,
          group: _stationLabel(r.station).toUpperCase(),
          note: '${side(r.inputs)} → ${side(r.outputs)} · ${r.seconds}s'),
  ];
}

String _stationLabel(StationKind s) =>
    s.name[0].toUpperCase() + s.name.substring(1);

String _fmtRate(double v) => v >= 10
    ? v.toStringAsFixed(1)
    : v >= 0.1
        ? v.toStringAsFixed(2)
        : v.toStringAsFixed(3);

class _TopBar extends StatelessWidget {
  const _TopBar(
      {required this.c,
      required this.title,
      required this.onSave,
      required this.treeOpen,
      required this.infoOpen,
      required this.onProductTree,
      required this.onRecipeInfo,
      this.onBack});
  final FactoryEditorController c;
  final String title;
  final VoidCallback? onSave;

  /// The product tree panel is open (its button shows pressed).
  final bool treeOpen;

  /// Null hides the button (no debugTools: the tree is debug-only).
  final VoidCallback? onProductTree;

  /// The Recipe info panel is open (its button shows pressed).
  final bool infoOpen;
  final VoidCallback onRecipeInfo;

  /// The host's close; null pops the route.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          color: AppTheme.panel,
          border: Border(bottom: BorderSide(color: AppTheme.accent, width: 2)),
        ),
        child: Row(
          children: [
            IconButton(
              key: const Key('factory-back'),
              icon: const Icon(Icons.arrow_back, color: AppTheme.text),
              onPressed: onBack ?? () => Navigator.of(context).maybePop(),
              tooltip: onBack == null ? 'Back' : 'Close floor',
            ),
            Flexible(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.title
                      .copyWith(color: AppTheme.accent, fontSize: 16)),
            ),
            const SizedBox(width: 16),
            // Speed is the driver's to set: hidden while the colony steps
            // the floor.
            if (c.drivesSim)
              for (final (s, icon, tip) in const [
                (0.0, Icons.pause, 'Pause'),
                (1.0, Icons.play_arrow, '1x'),
                (4.0, Icons.fast_forward, '4x'),
              ])
                IconButton(
                  key: Key('speed-${s.round()}'),
                  tooltip: tip,
                  onPressed: () => c.setSpeed(s),
                  icon: Icon(icon,
                      color:
                          c.speed == s ? AppTheme.accent : AppTheme.textDim),
                )
            else
              Text('LIVE · colony time',
                  key: const Key('colony-driven'),
                  style: AppTheme.dim.copyWith(color: AppTheme.accent2)),
            const SizedBox(width: 12),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final o in FactoryOverlay.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: HintPulse(
                        on: o == FactoryOverlay.bottleneck &&
                            c.hinted(ScenarioHintTarget.bottlenecks),
                        child: FilterChip(
                          key: Key('overlay-${o.name}'),
                          label: Text(switch (o) {
                            FactoryOverlay.power => 'Power',
                            FactoryOverlay.staffing => 'Staffing',
                            FactoryOverlay.bottleneck => 'Bottlenecks',
                            FactoryOverlay.traffic => 'Traffic',
                          }),
                          selected: c.overlays.contains(o),
                          onSelected: (_) => c.toggleOverlay(o),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            HintPulse(
              on: c.hinted(ScenarioHintTarget.recipeInfo),
              child: TextButton.icon(
                key: const Key('recipe-info-button'),
                onPressed: onRecipeInfo,
                icon: Icon(Icons.info_outline,
                    color: infoOpen ? AppTheme.accent : AppTheme.text),
                label: Text('Recipe info',
                    style: TextStyle(
                        color: infoOpen ? AppTheme.accent : AppTheme.text)),
              ),
            ),
            if (onProductTree case final open?)
              HintPulse(
                on: c.hinted(ScenarioHintTarget.productTree),
                child: TextButton.icon(
                  key: const Key('product-tree-button'),
                  onPressed: open,
                  icon: Icon(Icons.account_tree,
                      color: treeOpen ? AppTheme.accent : AppTheme.text),
                  label: Text('Product tree (debug)',
                      style: TextStyle(
                          color: treeOpen ? AppTheme.accent : AppTheme.text)),
                ),
              ),
            IconButton(
              key: const Key('undo'),
              tooltip: c.history.canUndo
                  ? 'Undo ${c.history.undoLabel!.toLowerCase()} (Ctrl+Z)'
                  : 'Nothing to undo',
              onPressed: c.history.canUndo ? c.undo : null,
              icon: Icon(Icons.undo,
                  color: c.history.canUndo ? AppTheme.text : AppTheme.textDim),
            ),
            IconButton(
              key: const Key('redo'),
              tooltip: c.history.canRedo
                  ? 'Redo ${c.history.redoLabel!.toLowerCase()} (Ctrl+Y)'
                  : 'Nothing to redo',
              onPressed: c.history.canRedo ? c.redo : null,
              icon: Icon(Icons.redo,
                  color: c.history.canRedo ? AppTheme.text : AppTheme.textDim),
            ),
            IconButton(
              key: const Key('fit-hall'),
              tooltip: 'Fit hall',
              onPressed: c.fitHall,
              icon: const Icon(Icons.fit_screen, color: AppTheme.text),
            ),
            if (onSave != null)
              TextButton.icon(
                key: const Key('save-blueprint'),
                onPressed: onSave,
                icon: const Icon(Icons.save_alt, color: AppTheme.accent2),
                label: const Text('Save as blueprint',
                    style: TextStyle(color: AppTheme.accent2)),
              ),
          ],
        ),
      ),
    );
  }
}

const TilePos _origin = TilePos(0, 0);

class _Palette extends StatelessWidget {
  const _Palette({required this.c});
  final FactoryEditorController c;

  Widget _entry(String label, IconData icon, bool on, VoidCallback tap,
          Key key, {bool hint = false}) =>
      HintPulse(
        on: hint,
        child: InkWell(
          key: key,
          onTap: tap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: on ? AppTheme.panelLight : null,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                  color: on ? AppTheme.accent : const Color(0x00000000)),
            ),
            child: Row(children: [
              Icon(icon, size: 16, color: on ? AppTheme.accent : AppTheme.textDim),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: AppTheme.body)),
            ]),
          ),
        ),
      );

  Widget _head(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Text(s, style: AppTheme.heading.copyWith(fontSize: 12)),
      );

  /// A floor kind the colony hasn't unlocked the kit for (a crane bay
  /// without cranes) is labelled; the sim's ghost check refuses it.
  Widget _kindEntry(EntityKind k, IconData icon) => _entry(
      c.unlocks.allowsPlacement(Placement(id: 0, kind: k, pos: _origin))
          ? _kindLabel(k)
          : '${_kindLabel(k)} (locked)',
      icon,
      c.tool == FactoryTool.place && c.kind == k,
      () => c.choose(k),
      Key('palette-${k.name}'),
      hint: _isHinted(c, _kindHint(k)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Container(
        color: AppTheme.panel,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            _head('TOOLS'),
            _entry('Select', Icons.near_me, c.tool == FactoryTool.select,
                () => c.setTool(FactoryTool.select), const Key('tool-select')),
            _entry('Delete', Icons.delete_outline,
                c.tool == FactoryTool.delete,
                () => c.setTool(FactoryTool.delete), const Key('tool-delete')),
            _entry('Clear piles', Icons.cleaning_services,
                c.tool == FactoryTool.clear,
                () => c.setTool(FactoryTool.clear), const Key('tool-clear')),
            _head('MACHINES'),
            for (final s in StationKind.values)
              _entry(
                  _stationLabel(s),
                  Icons.precision_manufacturing,
                  c.tool == FactoryTool.place &&
                      c.kind == EntityKind.machine &&
                      c.station == s,
                  () => c.choose(EntityKind.machine, st: s),
                  Key('palette-machine-${s.name}'),
                  hint: s == StationKind.assembler &&
                      c.hinted(ScenarioHintTarget.assembler)),
            if (c.tool == FactoryTool.place && c.kind == EntityKind.machine)
              _recipePicker(),
            _head('TRANSPORT'),
            _kindEntry(EntityKind.belt, Icons.double_arrow),
            if (c.tool == FactoryTool.place &&
                (c.kind == EntityKind.belt || c.kind == EntityKind.crossing))
              _runModes(),
            _kindEntry(EntityKind.arm, Icons.call_split),
            _kindEntry(EntityKind.chest, Icons.inventory_2_outlined),
            if (c.tool == FactoryTool.place && c.kind == EntityKind.arm)
              _itemPicker(),
            _kindEntry(EntityKind.crossing, Icons.drag_handle),
            _head('DOCKS'),
            _kindEntry(EntityKind.receivingDock, Icons.login),
            _kindEntry(EntityKind.shippingDock, Icons.logout),
            if (c.tool == FactoryTool.place &&
                (c.kind == EntityKind.receivingDock ||
                    c.kind == EntityKind.shippingDock ||
                    c.kind == EntityKind.chest))
              _itemPicker(),
            _head('FLOOR'),
            _kindEntry(EntityKind.aisle, Icons.view_stream_outlined),
            if (c.tool == FactoryTool.place && c.kind == EntityKind.aisle)
              _runModes(),
            _kindEntry(EntityKind.staging, Icons.crop_square),
            _kindEntry(EntityKind.craneBay, Icons.view_week_outlined),
            _kindEntry(EntityKind.rack, Icons.shelves),
            _kindEntry(EntityKind.chargingBay, Icons.ev_station),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 14, 10, 0),
              child: Text(
                  'R / Shift+R rotate · Del delete · Esc select\n'
                  'Hold X and sweep: delete under the cursor\n'
                  'Ctrl+Z undo · Ctrl+Y redo\n'
                  'Drag to lay belts, aisles, staging and crane bays.\n'
                  'M run shape (Straight / L / Free) · F flip the L ·\n'
                  'hold Shift for a straight run.\n'
                  'Drag a belt over a belt to re-point it (items stay).\n'
                  'A belt across an aisle is laid as a crossing; a\n'
                  'crossing laid on a belt replaces it.\n'
                  'Delete: drag a box; Shift also takes floor markings.\n'
                  'Middle-drag or drag empty floor to pan; wheel zooms.',
                  style: AppTheme.dim),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recipePicker() {
    final all = c.stationRecipes;
    if (all.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
        child: Text('No ${_stationLabel(c.station).toLowerCase()} recipes yet',
            key: const Key('palette-no-recipes'),
            style: AppTheme.dim.copyWith(color: AppTheme.warn)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 4),
      child: SearchablePicker<String>(
        key: const Key('palette-recipe'),
        title: '${_stationLabel(c.station)} recipe',
        selectedId: c.effectiveRecipe,
        options: _recipeOptions(all),
        onChanged: c.setRecipeChoice,
      ),
    );
  }

  Widget _itemPicker() {
    final ids = _pickerItems(c);
    final anyOk = c.kind != EntityKind.receivingDock;
    final value = c.itemChoice;
    final shown = value != null && ids.contains(value)
        ? value
        : (anyOk ? null : ids.first);
    // A receiving dock bringing in what no machine here takes: say so
    // while the player is still choosing (§10 item 6).
    final unused = c.kind == EntityKind.receivingDock &&
        shown != null &&
        !c.index.consumedItems.contains(shown);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SearchablePicker<String?>(
            key: const Key('palette-item'),
            title: '${_kindLabel(c.kind ?? EntityKind.chest)} item',
            selectedId: shown ?? kAnyItemOption,
            options: _itemOptions(c, any: anyOk),
            onChanged: c.setItemChoice,
          ),
          if (unused)
            Text('No machine here uses this yet',
                key: const Key('palette-item-unused'),
                style: AppTheme.dim.copyWith(color: AppTheme.warn)),
        ],
      ),
    );
  }

  /// Straight / L / Freeform for belt runs and aisles (§10 item 10), shown
  /// under the Belt, Crossing or Aisle entry while it is the tool. M cycles
  /// them from the keyboard, F flips an L, Shift forces Straight.
  Widget _runModes() {
    Widget chip(RunMode m, String label, String tip) => Tooltip(
          message: tip,
          child: ChoiceChip(
            key: Key('run-mode-${m.name}'),
            visualDensity: VisualDensity.compact,
            label: Text(label, style: const TextStyle(fontSize: 11)),
            selected: c.runMode == m,
            onSelected: (_) => c.setRunMode(m),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 4),
      child: Wrap(spacing: 4, runSpacing: 2, children: [
        chip(RunMode.straight, 'Straight', 'One axis-locked leg (M; hold '
            'Shift while dragging)'),
        chip(RunMode.lShape, c.lFlip ? 'L ↕' : 'L ↔',
            'One corner; F flips which leg comes first'),
        chip(RunMode.freeform, 'Free', 'Follows the cursor'),
      ]),
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.live]),
      builder: (context, _) => Container(
        color: AppTheme.panel,
        child: ListView(
          padding: const EdgeInsets.all(10),
          children: [
            PileInspector(c: c),
            _Inspector(c: c),
            const SizedBox(height: 14),
            _Roster(c: c),
            const SizedBox(height: 14),
            _Readout(c: c),
          ],
        ),
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final id = c.selectedId;
    final p = id == null ? null : c.index.byId(id);
    if (p == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('INSPECTOR', style: AppTheme.heading),
          SizedBox(height: 6),
          Text('Select something on the floor.', style: AppTheme.dim),
        ],
      );
    }
    final contents = c.sim.contentsOf(p.id);
    final keys = contents.keys.toList()..sort();
    final rid = p.recipe;
    final recipe = rid == null ? null : FactoryRecipes.byId(rid);
    final choices = recipe == null
        ? (FactoryRecipes.table.values.toList()
          ..sort((a, b) => a.id.compareTo(b.id)))
        : FactoryRecipes.forStation(recipe.station);
    return Column(
      key: const Key('inspector'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text('${_kindLabel(p.kind).toUpperCase()} #${p.id}',
                style: AppTheme.heading),
          ),
          if (!kSpannedKinds.contains(p.kind)) ...[
            IconButton(
              key: const Key('inspect-rotate-ccw'),
              tooltip: 'Rotate counter-clockwise (Shift+R)',
              onPressed: () => c.rotateSelected(ccw: true),
              icon: const Icon(Icons.rotate_left, color: AppTheme.text,
                  size: 18),
            ),
            IconButton(
              key: const Key('inspect-rotate'),
              tooltip: 'Rotate (R)',
              onPressed: c.rotateSelected,
              icon: const Icon(Icons.rotate_right, color: AppTheme.text,
                  size: 18),
            ),
          ],
          IconButton(
            key: const Key('inspect-delete'),
            tooltip: 'Delete (Del)',
            onPressed: c.removeSelected,
            icon: const Icon(Icons.delete_outline, color: AppTheme.danger,
                size: 18),
          ),
        ]),
        Text('at ${p.pos} facing ${p.dir.name}'
            '${p.item == null ? '' : ' · ${FactoryItems.byId(p.item!)?.pickerLabel ?? p.item}'}',
            style: AppTheme.dim),
        // A receiving dock whose goods nothing here consumes (§10 item 6):
        // the playtest's crate dock beside a bench that wanted loose parts.
        if (c.index.unusedDocks.any((d) => d.id == p.id))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Chip(
              key: const Key('dock-unused-warning'),
              visualDensity: VisualDensity.compact,
              backgroundColor: AppTheme.panelLight,
              side: const BorderSide(color: AppTheme.warn),
              avatar: const Icon(Icons.warning_amber,
                  size: 16, color: AppTheme.warn),
              label: Text('No machine on this floor uses '
                  '${FactoryItems.byId(p.item ?? '')?.label ?? p.item}',
                  style: AppTheme.dim.copyWith(color: AppTheme.warn)),
            ),
          ),
        if (p.kind == EntityKind.machine) ...[
          const SizedBox(height: 8),
          if (choices.isEmpty)
            const Text('No recipes registered', style: AppTheme.dim)
          else
            SearchablePicker<String>(
              key: const Key('inspect-recipe'),
              title: 'Recipe',
              hint: 'Choose recipe',
              selectedId: recipe == null ? null : rid,
              options: _recipeOptions(choices),
              onChanged: (v) => c.setMachineRecipe(p.id, v),
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            for (final m in MachineMode.values)
              ChoiceChip(
                key: Key('mode-${m.name}'),
                label: Text(c.unlocks.allowsMode(m) ? m.name : '${m.name} (locked)'),
                selected: p.crew == m,
                // A locked mode is greyed; the station keeps a mode it
                // already has (unlocks gate new purchases only).
                onSelected: c.unlocks.allowsMode(m) || p.crew == m
                    ? (_) => c.setMachineMode(p.id, m)
                    : null,
              ),
          ]),
          const SizedBox(height: 6),
          Text(
              'Status: ${c.sim.statusOf(p.id).name} · crew ${p.crew.workers}'
              '${p.crew.maintenance > 0 ? ' + ${p.crew.maintenance} tech' : ''}',
              key: const Key('inspect-status'),
              style: AppTheme.body),
          if (recipe != null)
            Text(
                '${recipe.inputs.map((q) => '${q.count} ${q.def?.label ?? q.item}').join(' + ')}'
                ' → ${recipe.outputs.map((q) => '${q.count} ${q.def?.label ?? q.item}').join(' + ')}'
                ' in ${recipe.seconds}s',
                style: AppTheme.dim),
        ],
        if (p.kind == EntityKind.arm) ...[
          const SizedBox(height: 8),
          const Text('Picks', style: AppTheme.body),
          _ArmFilter(c: c, arm: p),
        ],
        const SizedBox(height: 6),
        if (keys.isEmpty)
          const Text('Empty', style: AppTheme.dim)
        else
          for (final k in keys)
            Text('${FactoryItems.byId(k)?.label ?? k}: ${contents[k]}',
                style: AppTheme.mono),
      ],
    );
  }
}

/// An arm's pick filter: which item it swings (null = any).
class _ArmFilter extends StatelessWidget {
  const _ArmFilter({required this.c, required this.arm});
  final FactoryEditorController c;
  final Placement arm;

  @override
  Widget build(BuildContext context) {
    final cur = arm.item;
    return SearchablePicker<String?>(
      key: const Key('inspect-arm-item'),
      title: 'Arm picks',
      selectedId: cur ?? kAnyItemOption,
      options: _itemOptions(c, any: true),
      onChanged: (v) => c.setArmFilter(arm.id, v),
    );
  }
}

class _Roster extends StatelessWidget {
  const _Roster({required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final roster = c.sim.blueprint.roster;
    final busy = <HandlerKind, int>{};
    final charging = <HandlerKind, int>{};
    for (final h in c.sim.handlers) {
      if (h.state == HandlerState.charging) {
        charging[h.kind] = (charging[h.kind] ?? 0) + 1;
      } else if (h.state != HandlerState.idle) {
        busy[h.kind] = (busy[h.kind] ?? 0) + 1;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('HANDLERS', style: AppTheme.heading),
        const SizedBox(height: 4),
        for (final k in HandlerKind.values) _row(k, roster, busy, charging),
      ],
    );
  }

  /// One kind's row. A locked kind stays listed (so the player sees what
  /// research buys) but greyed; its + still asks the sim, whose refusal
  /// explains it, and letting go is always allowed.
  Widget _row(HandlerKind k, Map<HandlerKind, int> roster,
      Map<HandlerKind, int> busy, Map<HandlerKind, int> charging) {
    final locked = !c.unlocks.allowsHandler(k);
    final have = roster[k] ?? 0;
    final spec = kHandlerSpecs[k]!;
    final dim = locked ? AppTheme.textDim : AppTheme.text;
    final ch = charging[k] ?? 0;
    return Opacity(
      key: Key('roster-${k.name}'),
      opacity: locked ? 0.5 : 1,
      child: HintPulse(
        on: _isHinted(c, _handlerHint(k)),
        child: Row(children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                color: locked ? AppTheme.textDim : kHandlerColor[k],
                shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(locked ? '${spec.label} · locked' : spec.label,
                    key: Key('hire-${k.name}-label'),
                    style: AppTheme.body.copyWith(color: dim)),
                Text(
                    '${have * spec.operators} operators · '
                    '${busy[k] ?? 0} on a job'
                    '${ch > 0 ? ' · $ch charging' : ''}',
                    style: AppTheme.dim.copyWith(fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            key: Key('hire-${k.name}-minus'),
            visualDensity: VisualDensity.compact,
            onPressed: have > 0 ? () => c.hire(k, -1) : null,
            icon: const Icon(Icons.remove, size: 16),
            color: dim,
          ),
          SizedBox(
            width: 24,
            child: Text('$have',
                key: Key('hire-${k.name}-count'),
                textAlign: TextAlign.center,
                style: AppTheme.mono.copyWith(color: dim)),
          ),
          IconButton(
            key: Key('hire-${k.name}-plus'),
            visualDensity: VisualDensity.compact,
            onPressed: () => c.hire(k, 1),
            icon: Icon(locked ? Icons.lock_outline : Icons.add, size: 16),
            color: dim,
          ),
        ]),
      ),
    );
  }
}

/// What the layout costs to build and how big the hall is: the price of
/// every design choice, shown while the player makes them.
class _CostStrip extends StatelessWidget {
  const _CostStrip({required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.live]),
      builder: (context, _) {
        final FloorCapex k = c.capex;
        final hall = c.sim.blueprint.hall;
        String o(double v) => v.toStringAsFixed(v >= 10 ? 1 : 2);
        return Container(
          key: const Key('cost-strip'),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: AppTheme.panelLight,
          child: Row(children: [
            Text(
                'Hall ${hall.widthM.toStringAsFixed(0)} × '
                '${hall.depthM.toStringAsFixed(0)} m '
                '(${hall.areaM2.toStringAsFixed(0)} m²)',
                key: const Key('cost-hall'),
                style: AppTheme.mono),
            const SizedBox(width: 24),
            Expanded(
              child: Text(
                  'Build cost ${o(k.total)} ore  ·  hall ${o(k.hall)}  ·  '
                  'machines ${o(k.machines)}  ·  conveyors ${o(k.conveyors)}'
                  '  ·  storage ${o(k.storage)}  ·  vehicles ${o(k.vehicles)}',
                  key: const Key('cost-capex'),
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono),
            ),
          ]),
        );
      },
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final sim = c.sim;
    final ins = c.ratesIn.keys.toList()..sort();
    final outs = c.ratesOut.keys.toList()..sort();
    final pending = sim.pendingRequests;
    return Column(
      key: const Key('readout'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('THROUGHPUT', style: AppTheme.heading),
        const SizedBox(height: 4),
        Text('over the last ${c.windowSeconds.toStringAsFixed(0)} s of floor '
            'time',
            style: AppTheme.dim),
        const SizedBox(height: 4),
        const Text('In', style: AppTheme.body),
        if (ins.isEmpty) const Text('  —', style: AppTheme.dim),
        for (final k in ins)
          Text('  $k  ${_fmtRate(c.ratesIn[k]!)}/s', style: AppTheme.mono),
        const Text('Out', style: AppTheme.body),
        if (outs.isEmpty) const Text('  —', style: AppTheme.dim),
        for (final k in outs)
          Text('  $k  ${_fmtRate(c.ratesOut[k]!)}/s',
              key: Key('readout-out-$k'), style: AppTheme.mono),
        const SizedBox(height: 8),
        Text('Power  ${sim.powerDemandKw.toStringAsFixed(0)} kW',
            style: AppTheme.mono),
        Text('Jobs   ${sim.jobDemand.toStringAsFixed(1)}',
            style: AppTheme.mono),
        if (c.stuckPiles.isNotEmpty)
          Text('Stuck  ${c.stuckPiles.length} pile'
              '${c.stuckPiles.length == 1 ? '' : 's'} nothing can take',
              key: const Key('readout-stuck'),
              style: AppTheme.mono.copyWith(color: AppTheme.warn)),
        Text('Queue  $pending move request${pending == 1 ? '' : 's'}',
            key: const Key('readout-queue'),
            style: AppTheme.mono.copyWith(
                color: pending > 4 ? AppTheme.warn : AppTheme.text)),
        if (pending > 4)
          const Text('Long queue: hire more handlers or automate.',
              style: TextStyle(color: AppTheme.warn, fontSize: 11)),
        Text('Sim    ${sim.simSeconds.toStringAsFixed(0)} s · '
            '${sim.blueprint.hall.w}×${sim.blueprint.hall.h} tiles '
            '(${(sim.blueprint.hall.areaM2 / 1e4).toStringAsFixed(2)} ha)',
            style: AppTheme.dim),
      ],
    );
  }
}

