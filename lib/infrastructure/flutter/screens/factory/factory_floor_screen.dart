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
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../domain/colony/city/factory/factory_capex.dart';
import '../../../../domain/colony/city/factory/factory_colony_port.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/factory_unlocks.dart';
import '../../../../domain/colony/city/factory/floor_blueprint.dart';
import '../app_theme.dart';
import 'factory_editor_controller.dart';
import 'factory_floor_painter.dart';

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
  });

  final FactorySim sim;

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

  FactoryColonyPort get _port =>
      widget.port ?? (_sandbox ??= InfiniteColonyPort());

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

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  /// A new sim or port means a new floor: the controller (camera, selection,
  /// rate window, heat map) and the static-layer cache (keyed only by
  /// layoutRev, which two sims can share) both belong to the old one.
  /// New unlocks do NOT: a colony parent may build a fresh [FactoryUnlocks]
  /// on every rebuild, so they are swapped into the live controller.
  @override
  void didUpdateWidget(FactoryFloorScreen old) {
    super.didUpdateWidget(old);
    if (identical(old.sim, widget.sim) &&
        identical(old.port, widget.port) &&
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
          onKeyEvent: (_, e) => controller.handleKey(e)
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
          child: Column(
            children: [
              _TopBar(
                  c: controller,
                  title: widget.title,
                  onSave: widget.onSaveBlueprint == null
                      ? null
                      : () => widget.onSaveBlueprint!(
                          widget.sim.blueprint.copy())),
              _CostStrip(c: controller),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                        width: kPaletteWidth, child: _Palette(c: controller)),
                    Expanded(child: _canvas()),
                    SizedBox(
                        width: kSidePanelWidth,
                        child: _SidePanel(c: controller)),
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
    return LayoutBuilder(builder: (context, box) {
      c.setViewSize(box.biggest);
      return Stack(
        fit: StackFit.expand,
        children: [
          Listener(
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
        ],
      );
    });
  }
}

String _kindLabel(EntityKind k) => switch (k) {
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

String _stationLabel(StationKind s) =>
    s.name[0].toUpperCase() + s.name.substring(1);

String _fmtRate(double v) => v >= 10
    ? v.toStringAsFixed(1)
    : v >= 0.1
        ? v.toStringAsFixed(2)
        : v.toStringAsFixed(3);

class _TopBar extends StatelessWidget {
  const _TopBar({required this.c, required this.title, required this.onSave});
  final FactoryEditorController c;
  final String title;
  final VoidCallback? onSave;

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
              icon: const Icon(Icons.arrow_back, color: AppTheme.text),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Back',
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
                ]),
              ),
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
          Key key) =>
      InkWell(
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
      Key('palette-${k.name}'));

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
            _head('MACHINES'),
            for (final s in StationKind.values)
              _entry(
                  _stationLabel(s),
                  Icons.precision_manufacturing,
                  c.tool == FactoryTool.place &&
                      c.kind == EntityKind.machine &&
                      c.station == s,
                  () => c.choose(EntityKind.machine, st: s),
                  Key('palette-machine-${s.name}')),
            if (c.tool == FactoryTool.place && c.kind == EntityKind.machine)
              _recipePicker(),
            _head('TRANSPORT'),
            _kindEntry(EntityKind.belt, Icons.double_arrow),
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
            _kindEntry(EntityKind.staging, Icons.crop_square),
            _kindEntry(EntityKind.craneBay, Icons.view_week_outlined),
            _kindEntry(EntityKind.rack, Icons.shelves),
            _kindEntry(EntityKind.chargingBay, Icons.ev_station),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 14, 10, 0),
              child: Text(
                  'R rotate · Del delete · Esc select\n'
                  'Drag to lay belts, aisles, staging and crane bays.\n'
                  'A belt across an aisle is laid as a crossing; a\n'
                  'crossing laid on a belt replaces it.\n'
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
      child: DropdownButton<String>(
        key: const Key('palette-recipe'),
        isExpanded: true,
        dropdownColor: AppTheme.panelLight,
        value: c.effectiveRecipe,
        style: AppTheme.body,
        items: [
          for (final r in all)
            DropdownMenuItem(value: r.id, child: Text(r.label)),
        ],
        onChanged: c.setRecipeChoice,
      ),
    );
  }

  Widget _itemPicker() {
    final ids = FactoryItems.table.keys.toList()..sort();
    final anyOk = c.kind != EntityKind.receivingDock;
    final value = c.itemChoice;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 4),
      child: DropdownButton<String?>(
        key: const Key('palette-item'),
        isExpanded: true,
        dropdownColor: AppTheme.panelLight,
        value: value != null && ids.contains(value)
            ? value
            : (anyOk ? null : ids.first),
        style: AppTheme.body,
        items: [
          if (anyOk)
            const DropdownMenuItem<String?>(value: null, child: Text('Any item')),
          for (final id in ids)
            DropdownMenuItem<String?>(
                value: id, child: Text(FactoryItems.byId(id)!.label)),
        ],
        onChanged: c.setItemChoice,
      ),
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
          if (!kSpannedKinds.contains(p.kind))
            IconButton(
              key: const Key('inspect-rotate'),
              tooltip: 'Rotate (R)',
              onPressed: c.rotateSelected,
              icon: const Icon(Icons.rotate_right, color: AppTheme.text,
                  size: 18),
            ),
          IconButton(
            key: const Key('inspect-delete'),
            tooltip: 'Delete (Del)',
            onPressed: c.removeSelected,
            icon: const Icon(Icons.delete_outline, color: AppTheme.danger,
                size: 18),
          ),
        ]),
        Text('at ${p.pos} facing ${p.dir.name}'
            '${p.item == null ? '' : ' · ${FactoryItems.byId(p.item!)?.label ?? p.item}'}',
            style: AppTheme.dim),
        if (p.kind == EntityKind.machine) ...[
          const SizedBox(height: 8),
          if (choices.isEmpty)
            const Text('No recipes registered', style: AppTheme.dim)
          else
            DropdownButton<String>(
              key: const Key('inspect-recipe'),
              isExpanded: true,
              dropdownColor: AppTheme.panelLight,
              style: AppTheme.body,
              value: recipe == null ? null : rid,
              hint: const Text('Choose recipe', style: AppTheme.dim),
              items: [
                for (final r in choices)
                  DropdownMenuItem(value: r.id, child: Text(r.label)),
              ],
              onChanged: (v) {
                if (v != null) c.setMachineRecipe(p.id, v);
              },
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
    final ids = FactoryItems.table.keys.toList()..sort();
    final cur = arm.item;
    return DropdownButton<String?>(
      key: const Key('inspect-arm-item'),
      isExpanded: true,
      dropdownColor: AppTheme.panelLight,
      style: AppTheme.body,
      value: cur != null && ids.contains(cur) ? cur : null,
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Any item')),
        for (final id in ids)
          DropdownMenuItem<String?>(
              value: id, child: Text(FactoryItems.byId(id)!.label)),
      ],
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

