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
///
/// [SiteWorld] puts a colony, its buildings, its lane graph and a synced
/// [SiteTable] together, which is what every site test needs before it can
/// say anything, and [SiteChanges] records what a sync told the §7.6 sink.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'traffic_fixture.dart';

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
      _change.add(null);
      _sitesRev++;
    }
    _rebuild();
  }

  /// The graph the templates stand on, and the one they are current for.
  final RoadGraph graph;

  final bool validate;

  /// Per slot: its lot id and template, or null for a free slot, and the
  /// edit made to its draft before it is emitted.
  final List<String?> _lot = [];
  final List<SyntheticTemplate?> _template = [];
  final List<void Function(DraftSite)?> _change = [];

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
      _change[slot] = null;
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
        _change.add(null);
      }
      _lot[free] = lotId;
      _template[free] = template;
      _change[free] = null;
    }
    _sitesRev++;
    _stale.remove(lotId);
    _rebuild();
  }

  /// Edits [lotId]'s draft with [change] — null to stop editing it — before
  /// it is emitted, and republishes as [replace] does.
  ///
  /// The templates are whole sites, so swapping one for another moves every
  /// stall it has; a re-plan that moved PART of a site (a stall taken out,
  /// the rest left where it was) is what `stallKey` exists for, and this is
  /// the only way to build one. [validate] is worth turning off for an edit
  /// the road side's generators would never emit.
  void edit(String lotId, void Function(DraftSite)? change) {
    final slot = slotOf(lotId);
    if (slot < 0) return;
    _change[slot] = change;
    _sitesRev++;
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
      final draft = SyntheticSites.draftAt(graph, lot, t, siteId: lot);
      _change[s]?.call(draft);
      drafts.add(draft);
    }
    _chunks = drafts.isEmpty
        ? const []
        : List<SiteAccessChunk>.unmodifiable(
            [SyntheticSites.chunkOf(graph, drafts, validate: validate)]);
  }
}

/// What a sync told the §7.6 sink, in the order it told it: [kind] is one
/// of [kSiteChangeRev], [kSiteChangeLostRole] and [kSiteChangeGone].
const int kSiteChangeRev = 0;
const int kSiteChangeLostRole = 1;
const int kSiteChangeGone = 2;

/// The §7.6 sink, writing down what it was told rather than acting on it.
class SiteChanges implements SiteChangeSink {
  final List<int> kind = <int>[];
  final List<int> oldRow = <int>[];
  final List<int> newRow = <int>[];

  int get count => kind.length;

  void clear() {
    kind.clear();
    oldRow.clear();
    newRow.clear();
  }

  void _add(int k, int was, int now) {
    kind.add(k);
    oldRow.add(was);
    newRow.add(now);
  }

  @override
  void siteRevChanged(int was, int now) => _add(kSiteChangeRev, was, now);

  @override
  void siteLostRole(int was, int now) => _add(kSiteChangeLostRole, was, now);

  @override
  void siteGone(int was) => _add(kSiteChangeGone, was, -1);
}

/// A colony whose lots carry synthetic plans, with the buildings, the lane
/// graph and the site table a site test reads.
///
/// Every lot named in [byLot] is a BUILT lot of the town, so the building
/// table has a slot for it and the site table can hang a row on that slot.
class SiteWorld {
  SiteWorld(Map<String, SyntheticTemplate> byLot,
      {CitySim? on, bool validate = true})
      : city = on ?? town() {
    graph = city.roadGraph;
    lg = LaneGraphBuilder.build(graph);
    // The plans first: a building's access rows ARE its plan's joins (§7.3),
    // so the table is synced against the same source the site table reads.
    plans = FixturePlanSource(graph, byLot, validate: validate);
    buildings = BuildingTable()..sync(city, lg, plans);
  }

  /// The town the lots stand in, and the graph and lanes its cars drive.
  final CitySim city;
  late final RoadGraph graph;
  late final LaneGraph lg;

  /// Every built site, the plans on them, and the synced site networks.
  late final BuildingTable buildings;
  late final FixturePlanSource plans;
  final SiteTable sites = SiteTable();

  /// What the last [sync] told the sink.
  final SiteChanges changes = SiteChanges();

  /// One sync, its §7.6 cases recorded afresh.
  void sync({bool keepChanges = false}) {
    if (!keepChanges) changes.clear();
    sites.sync(plans, buildings, lg, changes);
  }

  /// The building slot of [lotId], or −1.
  int buildingOf(String lotId) {
    final h = buildings.handleOfSite(lotId);
    return h == null ? -1 : SlotPool.slotOf(h);
  }

  /// The site row of [lotId], or −1 when it has none.
  int rowOf(String lotId) => sites.rowOfBuilding(buildingOf(lotId));

  SiteAccessPlan planOf(String lotId) => sites.plan[rowOf(lotId)]!;

  SiteLaneGraph lanesOf(String lotId) => sites.lanes[rowOf(lotId)]!;
}

/// The starter lot each template stands on, as `SyntheticSites` places it.
String lotOf(SyntheticTemplate t) => SyntheticSites.starterLots[t]!.$1;

/// Every template on its own starter lot: the widest world a site test can
/// ask for.
Map<String, SyntheticTemplate> everyTemplate() => <String, SyntheticTemplate>{
      for (final t in SyntheticTemplate.values) lotOf(t): t,
    };
