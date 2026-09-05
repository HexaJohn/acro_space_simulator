// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A tile's members as typed columns: the shape a tile crosses to a worker
/// in.
///
/// The request used to carry the tile's snapshot OBJECTS, and an isolate
/// send deep-copies whatever it is handed on the sending thread — every
/// snapshot's four strings, every road's points as a growable list of
/// boxed doubles (a near tile: two hundred roads, forty points each, three
/// doubles a point — twenty-odd thousand heap objects), every bridge list,
/// every record. Measured on the moving-camera sweep, one tile's send was
/// up to twenty-five milliseconds of the UI thread: the single worst
/// per-frame cost left in the colony renderer, and the one the budget
/// loop cannot slice.
///
/// A typed list crosses as ONE block — the VM copies its bytes with a
/// memcpy and never walks its elements — so the same tile packed into a
/// few `Float64List`s and `Int32List`s is a fraction of a millisecond to
/// send, however many points its roads have. The only strings that still
/// travel are the ones the meshing needs as strings: each building's id
/// (the archetype seed), and the type, colony and body names, which repeat
/// across a tile and go once each through a small per-tile table.
///
/// The application snapshots are the wire format and stay as they are;
/// this is the renderer's own packing of them, built once per tile on the
/// UI thread ([fromSnapshots]), sent as many times as the tile is re-keyed
/// (a tier change, a camera cell crossed), and unpacked back into the very
/// same snapshot classes on the worker ([toSnapshots]) so the mesher runs
/// unchanged over what it always read. The round trip is exact: every
/// field of every snapshot comes back equal, nulls included, which the
/// mesher's byte-identical output depends on.
library;

import 'dart:typed_data';

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/shared/vector3.dart';

/// A road end that falls in a tile: where, the point just inside it, and
/// what the road is. Body-fixed; the junction pass anchors it.
class CityTileEnd {
  const CityTileEnd(this.at, this.next, this.halfWidthM, this.roadClass,
      this.paved, this.collector);
  final Vector3 at, next;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved, collector;
}

/// A tile's members as the mesher reads them: the snapshot lists, rebuilt
/// from [CityTileColumns] on the side that meshes.
class CityTileMembers {
  const CityTileMembers({
    required this.buildings,
    required this.roads,
    required this.patches,
    required this.ends,
    required this.roadEnds,
    required this.transitEnds,
  });

  final List<BuildingSnapshot> buildings;
  final List<RoadSnapshot> roads;
  final List<CityPatchSnapshot> patches;
  final List<CityTileEnd> ends;

  /// Per road, in [roads] order: what the body's end table says of its two
  /// ends — the widest carriageway meeting the end and how many ends meet
  /// there — at `[2 * i]` for the road's first point and `[2 * i + 1]` for
  /// its last, or null where the table has no entry (elevated roads are
  /// not tabled).
  final List<(double, int)?> roadEnds;

  /// Every end of elevated rail on the body within reach of an end of one
  /// of the tile's transit roads, body-fixed: what decides whether an end
  /// is free and takes a terminal.
  final List<Vector3> transitEnds;
}

/// One tile's buildings, roads, patches and ends as typed columns.
///
/// Every numeric field is a `Float64List` (positions, quaternions, sizes,
/// half widths, the roads' points and bridge spans concatenated with a
/// list of per-road starts), every enum, count and flag an `Int32List`,
/// the facade colours a `Uint32List` — ARGB is an unsigned word, and a
/// signed column would hand back a negative — and the strings the meshing
/// cannot do without a `List<String>`. Plain typed lists, on purpose, not
/// a `TransferableTypedData`: a transfer CONSUMES its lists, and a tile
/// sends the same columns every time it is re-keyed, so the packing must
/// survive the send. A plain typed list is copied as a block instead.
class CityTileColumns {
  const CityTileColumns._({
    required this.strings,
    required this.buildingIds,
    required this.buildingStrings,
    required this.buildingF,
    required this.buildingI,
    required this.buildingColors,
    required this.roadStrings,
    required this.roadPoints,
    required this.roadPointStarts,
    required this.roadBridges,
    required this.roadBridgeStarts,
    required this.roadF,
    required this.roadI,
    required this.patchStrings,
    required this.patchF,
    required this.patchKinds,
    required this.endF,
    required this.endI,
    required this.roadEndHalf,
    required this.roadEndCount,
    required this.transitEnds,
  });

  /// The per-tile string table: each distinct type, colony and body name
  /// once. The string columns hold indices into it.
  final List<String> strings;

  /// Building ids, one per building — the archetype seed, and the one
  /// string per member that cannot be tabled because it never repeats.
  final List<String> buildingIds;

  /// Per building: type, colonyId, body as [strings] indices.
  final Int32List buildingStrings;

  /// Per building: px, py, pz, qw, qx, qy, qz, lat, lon, siteWidthM,
  /// siteDepthM.
  final Float64List buildingF;

  /// Per building: siteKindIndex, flags ([cornerFlag]).
  final Int32List buildingI;

  /// Per building: colorArgb.
  final Uint32List buildingColors;

  /// Per road: colonyId, body as [strings] indices.
  final Int32List roadStrings;

  /// Every road's points, one after another; road i's are
  /// `[roadPointStarts[i], roadPointStarts[i + 1])`.
  final Float64List roadPoints;
  final Int32List roadPointStarts;

  /// Every road's bridge spans, likewise.
  final Float64List roadBridges;
  final Int32List roadBridgeStarts;

  /// Per road: halfWidthM, startHalfWidthM, endHalfWidthM — the last two
  /// meaningful only where the road's flags say the snapshot had them.
  final Float64List roadF;

  /// Per road: roadClassIndex, flags ([sealedFlag], [soundWallsFlag],
  /// [collectorFlag], [hasStartHalfFlag], [hasEndHalfFlag]).
  final Int32List roadI;

  /// Per patch: colonyId, body as [strings] indices.
  final Int32List patchStrings;

  /// Per patch: px, py, pz, qw, qx, qy, qz, sizeM, depthM.
  final Float64List patchF;

  /// Per patch: kind.
  final Int32List patchKinds;

  /// Per end: at (3), next (3), halfWidthM.
  final Float64List endF;

  /// Per end: roadClass index, flags ([pavedFlag], [collectorFlag]).
  final Int32List endI;

  /// Per road end (two per road, first then last): the widest half width
  /// meeting there, and how many ends meet — or [noEntry] where the body's
  /// table has none, in which case the half width is zero and unread.
  final Float64List roadEndHalf;
  final Int32List roadEndCount;

  /// Transit ends, three doubles each.
  final Float64List transitEnds;

  static const int cornerFlag = 1;
  static const int sealedFlag = 1;
  static const int soundWallsFlag = 2;
  static const int collectorFlag = 4;
  static const int hasStartHalfFlag = 8;
  static const int hasEndHalfFlag = 16;
  static const int pavedFlag = 1;
  static const int endCollectorFlag = 2;
  static const int noEntry = -1;

  static const int _buildingF = 11;
  static const int _patchF = 9;
  static const int _endF = 7;

  int get buildingCount => buildingIds.length;
  int get roadCount => roadPointStarts.length - 1;
  int get patchCount => patchKinds.length;
  int get endCount => endI.length ~/ 2;

  /// Bytes the send copies as blocks: every typed column. The strings are
  /// on top of this, one object each.
  int get typedBytes =>
      buildingStrings.lengthInBytes +
      buildingF.lengthInBytes +
      buildingI.lengthInBytes +
      buildingColors.lengthInBytes +
      roadStrings.lengthInBytes +
      roadPoints.lengthInBytes +
      roadPointStarts.lengthInBytes +
      roadBridges.lengthInBytes +
      roadBridgeStarts.lengthInBytes +
      roadF.lengthInBytes +
      roadI.lengthInBytes +
      patchStrings.lengthInBytes +
      patchF.lengthInBytes +
      patchKinds.lengthInBytes +
      endF.lengthInBytes +
      endI.lengthInBytes +
      roadEndHalf.lengthInBytes +
      roadEndCount.lengthInBytes +
      transitEnds.lengthInBytes;

  /// Pack a tile's members. [roadEnds] has two entries per road, in
  /// [roads] order (see [CityTileMembers.roadEnds]).
  factory CityTileColumns.fromSnapshots({
    required List<BuildingSnapshot> buildings,
    required List<RoadSnapshot> roads,
    required List<CityPatchSnapshot> patches,
    required List<CityTileEnd> ends,
    required List<(double, int)?> roadEnds,
    required List<Vector3> transitEnds,
  }) {
    if (roadEnds.length != 2 * roads.length) {
      throw ArgumentError(
          'roadEnds has ${roadEnds.length} entries for ${roads.length} roads');
    }
    final table = <String>[];
    final index = <String, int>{};
    int intern(String s) => index.putIfAbsent(s, () {
          table.add(s);
          return table.length - 1;
        });

    final nb = buildings.length;
    final buildingIds = List<String>.generate(nb, (i) => buildings[i].id,
        growable: false);
    final buildingStrings = Int32List(nb * 3);
    final buildingF = Float64List(nb * _buildingF);
    final buildingI = Int32List(nb * 2);
    final buildingColors = Uint32List(nb);
    for (var i = 0; i < nb; i++) {
      final b = buildings[i];
      buildingStrings[i * 3] = intern(b.type);
      buildingStrings[i * 3 + 1] = intern(b.colonyId);
      buildingStrings[i * 3 + 2] = intern(b.body);
      final f = i * _buildingF;
      buildingF[f] = b.px;
      buildingF[f + 1] = b.py;
      buildingF[f + 2] = b.pz;
      buildingF[f + 3] = b.qw;
      buildingF[f + 4] = b.qx;
      buildingF[f + 5] = b.qy;
      buildingF[f + 6] = b.qz;
      buildingF[f + 7] = b.lat;
      buildingF[f + 8] = b.lon;
      buildingF[f + 9] = b.siteWidthM;
      buildingF[f + 10] = b.siteDepthM;
      buildingI[i * 2] = b.siteKindIndex;
      buildingI[i * 2 + 1] = b.corner ? cornerFlag : 0;
      buildingColors[i] = b.colorArgb;
    }

    final nr = roads.length;
    var pointCount = 0, bridgeCount = 0;
    for (final r in roads) {
      pointCount += r.points.length;
      bridgeCount += r.bridges.length;
    }
    final roadStrings = Int32List(nr * 2);
    final roadPoints = Float64List(pointCount);
    final roadPointStarts = Int32List(nr + 1);
    final roadBridges = Float64List(bridgeCount);
    final roadBridgeStarts = Int32List(nr + 1);
    final roadF = Float64List(nr * 3);
    final roadI = Int32List(nr * 2);
    final roadEndHalf = Float64List(nr * 2);
    final roadEndCount = Int32List(nr * 2);
    var pAt = 0, bAt = 0;
    for (var i = 0; i < nr; i++) {
      final r = roads[i];
      roadStrings[i * 2] = intern(r.colonyId);
      roadStrings[i * 2 + 1] = intern(r.body);
      roadPointStarts[i] = pAt;
      roadPoints.setRange(pAt, pAt + r.points.length, r.points);
      pAt += r.points.length;
      roadBridgeStarts[i] = bAt;
      roadBridges.setRange(bAt, bAt + r.bridges.length, r.bridges);
      bAt += r.bridges.length;
      roadF[i * 3] = r.halfWidthM;
      roadF[i * 3 + 1] = r.startHalfWidthM ?? 0;
      roadF[i * 3 + 2] = r.endHalfWidthM ?? 0;
      roadI[i * 2] = r.roadClassIndex;
      roadI[i * 2 + 1] = (r.sealed ? sealedFlag : 0) |
          (r.soundWalls ? soundWallsFlag : 0) |
          (r.collector ? collectorFlag : 0) |
          (r.startHalfWidthM != null ? hasStartHalfFlag : 0) |
          (r.endHalfWidthM != null ? hasEndHalfFlag : 0);
      for (var k = 0; k < 2; k++) {
        final e = roadEnds[i * 2 + k];
        roadEndHalf[i * 2 + k] = e?.$1 ?? 0;
        roadEndCount[i * 2 + k] = e?.$2 ?? noEntry;
      }
    }
    roadPointStarts[nr] = pAt;
    roadBridgeStarts[nr] = bAt;

    final np = patches.length;
    final patchStrings = Int32List(np * 2);
    final patchF = Float64List(np * _patchF);
    final patchKinds = Int32List(np);
    for (var i = 0; i < np; i++) {
      final p = patches[i];
      patchStrings[i * 2] = intern(p.colonyId);
      patchStrings[i * 2 + 1] = intern(p.body);
      final f = i * _patchF;
      patchF[f] = p.px;
      patchF[f + 1] = p.py;
      patchF[f + 2] = p.pz;
      patchF[f + 3] = p.qw;
      patchF[f + 4] = p.qx;
      patchF[f + 5] = p.qy;
      patchF[f + 6] = p.qz;
      patchF[f + 7] = p.sizeM;
      patchF[f + 8] = p.depthM;
      patchKinds[i] = p.kind;
    }

    final ne = ends.length;
    final endF = Float64List(ne * _endF);
    final endI = Int32List(ne * 2);
    for (var i = 0; i < ne; i++) {
      final e = ends[i];
      final f = i * _endF;
      endF[f] = e.at.x;
      endF[f + 1] = e.at.y;
      endF[f + 2] = e.at.z;
      endF[f + 3] = e.next.x;
      endF[f + 4] = e.next.y;
      endF[f + 5] = e.next.z;
      endF[f + 6] = e.halfWidthM;
      endI[i * 2] = e.roadClass.index;
      endI[i * 2 + 1] =
          (e.paved ? pavedFlag : 0) | (e.collector ? endCollectorFlag : 0);
    }

    final transit = Float64List(transitEnds.length * 3);
    for (var i = 0; i < transitEnds.length; i++) {
      transit[i * 3] = transitEnds[i].x;
      transit[i * 3 + 1] = transitEnds[i].y;
      transit[i * 3 + 2] = transitEnds[i].z;
    }

    return CityTileColumns._(
      strings: List<String>.of(table, growable: false),
      buildingIds: buildingIds,
      buildingStrings: buildingStrings,
      buildingF: buildingF,
      buildingI: buildingI,
      buildingColors: buildingColors,
      roadStrings: roadStrings,
      roadPoints: roadPoints,
      roadPointStarts: roadPointStarts,
      roadBridges: roadBridges,
      roadBridgeStarts: roadBridgeStarts,
      roadF: roadF,
      roadI: roadI,
      patchStrings: patchStrings,
      patchF: patchF,
      patchKinds: patchKinds,
      endF: endF,
      endI: endI,
      roadEndHalf: roadEndHalf,
      roadEndCount: roadEndCount,
      transitEnds: transit,
    );
  }

  /// The members back as snapshots, field for field.
  ///
  /// A road's points and bridges come back as `Float64List` VIEWS over the
  /// columns rather than growable copies: the mesher only reads them, a
  /// view costs nothing to make, and the doubles are the same doubles, so
  /// the geometry is the geometry the snapshot objects gave.
  CityTileMembers toSnapshots() {
    final nb = buildingCount;
    final buildings = List<BuildingSnapshot>.generate(nb, (i) {
      final f = i * _buildingF;
      return BuildingSnapshot(
        id: buildingIds[i],
        type: strings[buildingStrings[i * 3]],
        colonyId: strings[buildingStrings[i * 3 + 1]],
        body: strings[buildingStrings[i * 3 + 2]],
        px: buildingF[f],
        py: buildingF[f + 1],
        pz: buildingF[f + 2],
        qw: buildingF[f + 3],
        qx: buildingF[f + 4],
        qy: buildingF[f + 5],
        qz: buildingF[f + 6],
        lat: buildingF[f + 7],
        lon: buildingF[f + 8],
        siteWidthM: buildingF[f + 9],
        siteDepthM: buildingF[f + 10],
        siteKindIndex: buildingI[i * 2],
        corner: buildingI[i * 2 + 1] & cornerFlag != 0,
        colorArgb: buildingColors[i],
      );
    }, growable: false);

    final nr = roadCount;
    final roads = List<RoadSnapshot>.generate(nr, (i) {
      final flags = roadI[i * 2 + 1];
      return RoadSnapshot(
        colonyId: strings[roadStrings[i * 2]],
        body: strings[roadStrings[i * 2 + 1]],
        points: Float64List.sublistView(
            roadPoints, roadPointStarts[i], roadPointStarts[i + 1]),
        halfWidthM: roadF[i * 3],
        roadClassIndex: roadI[i * 2],
        sealed: flags & sealedFlag != 0,
        soundWalls: flags & soundWallsFlag != 0,
        collector: flags & collectorFlag != 0,
        bridges: Float64List.sublistView(
            roadBridges, roadBridgeStarts[i], roadBridgeStarts[i + 1]),
        startHalfWidthM: flags & hasStartHalfFlag != 0 ? roadF[i * 3 + 1] : null,
        endHalfWidthM: flags & hasEndHalfFlag != 0 ? roadF[i * 3 + 2] : null,
      );
    }, growable: false);
    final roadEnds = List<(double, int)?>.generate(nr * 2, (i) {
      final n = roadEndCount[i];
      return n == noEntry ? null : (roadEndHalf[i], n);
    }, growable: false);

    final patches = List<CityPatchSnapshot>.generate(patchCount, (i) {
      final f = i * _patchF;
      return CityPatchSnapshot(
        colonyId: strings[patchStrings[i * 2]],
        body: strings[patchStrings[i * 2 + 1]],
        px: patchF[f],
        py: patchF[f + 1],
        pz: patchF[f + 2],
        qw: patchF[f + 3],
        qx: patchF[f + 4],
        qy: patchF[f + 5],
        qz: patchF[f + 6],
        sizeM: patchF[f + 7],
        depthM: patchF[f + 8],
        kind: patchKinds[i],
      );
    }, growable: false);

    final ends = List<CityTileEnd>.generate(endCount, (i) {
      final f = i * _endF;
      final flags = endI[i * 2 + 1];
      return CityTileEnd(
        Vector3(endF[f], endF[f + 1], endF[f + 2]),
        Vector3(endF[f + 3], endF[f + 4], endF[f + 5]),
        endF[f + 6],
        RoadClass.values[endI[i * 2]],
        flags & pavedFlag != 0,
        flags & endCollectorFlag != 0,
      );
    }, growable: false);

    final transit = List<Vector3>.generate(
        transitEnds.length ~/ 3,
        (i) => Vector3(
            transitEnds[i * 3], transitEnds[i * 3 + 1], transitEnds[i * 3 + 2]),
        growable: false);

    return CityTileMembers(
      buildings: buildings,
      roads: roads,
      patches: patches,
      ends: ends,
      roadEnds: roadEnds,
      transitEnds: transit,
    );
  }
}
