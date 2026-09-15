// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The scripted poses of a stall manoeuvre and a home back-out
/// (docs/plans/t4a-implementation.md §1.6; site-access.md §7.4).
///
/// STUB (P0). Package C implements it; the wire's capture (package F) calls
/// the same functions, so a car is drawn exactly where the simulation put
/// it — one definition of the curve, never two.
///
/// The contract C builds to:
///
/// - A manoeuvre is a parameter `u` in 0..1 along a CUBIC BÉZIER, and the
///   pose at `u` is `(e, n, dirE, dirN)`: the final pose at `u = 1` IS the
///   stall pose, so "within 0.05 m and 2°" is a snap, not an IDM tolerance.
/// - **No trigonometry** (D27): Béziers and `sqrt` only, so two machines
///   agree bit for bit.
/// - The poses are colony-local east/north; heights come from R3's
///   `SiteChunkGeometry` by reference (§0 A14), never from a ground query.
library;

import 'dart:typed_data';

import '../site_access/site_access_plan.dart';
import 'lane_graph.dart';

/// The manoeuvre curves. See the library comment.
abstract final class SiteManoeuvre {
  /// The pose at [u] (0..1) of the manoeuvre into (or, reversed, out of)
  /// [stall] of [p] for direction bit [dir] (`kSiteDir*`), written into
  /// [out] at [o] as east, north, dirE, dirN.
  static void stallPose(SiteAccessPlan p, int stall, int dir, double u,
          Float64List out, int o) =>
      throw UnimplementedError('T4a C: SiteManoeuvre.stallPose');

  /// The pose at [u] (0..1) of a home back-out from [stall] of [p] through
  /// [join], reversing down the drive and swinging the tail upstream into
  /// road lane [lane] of [lg], written into [out] at [o] as east, north,
  /// dirE, dirN. `u = 1` is the car in its lane, nose downstream.
  static void backOutPose(SiteAccessPlan p, int join, int stall, int lane,
          LaneGraph lg, double u, Float64List out, int o) =>
      throw UnimplementedError('T4a C: SiteManoeuvre.backOutPose');
}
