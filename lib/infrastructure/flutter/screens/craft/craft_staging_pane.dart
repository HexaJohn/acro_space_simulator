// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import '../../../../domain/craft/craft_balance.dart';
import '../../../../domain/parts/part_def.dart';
import '../app_theme.dart';
import 'craft_catalog_pane.dart';
import 'craft_editor_controller.dart';
import 'craft_stats_pane.dart';

/// The staging list: one card per staging group, drag-reorderable, plus the two
/// ways to fix a craft's staging without dragging anything.
///
/// ## What changed from the old assembly screen
///
/// The reorderable list is the same widget with the same touch gesture and the
/// same `if (to > from) to -= 1` drop-slot correction — but it is pointed at
/// STAGING GROUPS instead of at individual parts. The old screen gave every part
/// its own stage, which made "reorder the list" and "reorder the staging" the
/// same operation by accident; here a group holds a tank, its engine and the
/// four quads bolted to the hull, and moving it moves all of them.
///
/// AUTO STAGE exists because the domain's default is deliberately conservative:
/// `attachPart` puts a part in its parent's group, so a whole stack lands in
/// group 0 and `Vessel.deltaVCapacity()` — which sums propellant over the active
/// group only — then reports a craft that cannot possibly fly the mission.
///
/// ## Which end fires
///
/// Groups are listed ASCENDING, so group 0 (the payload end, nearest the root)
/// is at the top and the group that lights on the pad is at the BOTTOM. That
/// matches both the physical stack and the flight model, where
/// `Vessel.activeStage` is `stages.last` and `separateStage()` drops the last.
class CraftStagingPane extends StatelessWidget {
  const CraftStagingPane({super.key, required this.controller});

  final CraftEditorController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _pane(),
      );

  Widget _pane() {
    final design = controller.design;
    final order = design.stages;
    // Once for the whole list: every card wants its own group's number and the
    // budget sweep walks every part per stage.
    final budgets = {
      for (final b in CraftStatsPane.budgets(design)) b.stage: b,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        _selectionStrip(),
        const Divider(height: 1, color: Color(0xFF223247)),
        // The list FILLS the pane and scrolls inside it; the screen around it
        // never scrolls, in either layout.
        Expanded(
          child: design.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Add parts to begin.',
                        textAlign: TextAlign.center, style: AppTheme.dim),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: order.length,
                  // `onReorderItem` hands back an index the framework has
                  // ALREADY shifted down for the removed item;
                  // `moveStageGroup` takes the raw drop SLOT and owns that
                  // correction itself, so that every caller cannot get it
                  // subtly different. Undo the framework's adjustment here
                  // rather than teach the controller a second convention.
                  onReorderItem: (from, to) =>
                      controller.moveStageGroup(from, to >= from ? to + 1 : to),
                  itemBuilder: (_, i) => _stageCard(order, i, budgets),
                ),
        ),
      ],
    );
  }

  /// AUTO STAGE takes the width it can get and `Renumber` takes what it needs:
  /// the pane is a tab in a phone-width sheet as well as a 300 px inspector
  /// column, and a fixed-width button row overflows the narrow one.
  Widget _toolbar() => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: controller.design.isEmpty
                    ? null
                    : () => controller.autoStage(),
                icon: const Icon(Icons.auto_awesome_motion, size: 16),
                label: const Text('AUTO STAGE', overflow: TextOverflow.ellipsis),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  foregroundColor: AppTheme.bg,
                  disabledBackgroundColor: AppTheme.panelLight,
                  textStyle: const TextStyle(fontSize: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: controller.design.isEmpty
                  ? null
                  : () => controller.renumberStages(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.text,
                side: const BorderSide(color: Color(0xFF223247)),
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('Renumber'),
            ),
          ],
        ),
      );

  /// The `Stage −/+` stepper on whatever is selected — the fallback for anyone
  /// who finds drag-reorder fiddly, and the only staging control that works
  /// under a thumb. Staging moves the whole symmetry group by default, which is
  /// the difference between one action and sixteen on a craft with four quads
  /// and four legs.
  Widget _selectionStrip() {
    final id = controller.selectedId;
    final part = id == null ? null : controller.design.partById(id);
    if (part == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(10, 2, 10, 8),
        child: Text('Groups fire from the bottom of this list up. Select a part '
            'to move it between them.', style: AppTheme.dim),
      );
    }
    final count = controller.selection.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: AppTheme.panelBox(),
      child: Row(
        children: [
          Icon(CraftCatalogPane.categoryIcon(part.def.category),
              size: 16, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${part.def.name}${count > 1 ? '  ×$count' : ''}',
                style: AppTheme.body, overflow: TextOverflow.ellipsis),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 18),
            color: AppTheme.text,
            tooltip: 'Move toward the payload',
            onPressed: part.stage == 0 ? null : () => controller.nudgeStage(-1),
          ),
          Text('S${part.stage}',
              style: AppTheme.mono.copyWith(color: AppTheme.warn)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 18),
            color: AppTheme.text,
            tooltip: 'Move toward the pad',
            onPressed: () => controller.nudgeStage(1),
          ),
        ],
      ),
    );
  }

  Widget _stageCard(List<int> order, int i, Map<int, StageBudget> budgets) {
    final stage = order[i];
    final design = controller.design;
    final groups = _groupsIn(stage);
    final mass = design.parts
        .where((p) => p.stage == stage)
        .fold(0.0, (s, p) => s + CraftBalance.partMass(p.def));
    final budget = budgets[stage];
    final firesFirst = i == order.length - 1;

    return Card(
      key: ValueKey('stage-$stage'),
      color: AppTheme.panelLight,
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('S$stage',
                    style: AppTheme.mono
                        .copyWith(color: AppTheme.warn, fontSize: 14)),
                const SizedBox(width: 10),
                // The badge is flexible for the same reason the readout is:
                // this card is a tab in a phone-width sheet as well as an
                // inspector column, and two fixed-width icon buttons plus an
                // inflexible badge give the row a minimum width the narrow one
                // cannot meet. 3:2 keeps the mass and delta-v readable.
                Expanded(
                  flex: 3,
                  child: Text(
                    '${(mass / 1000).toStringAsFixed(2)} t'
                    '${budget == null ? '' : '  ·  ${budget.deltaV.toStringAsFixed(0)} m/s'}',
                    style: AppTheme.dim,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (firesFirst)
                  const Flexible(
                    flex: 2,
                    child: Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Text('FIRES FIRST',
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppTheme.accent2,
                              fontSize: 10,
                              letterSpacing: 1)),
                    ),
                  ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 16),
                  color: AppTheme.textDim,
                  tooltip: 'Later in the flight',
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      i == 0 ? null : () => controller.moveStageGroup(i, i - 1),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 16),
                  color: AppTheme.textDim,
                  tooltip: 'Earlier in the flight',
                  visualDensity: VisualDensity.compact,
                  // The drop SLOT one place further down is `i + 2`; the
                  // controller folds it back to an index.
                  onPressed: i == order.length - 1
                      ? null
                      : () => controller.moveStageGroup(i, i + 2),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (groups.isEmpty)
              const Text('Empty group.', style: AppTheme.dim)
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final g in groups) _groupChip(g)],
              ),
          ],
        ),
      ),
    );
  }

  Widget _groupChip(_PartGroup g) {
    final selected = controller.selection.contains(g.anchorId);
    return InkWell(
      onTap: () => controller.select(g.anchorId),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: selected ? AppTheme.accent : const Color(0xFF223247)),
        ),
        child: Row(
          // A part name is as long as the artist made it and a chip lives in a
          // 300 px sheet: the name yields, never the count.
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CraftCatalogPane.categoryIcon(g.def.category),
                size: 13, color: selected ? AppTheme.accent : AppTheme.textDim),
            const SizedBox(width: 6),
            Flexible(
              child: Text(g.def.name,
                  style: AppTheme.dim.copyWith(color: AppTheme.text),
                  overflow: TextOverflow.ellipsis),
            ),
            if (g.count > 1) ...[
              const SizedBox(width: 5),
              Text('×${g.count}',
                  style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
            ],
          ],
        ),
      ),
    );
  }

  /// The distinct part groups sitting in [stage], symmetry siblings collapsed to
  /// one entry. `symmetryGroupOf` already requires siblings to share a stage, so
  /// a group can never straddle two cards.
  List<_PartGroup> _groupsIn(int stage) {
    final seen = <String>{};
    final out = <_PartGroup>[];
    for (final p in controller.design.parts) {
      if (p.stage != stage) continue;
      if (seen.contains(p.instanceId)) continue;
      final group = controller.symmetryGroupOf(p.instanceId);
      final ids = group.isEmpty ? {p.instanceId} : group;
      seen.addAll(ids);
      out.add(_PartGroup(def: p.def, count: ids.length, anchorId: p.instanceId));
    }
    return out;
  }
}

/// One catalog part and how many copies of it this staging group holds.
class _PartGroup {
  final PartDef def;
  final int count;

  /// The member the chip selects — selecting any sibling selects them all.
  final String anchorId;

  const _PartGroup(
      {required this.def, required this.count, required this.anchorId});
}
