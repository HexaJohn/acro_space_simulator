// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Plain widgets over the factory canvas for items (docs/plans/
/// factory-floors.md §10 items 17 and 18).
///
/// All three are siblings ABOVE the canvas's gesture layer, never inside it
/// (an ancestor gesture widget would steal clicks; see tutorial_panel.dart):
///
/// * [FloorHoverTip]: a tooltip at the cursor listing what the tile under it
///   holds (name, count, load class). Ignores pointers entirely.
/// * [FloorLegend]: a collapsible list of every item colour on the floor.
/// * [PileInspector]: the Inspector's section for a selected floor pile, with
///   its Dispose button.
library;

import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'factory_editor_controller.dart';
import 'factory_floor_painter.dart' show itemColor;
import 'floor_item_info.dart';

/// The hover tooltip. Place it in the canvas `Stack` (it positions itself).
class FloorHoverTip extends StatelessWidget {
  const FloorHoverTip({super.key, required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ListenableBuilder(
          listenable: c.frame,
          builder: (context, _) {
            final h = c.hover;
            final tip = h == null ? null : tipAt(c.sim, c.index, h);
            if (h == null || tip == null || c.clearRect != null) {
              return const SizedBox.shrink();
            }
            final at = c.tileCenterLocal(h) + const Offset(16, 16);
            return Stack(children: [
              Positioned(left: at.dx, top: at.dy, child: _TipBox(tip: tip)),
            ]);
          },
        ),
      ),
    );
  }
}

class _TipBox extends StatelessWidget {
  const _TipBox({required this.tip});
  final FloorTip tip;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('floor-tip'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: AppTheme.panelBox(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tip.title, style: AppTheme.heading),
          if (tip.rows.isEmpty) const Text('empty', style: AppTheme.dim),
          for (final r in tip.rows)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 9, height: 9, color: itemColor(r.item)),
              const SizedBox(width: 5),
              Text(r.toString(), style: AppTheme.body),
            ]),
        ],
      ),
    );
  }
}

/// Collapsible legend of the item colours on the floor now. Place it in the
/// canvas `Stack`; it pins itself to the top-right corner.
class FloorLegend extends StatefulWidget {
  const FloorLegend({super.key, required this.c});
  final FactoryEditorController c;

  @override
  State<FloorLegend> createState() => _FloorLegendState();
}

class _FloorLegendState extends State<FloorLegend> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Positioned(
      right: 8,
      top: 8,
      child: ListenableBuilder(
        listenable: c.live,
        builder: (context, _) {
          final entries = _open ? legendOf(c.sim) : const <LegendEntry>[];
          return Container(
            key: const Key('floor-legend'),
            padding: const EdgeInsets.all(6),
            decoration: AppTheme.panelBox(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  key: const Key('floor-legend-toggle'),
                  onTap: () => setState(() => _open = !_open),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_open ? Icons.expand_less : Icons.expand_more,
                        size: 16, color: AppTheme.textDim),
                    const SizedBox(width: 2),
                    const Text('ITEMS', style: AppTheme.heading),
                  ]),
                ),
                if (_open && entries.isEmpty)
                  const Text('nothing on the floor', style: AppTheme.dim),
                for (final e in entries)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 10, color: e.color),
                    const SizedBox(width: 5),
                    Text('${itemAbbrev(e.item)}  ${e.name}  ×${e.count}',
                        style: AppTheme.body),
                  ]),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The Inspector section for a floor pile picked with Select: what it
/// holds, whether it is stuck, and a Dispose button.
class PileInspector extends StatelessWidget {
  const PileInspector({super.key, required this.c});
  final FactoryEditorController c;

  @override
  Widget build(BuildContext context) {
    final t = c.selectedPile;
    if (t == null) return const SizedBox.shrink();
    final tip = tipAt(c.sim, c.index, t);
    final stuck = c.stuckPiles.contains(t);
    return Column(
      key: const Key('pile-inspector'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('PILE (${t.x}, ${t.y})', style: AppTheme.heading),
        for (final r in tip?.rows ?? const <TipRow>[])
          Text('  ${r.toString()}', style: AppTheme.mono),
        if (stuck)
          const Text('Nothing can take this: add a chest, staging area or '
              'shipping dock with room.',
              style: TextStyle(color: AppTheme.warn, fontSize: 11)),
        const SizedBox(height: 4),
        OutlinedButton(
          key: const Key('pile-dispose'),
          onPressed: c.disposeSelectedPile,
          child: Text(c.sandbox ? 'Scrap pile' : 'Dispose (ship out)'),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}
