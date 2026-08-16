// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/material.dart';

import '../../../../domain/craft/attach_targets.dart';
import '../../../../domain/parts/attach_node.dart';
import '../../../../domain/parts/part_def.dart';
import '../app_theme.dart';
import 'craft_catalog_pane.dart';
import 'craft_editor_controller.dart';

/// The craft as plain rows: the attach tree on top, and underneath it every
/// open attach node — or, while a part is being moved, every seat that part
/// could move to.
///
/// ## The NODES list is the accessibility floor, not a debug view
///
/// Tapping a node row seats the held part on that node, with the current
/// symmetry, through exactly the same [CraftEditorController.attachAt] call the
/// 3D viewport makes. **The entire craft is therefore buildable from this pane
/// with the 3D picker completely broken** — which is what makes the editor
/// usable with a screen reader, with a trackpad on a small laptop, and on the
/// day a projection sign flips.
///
/// It is also the standing answer to the picker's one real weakness: projected
/// markers are occlusion-blind, so on a finished vehicle four ring nodes 90°
/// apart can land within a few pixels of one another from an axial view. Every
/// one of them is an unambiguous row here.
///
/// ## Why rows are pairings, not nodes
///
/// A row is one legal `(target node, held part's own node)` pair, because that
/// pair is what the mate needs and a decoupler has two nodes that are not
/// interchangeable. When a target offers only one pairing the row hides the
/// distinction; when it offers several they are separate rows, which is the
/// list-shaped equivalent of the viewport's `W`/`S` cycle.
///
/// ## Move is re-mate, and this is where it lives
///
/// There is no free placement in this editor to drag a part to, so "move" is
/// expressed as choosing a different compatible seat:
/// [CraftEditorController.remate] re-solves the joint, and the domain's mate
/// carries the part AND everything bolted to it rigidly, so a half-built stack
/// survives being re-parented. Without it, a part on the wrong node can only be
/// deleted and rebuilt, and its whole subtree goes with it.
///
/// The offer set is [CraftEditorController.pairingsForMove], which is
/// two-sided: the mover's own subtree and the stack nodes its children already
/// hold are dropped, so every row here is a mate the domain agreed to in
/// advance. It is still only agreed to for the frame it was built in — a
/// refusal from [CraftEditorController.remate] lands in
/// [CraftEditorController.blocked] and is shown by [_blockedBanner] with the
/// offer left open, because a tap that quietly does nothing is the one failure
/// this pane cannot afford.
///
/// A LIST rather than a drag for the same reason the NODES section is one:
/// re-seating a part is exactly what an occlusion-blind 3D picker is worst at,
/// and a craft that can be built from rows has to be repairable from them too.
class CraftTreePane extends StatefulWidget {
  const CraftTreePane({super.key, required this.controller});

  final CraftEditorController controller;

  @override
  State<CraftTreePane> createState() => _CraftTreePaneState();
}

class _CraftTreePaneState extends State<CraftTreePane> {
  /// The part whose move offer is open, or null. VIEW state: it survives no
  /// undo, records nothing about the craft, and is dropped the moment it stops
  /// meaning anything (see [_onControllerChanged]).
  String? _movingId;

  CraftEditorController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(CraftTreePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      controller.addListener(_onControllerChanged);
      _movingId = null;
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// Close the move offer when it can no longer be completed.
  ///
  /// Two ways out: the part left the craft (an undo, a delete from anywhere
  /// else), or a part was picked up in the catalog — placing and moving are
  /// alternatives, and a list that offered both would make the next tap
  /// ambiguous.
  void _onControllerChanged() {
    final id = _movingId;
    if (id == null) return;
    if (controller.held == null && controller.design.contains(id)) return;
    setState(() => _movingId = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _pane(),
      );

  Widget _pane() {
    final design = controller.design;
    final tree = _tree();
    final movingId = _movingId;
    final moving = movingId == null ? null : design.partById(movingId);
    // One ListView for both sections: the pane lives in a bounded box in both
    // layouts and must scroll inside itself, and two nested scrollers would
    // make the node list unreachable on a phone.
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _sectionHeader('PARTS', '${design.partCount}'),
        if (tree.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Text('Nothing placed yet — hold a command pod and place it '
                'as the craft root.', style: AppTheme.dim),
          )
        else
          for (final row in tree) _partRow(row),
        const SizedBox(height: 10),
        const Divider(height: 1, color: Color(0xFF223247)),
        if (moving != null)
          ..._moveSection(moving)
        else
          ..._nodesSection(),
      ],
    );
  }

  // ---------------- parts ----------------

  Widget _sectionHeader(String title, String trailing) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Row(
          children: [
            Text(title, style: AppTheme.heading),
            const Spacer(),
            Text(trailing, style: AppTheme.mono.copyWith(color: AppTheme.textDim)),
          ],
        ),
      );

  Widget _partRow(_TreeRow row) {
    final part = row.part;
    final selected = controller.selection.contains(part.instanceId);
    final moving = part.instanceId == _movingId;
    final mate = part.attachment;
    final loose = mate == null && part.instanceId != controller.design.rootId;
    final where = mate == null
        ? (loose ? 'loose — attached to nothing' : 'root')
        : '${mate.parentNode} ← ${mate.childNode}';

    // `tileColor` rather than a wrapping ColoredBox: a ListTile paints its
    // background on the nearest Material ancestor, so a box around it hides the
    // tile's own background and its ink splashes — which the framework asserts
    // about in debug.
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      tileColor: selected ? AppTheme.panelLight : null,
      contentPadding: EdgeInsets.only(left: 12 + row.depth * 14.0, right: 4),
      leading: Icon(
          moving
              ? Icons.drive_file_move_outline
              : CraftCatalogPane.categoryIcon(part.def.category),
          size: 18,
          color: selected ? AppTheme.accent : AppTheme.textDim),
      title: Row(
        children: [
          Flexible(
            child: Text(part.def.name,
                style: AppTheme.body, overflow: TextOverflow.ellipsis),
          ),
          if (row.count > 1) ...[
            const SizedBox(width: 6),
            Text('×${row.count}',
                style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
          ],
        ],
      ),
      subtitle: Text(
          moving ? 'moving — choose a seat below' : 'S${part.stage}  ·  $where',
          style: loose
              ? AppTheme.dim.copyWith(color: AppTheme.danger)
              : AppTheme.dim,
          overflow: TextOverflow.ellipsis),
      onTap: () => controller.select(part.instanceId),
      trailing: _partMenu(row),
    );
  }

  Widget _partMenu(_TreeRow row) {
    final id = row.part.instanceId;
    final detachable = row.part.attachment != null;
    return PopupMenuButton<_PartAction>(
      key: ValueKey('part-menu-$id'),
      icon: const Icon(Icons.more_vert, size: 18, color: AppTheme.textDim),
      color: AppTheme.panel,
      tooltip: 'Part actions',
      onSelected: (action) => switch (action) {
        _PartAction.move => _beginMove(id),
        _PartAction.detach => controller.detach(id),
        _PartAction.deleteOne => controller.deletePart(id, wholeGroup: false),
        _PartAction.deleteGroup => controller.deletePart(id),
      },
      itemBuilder: (_) => [
        // Always offered, never greyed: a part with nowhere to go is worth a
        // sentence saying so, and greying the row leaves the player guessing
        // whether the editor can move parts at all.
        const PopupMenuItem(
          value: _PartAction.move,
          child: Text('Move to...', style: AppTheme.body),
        ),
        PopupMenuItem(
          value: _PartAction.detach,
          enabled: detachable,
          child: Text('Detach',
              style: AppTheme.body.copyWith(
                  color: detachable ? AppTheme.text : AppTheme.textDim)),
        ),
        if (row.count > 1)
          PopupMenuItem(
            value: _PartAction.deleteOne,
            child: Text('Delete this one',
                style: AppTheme.body.copyWith(color: AppTheme.danger)),
          ),
        PopupMenuItem(
          value: _PartAction.deleteGroup,
          child: Text(row.count > 1 ? 'Delete all ×${row.count}' : 'Delete',
              style: AppTheme.body.copyWith(color: AppTheme.danger)),
        ),
      ],
    );
  }

  /// The attach tree flattened depth-first, symmetry siblings collapsed to one
  /// row each.
  ///
  /// Children of EVERY member of a collapsed group are still walked, so folding
  /// four RCS quads into one row can never hide something bolted to quads two
  /// through four. Loose branches follow the root's tree rather than being
  /// dropped: a part attached to nothing is exactly what the player needs to
  /// find, and it is what gates LAUNCH.
  List<_TreeRow> _tree() {
    final design = controller.design;
    final seen = <String>{};
    final out = <_TreeRow>[];

    void walk(PlacedPart p, int depth) {
      if (seen.contains(p.instanceId)) return;
      final group = controller.symmetryGroupOf(p.instanceId);
      final ids = group.isEmpty ? <String>{p.instanceId} : group;
      seen.addAll(ids);
      out.add(_TreeRow(part: p, depth: depth, count: ids.length));
      for (final id in ids) {
        for (final child in design.childrenOf(id)) {
          walk(child, depth + 1);
        }
      }
    }

    final root = design.root;
    if (root != null) walk(root, 0);
    for (final p in design.roots) {
      walk(p, 0);
    }
    // Anything the forest walk missed — a part whose parent was removed under a
    // hand-edited save would otherwise be invisible in the only list that can
    // delete it.
    for (final p in design.parts) {
      walk(p, 0);
    }
    return out;
  }

  // ---------------- moving ----------------

  /// Open the move offer for [instanceId].
  ///
  /// The part is selected as well, so the viewport outlines the thing that is
  /// about to travel — including its symmetry siblings, which are what the
  /// player sees as one object.
  void _beginMove(String instanceId) {
    if (!controller.design.contains(instanceId)) return;
    controller.select(instanceId);
    setState(() => _movingId = instanceId);
  }

  /// Every seat [moving] can be re-mated to, as plain rows.
  ///
  /// Replaces the NODES section rather than sitting beside it: while a move is
  /// open, a node row that placed a part instead would be the same tap meaning
  /// two different things.
  List<Widget> _moveSection(PlacedPart moving) {
    final offers = controller.pairingsForMove(moving.instanceId);
    // How many of the moving part's own nodes each target will take — the same
    // rule the placement rows use, so a decoupler's two ends stay distinct.
    final options = <(String, String), int>{};
    for (final p in offers) {
      final key = (p.target.ownerInstanceId, p.target.nodeName);
      options[key] = (options[key] ?? 0) + 1;
    }

    return [
      _sectionHeader('MOVE', '${offers.length}'),
      _hint(offers.isEmpty
          ? 'Nothing else on this craft can take ${moving.def.name}. Its nodes '
              'are the wrong kind or the wrong size class for every other open '
              'seat.'
          : 'Tap the seat ${moving.def.name} moves to. Everything bolted to it '
              'travels with it.'),
      _blockedBanner(),
      ListTile(
        key: const ValueKey('move-cancel'),
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.only(left: 12, right: 8),
        leading: const Icon(Icons.close, size: 18, color: AppTheme.textDim),
        title: const Text('Leave it where it is', style: AppTheme.body),
        onTap: () => setState(() => _movingId = null),
      ),
      for (final p in offers)
        _moveRow(moving.instanceId, p,
            showChildNode:
                (options[(p.target.ownerInstanceId, p.target.nodeName)] ?? 1) >
                    1),
    ];
  }

  Widget _moveRow(String instanceId, TargetPairing pairing,
      {required bool showChildNode}) {
    final target = pairing.target;
    final owner = controller.design.partById(target.ownerInstanceId);
    return ListTile(
      key: ValueKey('move-to-${target.ownerInstanceId}-${target.nodeName}'
          '-${pairing.childNodeName}'),
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.only(left: 12, right: 8),
      leading: Icon(_kindIcon(target.kind), size: 18, color: AppTheme.accent),
      title: Text(
          '${owner?.def.name ?? target.ownerInstanceId} › ${target.nodeName}',
          style: AppTheme.body, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${target.kind.name} ${target.size.toStringAsFixed(2)} m'
          '${showChildNode ? '  ←  ${pairing.childNodeName}' : ''}',
          style: AppTheme.dim),
      trailing: const Icon(Icons.drive_file_move_outline,
          size: 18, color: AppTheme.accent),
      onTap: () => _commitMove(instanceId, pairing),
    );
  }

  /// Re-seat, and close the offer only if the domain took it.
  ///
  /// A refusal leaves the offer open on purpose: the reason lands in
  /// [CraftEditorController.blocked], [_blockedBanner] shows it at the top of
  /// this list, and the alternatives are still under it. Closing the list on a
  /// failure would put the sentence somewhere the player has already navigated
  /// away from.
  void _commitMove(String instanceId, TargetPairing pairing) {
    if (controller.remate(instanceId, pairing)) {
      setState(() => _movingId = null);
    }
  }

  // ---------------- nodes ----------------

  List<Widget> _nodesSection() {
    final held = controller.held;
    final design = controller.design;

    if (held != null && design.isEmpty) {
      return [
        _sectionHeader('NODES', '0'),
        _hint('An empty craft has no nodes. Place ${held.def.name} as the root '
            'and its own nodes appear here.'),
        _blockedBanner(),
        ListTile(
          dense: true,
          leading: const Icon(Icons.adjust, size: 18, color: AppTheme.accent2),
          title: Text('Place ${held.def.name} as the craft root',
              style: AppTheme.body),
          subtitle: const Text('at the craft origin, on the pad',
              style: AppTheme.dim),
          trailing: const Icon(Icons.add, size: 18, color: AppTheme.accent2),
          onTap: () => controller.placeRoot(),
        ),
      ];
    }

    if (held == null) {
      final open = controller.openTargets;
      return [
        _sectionHeader('NODES', '${open.length}'),
        _hint('Hold a part in PARTS, then tap the node it goes on. Every part '
            'on this craft can be placed from these rows.'),
        _blockedBanner(),
        for (final t in open) _openNodeRow(t),
      ];
    }

    final pairings = controller.pairings;
    // How many of the held part's own nodes each target will take: a decoupler
    // offers two and the row has to name which, a pod offers one and naming it
    // would be noise.
    final options = <(String, String), int>{};
    for (final p in pairings) {
      final key = (p.target.ownerInstanceId, p.target.nodeName);
      options[key] = (options[key] ?? 0) + 1;
    }

    return [
      _sectionHeader('NODES', '${pairings.length}'),
      _hint(pairings.isEmpty
          ? 'Nothing on this craft can take ${held.def.name}. Its nodes are the '
              'wrong kind or the wrong size class for every open seat.'
          : 'Tap a row to bolt ${held.def.name} on. The craft is fully buildable '
              'from this list.'),
      _blockedBanner(),
      for (final p in pairings)
        _pairingRow(p,
            showChildNode:
                (options[(p.target.ownerInstanceId, p.target.nodeName)] ?? 1) >
                    1),
    ];
  }

  Widget _pairingRow(TargetPairing pairing, {required bool showChildNode}) {
    final target = pairing.target;
    final owner = controller.design.partById(target.ownerInstanceId);
    final seats = controller.seatsFor(target).length;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.only(left: 12, right: 8),
      leading: Icon(_kindIcon(target.kind), size: 18, color: AppTheme.accent2),
      title: Text('${owner?.def.name ?? target.ownerInstanceId} › ${target.nodeName}',
          style: AppTheme.body, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${target.kind.name} ${target.size.toStringAsFixed(2)} m'
          '${showChildNode ? '  ←  ${pairing.childNodeName}' : ''}',
          style: AppTheme.dim),
      trailing: seats > 1
          ? Text('×$seats', style: AppTheme.mono.copyWith(color: AppTheme.accent2))
          : const Icon(Icons.add, size: 18, color: AppTheme.accent2),
      onTap: () => controller.attachAt(pairing),
    );
  }

  Widget _openNodeRow(AttachTarget target) {
    final owner = controller.design.partById(target.ownerInstanceId);
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.only(left: 12, right: 8),
      leading: Icon(_kindIcon(target.kind), size: 18, color: AppTheme.textDim),
      title: Text('${owner?.def.name ?? target.ownerInstanceId} › ${target.nodeName}',
          style: AppTheme.dim.copyWith(color: AppTheme.text),
          overflow: TextOverflow.ellipsis),
      subtitle: Text('${target.kind.name} ${target.size.toStringAsFixed(2)} m',
          style: AppTheme.dim),
    );
  }

  /// The controller's refusal sentence, repeated here on purpose.
  ///
  /// This pane is the path that has to keep working when the viewport does not,
  /// and in the narrow layout the viewport's HUD strip is off screen while this
  /// list is open. A tap that quietly does nothing is the one failure that would
  /// make the fallback useless.
  Widget _blockedBanner() {
    final blocked = controller.blocked;
    if (blocked == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.block, size: 14, color: AppTheme.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(blocked,
                style: AppTheme.dim.copyWith(color: AppTheme.danger)),
          ),
        ],
      ),
    );
  }

  static Widget _hint(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Text(text, style: AppTheme.dim),
      );

  static IconData _kindIcon(AttachKind kind) =>
      kind == AttachKind.stack ? Icons.swap_vert : Icons.push_pin_outlined;
}

/// What a part row's overflow menu can do to it.
enum _PartAction { move, detach, deleteOne, deleteGroup }

/// One row of the flattened attach tree: a part, how deep it hangs, and how many
/// symmetry siblings the row stands for.
class _TreeRow {
  final PlacedPart part;
  final int depth;
  final int count;

  const _TreeRow({required this.part, required this.depth, required this.count});
}
