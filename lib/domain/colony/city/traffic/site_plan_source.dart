// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where traffic reads site access plans from (docs/plans/t4a-implementation.md
/// §1.1; site-access.md §4.1, §7.6).
///
/// A test seam: the colony's [SiteAccessBook] and the synthetic chunks the
/// tests build (`FixturePlanSource`, test/traffic/site_fixture.dart) look
/// the same to the site table, so the site sync, the mover and the parking
/// are built and tested on the road side's fixtures and run unchanged on
/// real plans.
///
/// Traffic only READS plans (§7.1): it never generates, edits or re-derives
/// site geometry. Published chunks are immutable, so a chunk traffic holds
/// stays readable after the book has moved on — that is traffic's limbo
/// (§7.6 as built).
library;

import '../road_graph.dart';
import '../site_access/site_access_book.dart';
import '../site_access/site_access_plan.dart';

/// The plans traffic reads. See the library comment.
abstract interface class SitePlanSource {
  /// Moves when any plan appears, goes or changes `rev`. A re-resolution
  /// against a new graph and a rename do not move it: those show through
  /// [isCurrentFor] and the chunks' identities.
  int get sitesRev;

  /// The published chunks, chunk `k` holding slots `k * kSitesPerChunk ..`.
  /// A chunk's identity changes only when one of its sites changed, so the
  /// site sync compares the chunks ELEMENT BY ELEMENT with `identical`; the
  /// list object itself may be a new view on every read (the book's is).
  List<SiteAccessChunk> get chunks;

  /// [siteId]'s plan, or null. Allocates a view: site sync and tests only,
  /// never a sub-step.
  SiteAccessPlan? planOf(String siteId);

  /// [siteId]'s slot, or −1 with no plan: stable while the site lives, kept
  /// by a rename. The wire ordinal (`siteOrd`, §0 Q4) and the index of
  /// `CityAgents.agentManaged`.
  int slotOf(String siteId);

  /// Whether [siteId]'s plan was resolved against [g]'s structure and is
  /// not queued for a check. A site that is not current reads kerbside at
  /// [g]'s slot 0 for new arrivals (§0 Q5).
  bool isCurrentFor(String siteId, RoadGraph g);

  /// Whether the source has nothing left to plan: every site it knows of has
  /// the plan it is going to have, so a site with no plan NOW has none
  /// coming (site-access §4.1: the book's sync is resumable and budgeted, and
  /// says so when it finishes).
  ///
  /// The load reads it and nothing else does (§14.1 as built). A saved car
  /// whose lot has not been synced yet is held rather than garaged, and this
  /// is what says the waiting is over: false while a re-plan backlog is still
  /// in flight, true the moment the backlog drains. A source that can never
  /// say true is not wrong, only slower — the load's own hold
  /// ([kRestoreHoldS]) bounds it either way.
  bool get plansComplete;
}

/// The colony's [SiteAccessBook] as a [SitePlanSource]: every read goes
/// straight to the book, whose names the seam took.
final class BookPlanSource implements SitePlanSource {
  BookPlanSource(this.book);

  /// The book read.
  final SiteAccessBook book;

  @override
  int get sitesRev => book.sitesRev;

  /// The book's chunks, as a new unmodifiable view per read: compare its
  /// elements, never the list.
  @override
  List<SiteAccessChunk> get chunks => book.chunks;

  @override
  SiteAccessPlan? planOf(String siteId) => book.planOf(siteId);

  @override
  int slotOf(String siteId) => book.slotOf(siteId);

  @override
  bool isCurrentFor(String siteId, RoadGraph g) =>
      book.isCurrentFor(siteId, g);

  /// What the book's last sync reported (`SiteAccessSyncStats.complete`: an
  /// empty queue, no walk, no re-walk and no sweep left). A book that has
  /// never synced reports false, which is the safe answer — it has not said
  /// it is finished.
  @override
  bool get plansComplete => book.lastSync.complete;
}
