// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/parts/part_catalog.dart';
import 'app_theme.dart';
import 'craft/craft_catalog_pane.dart';
import 'craft/craft_editor_controller.dart';
import 'craft/craft_editor_state.dart';
import 'craft/craft_editor_viewport.dart';
import 'craft/craft_launch.dart';
import 'craft/craft_staging_pane.dart';
import 'craft/craft_stats_pane.dart';
import 'craft/craft_tree_pane.dart';

/// A place a craft can launch from, surfaced to the VAB so the player can build
/// then launch from a colony's pad/runway. [acceptsPlane] true = an airfield
/// (winged/jet craft); false = a spaceport (vertical rockets).
class LaunchSite {
  final String name;
  final bool acceptsPlane;

  /// Launch towers / pads at this site (its footprint tile count) — shown as
  /// pads across the bottom of the ascent view.
  final int pads;
  const LaunchSite(
      {required this.name, required this.acceptsPlane, this.pads = 1});
}

/// Craft assembly: pick parts from the [PartCatalog] and bolt them onto each
/// other's ATTACH NODES in a 3D view, watching the [CraftLaunch] bake turn the
/// design into a real vessel live (mass, Δv, thrust, crew, balance, staging).
///
/// When opened from a colony with [launchSites], a LAUNCH action lets the player
/// fly the finished design from a compatible pad/runway (gated by craft type:
/// winged/jet -> airfield, otherwise -> spaceport).
///
/// ## What this class is
///
/// A shell. It owns exactly three things: the [CraftEditorController] (built in
/// [State.initState], never in the constructor, because the constructor is
/// `const` and every existing call site depends on that), the two layouts, and
/// the routes — dialogs, sheets and the launch push. Every pixel inside it comes
/// from a pane or the viewport, and every mutation goes through the controller's
/// funnel, which is what makes undo total.
///
/// ## Layout
///
/// Wide (`> 720` logical px, the old threshold, unchanged):
/// `Row[ catalog | Column[toolbar, viewport, HUD] | inspector ]`, with the
/// launch bar pinned to the bottom of the inspector.
///
/// Narrow: `Column[ viewport, tool strip, tabbed sheet ]`, viewport first and
/// biggest. The old narrow split gave the parts list the top 55% and the design
/// the rest; a 3D editor cannot work that way, so the viewport is the subject
/// and the sheet collapses to a one-line bar the moment a part is picked up.
///
/// NEITHER layout scrolls as a page. Every pane is bounded and scrolls inside
/// itself — the invariant the old screen had and the one thing that makes the
/// viewport's height predictable enough to project pixels into.
class CraftAssemblyScreen extends StatefulWidget {
  /// World to launch from (defaults to Earth in the standalone VAB).
  final String? bodyId;

  /// Launch sites offered by the calling colony. Empty = standalone VAB (no
  /// launch action; design-only).
  final List<LaunchSite> launchSites;

  /// Colony site on the host body (degrees) — where the craft spawns to launch.
  final double latitude, longitude;

  const CraftAssemblyScreen({
    super.key,
    this.bodyId,
    this.launchSites = const [],
    this.latitude = 0,
    this.longitude = 0,
  });

  @override
  State<CraftAssemblyScreen> createState() => _CraftAssemblyScreenState();
}

/// The title-bar actions, as one enum so the narrow overflow menu and the wide
/// button row cannot drift apart.
enum _CraftAction { rename, open, save, clear }

class _CraftAssemblyScreenState extends State<CraftAssemblyScreen> {
  /// The wide/narrow threshold, in logical pixels.
  ///
  /// DELIBERATELY HIGHER than the 720 the old screen used, and this is the one
  /// number in the layout that is a judgement rather than a measurement. That
  /// screen put two LISTS side by side, and two lists share 720 px perfectly
  /// well. This one puts a 3D view between them: below roughly 950 px the three
  /// columns can only be fitted by starving one of them, and the two failures
  /// that produces are a viewport too small to aim in and a catalog so narrow
  /// that every part name wraps to four lines. Stacking the view over a tabbed
  /// sheet is simply better at that size, which is what the narrow layout is.
  static const double _wideBreakpointPx = 960;

  /// Hairline between panes. The same value the old screen used inline.
  static const Color _rule = Color(0xFF223247);

  /// Roll per press of the context sheet's rotate buttons — the viewport's `Q`
  /// and `E` step, so the touch path and the key path move a part by the same
  /// amount.
  static const double _rollStep = 15 * math.pi / 180;

  late final CraftEditorController _controller;

  /// Reaches the viewport's public state for `F`-equivalent framing from the
  /// toolbar. The viewport keeps its own camera, so the screen must not hold a
  /// copy of the pose.
  final GlobalKey<CraftEditorViewportState> _viewportKey =
      GlobalKey<CraftEditorViewportState>();

  /// Wide: STATS / TREE / STAGING. Narrow: PARTS / STATS / TREE / STAGING.
  /// Two indices rather than one, because the narrow sheet has a tab the
  /// inspector does not and folding them would make PARTS mean STATS on rotate.
  int _inspectorTab = 0;
  int _sheetTab = 0;

  /// Narrow only: the sheet is down to a one-line `Placing:` bar so the whole
  /// viewport is visible for the placing tap. Reset the moment nothing is held.
  bool _sheetCollapsed = false;

  /// Last revision an autosave was scheduled for, so a hover or a selection —
  /// which notify without changing the craft — cannot restart the debounce.
  int _autosavedRevision = 0;

  @override
  void initState() {
    super.initState();
    // In initState, NOT in the constructor: `CraftAssemblyScreen` is const and
    // is constructed as such by the menu, the city builder and two test suites.
    _controller = CraftEditorController(catalog: PartCatalog.standard());
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // The recovery copy, written on the way out. The debounced timer may not
    // have fired yet and the player is leaving; a craft must never be lost by
    // closing the screen that made it. Fire and forget — `autosave` swallows
    // its own failures on purpose (see its doc), so this cannot throw out of a
    // dispose.
    if (!_controller.design.isEmpty) unawaited(_controller.autosave());
    _controller.dispose();
    super.dispose();
  }

  /// The controller notifies for view state too (selection, held part,
  /// symmetry), so both branches here check what actually changed.
  ///
  /// Only a REVISION change is a change to the craft, and only that is worth an
  /// autosave — otherwise picking a part up would restart the debounce.
  void _onControllerChanged() {
    if (_controller.revision != _autosavedRevision) {
      _autosavedRevision = _controller.revision;
      _controller.scheduleAutosave();
    }
    // Nothing on the cursor is no longer a reason to keep the parts sheet
    // folded away — placing the part, or `Esc`, brings it straight back.
    if (_sheetCollapsed && _controller.held == null) {
      setState(() => _sheetCollapsed = false);
    }
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) => AppTheme.scaffold(
        context: context,
        title: 'CRAFT ASSEMBLY',
        actions: [
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _titleActions(context),
          ),
        ],
        body: LayoutBuilder(builder: (context, c) {
          if (c.maxWidth > _wideBreakpointPx) return _wide(c);
          return ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _narrow(),
          );
        }),
      );

  /// Rename / Open / Save / Clear, as four buttons or as one overflow menu.
  ///
  /// The title bar is a fixed-height [Row] with the screen name in it, so the
  /// actions are the only part of it that can yield. Four 48 px targets beside
  /// a 14-character title do not fit a phone, and a title bar that overflows is
  /// a rendering error rather than a squeeze — hence the menu below the same
  /// breakpoint the body uses.
  Widget _titleActions(BuildContext context) {
    final empty = _controller.design.isEmpty;
    if (MediaQuery.sizeOf(context).width <= _wideBreakpointPx) {
      return PopupMenuButton<_CraftAction>(
        key: const ValueKey('craft-actions'),
        icon: const Icon(Icons.more_vert, color: AppTheme.text),
        color: AppTheme.panel,
        tooltip: 'Craft actions',
        onSelected: (action) => switch (action) {
          _CraftAction.rename => _promptRename(),
          _CraftAction.open => _promptOpen(),
          _CraftAction.save => _promptSave(),
          // Undoable, which it never was: the old screen's Clear was the one
          // action that could throw away an hour.
          _CraftAction.clear => Future.sync(_controller.clear),
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
              value: _CraftAction.rename,
              child: Text('Rename', style: AppTheme.body)),
          const PopupMenuItem(
              value: _CraftAction.open,
              child: Text('Open a saved craft', style: AppTheme.body)),
          PopupMenuItem(
              value: _CraftAction.save,
              enabled: !empty,
              child: const Text('Save', style: AppTheme.body)),
          PopupMenuItem(
            value: _CraftAction.clear,
            enabled: !empty,
            child: const Text('Clear',
                style: TextStyle(color: AppTheme.danger, fontSize: 13)),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('craft-rename'),
          icon:
              const Icon(Icons.drive_file_rename_outline, color: AppTheme.text),
          tooltip: 'Rename "${_controller.design.name}"',
          onPressed: _promptRename,
        ),
        IconButton(
          key: const ValueKey('craft-open'),
          icon: const Icon(Icons.folder_open, color: AppTheme.text),
          tooltip: 'Open a saved craft',
          onPressed: _promptOpen,
        ),
        IconButton(
          key: const ValueKey('craft-save'),
          icon: const Icon(Icons.save, color: AppTheme.text),
          tooltip: 'Save this craft',
          onPressed: empty ? null : _promptSave,
        ),
        if (!empty)
          IconButton(
            key: const ValueKey('craft-clear'),
            icon: const Icon(Icons.delete_sweep, color: AppTheme.danger),
            tooltip: 'Clear',
            onPressed: _controller.clear,
          ),
      ],
    );
  }

  /// `Row[ catalog | Column[toolbar, viewport, HUD] | inspector ]`.
  ///
  /// Both side columns scale with the window between a floor and a ceiling, and
  /// both floors are measurements rather than taste.
  ///
  /// The INSPECTOR's floor is set by `CraftStatsPane`'s STAGING header, which
  /// lays a heading and a running total side by side with no flex on either: a
  /// column narrower than that pair's natural width is a rendering error, not
  /// an ellipsis.
  ///
  /// The CATALOG's floor is set by a part row. Squeeze it and the name, the
  /// mass and the icon do not ellipsize — a `ListTile` wraps them — so a 150 px
  /// catalog turns three parts into a page of ragged text with the rest of the
  /// roster below the fold.
  ///
  /// Everything left over is the viewport, which is the subject of this screen.
  Widget _wide(BoxConstraints c) {
    final inspectorW = (c.maxWidth * 0.28).clamp(352.0, 380.0);
    final catalogW = (c.maxWidth * 0.22).clamp(240.0, 300.0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
            width: catalogW, child: CraftCatalogPane(controller: _controller)),
        const VerticalDivider(width: 1, color: _rule),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _toolbar(),
              const Divider(height: 1, color: _rule),
              Expanded(child: _viewport()),
              const Divider(height: 1, color: _rule),
              _hudStrip(),
            ],
          ),
        ),
        const VerticalDivider(width: 1, color: _rule),
        SizedBox(width: inspectorW, child: _inspector()),
      ],
    );
  }

  /// `Column[ viewport, tool strip, sheet ]`.
  ///
  /// The viewport takes six parts to the sheet's four, and the whole sheet folds
  /// to one line while a part is held — so placing a part on a phone is tap the
  /// row, tap the node, with the craft fully visible for the second tap.
  Widget _narrow() {
    final held = _controller.held;
    // `_onControllerChanged` clears the flag as soon as nothing is held; the
    // second half of this is belt and braces for the frame in between.
    final collapsed = _sheetCollapsed && held != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: collapsed ? 1 : 6,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _viewport(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(child: _hudStrip()),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: _rule),
        _toolbar(),
        const Divider(height: 1, color: _rule),
        if (collapsed)
          _placingBar(held.def.name)
        else
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _tabs(const ['PARTS', 'STATS', 'TREE', 'STAGING'], _sheetTab,
                    (i) => setState(() => _sheetTab = i)),
                const Divider(height: 1, color: _rule),
                Expanded(
                  child: IndexedStack(
                    index: _sheetTab,
                    sizing: StackFit.expand,
                    children: [
                      CraftCatalogPane(
                        controller: _controller,
                        onPartHeld: (_) => setState(() => _sheetCollapsed = true),
                      ),
                      CraftStatsPane(controller: _controller),
                      CraftTreePane(controller: _controller),
                      CraftStagingPane(controller: _controller),
                    ],
                  ),
                ),
                _launchBar(),
              ],
            ),
          ),
      ],
    );
  }

  Widget _viewport() => CraftEditorViewport(
        key: _viewportKey,
        controller: _controller,
        // A modal sheet is a route, and the viewport must not push routes — so
        // it picks the part and hands the id up.
        onLongPressPart: (instanceId, _) => _showPartSheet(instanceId),
        // The chords are only claimed because these are wired; see the
        // viewport's `onSave`/`onOpen` doc.
        onSave: _promptSave,
        onOpen: _promptOpen,
      );

  Widget _inspector() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tabs(const ['STATS', 'TREE', 'STAGING'], _inspectorTab,
              (i) => setState(() => _inspectorTab = i)),
          const Divider(height: 1, color: _rule),
          Expanded(
            child: IndexedStack(
              index: _inspectorTab,
              sizing: StackFit.expand,
              children: [
                CraftStatsPane(controller: _controller),
                CraftTreePane(controller: _controller),
                CraftStagingPane(controller: _controller),
              ],
            ),
          ),
          _launchBar(),
        ],
      );

  /// The LAUNCH bar, or nothing at all.
  ///
  /// Present only when a colony offered pads AND there is a craft to fly, which
  /// is exactly the old screen's condition. `CraftLaunchBar` owns everything
  /// past that: the type gate, the multi-site sheet and the push into the sim.
  Widget _launchBar() => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          if (widget.launchSites.isEmpty) return const SizedBox.shrink();
          final vessel = CraftLaunch.preview(_controller.design);
          if (vessel == null) return const SizedBox.shrink();
          return CraftLaunchBar(
            design: _controller.design,
            vessel: vessel,
            launchSites: widget.launchSites,
            bodyId: widget.bodyId,
            latitude: widget.latitude,
            longitude: widget.longitude,
            loosePartCount: _controller.looseParts.length,
            // Flying a craft must not be a way to lose it: the recovery copy is
            // written before the route is pushed, not on the way back.
            onLaunched: () => unawaited(_controller.autosave()),
          );
        },
      );

  // ---------------- toolbar ----------------

  /// Every editor action that is not a part, on one horizontally scrolling row.
  ///
  /// One toolbar serves both layouts on purpose. Spec 4.5: no touch flow may
  /// depend on a key, so undo, symmetry, the overlay toggles and framing all
  /// have to be reachable by thumb — and having the desktop use the same strip
  /// means a control can never exist on only one of them.
  Widget _toolbar() => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final counts = _expressibleSymmetryCounts();
          final tool = _controller.tool;
          return SizedBox(
            height: 44,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  _toolButton(
                    id: 'editor-undo',
                    icon: Icons.undo,
                    tooltip: _controller.undoLabel == null
                        ? 'Nothing to undo'
                        : 'Undo ${_controller.undoLabel}',
                    active: false,
                    onPressed: _controller.canUndo ? _controller.undo : null,
                  ),
                  _toolButton(
                    id: 'editor-redo',
                    icon: Icons.redo,
                    tooltip: _controller.redoLabel == null
                        ? 'Nothing to redo'
                        : 'Redo ${_controller.redoLabel}',
                    active: false,
                    onPressed: _controller.canRedo ? _controller.redo : null,
                  ),
                  _separator(),
                  _toolButton(
                    id: 'tool-select',
                    icon: Icons.near_me,
                    tooltip: 'Select parts',
                    active: tool == EditorTool.select,
                    onPressed: () => _controller.setTool(EditorTool.select),
                  ),
                  _toolButton(
                    id: 'tool-stage',
                    icon: Icons.layers,
                    tooltip: 'Staging tool — show S# badges on the craft',
                    active: tool == EditorTool.stage,
                    onPressed: () => _controller.setTool(tool == EditorTool.stage
                        ? EditorTool.select
                        : EditorTool.stage),
                  ),
                  _separator(),
                  for (final n in const [1, 2, 4])
                    _symmetryChip(n, expressible: counts.contains(n)),
                  _mirrorChip(expressible: counts.contains(2)),
                  _separator(),
                  _toolButton(
                    id: 'toggle-nodes',
                    icon: Icons.scatter_plot,
                    tooltip: 'Attach-node markers (G)',
                    active: _controller.showNodes,
                    onPressed: () =>
                        _controller.setShowNodes(!_controller.showNodes),
                  ),
                  _toolButton(
                    id: 'toggle-balance',
                    icon: Icons.balance,
                    tooltip: 'Centre of mass and thrust (C)',
                    active: _controller.showBalance,
                    onPressed: () =>
                        _controller.setShowBalance(!_controller.showBalance),
                  ),
                  _toolButton(
                    id: 'frame-craft',
                    icon: Icons.center_focus_strong,
                    tooltip: 'Frame the craft (F)',
                    active: false,
                    onPressed: () => _viewportKey.currentState?.frameCraft(),
                  ),
                  _separator(),
                  _toolButton(
                    id: 'delete-selection',
                    icon: Icons.delete_outline,
                    tooltip: 'Delete the selection and its symmetry group',
                    active: false,
                    onPressed: _controller.selectedId == null
                        ? null
                        : () => _controller.deleteSelection(),
                  ),
                ],
              ),
            ),
          );
        },
      );

  Widget _separator() => Container(
        width: 1,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        color: _rule,
      );

  Widget _toolButton({
    required String id,
    required IconData icon,
    required String tooltip,
    required bool active,
    VoidCallback? onPressed,
  }) =>
      IconButton(
        key: ValueKey(id),
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        color: active ? AppTheme.accent : AppTheme.text,
        disabledColor: AppTheme.textDim.withValues(alpha: 0.4),
        onPressed: onPressed,
      );

  /// The `1` / `2` / `4` chips.
  ///
  /// Disabled — not silently ignored — when no open node on this craft sits on a
  /// ring that can hold that many copies. `SymmetryChoice.seatsOn` would collapse
  /// the request to one part, and a chip that reads "×4" while placing one is a
  /// chip that teaches the player to distrust the toolbar.
  Widget _symmetryChip(int count, {required bool expressible}) {
    final selected =
        !_controller.symmetry.mirror && _controller.symmetry.count == count;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ChoiceChip(
        key: ValueKey('symmetry-$count'),
        label: Text('×$count',
            style: TextStyle(
                fontSize: 11,
                color: selected
                    ? AppTheme.bg
                    : expressible
                        ? AppTheme.text
                        : AppTheme.textDim)),
        selected: selected,
        selectedColor: AppTheme.accent,
        backgroundColor: AppTheme.panelLight,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        tooltip: expressible
            ? 'One copy on each of $count ring seats'
            : 'No attach ring on this craft can hold $count evenly spaced copies',
        onSelected:
            expressible ? (_) => _controller.setSymmetryCount(count) : null,
      ),
    );
  }

  /// Mirror is an ALTERNATIVE to a radial count, never a layer on one: turning
  /// it off returns to a single copy, so the strip always reads as what the next
  /// click will do.
  Widget _mirrorChip({required bool expressible}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: ChoiceChip(
          key: const ValueKey('symmetry-mirror'),
          label: Text('M',
              style: TextStyle(
                  fontSize: 11,
                  color: _controller.symmetry.mirror
                      ? AppTheme.bg
                      : expressible
                          ? AppTheme.text
                          : AppTheme.textDim)),
          selected: _controller.symmetry.mirror,
          selectedColor: AppTheme.accent,
          backgroundColor: AppTheme.panelLight,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          tooltip: 'Mirror the placement across the craft centreline (M)',
          onSelected: expressible
              ? (_) => _controller.setMirror(!_controller.symmetry.mirror)
              : null,
        ),
      );

  /// Which symmetry counts anything currently on the craft could actually take.
  ///
  /// Derived from the whole craft rather than from the hovered node, because the
  /// hover lives in the viewport and changes on every pointer move — a toolbar
  /// that re-enabled its chips per mouse move would flicker, and wiring the
  /// hover up here would rebuild every pane to do it.
  Set<int> _expressibleSymmetryCounts() {
    final out = <int>{1};
    for (final target in _controller.openTargets) {
      out.addAll(_controller.symmetryCountsAt(target));
    }
    return out;
  }

  // ---------------- HUD strip ----------------

  /// One line under (wide) or over (narrow) the viewport: why the last action
  /// did not happen, or what the next click will do.
  ///
  /// The refusal wins whenever there is one. A tap that quietly does nothing is
  /// the failure mode an enumerated-target editor has to design against — every
  /// node is a 22 px marker, and the difference between "wrong node" and "that
  /// mate is illegal" is invisible without a sentence.
  Widget _hudStrip() => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final blocked = _controller.blocked;
          final held = _controller.held;
          final bits = <String>[];
          if (held != null) {
            bits.add('Placing: ${held.def.name} · Esc to stop');
          } else if (_controller.selectedId != null) {
            final part = _controller.design.partById(_controller.selectedId!);
            final group = _controller.selection.length;
            if (part != null) {
              bits.add('${part.def.name}${group > 1 ? ' ×$group' : ''} · '
                  'S${part.stage}');
            }
          }
          if (!_controller.symmetry.isSingle) {
            bits.add(_controller.symmetry.mirror
                ? 'mirror'
                : '×${_controller.symmetry.count}');
          }
          if (_controller.hasLooseParts) {
            bits.add('${_controller.looseParts.length + 1} pieces');
          }
          if (bits.isEmpty) {
            bits.add('Drag to orbit · hold a part in the catalog · F to frame');
          }
          return Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            color: AppTheme.panel,
            child: Text(
              blocked ?? bits.join('  ·  '),
              style: AppTheme.dim.copyWith(
                  color: blocked != null ? AppTheme.danger : AppTheme.textDim),
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      );

  /// The collapsed narrow sheet: one line saying what is on the cursor, and a
  /// tap target to bring the parts list back.
  Widget _placingBar(String partName) => Material(
        color: AppTheme.panel,
        child: InkWell(
          key: const ValueKey('placing-bar'),
          onTap: () => setState(() => _sheetCollapsed = false),
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Icon(Icons.adjust, size: 16, color: AppTheme.accent2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Placing: $partName — tap a node',
                      style: AppTheme.body, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: AppTheme.textDim,
                  tooltip: 'Stop placing',
                  onPressed: _controller.clearHeld,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      );

  // ---------------- tabs ----------------

  Widget _tabs(List<String> labels, int index, ValueChanged<int> onTap) =>
      SizedBox(
        height: 36,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: InkWell(
                  key: ValueKey('tab-${labels[i].toLowerCase()}'),
                  onTap: () => onTap(i),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                            color: i == index
                                ? AppTheme.accent
                                : Colors.transparent,
                            width: 2),
                      ),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.bold,
                        color:
                            i == index ? AppTheme.accent : AppTheme.textDim,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  // ---------------- routes ----------------

  /// The touch context sheet (spec 4.5): everything `Q`/`E`, the stage stepper
  /// and `Delete` do, without a keyboard.
  Future<void> _showPartSheet(String instanceId) async {
    _controller.select(instanceId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      builder: (sheetContext) => SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final part = _controller.design.partById(instanceId);
            if (part == null) return const SizedBox.shrink();
            final group = _controller.selection.length;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      Icon(CraftCatalogPane.categoryIcon(part.def.category),
                          size: 18, color: AppTheme.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                            '${part.def.name}${group > 1 ? '  ×$group' : ''}',
                            style: AppTheme.heading,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
                _sheetStepper(
                  label: 'Roll',
                  value: '±15°',
                  onDown: () {
                    _controller.roll(-_rollStep);
                    _controller.endGesture();
                  },
                  onUp: () {
                    _controller.roll(_rollStep);
                    _controller.endGesture();
                  },
                ),
                _sheetStepper(
                  label: 'Stage',
                  value: 'S${part.stage}',
                  onDown:
                      part.stage == 0 ? null : () => _controller.nudgeStage(-1),
                  onUp: () => _controller.nudgeStage(1),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.link_off,
                      size: 18, color: AppTheme.textDim),
                  title: const Text('Detach', style: AppTheme.body),
                  enabled: part.attachment != null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _controller.detach(instanceId);
                  },
                ),
                if (group > 1)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.remove_circle_outline,
                        size: 18, color: AppTheme.danger),
                    title: const Text('Delete this one',
                        style: TextStyle(color: AppTheme.danger, fontSize: 13)),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _controller.deletePart(instanceId, wholeGroup: false);
                    },
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.delete_outline,
                      size: 18, color: AppTheme.danger),
                  title: Text(group > 1 ? 'Delete all ×$group' : 'Delete',
                      style: const TextStyle(
                          color: AppTheme.danger, fontSize: 13)),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _controller.deletePart(instanceId);
                  },
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sheetStepper({
    required String label,
    required String value,
    VoidCallback? onDown,
    VoidCallback? onUp,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppTheme.body)),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              color: AppTheme.text,
              onPressed: onDown,
            ),
            SizedBox(
              width: 44,
              child: Text(value,
                  textAlign: TextAlign.center,
                  style: AppTheme.mono.copyWith(color: AppTheme.warn)),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline, size: 20),
              color: AppTheme.text,
              onPressed: onUp,
            ),
          ],
        ),
      );

  Future<void> _promptRename() async {
    final field = TextEditingController(text: _controller.design.name);
    final name = await _promptText(
      title: 'Craft name',
      field: field,
      confirm: 'Rename',
    );
    field.dispose();
    if (name == null) return;
    _controller.rename(name);
    // Renames coalesce into one undo step; this one is finished.
    _controller.endGesture();
  }

  Future<void> _promptSave() async {
    final field = TextEditingController(text: _controller.design.name);
    final slot = await _promptText(
      title: 'Save craft as',
      field: field,
      confirm: 'Save',
      hint: 'A name you will find it under',
    );
    field.dispose();
    if (slot == null || !mounted) return;
    final ok = await _controller.save(slot);
    if (!mounted) return;
    _toast(ok
        ? 'Saved "${slot.trim()}".'
        : _controller.blocked ?? 'Could not save that craft.');
  }

  Future<String?> _promptText({
    required String title,
    required TextEditingController field,
    required String confirm,
    String? hint,
  }) =>
      showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppTheme.panel,
          title: Text(title, style: AppTheme.heading),
          content: TextField(
            controller: field,
            autofocus: true,
            style: AppTheme.body,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: AppTheme.dim,
              enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: _rule)),
              focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppTheme.accent)),
            ),
            onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel', style: AppTheme.dim),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(field.text),
              child: Text(confirm,
                  style: const TextStyle(color: AppTheme.accent2)),
            ),
          ],
        ),
      );

  /// The open sheet: named saves, newest first, plus the recovery copy.
  ///
  /// The autosave is offered here rather than restored on entry. Opening the VAB
  /// and finding yesterday's half-built craft already loaded — over a `const`
  /// screen two other features push — is a surprise; a row that says what it is
  /// and waits to be asked is not.
  Future<void> _promptOpen() async {
    final slots = [...await _controller.savedSlots()];
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheetState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('OPEN A CRAFT', style: AppTheme.heading),
              ),
              if (slots.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text('No saved crafts yet.', style: AppTheme.dim),
                ),
              for (final s in slots)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.rocket_launch,
                      size: 18, color: AppTheme.accent2),
                  title: Text(s.slot, style: AppTheme.body),
                  subtitle: Text('${s.craftName}  ·  ${s.partCount} parts',
                      style: AppTheme.dim),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: AppTheme.danger),
                    tooltip: 'Delete this save',
                    onPressed: () async {
                      await _controller.deleteSlot(s.slot);
                      setSheetState(() => slots.remove(s));
                    },
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_open(s.slot));
                  },
                ),
              const Divider(height: 1, color: _rule),
              ListTile(
                dense: true,
                leading: const Icon(Icons.restore, size: 18, color: AppTheme.warn),
                title: const Text('Restore the autosaved craft',
                    style: AppTheme.body),
                subtitle: const Text('The copy the editor keeps for you',
                    style: AppTheme.dim),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_restore());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(String slot) async {
    final ok = await _controller.load(slot);
    if (!mounted) return;
    if (!ok) _toast(_controller.blocked ?? 'Could not open "$slot".');
  }

  Future<void> _restore() async {
    final ok = await _controller.restoreAutosave();
    if (!mounted) return;
    _toast(ok
        ? 'Restored the autosaved craft.'
        : _controller.blocked ?? 'There is no autosaved craft.');
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: AppTheme.body),
          backgroundColor: AppTheme.panelLight,
          duration: const Duration(seconds: 3),
        ),
      );
}
