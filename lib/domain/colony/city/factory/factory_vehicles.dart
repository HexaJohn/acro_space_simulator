// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How each kind of handler gets around, and what keeps it running
/// (docs/plans/factory-floors.md §3 "Material handling", phase 4).
///
/// The user's brief: workers move freight with heavy vehicles — pallet
/// jacks, forklifts, overhead cranes — or on their own, and very few plants
/// are lights-out. So every kind is simulated, and each pays for itself in
/// FLOOR SPACE, which is the design puzzle:
///
/// * **Walkers and pallet jacks** go anywhere a person can walk.
/// * **Forklifts and AGVs** drive only on marked floor (aisle, staging,
///   charging bay) that is wide enough for them: see [driveMask] for the
///   tiles they may cover and [driveAnchors] for how they path. A forklift
///   with no drivable route to a job is never sent; the job waits, and that
///   waiting queue is the "lay an aisle" signal.
/// * **Cranes** run on a fixed runway (a crane bay) and pass over
///   everything in it, machines included; they work only what lies under
///   or beside their bay.
/// * **Battery vehicles** (forklift, AGV) run down while they work and
///   recharge at a charging bay; with no bay they work until flat.
///
/// Each kind paths on its own LAYER (a passability mask) with its own flow
/// fields, all in the floor's one bounded field cache keyed by
/// (layer, target), so adding vehicles never multiplies BFS work beyond the
/// targets they really visit.
///
/// **No handler-handler collision**, deliberately: two forklifts may share
/// an aisle tile and any number of vehicles may share a charging bay.
/// Modelling traffic would make the dispatcher order-dependent and the
/// floor far costlier to measure, for little design value at this scale —
/// aisle WIDTH is the space cost a designer pays, not congestion.
///
/// **Time scale.** Floor seconds are colony seconds, and a colony day is
/// 120 s, so battery figures are gameplay-scaled, not real hours: a shift's
/// charge lasts a few colony days of steady work, and a recharge takes
/// about half a day.
library;

import 'dart:typed_data';

import 'factory_grid.dart';
import 'factory_handling.dart';

/// Tie-break between handlers equally near a job: the cheapest capable kind
/// goes, so a walker carries a box before a forklift is spent on it and a
/// crane is the last resort. Lower = cheaper to run (walker < jack <
/// forklift < AGV < crane). Not the enum order, which is fixed by saves.
const Map<HandlerKind, int> kHandlerCostRank = {
  HandlerKind.onFoot: 0,
  HandlerKind.palletJack: 1,
  HandlerKind.forklift: 2,
  HandlerKind.agv: 3,
  HandlerKind.crane: 4,
};

/// Seconds of work a full battery gives: 360 s, three colony days of steady
/// driving — a forklift's shift charge, gameplay-scaled. An AGV crawls
/// slower and lighter, so its pack lasts longer.
const Map<HandlerKind, double> kBatteryRuntimeS = {
  HandlerKind.forklift: 360,
  HandlerKind.agv: 480,
};

/// Seconds a flat battery takes to fill at full power: 60 s, half a colony
/// day — a fast-charge bay. A brownout charges slower in proportion.
const Map<HandlerKind, double> kBatteryChargeS = {
  HandlerKind.forklift: 60,
  HandlerKind.agv: 90,
};

/// A battery vehicle at or below this share of its runtime heads for a
/// charging bay once it has finished its current trip. 20% is a trip's
/// reserve with plenty to spare on any hall a template uses.
const double kBatteryLowFrac = 0.2;

/// Whether [kind] runs on a battery.
bool isBatteryKind(HandlerKind kind) => kBatteryRuntimeS.containsKey(kind);

/// Seconds an automated station may run unmaintained before it breaks
/// down: 240 s, two colony days without its technician. Wear is a plain
/// accumulator (no RNG): it grows while the station works without its
/// technician share and drains at the same rate while it has one.
const double kWearToBreakS = 240;

/// Seconds of technician time a broken station needs to run again: 30 s, a
/// quarter of a colony day.
const double kRepairS = 30;

/// Path layer of walkers and pallet jacks: every walkable tile.
const int kWalkLayer = 0;

/// The layer vehicles needing an aisle [width] tiles wide drive on (2 for
/// forklifts and AGVs). Crane layers are negative (`-bayId`), so the keys
/// never collide.
int driveLayer(int width) => width <= 1 ? kWalkLayer : width;

/// The layer a crane bound to bay [bayId] runs on.
int craneLayer(int bayId) => -bayId;

/// Tiles a vehicle needing [width]-wide aisles may drive on, from [marked]
/// (1 = an aisle, staging or charging-bay tile with nothing solid on it
/// that blocks walking), row-major `y * w + x`.
///
/// **"Wide enough", precisely:** a tile is drivable iff SOME [width] ×
/// [width] square of tiles containing it — in any alignment — lies wholly
/// on marked tiles inside the hall. That is the morphological opening of
/// the marked area by the vehicle's square: a 2-wide aisle is drivable
/// along its whole length (corners and T-junctions included), a 1-wide
/// aisle is not drivable anywhere, and a 1-tile spur off a 2-wide aisle is
/// not drivable either. Width ≤ 1 returns the marked tiles themselves.
///
/// This is the set of tiles a vehicle may COVER (what the editor shades as
/// drivable), not its connectivity: two 2-wide runs offset diagonally by
/// one tile share a single tile, which joins them in this mask although no
/// 2 × 2 vehicle could sweep through. Vehicles path on [driveAnchors].
Uint8List driveMask(HallSize hall, Uint8List marked, int width) {
  final w = hall.w, h = hall.h;
  assert(marked.length == w * h);
  final out = Uint8List(w * h);
  if (width <= 1) {
    out.setAll(0, marked);
    return out;
  }
  if (w < width || h < width) return out;
  // Summed-area table: any square's marked count in four lookups.
  final sw = w + 1;
  final sum = Int32List(sw * (h + 1));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      sum[(y + 1) * sw + x + 1] =
          marked[y * w + x] +
          sum[y * sw + x + 1] +
          sum[(y + 1) * sw + x] -
          sum[y * sw + x];
    }
  }
  final full = width * width;
  for (var y0 = 0; y0 + width <= h; y0++) {
    for (var x0 = 0; x0 + width <= w; x0++) {
      final y1 = y0 + width, x1 = x0 + width;
      final n =
          sum[y1 * sw + x1] -
          sum[y0 * sw + x1] -
          sum[y1 * sw + x0] +
          sum[y0 * sw + x0];
      if (n != full) continue;
      for (var y = y0; y < y1; y++) {
        out.fillRange(y * w + x0, y * w + x1, 1);
      }
    }
  }
  return out;
}

/// Where a vehicle needing [width]-wide aisles may STAND, as anchors: tile
/// (x, y) is 1 iff the [width] × [width] square whose low-x, low-y corner it
/// is lies wholly on [marked] tiles inside the hall. Vehicles path on this
/// mask (the configuration space) with 4-neighbour moves, so a step from
/// one anchor to the next is the whole square sliding one tile — every
/// tile it sweeps is marked. That is what makes "wide enough" hold for
/// CONNECTIVITY too: a 1-tile neck between two wide runs ([driveMask]
/// joins them) has no anchor path through it. A vehicle's `at` tile is its
/// anchor; it works a target from any anchor whose square touches one of
/// the target's drivable work tiles. Width ≤ 1 returns [marked] itself.
Uint8List driveAnchors(HallSize hall, Uint8List marked, int width) {
  final w = hall.w, h = hall.h;
  assert(marked.length == w * h);
  final out = Uint8List(w * h);
  if (width <= 1) {
    out.setAll(0, marked);
    return out;
  }
  if (w < width || h < width) return out;
  for (var y0 = 0; y0 + width <= h; y0++) {
    for (var x0 = 0; x0 + width <= w; x0++) {
      var full = true;
      for (var y = y0; y < y0 + width && full; y++) {
        for (var x = x0; x < x0 + width; x++) {
          if (marked[y * w + x] != 1) {
            full = false;
            break;
          }
        }
      }
      if (full) out[y0 * w + x0] = 1;
    }
  }
  return out;
}
