// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How vehicles move inside sites, and across the kerb
/// (docs/plans/t4a-implementation.md §1.6; site-access.md §7.4, §7.8 items
/// 3–7, D49).
///
/// STUB (P0). Package C implements it; until then every method throws, and
/// the one getter the road mover may read, [SiteMover.count], reads 0.
///
/// The contract C builds to:
///
/// - **Inside a site** a vehicle has element −1 and state
///   `VehicleState.onSite`; its place is `(SiteVehicles.row, .lane,
///   VehicleTable.s)`. [SiteMover.step] runs IDM on site lanes (speed caps
///   from the plan), follows `SiteTable.nextLane` hops through §2.5
///   movements and turnarounds, and ends in a scripted stall manoeuvre that
///   lands exactly on the stall pose ([SiteManoeuvre]). `sharedSingle` units
///   are claimed whole, one direction at a time.
/// - **The arrival gate** ([SiteMover.holdAtGate]): a car at `destS` with a
///   reserved stall is granted on G1–G3 (G2 by `JunctionArbiter.opposingClear`),
///   forced after `AgentTuning.gateForcedS`, given up after `gateGiveUpS`
///   ([SiteSink.gateGaveUp]). A grant logs ENTER, detaches the car and puts
///   it on the throat in-lane at s = 0.
/// - **Departures** ([SiteMover.spawnFromStall]): a vehicle row spawns
///   detached at the stall, reverses or pulls out, drives to the throat and
///   waits with its front `throatStopM` inside the kerb line for `canJoin`;
///   a grant logs EXIT and attaches it. A home car waits in its stall for a
///   back-out gap (`AccessGaps`), then reverses and swings into its target
///   lane as a REVERSING manoeuvre (`VehicleState.manoeuvre`, `kReversing`),
///   logged EXIT as its rear crosses the kerb line.
/// - **Lane obstacles.** Back-out footprints and far-direction claims are
///   answered to the road mover through [LaneObstacles].
/// - **Rebuilds and site changes.** [SiteMover.relink] rebuilds the site
///   lists after a site sync renumbers elements; [SiteMover.snap] and
///   [SiteMover.evacuate] are the §7.6 row 1 and row 3 moves;
///   [SiteMover.remapHeld] carries the road routes of cars inside sites
///   across a lane-graph rebuild.
///
/// Nothing in a step allocates (§15.2).
library;

import 'dart:typed_data';

import 'access_events.dart';
import 'agent_kind.dart';
import 'graph_lineage.dart';
import 'junction_arbiter.dart';
import 'lane_graph.dart';
import 'lane_obstacles.dart';
import 'site_stats.dart';
import 'site_table.dart';
import 'site_vehicles.dart';
import 'trip_planner.dart';
import 'vehicle_mover.dart';
import 'vehicle_table.dart';

/// Told what the site mover did to vehicles, before their slots change, so
/// the owner can still read their columns. Implemented by the facade
/// (package E).
abstract interface class SiteSink {
  /// [handle] finished its stall manoeuvre on [stall] of site [row]: free
  /// its vehicle row and park its car there.
  void parkedInStall(int handle, int row, int stall);

  /// [handle] gave its reserved stall up at the gate — the lot full, or 30 s
  /// refused on the throat's room: go on to D17 step 2 (a kerb slot).
  void gateGaveUp(int handle);

  /// [handle] crossed the kerb line out of its site onto the road (EXIT
  /// logged, attached).
  void exited(int handle);
}

/// Moves the vehicles inside sites. See the library comment.
class SiteMover implements LaneObstacles {
  SiteMover(this.table, this.site, this.sites, this.arbiter, this.events,
      this.stats);

  /// The vehicles, their site columns, and the synced site networks.
  final VehicleTable table;
  final SiteVehicles site;
  final SiteTable sites;

  /// The road's junction arbiter: `canJoin` and `opposingClear` at the kerb.
  final JunctionArbiter arbiter;

  /// Where ENTER and EXIT are logged, and what is counted.
  final AccessEventLog events;
  final SiteStats stats;

  /// No obstacles until C lands: the road mover never asks.
  @override
  int get count => 0;

  /// Puts the mover on the road lane graph [lg].
  void bind(LaneGraph lg) => throw UnimplementedError('T4a C: SiteMover.bind');

  /// Holds [handle], at its `destS`, at the gate of in-join [join] of site
  /// [row], with [stall] reserved for it (§7.4 steps 2–4).
  void holdAtGate(int handle, int row, int join, int stall) =>
      throw UnimplementedError('T4a C: SiteMover.holdAtGate');

  /// Spawns a departing car detached on [stall] of site [row], leaving by
  /// out-join [join] on the road route [route] of [n] elements
  /// (`[firstLane, c₁, …]`) from [originT] to [destT]; its car is of [kind]
  /// and [variant], owned by [owner] of `CarOwnerKind` index [ownerKind].
  /// Returns its handle, or `SlotPool.none` when the table is full.
  int spawnFromStall(
          {required int row,
          required int stall,
          required int join,
          required AgentKind kind,
          required int variant,
          required int ownerKind,
          required int owner,
          required Int32List route,
          required int n,
          required double originT,
          required double destT,
          required int nowUs,
          required double speedFactor,
          required double freeFlowS}) =>
      throw UnimplementedError('T4a C: SiteMover.spawnFromStall');

  /// One sub-step at agent time [nowUs], after the road mover's: the gate,
  /// the site lanes, the manoeuvres, the throats and the back-outs, telling
  /// [s] and [v] what became of each vehicle.
  void step(int nowUs, SiteSink s, VehicleSink v) =>
      throw UnimplementedError('T4a C: SiteMover.step');

  /// Rebuilds the site lists from the site columns after a site sync has
  /// renumbered the site elements.
  void relink() => throw UnimplementedError('T4a C: SiteMover.relink');

  /// §7.6 row 1: the movers in [oldRow] snap onto [newRow]'s lanes (within
  /// `siteSnapM` and the angle of `siteSnapCos`), or park, relocate or
  /// head out as the table says.
  void snap(int oldRow, int newRow) =>
      throw UnimplementedError('T4a C: SiteMover.snap');

  /// §7.6 row 3: the movers in [oldRow], whose plan went, carry on in limbo:
  /// inbound drops its reservation and exits, outbound carries on.
  void evacuate(int oldRow) =>
      throw UnimplementedError('T4a C: SiteMover.evacuate');

  /// Carries the held road route of every car inside a site across a lane
  /// graph rebuild by [rm], as `TripPlanner.remapWaiting` does; a route made
  /// impossible is reported to [sink]. Returns the routes it re-planned.
  int remapHeld(RouteRemapper rm, SpawnSink sink) =>
      throw UnimplementedError('T4a C: SiteMover.remapHeld');

  /// See [LaneObstacles.obstacleAhead].
  @override
  bool obstacleAhead(int lane, double laneS, Float64List out) =>
      throw UnimplementedError('T4a C: SiteMover.obstacleAhead');

  /// Every buffer by name into [into], for the allocation test (A13).
  void collectBuffers(Map<String, Object> into, String name) =>
      throw UnimplementedError('T4a C: SiteMover.collectBuffers');

  /// [hash] with the mover's own state folded in (claims, gate timers).
  int digest(int hash) => throw UnimplementedError('T4a C: SiteMover.digest');
}
