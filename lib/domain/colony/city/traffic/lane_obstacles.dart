// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Obstacles in a road lane that are not vehicles on its list
/// (docs/plans/t4a-implementation.md §1.6, §2; site-access.md §7.4).
///
/// A home back-out claims a footprint `[T − 10, T + 2]` in its target lane
/// before its body is in that lane, and a far-direction back-out claims the
/// near lane it swings across without ever being on it. Followers must stop
/// short of both, so the road mover asks this seam as it asks for a leader.
///
/// It lives in its own library so the road mover can import it, and the
/// site mover that implements it can import the road mover, with no cycle.
library;

import 'dart:typed_data';

/// What the road mover asks about obstacles ahead in a lane
/// (`VehicleMover.obstacles`). Implemented by `SiteMover`.
abstract interface class LaneObstacles {
  /// Obstacles standing now. The mover asks [obstacleAhead] only while this
  /// is above 0, so a colony with no back-out in progress pays one compare
  /// per moved vehicle.
  int get count;

  /// Whether an obstacle stands in [lane] ahead of [laneS] lane metres (a
  /// front position; negative for a vehicle still on the connector into
  /// [lane]). When one does, writes into [out] the lane metres of the
  /// nearest one's near (upstream) end at `out[0]`, and its speed in m/s at
  /// `out[1]` (0 for a claim or a stopped footprint). Allocation-free: it is
  /// asked once per moved vehicle per sub-step.
  bool obstacleAhead(int lane, double laneS, Float64List out);
}
