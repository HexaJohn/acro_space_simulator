// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a dock may stand (docs/plans/factory-floors.md §10 item 3).
///
/// The playtest found docks "oddly sized, and placeable mid-hall": nothing
/// said a dock is a DOOR. Now a dock is a 4 m door in an outer wall with a
/// 4 × 6 m loading area inside it (2 × 3 tiles), and the truck that serves
/// it parks outside the wall. So:
///
/// * a dock's [Placement.dir] points from the door INTO the hall (the way
///   goods leave a receiving dock; the same convention every template's
///   docks already used), and its BACK edge — the door — must lie on the
///   hall's outer edge;
/// * the editor's ghost snaps to the nearest wall ([snapDockToWall]), so
///   the player never has to aim at the one valid row of tiles;
/// * a dock placed by the player is a "wall dock": its [Placement.span] is
///   [kDockSpan] and its footprint the full loading area. Older docks
///   (templates, saves from before item 3) have no span and keep their
///   original 2 × 1 footprint, so every template measures exactly as
///   before; their docks already sit on walls.
library;

import 'factory_entities.dart';
import 'factory_grid.dart';

/// A wall dock's footprint, east-facing: 3 tiles deep into the hall (6 m)
/// by 2 tiles of door (4 m). Rotated by [Placement.dir] like any fixed
/// footprint.
const (int, int) kDockSpan = (3, 2);

/// Length of a parked truck outside the wall, tiles (a 12 m rig).
const int kTruckLengthTiles = 6;

bool isDockKind(EntityKind k) =>
    k == EntityKind.receivingDock || k == EntityKind.shippingDock;

/// A player-placed dock (the wall-dock footprint), as opposed to a legacy
/// spanless dock from a template or an old save.
bool isWallDock(Placement p) => isDockKind(p.kind) && p.span != null;

/// Whether [p]'s door — the edge behind its facing — lies on the outer
/// edge of [hall], with the whole footprint inside.
bool dockOnOuterWall(Placement p, HallSize hall) {
  final f = p.footprint;
  if (!hall.rect.containsRect(f)) return false;
  return switch (p.dir) {
    Dir4.east => f.x0 == 0,
    Dir4.north => f.y0 == 0,
    Dir4.west => f.x1 == hall.w,
    Dir4.south => f.y1 == hall.h,
  };
}

/// The wall dock of [kind] whose door is nearest [cursor]: the door
/// centred on the cursor along that wall (clamped to the hall), the
/// loading area reaching inward. Ties between walls go west, east, south,
/// north, so the snap is deterministic. [item] is carried onto the
/// placement unchanged.
Placement snapDockToWall(HallSize hall, TilePos cursor, EntityKind kind,
    {String? item}) {
  final (deep, door) = kDockSpan;
  int clampTo(int v, int max) => v < 0 ? 0 : (v > max ? max : v);
  final cx = clampTo(cursor.x, hall.w - 1), cy = clampTo(cursor.y, hall.h - 1);
  final dWest = cx, dEast = hall.w - 1 - cx;
  final dSouth = cy, dNorth = hall.h - 1 - cy;
  var best = dWest;
  var dir = Dir4.east;
  if (dEast < best) {
    best = dEast;
    dir = Dir4.west;
  }
  if (dSouth < best) {
    best = dSouth;
    dir = Dir4.north;
  }
  if (dNorth < best) {
    best = dNorth;
    dir = Dir4.south;
  }
  // The door is `door` tiles along the wall: start it so the cursor sits
  // on its first tile (the ghost's anchor), kept inside the hall.
  final along = door - 1;
  final TilePos pos = switch (dir) {
    Dir4.east => TilePos(0, clampTo(cy - along ~/ 2, hall.h - door)),
    Dir4.west => TilePos(hall.w - deep, clampTo(cy - along ~/ 2, hall.h - door)),
    Dir4.north => TilePos(clampTo(cx - along ~/ 2, hall.w - door), 0),
    Dir4.south => TilePos(clampTo(cx - along ~/ 2, hall.w - door), hall.h - deep),
  };
  return Placement(
      id: 0, kind: kind, pos: pos, dir: dir, item: item, span: kDockSpan);
}

/// The door tiles' outside neighbours: where the truck backs up to. A
/// rectangle [kTruckLengthTiles] long behind the dock's back edge, as wide
/// as the door. May lie outside the hall (it is meant to).
TileRect truckBayOf(Placement p) {
  final f = p.footprint;
  const l = kTruckLengthTiles;
  return switch (p.dir) {
    Dir4.east => TileRect(f.x0 - l, f.y0, l, f.h),
    Dir4.west => TileRect(f.x1, f.y0, l, f.h),
    Dir4.north => TileRect(f.x0, f.y0 - l, f.w, l),
    Dir4.south => TileRect(f.x0, f.y1, f.w, l),
  };
}
