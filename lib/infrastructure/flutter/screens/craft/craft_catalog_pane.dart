// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import '../../../../domain/parts/part_def.dart';
import '../app_theme.dart';
import 'craft_editor_controller.dart';

/// The parts catalog: a category filter over the top and the roster below.
///
/// ## What a row does
///
/// Tapping a row PICKS THE PART UP — it goes on the cursor and the next click
/// in the 3D view seats it on whichever attach node is under the pointer. That
/// is the editor's whole interaction and every flow starts here.
///
/// Long-pressing a row (or long-pressing its `+`) QUICK-STACKS instead: the
/// part is bolted straight onto the lowest free compatible stack node with no
/// aiming at all. That is what the old assembly screen's `+` did, and it is
/// kept because a player who just wants a rocket should never have to hit a
/// 22 px marker to get one — the aiming is what buys radial mounts and
/// symmetry, and it should be optional until they want those.
///
/// Dragging a row sideways into the 3D view is the same pickup followed by a
/// place: the row anchors its drag to the POINTER, so the offset the viewport
/// is handed on drop is the cursor's own position and the drop commits the node
/// the cursor is over. Anything else silently aims somewhere else.
///
/// The pane never touches [CraftDesign]: it calls [CraftEditorController.hold]
/// and [CraftEditorController.quickStack], so a quick-stack is an undo step
/// like any other and a refusal comes back as a sentence rather than an
/// exception out of a button callback.
class CraftCatalogPane extends StatefulWidget {
  const CraftCatalogPane({
    super.key,
    required this.controller,
    this.initialCategory = PartCategory.commandPod,
    this.onPartHeld,
  });

  final CraftEditorController controller;

  /// Which chip is selected on first build. Command pods first, because an
  /// empty craft needs a root and every other category would be a dead end.
  final PartCategory initialCategory;

  /// Fired after a part is picked up. The narrow layout collapses its parts
  /// sheet on this so the viewport is fully visible for the placing tap — two
  /// taps to place a part instead of two taps and a scroll.
  final ValueChanged<PartDef>? onPartHeld;

  /// Display name for a category chip.
  static String categoryLabel(PartCategory c) => switch (c) {
        PartCategory.commandPod => 'Command',
        PartCategory.fuelTank => 'Fuel',
        PartCategory.rocketEngine => 'Rocket',
        PartCategory.jetEngine => 'Jet',
        PartCategory.intake => 'Intake',
        PartCategory.wing => 'Wing',
        PartCategory.controlSurface => 'Control',
        PartCategory.structural => 'Struct',
        PartCategory.decoupler => 'Decoupler',
        PartCategory.landingGear => 'Gear',
        PartCategory.parachute => 'Chute',
        PartCategory.science => 'Science',
        PartCategory.rcsThruster => 'RCS',
        PartCategory.heatShield => 'Heat',
      };

  /// The glyph a part of this category wears, here and in the tree and staging
  /// panes — one table so a part looks the same everywhere it is listed.
  static IconData categoryIcon(PartCategory c) => switch (c) {
        PartCategory.commandPod => Icons.airline_seat_recline_normal,
        PartCategory.fuelTank => Icons.local_gas_station,
        PartCategory.rocketEngine => Icons.local_fire_department,
        PartCategory.jetEngine => Icons.air,
        PartCategory.intake => Icons.input,
        PartCategory.wing => Icons.flight,
        PartCategory.controlSurface => Icons.tune,
        PartCategory.structural => Icons.view_in_ar,
        PartCategory.decoupler => Icons.unfold_more,
        PartCategory.landingGear => Icons.airline_seat_legroom_extra,
        PartCategory.parachute => Icons.paragliding,
        PartCategory.science => Icons.science,
        PartCategory.rcsThruster => Icons.control_camera,
        PartCategory.heatShield => Icons.shield,
      };

  /// The one-line spec under a part's name: mass first, then whichever
  /// capabilities it actually carries.
  static String partSummary(PartDef def) {
    final bits = <String>['${(def.dryMass).toStringAsFixed(0)} kg'];
    if (def.rocketEngine != null) {
      bits.add(
          '${(def.rocketEngine!.maxThrustVacuum / 1000).toStringAsFixed(0)} kN');
    }
    if (def.jetEngine != null) {
      bits.add(
          '${(def.jetEngine!.maxStaticThrust / 1000).toStringAsFixed(0)} kN jet');
    }
    if (def.crewCapacity > 0) bits.add('${def.crewCapacity} crew');
    if (def.resources.isNotEmpty) {
      final fuel = def.resources.fold(0.0, (s, r) => s + r.capacity);
      bits.add('${fuel.toStringAsFixed(0)} fuel');
    }
    if (def.wing != null) {
      bits.add('wing ${def.wing!.area.toStringAsFixed(0)} m²');
    }
    return bits.join('  ·  ');
  }

  @override
  State<CraftCatalogPane> createState() => _CraftCatalogPaneState();
}

class _CraftCatalogPaneState extends State<CraftCatalogPane> {
  late PartCategory _filter = widget.initialCategory;

  CraftEditorController get _c => widget.controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _c,
        builder: (context, _) => _pane(),
      );

  Widget _pane() {
    final cats = PartCategory.values
        .where((c) => _c.catalog.inCategory(c).isNotEmpty)
        .toList();
    final parts = _c.catalog.inCategory(_filter).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final cat in cats)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(CraftCatalogPane.categoryLabel(cat),
                          style: TextStyle(
                              fontSize: 11,
                              color:
                                  _filter == cat ? AppTheme.bg : AppTheme.text)),
                      selected: _filter == cat,
                      selectedColor: AppTheme.accent,
                      backgroundColor: AppTheme.panelLight,
                      onSelected: (_) => setState(() => _filter = cat),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // The roster FILLS the rest of the pane and scrolls inside it: this pane
        // lives in a bounded Column in both layouts, so an outer page scroll
        // would be the thing that pushes the viewport off the screen.
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: parts.length,
            itemBuilder: (_, i) => _catalogRow(parts[i]),
          ),
        ),
      ],
    );
  }

  Widget _catalogRow(PartDef def) {
    final held = _c.held?.def.id == def.id;
    final row = Card(
      color: held ? AppTheme.panelLight : AppTheme.panel,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(
            color: held ? AppTheme.accent2 : Colors.transparent, width: 1),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(CraftCatalogPane.categoryIcon(def.category),
            color: held ? AppTheme.accent2 : AppTheme.accent),
        title: Text(def.name, style: AppTheme.body),
        subtitle: Text(CraftCatalogPane.partSummary(def), style: AppTheme.dim),
        onTap: () => _hold(def),
        onLongPress: () => _c.quickStack(def),
        // The tap and the long press are the SAME two actions the row itself
        // offers, so the button is a bigger target for them rather than a third
        // behaviour to learn.
        trailing: GestureDetector(
          onLongPress: () => _c.quickStack(def),
          child: IconButton(
            icon: const Icon(Icons.add_circle, color: AppTheme.accent2),
            tooltip: 'Hold to place · long-press to bolt on the end',
            onPressed: () => _hold(def),
          ),
        ),
      ),
    );
    // Desktop nicety: drag a row into the viewport and drop it on a node. The
    // affinity keeps a vertical drag scrolling the roster, so the gesture is
    // additive rather than a tax on browsing.
    return Draggable<PartDef>(
      data: def,
      affinity: Axis.horizontal,
      // THE DROP HAS TO PICK UNDER THE CURSOR. `DragTargetDetails.offset` is
      // `globalPosition - dragStartPoint`, and the default child anchor makes
      // `dragStartPoint` wherever inside this row the player grabbed it — a row
      // is the full width of the pane, so that is up to ~280 px. The viewport
      // would then run its pick that far from the pointer, land outside both
      // the grab radius and the world cap, and place nothing at all. Anchoring
      // to the pointer makes the term zero, so the drop resolves to exactly the
      // node a tap on that pixel would.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        // The chip hangs down and to the right of the cursor: with a pointer
        // anchor its top-left IS the cursor, and a label sitting on the marker
        // being aimed at would hide the commitment display the drop depends on.
        child: Transform.translate(
          offset: const Offset(14, 10),
          child: Opacity(
            opacity: 0.85,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: AppTheme.panelBox(border: AppTheme.accent2),
              child: Text(def.name, style: AppTheme.body),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      onDragStarted: () => _hold(def),
      child: row,
    );
  }

  void _hold(PartDef def) {
    _c.hold(def);
    // Only announce a pickup that actually took: `hold` refuses a def this
    // editor's catalog cannot resolve, and collapsing the sheet for a part that
    // was never picked up would hide the sentence explaining why.
    if (_c.held?.def.id == def.id) widget.onPartHeld?.call(def);
  }
}
