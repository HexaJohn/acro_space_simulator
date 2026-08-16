// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../domain/craft/craft_design.dart';
import '../../../../domain/craft/craft_design_codec.dart';
import '../../../../domain/parts/part_catalog.dart';

/// What a saved slot holds, without opening it.
///
/// The list of saved crafts is drawn far more often than a craft is loaded, and
/// decoding every design to render a menu would resolve every part def through
/// the catalog for nothing. The index carries enough to draw the row and no
/// more.
class CraftSaveSlot {
  /// The key the player named this save with — what [CraftDesignStore.load]
  /// takes, not the craft's own name.
  final String slot;

  /// [CraftDesign.name] as it was when the slot was written. It can differ from
  /// [slot]: renaming the craft does not move the save.
  final String craftName;

  final int partCount;

  final DateTime savedAt;

  const CraftSaveSlot({
    required this.slot,
    required this.craftName,
    required this.partCount,
    required this.savedAt,
  });

  @override
  bool operator ==(Object other) =>
      other is CraftSaveSlot &&
      other.slot == slot &&
      other.craftName == craftName &&
      other.partCount == partCount &&
      other.savedAt == savedAt;

  @override
  int get hashCode => Object.hash(slot, craftName, partCount, savedAt);

  @override
  String toString() => 'CraftSaveSlot($slot, "$craftName", $partCount parts)';
}

/// Named save slots plus an autosave, over [SharedPreferences].
///
/// ## Why SharedPreferences and not a file
///
/// The editor has to work on web, where there is no `dart:io` and no path to
/// write to; `SharedPreferences` is already this app's persistence (it carries
/// the render-backend choice) and is backed by `localStorage` in the browser
/// and by the platform preference store everywhere else. Craft designs are a
/// few kilobytes of JSON — a saved LM is about 2 KB — which is well inside what
/// a preference store is meant to carry.
///
/// ## What is stored
///
/// Every value is a JSON string, because that is the only structured type a
/// preference store has. Per slot:
///
/// ```json
/// {"saved": "<iso8601 utc>", "design": { ...CraftDesignCodec.encode... }}
/// ```
///
/// plus one index key holding the slot list. The index is written LAST on save
/// and FIRST on delete, so a write interrupted halfway leaves an unreferenced
/// payload rather than an index entry pointing at nothing — a slot that is
/// missing is a visible loss, a slot that fails to open is a bug report.
///
/// ## What is not stored
///
/// Part specifications. [CraftDesignCodec] persists which catalog part sits
/// where, and the def is resolved through a [PartCatalog] on load, so
/// rebalancing a tank improves every saved craft instead of baking a stale copy
/// into each file. The corollary is that [load] needs the catalog the craft was
/// built from, and a craft referencing a part that has since been removed
/// refuses to open rather than quietly losing mass and delta-v.
class CraftDesignStore {
  CraftDesignStore({
    this.namespace = 'craftDesign',
    CraftDesignCodec codec = const CraftDesignCodec(),
  }) : _codec = codec;

  /// Key prefix, so the editor's saves cannot collide with another feature's
  /// preferences in the one flat store the platform gives us.
  final String namespace;

  final CraftDesignCodec _codec;

  /// The slot the editor writes to on its own initiative.
  ///
  /// Reserved: it is filtered out of [list] and refused by [save], so a player
  /// cannot name a craft over the recovery copy and then lose both to one
  /// mistake.
  static const String autosaveSlot = '__autosave__';

  String get indexKey => '$namespace.index';

  String keyFor(String slot) => '$namespace.slot.${_requireSlot(slot)}';

  /// Named saves, most recently written first. The autosave is not one.
  Future<List<CraftSaveSlot>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = _readIndex(prefs)
        .where((e) => e.slot != autosaveSlot)
        .toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  /// What [slot] holds, or null when nothing is saved under that name.
  Future<CraftSaveSlot?> describe(String slot) async {
    final name = _requireSlot(slot);
    final prefs = await SharedPreferences.getInstance();
    for (final e in _readIndex(prefs)) {
      if (e.slot == name) return e;
    }
    return null;
  }

  /// Write [design] to [slot], replacing whatever was there.
  ///
  /// Throws [ArgumentError] for a blank slot name or for [autosaveSlot] — use
  /// [saveAutosave] for that one, so "the editor saved over my craft" cannot
  /// happen by passing a string through.
  Future<void> save(String slot, CraftDesign design) async {
    final name = _requireSlot(slot);
    if (name == autosaveSlot) {
      throw ArgumentError.value(
          slot, 'slot', 'the autosave slot is written by saveAutosave()');
    }
    await _write(name, design);
  }

  /// Read [slot] back through [catalog], or null when the slot is empty.
  ///
  /// Propagates [FormatException] for a corrupt or too-new payload and
  /// [StateError] for one whose attach tree is not a valid forest, both from
  /// [CraftDesignCodec]. Refusing loudly is the design's own stance: a craft
  /// that quietly loses a stage is worse than one that will not open.
  Future<CraftDesign?> load(String slot, {required PartCatalog catalog}) async {
    final name = _requireSlot(slot);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(keyFor(name));
    if (raw == null) return null;

    final decoded = json.decode(raw);
    if (decoded is! Map) {
      throw FormatException('saved craft "$name" is not an object');
    }
    final payload = decoded['design'];
    if (payload is! Map) {
      throw FormatException('saved craft "$name" has no design');
    }
    return _codec.decode(payload.cast<String, dynamic>(), catalog: catalog);
  }

  /// Forget [slot]. True when something was there.
  Future<bool> delete(String slot) async {
    final name = _requireSlot(slot);
    final prefs = await SharedPreferences.getInstance();
    final existed = prefs.containsKey(keyFor(name));
    // Index first: an entry pointing at a payload that is gone would make the
    // slot appear in the menu and then fail to open.
    await _writeIndex(
        prefs, _readIndex(prefs).where((e) => e.slot != name).toList());
    await prefs.remove(keyFor(name));
    return existed;
  }

  /// Overwrite the recovery copy. Called on a timer or on leaving the editor,
  /// so it must stay cheap and must never throw into a UI callback.
  Future<void> saveAutosave(CraftDesign design) => _write(autosaveSlot, design);

  /// The recovery copy, or null when there is none.
  Future<CraftDesign?> loadAutosave({required PartCatalog catalog}) =>
      load(autosaveSlot, catalog: catalog);

  Future<bool> deleteAutosave() => delete(autosaveSlot);

  /// Drop every slot this store owns, index included. Test and "reset my saves"
  /// support; it touches nothing outside [namespace].
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    for (final e in _readIndex(prefs)) {
      await prefs.remove(keyFor(e.slot));
    }
    await prefs.remove(indexKey);
  }

  // ---------------- internals ----------------

  Future<void> _write(String slot, CraftDesign design) async {
    final prefs = await SharedPreferences.getInstance();
    final savedAt = DateTime.now().toUtc();
    await prefs.setString(
      keyFor(slot),
      json.encode({
        'saved': savedAt.toIso8601String(),
        'design': _codec.encode(design),
      }),
    );
    // Index last: see the class doc. An unreferenced payload is invisible; a
    // dangling index entry is a broken menu row.
    final index = _readIndex(prefs).where((e) => e.slot != slot).toList()
      ..add(CraftSaveSlot(
        slot: slot,
        craftName: design.name,
        partCount: design.partCount,
        savedAt: savedAt,
      ));
    await _writeIndex(prefs, index);
  }

  /// The index, or an empty list when it is missing or unreadable.
  ///
  /// Tolerant on purpose, and the ONLY tolerant read in this file: the index is
  /// derived data that [_write] rebuilds, so a corrupt one costs a menu listing
  /// and nothing else. A corrupt DESIGN is the player's work and throws.
  List<CraftSaveSlot> _readIndex(SharedPreferences prefs) {
    final raw = prefs.getString(indexKey);
    if (raw == null) return [];
    final Object? decoded;
    try {
      decoded = json.decode(raw);
    } on FormatException {
      return [];
    }
    if (decoded is! List) return [];
    final out = <CraftSaveSlot>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final slot = entry['slot'];
      final name = entry['name'];
      final saved = entry['saved'];
      if (slot is! String || slot.isEmpty) continue;
      out.add(CraftSaveSlot(
        slot: slot,
        craftName: name is String && name.isNotEmpty ? name : slot,
        partCount: (entry['parts'] as num?)?.toInt() ?? 0,
        savedAt: saved is String
            ? (DateTime.tryParse(saved) ?? DateTime.fromMillisecondsSinceEpoch(0))
            : DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    return out;
  }

  Future<void> _writeIndex(
          SharedPreferences prefs, List<CraftSaveSlot> index) =>
      prefs.setString(
        indexKey,
        json.encode([
          for (final e in index)
            {
              'slot': e.slot,
              'name': e.craftName,
              'parts': e.partCount,
              'saved': e.savedAt.toIso8601String(),
            }
        ]),
      );

  /// Slot names are keys, so they are trimmed and must not be blank — a save
  /// called "  " is one the player can never find again.
  static String _requireSlot(String slot) {
    final trimmed = slot.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(slot, 'slot', 'save slot name must not be blank');
    }
    return trimmed;
  }
}
