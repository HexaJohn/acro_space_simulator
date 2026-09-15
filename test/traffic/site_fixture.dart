// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Synthetic site plans as a [SitePlanSource]
/// (docs/plans/t4a-implementation.md §1.1; site-access.md §7.9).
///
/// The traffic side is built against the road side's R2a fixtures first and
/// real plans after: [FixturePlanSource] puts the `SyntheticSites` templates
/// on real join slots of a real road graph and answers exactly as
/// `BookPlanSource` over the colony's book does — the same slots, the same
/// chunk identity rules, the same `sitesRev`.
///
/// It keeps the book's semantics where they matter to traffic:
///
/// - a site takes the lowest free slot on first appearance and keeps it
///   while it lives, so a slot is the wire ordinal;
/// - the rows of the chunk are its live slots in ascending order;
/// - `sitesRev` moves once whenever a plan appears, goes or changes, and
///   the chunk's identity changes with it (a new chunk object);
/// - a site id IS its lot id, as the book's is.
///
/// Its own seam, which no book has: [FixturePlanSource.replace] edits the
/// plans mid-test, and [FixturePlanSource.markStale] makes a site not
/// current without touching the graph (§0 Q5).
library;

import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';

import '../colony/site_access/site_plan_fixtures.dart';

/// `SyntheticSites` templates on the lots of one road graph, as the plan
/// source traffic reads. See the library comment.
class FixturePlanSource implements SitePlanSource {
  /// One site per entry of [byLot] (graph lot id → template), taking slots
  /// in sorted lot order. [validate] runs the road side's V1–V13 over every
  /// chunk built, as `SyntheticSites.chunkOf` does by default.
  FixturePlanSource(this.graph, Map<String, SyntheticTemplate> byLot,
      {this.validate = true}) {
    final lots = byLot.keys.toList()..sort();
    for (final lot in lots) {
      _lot.add(lot);
      _template.add(byLot[lot]!);
      _sitesRev++;
    }
    _rebuild();
  }

  /// The graph the templates stand on, and the one they are current for.
  final RoadGraph graph;

  final bool validate;

  /// Per slot: its lot id and template, or null for a free slot.
  final List<String?> _lot = [];
  final List<SyntheticTemplate?> _template = [];

  /// Per slot: its row in the chunk, or −1.
  final List<int> _rowOfSlot = [];

  final Set<String> _stale = <String>{};

  int _sitesRev = 0;
  List<SiteAccessChunk> _chunks = const [];

  @override
  int get sitesRev => _sitesRev;

  @override
  List<SiteAccessChunk> get chunks => _chunks;

  @override
  SiteAccessPlan? planOf(String siteId) {
    final slot = slotOf(siteId);
    if (slot < 0) return null;
    final row = _rowOfSlot[slot];
    return row < 0 ? null : _chunks[0].plan(row);
  }

  @override
  int slotOf(String siteId) {
    for (var s = 0; s < _lot.length; s++) {
      if (_lot[s] == siteId) return s;
    }
    return -1;
  }

  @override
  bool isCurrentFor(String siteId, RoadGraph g) =>
      slotOf(siteId) >= 0 &&
      !_stale.contains(siteId) &&
      g.structureStamp == graph.structureStamp;

  /// Puts [template] on lot [lotId] — a new site, another template, or null
  /// to clear it — and moves [sitesRev] and the chunk identity with it, as
  /// a book's re-plan does. A template that is already there changes
  /// nothing, as an unchanged site's check does not.
  void replace(String lotId, SyntheticTemplate? template) {
    final slot = slotOf(lotId);
    if (slot < 0 && template == null) return;
    if (slot >= 0 && _template[slot] == template) return;
    if (template == null) {
      _lot[slot] = null;
      _template[slot] = null;
    } else if (slot >= 0) {
      _template[slot] = template;
    } else {
      var free = -1;
      for (var s = 0; s < _lot.length && free < 0; s++) {
        if (_lot[s] == null) free = s;
      }
      if (free < 0) {
        free = _lot.length;
        _lot.add(null);
        _template.add(null);
      }
      _lot[free] = lotId;
      _template[free] = template;
    }
    _sitesRev++;
    _stale.remove(lotId);
    _rebuild();
  }

  /// Marks [siteId] queued for a check, so [isCurrentFor] reads false
  /// without a graph edit: what a road edit's dirty box does to a book.
  void markStale(String siteId, {bool stale = true}) {
    if (stale) {
      _stale.add(siteId);
    } else {
      _stale.remove(siteId);
    }
  }

  /// Builds the one chunk afresh: every live slot in ascending order, so a
  /// row is its slot's rank. A new chunk object every time, as a book
  /// publishes one whenever a site of it changed.
  void _rebuild() {
    final drafts = <DraftSite>[];
    _rowOfSlot
      ..clear()
      ..addAll(List<int>.filled(_lot.length, -1));
    for (var s = 0; s < _lot.length; s++) {
      final lot = _lot[s];
      final t = _template[s];
      if (lot == null || t == null) continue;
      _rowOfSlot[s] = drafts.length;
      drafts.add(SyntheticSites.draftAt(graph, lot, t, siteId: lot));
    }
    _chunks = drafts.isEmpty
        ? const []
        : List<SiteAccessChunk>.unmodifiable(
            [SyntheticSites.chunkOf(graph, drafts, validate: validate)]);
  }
}
