// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// One type-to-search picker for every item and recipe choice on the floor
/// editor (docs/plans/factory-floors.md §10 item 16).
///
/// **Why.** Every plant chain registers its items and recipes in one open
/// table, so an item dropdown lists well over a hundred entries and the
/// player scrolled a long menu to find "Ore". The arm filter, the dock and
/// chest item, the machine recipe (palette and inspector) and the Recipe
/// info product all use THIS widget, so they search the same way: a
/// case-insensitive substring of the label OR the id, matches kept in their
/// groups, arrow keys to move, Enter to pick, Esc to close.
///
/// **Where it opens.** The list is a dialog ROUTE, not a widget inside the
/// palette or the inspector. That puts it outside the canvas's pointer
/// [Listener] (an ancestor recognizer would steal its clicks: memory
/// flutter-gesture-button-filter), gives it room the 212 px palette doesn't
/// have, and takes it out of the editor's focus chain altogether.
///
/// **Keys.** The editor binds bare letters (R, X, M, F), Del and Ctrl+Z on
/// a [Focus] above the screen, and a colony host has its own bindings above
/// that. The dialog is not under them, and its own [Focus] still stops
/// every key from bubbling further ([KeyEventResult.skipRemainingHandlers],
/// as the product tree's search does), so typing "rx" can never rotate or
/// sweep-delete. Stopping the bubble also cuts the field off from the
/// app-level text-editing shortcuts (Backspace, arrows, select-all), so a
/// copy of [DefaultTextEditingShortcuts] sits inside, below the stop.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';

/// Most of the dialog's height the match list may take, logical px.
const double kPickerListMaxHeight = 420;

/// Width of the picker dialog, logical px: a recipe's full label plus its
/// "used here" note fits on one line.
const double kPickerDialogWidth = 380;

/// One choice in a [SearchablePicker].
class PickerOption<T> {
  const PickerOption(
      {required this.value,
      required this.id,
      required this.label,
      this.group = '',
      this.note});

  /// What picking it hands back (may be null: "Any item").
  final T value;

  /// A stable search key and widget-key suffix (an item or recipe id).
  final String id;

  /// What the player reads.
  final String label;

  /// The heading it is listed under; options of one group must be
  /// adjacent (the list is shown in the order given).
  final String group;

  /// A dim second line (a recipe's inputs and outputs, say).
  final String? note;

  /// Does [query] (already lower-cased and trimmed) match this option?
  /// A substring of the label or the id, so "elec" finds "Electronics ×10
  /// (crate · pallet)" and "crate:" finds every crate.
  bool matches(String query) =>
      query.isEmpty ||
      label.toLowerCase().contains(query) ||
      id.toLowerCase().contains(query);
}

/// The options [query] keeps, in order (the filter the dialog applies;
/// public so a test can pin it without a widget).
List<PickerOption<T>> filterPickerOptions<T>(
    List<PickerOption<T>> options, String query) {
  final q = query.trim().toLowerCase();
  return [for (final o in options) if (o.matches(q)) o];
}

/// Opens the search dialog over [context] and returns the option picked,
/// or null when it was dismissed. (The OPTION, not its value: "Any item"
/// is a real choice whose value is null.)
Future<PickerOption<T>?> showSearchablePicker<T>(BuildContext context,
    {required String title,
    required List<PickerOption<T>> options,
    String? selectedId}) {
  return showDialog<PickerOption<T>>(
    context: context,
    builder: (_) => _PickerDialog<T>(
        title: title, options: options, selectedId: selectedId),
  );
}

/// A dropdown-shaped field that opens [showSearchablePicker]: the current
/// choice's label and a search icon. Drop-in for the editor's former
/// [DropdownButton]s (it keeps their widget keys).
class SearchablePicker<T> extends StatelessWidget {
  const SearchablePicker({
    super.key,
    required this.title,
    required this.options,
    required this.selectedId,
    required this.onChanged,
    this.hint = 'Choose…',
  });

  /// The dialog's heading ("Arm picks", "Recipe").
  final String title;
  final List<PickerOption<T>> options;

  /// The [PickerOption.id] of the current choice (null: none, show [hint]).
  final String? selectedId;
  final ValueChanged<T>? onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    PickerOption<T>? cur;
    for (final o in options) {
      if (o.id == selectedId) cur = o;
    }
    final change = onChanged;
    return InkWell(
      onTap: change == null
          ? null
          : () async {
              final got = await showSearchablePicker<T>(context,
                  title: title, options: options, selectedId: selectedId);
              if (got != null) change(got.value);
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.textDim))),
        child: Row(children: [
          Expanded(
            child: Text(cur?.label ?? hint,
                overflow: TextOverflow.ellipsis,
                style: cur == null ? AppTheme.dim : AppTheme.body),
          ),
          const Icon(Icons.search, size: 16, color: AppTheme.textDim),
        ]),
      ),
    );
  }
}

class _PickerDialog<T> extends StatefulWidget {
  const _PickerDialog(
      {super.key, required this.title, required this.options, this.selectedId});
  final String title;
  final List<PickerOption<T>> options;
  final String? selectedId;

  @override
  State<_PickerDialog<T>> createState() => _PickerDialogState<T>();
}

class _PickerDialogState<T> extends State<_PickerDialog<T>> {
  final TextEditingController _q = TextEditingController();
  final FocusNode _field = FocusNode(debugLabel: 'picker-search');
  final ScrollController _scroll = ScrollController();

  /// On the highlighted row, so moving the highlight (or opening on the
  /// current pick far down the list) scrolls it into view.
  final GlobalKey _hiKey = GlobalKey(debugLabel: 'picker-highlight');

  /// Index into the current matches of the keyboard's highlight.
  int _hi = 0;

  List<PickerOption<T>> get _matches =>
      filterPickerOptions(widget.options, _q.text);

  @override
  void initState() {
    super.initState();
    final i = widget.options.indexWhere((o) => o.id == widget.selectedId);
    _hi = i < 0 ? 0 : i;
    _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _hiKey.currentContext;
        if (mounted && ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0.5);
        }
      });

  @override
  void dispose() {
    _q.dispose();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _pick(PickerOption<T> o) => Navigator.of(context).pop(o);

  /// Arrow keys move the highlight, Enter picks it, Esc closes. Handled
  /// BELOW the text-editing shortcuts so Up / Down move the list, not the
  /// caret.
  KeyEventResult _nav(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final m = _matches;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      if (m.isEmpty) return KeyEventResult.handled;
      final d = k == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() => _hi = (_hi + d).clamp(0, m.length - 1));
      _reveal();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (m.isNotEmpty) _pick(m[_hi.clamp(0, m.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = _matches;
    final hi = m.isEmpty ? -1 : _hi.clamp(0, m.length - 1);
    final rows = <Widget>[];
    String? group;
    for (var i = 0; i < m.length; i++) {
      final o = m[i];
      if (o.group.isNotEmpty && o.group != group) {
        rows.add(Padding(
          key: Key('picker-group-${o.group}'),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
          child: Text(o.group, style: AppTheme.dim.copyWith(fontSize: 10)),
        ));
      }
      group = o.group;
      final on = i == hi;
      final note = o.note;
      final row = InkWell(
        key: Key('picker-option-${o.id}'),
        onTap: () => _pick(o),
        child: Container(
          color: on ? AppTheme.panelLight : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(o.label,
                  style: AppTheme.body.copyWith(
                      color: o.id == widget.selectedId
                          ? AppTheme.accent
                          : AppTheme.text)),
              if (note != null)
                Text(note, style: AppTheme.dim.copyWith(fontSize: 11)),
            ],
          ),
        ),
      );
      rows.add(on ? KeyedSubtree(key: _hiKey, child: row) : row);
    }
    return Focus(
      // Nothing typed here may reach the editor's (or a colony's) keys.
      onKeyEvent: (_, e) => KeyEventResult.skipRemainingHandlers,
      child: DefaultTextEditingShortcuts(
        child: Dialog(
          key: const Key('picker-dialog'),
          backgroundColor: AppTheme.panel,
          child: SizedBox(
            width: kPickerDialogWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                  child: Text(widget.title, style: AppTheme.heading),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Focus(
                    onKeyEvent: _nav,
                    skipTraversal: true,
                    child: TextField(
                      key: const Key('picker-search'),
                      controller: _q,
                      focusNode: _field,
                      autofocus: true,
                      style: AppTheme.body,
                      decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'Type to search…',
                          hintStyle: AppTheme.dim,
                          prefixIcon: Icon(Icons.search, size: 16)),
                      onChanged: (_) => setState(() => _hi = 0),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxHeight: kPickerListMaxHeight),
                  child: m.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: Text('Nothing matches',
                              key: Key('picker-empty'), style: AppTheme.dim))
                      // Every row built (not a lazy list), so the
                      // highlight's key always has a context to reveal.
                      : SingleChildScrollView(
                          key: const Key('picker-list'),
                          controller: _scroll,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: rows)),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
