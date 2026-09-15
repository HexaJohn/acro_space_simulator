// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's site access plans on the wire (docs/plans/site-access.md §5.2,
/// §6.4): the book's published chunks by reference, the heights a renderer
/// needs to put their points down, and the capture cache that keeps a
/// steady frame to a few identity compares.
///
/// - **By reference.** A [SiteChunkGeometry] holds the domain
///   [SiteAccessChunk] itself and two typed lists of its own: per point its
///   height above the body datum, per stall the pave under it, per site its
///   steepest drive (diagnostic), its tile key term and its book slot. A
///   chunk's geometry is built when the chunk's identity or the ground
///   stamp moves, never per frame, and a rebuild whose quantised heights did
///   not move keeps the old object.
/// - **Heights (§6.4)**, as road points are placed: `localToBodyFixed` at a
///   radius along the colony's up, so a point is
///   `up·(R + ptUp) + east·e + north·n`. A pad point stands on its lot's
///   cached pad ground (`groundFor('lot:<id>')`); on a draped lot a pad
///   point more than [padReachM] from the centroid takes one cached ground
///   sample of its own (`site:<id>:<point>`), paid once per plan; a kerb
///   point stands on its join road's drape at the join; a blend point
///   between the two by its `ptHT`. The corridor and pad datums of the
///   terrain slice (R5) are not read yet.
/// - **Kerb cuts** ([KerbCuts]): the canonical table is built per chunk set
///   and road graph, and each road's drawn copy per drape.
///
/// NOT the traffic contract: traffic reads the book. Serialised in a JSON
/// frame (a renderer must build a colony from a frame alone) and left out
/// of the fingerprint.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/colony/city/city_sim.dart';
import '../../domain/colony/city/hash32.dart';
import '../../domain/colony/city/parcel.dart';
import '../../domain/colony/city/road_graph.dart';
import '../../domain/colony/city/site_access/kerb_cuts.dart';
import '../../domain/colony/city/site_access/site_access_book.dart';
import '../../domain/colony/city/site_access/site_access_constants.dart';
import '../../domain/colony/city/site_access/site_access_plan.dart';
import '../../domain/shared/vector3.dart';

/// One chunk's heights and keys, beside the chunk itself. Retains at most
/// three objects: itself, one Float32List and one Int32List (§2.3).
class SiteChunkGeometry {
  SiteChunkGeometry._(this.plan, this.chunkIndex, this._f32, this._i32)
      : _pointRows = plan.ptStart(plan.siteCount),
        _stallRows = plan.stallStart(plan.siteCount);

  /// [f32] and [i32] in this layout, taken, not copied:
  /// `f32 = [ptUp × points][stallUp × stalls][siteMaxGrade × sites]`,
  /// `i32 = [siteKey × sites][siteSlot × sites]`.
  factory SiteChunkGeometry.adopt(
      {required SiteAccessChunk plan,
      required int chunkIndex,
      required Float32List f32,
      required Int32List i32}) {
    final s = plan.siteCount;
    final want = plan.ptStart(s) + plan.stallStart(s) + s;
    if (f32.length != want || i32.length != 2 * s) {
      throw ArgumentError('geometry of ${f32.length}/${i32.length} for a '
          'chunk wanting $want/${2 * s}');
    }
    return SiteChunkGeometry._(plan, chunkIndex, f32, i32);
  }

  /// The domain chunk, by identity.
  final SiteAccessChunk plan;

  /// The book's chunk index (`slot >> 10`), or −1 in a subset frame.
  final int chunkIndex;

  final Float32List _f32;
  final Int32List _i32;
  final int _pointRows, _stallRows;

  int get siteCount => plan.siteCount;

  /// Metres above the body datum radius, along the colony's up, of
  /// chunk-global point [row].
  double ptUp(int row) => _f32[row];

  /// The pave under chunk-global stall [row], as [ptUp].
  double stallUp(int row) => _f32[_pointRows + row];

  /// The steepest rise over run of [site]'s drives: diagnostics and the
  /// overlay only, never read by the sim.
  double siteMaxGrade(int site) => _f32[_pointRows + _stallRows + site];

  /// [site]'s tile key term: its `rev` mixed with its quantised heights.
  int siteKey(int site) => _i32[site];

  /// [site]'s book slot (`BuildingSnapshot.siteSlot`).
  int siteSlot(int site) => _i32[siteCount + site];

  /// The site holding book slot [slot], or −1. Slots ascend with rows.
  int rowOfSlot(int slot) {
    var lo = 0, hi = siteCount - 1;
    final base = siteCount;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = _i32[base + mid];
      if (v < slot) {
        lo = mid + 1;
      } else if (v > slot) {
        hi = mid - 1;
      } else {
        return mid;
      }
    }
    // A subset frame keeps its rows in the caller's order.
    if (chunkIndex < 0) {
      for (var k = 0; k < siteCount; k++) {
        if (_i32[base + k] == slot) return k;
      }
    }
    return -1;
  }

  /// Tests only: the two lists this retains.
  List<Object> get debugRetained => [_f32, _i32];

  /// Bytes of the two lists.
  int get byteLength => _f32.lengthInBytes + _i32.lengthInBytes;

  /// Tests only: this geometry with site [site]'s key replaced.
  SiteChunkGeometry debugWithSiteKey(int site, int key) => SiteChunkGeometry._(
      plan, chunkIndex, _f32, Int32List.fromList(_i32)..[site] = key);
}

/// One colony's site access on the frame (§5.2).
class CitySiteFrame {
  CitySiteFrame({
    required this.colonyId,
    required this.bodyId,
    required this.sitesRev,
    required this.geometryStamp,
    required this.datumRadiusM,
    required this.up,
    required this.east,
    required this.north,
    required this.chunks,
  });

  final String colonyId, bodyId;

  /// The book's `sitesRev` when captured.
  final int sitesRev;

  /// Moves when some site's key, or the kerb cuts, changed.
  final int geometryStamp;

  /// The body's datum radius, and the colony's tangent frame: a point
  /// (e, n) of height `ptUp` is `up·(datum + ptUp) + east·e + north·n`.
  final double datumRadiusM;
  final Vector3 up, east, north;

  /// Per book chunk index, in order (a capture's); or a tile's own sites
  /// (a subset, [SiteChunkGeometry.chunkIndex] −1).
  final List<SiteChunkGeometry> chunks;

  int get siteCount => chunks.fold(0, (n, c) => n + c.siteCount);

  /// The geometry and row of book slot [siteSlot], or null.
  (SiteChunkGeometry, int)? locate(int siteSlot) {
    if (siteSlot < 0) return null;
    final c = siteSlot ~/ kSitesPerChunk;
    if (c < chunks.length && chunks[c].chunkIndex == c) {
      final row = chunks[c].rowOfSlot(siteSlot);
      return row < 0 ? null : (chunks[c], row);
    }
    for (final g in chunks) {
      if (g.chunkIndex >= 0 && g.chunkIndex != c) continue;
      final row = g.rowOfSlot(siteSlot);
      if (row >= 0) return (g, row);
    }
    return null;
  }

  /// Body-fixed metres of local ([e], [n]) at [upM] above the datum.
  Vector3 localToBodyFixed(double e, double n, double upM) => Vector3(
        up.x * (datumRadiusM + upM) + east.x * e + north.x * n,
        up.y * (datumRadiusM + upM) + east.y * e + north.y * n,
        up.z * (datumRadiusM + upM) + east.z * e + north.z * n,
      );

  /// The centre of [site]'s envelope, body-fixed at the datum: what a tile
  /// cut buckets the site by (§5.3). Frame metres into colony-local ones:
  /// `origin + u·x + v·y`, `v` being `u` turned a quarter counter-clockwise.
  static (double, double) envelopeCentreLocal(SiteAccessChunk c, int site) {
    final x = (c.envX0(site) + c.envX1(site)) / 2;
    final y = (c.envY0(site) + c.envY1(site)) / 2;
    final ue = c.frameUE(site), un = c.frameUN(site);
    return (c.frameE(site) + ue * x - un * y, c.frameN(site) + un * x + ue * y);
  }

  /// [site]'s building heading, radians in the `Parcel.heading` convention
  /// (§3.1): spinning a building by `−buildingHeading` puts its local +Y on
  /// the frame's `v` (into the lot) and its local +X on `u` (along the
  /// frontage), so the envelope, the gate and the door share the building's
  /// axes by construction.
  ///
  /// Read off the stored frame vector rather than rebuilt from the lot: a
  /// plan is a pure function of the layout it was made against, and a
  /// re-derived frame would turn a saved building on a lot whose polygon has
  /// since been re-sampled.
  static double buildingHeadingOf(SiteAccessChunk c, int site) {
    // v = u.perp = (−u.n, u.e), so the street side −v is (u.n, −u.e).
    // Written as `0 ± x` so no component is −0.0 (see `SiteFrame`).
    final ue = c.frameUE(site), un = c.frameUN(site);
    return Vec2(0.0 + un, 0.0 - ue).heading + math.pi;
  }

  /// A frame of just [rows] (geometry, site), in that order: the sites a
  /// tile or a detail job sends a worker (§5.3). Chunks of at most
  /// [kSitesPerChunk] sites, packed as the book packs them; heights and keys
  /// copied row for row.
  CitySiteFrame subset(List<(SiteChunkGeometry, int)> rows) {
    final out = <SiteChunkGeometry>[];
    for (var a = 0; a < rows.length; a += kSitesPerChunk) {
      final b = a + kSitesPerChunk < rows.length ? a + kSitesPerChunk : rows.length;
      final part = rows.sublist(a, b);
      final plan = SiteAccessBook.repack([for (final (g, k) in part) (g.plan, k)]);
      final s = plan.siteCount;
      final f32 = Float32List(plan.ptStart(s) + plan.stallStart(s) + s);
      final i32 = Int32List(2 * s);
      var pAt = 0, stAt = 0;
      final stBase = plan.ptStart(s), gBase = stBase + plan.stallStart(s);
      for (var i = 0; i < s; i++) {
        final (g, k) = part[i];
        final src = g.plan;
        final p0 = src.ptStart(k), p1 = src.ptStart(k + 1);
        f32.setRange(pAt, pAt + p1 - p0, g._f32, p0);
        pAt += p1 - p0;
        final t0 = src.stallStart(k), t1 = src.stallStart(k + 1);
        f32.setRange(stBase + stAt, stBase + stAt + t1 - t0, g._f32,
            g._pointRows + t0);
        stAt += t1 - t0;
        f32[gBase + i] = g.siteMaxGrade(k);
        i32[i] = g.siteKey(k);
        i32[s + i] = g.siteSlot(k);
      }
      out.add(SiteChunkGeometry._(plan, -1, f32, i32));
    }
    return CitySiteFrame(
      colonyId: colonyId,
      bodyId: bodyId,
      sitesRev: sitesRev,
      geometryStamp: geometryStamp,
      datumRadiusM: datumRadiusM,
      up: up,
      east: east,
      north: north,
      chunks: out,
    );
  }

  // ---- JSON ------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'colony': colonyId,
        'body': bodyId,
        'rev': sitesRev,
        'stamp': geometryStamp,
        'datum': datumRadiusM,
        'basis': [up.x, up.y, up.z, east.x, east.y, east.z, north.x, north.y, north.z],
        'chunks': [
          for (final g in chunks)
            {
              'i': g.chunkIndex,
              'ids': g.plan.siteIds,
              'f64': _doubles(g.plan.debugRetained[0] as List<double>),
              'f32': _doubles(g.plan.debugRetained[1] as List<double>),
              'i32': g.plan.debugRetained[2],
              'u8': g.plan.debugRetained[3],
              'off': g.plan.debugRetained[4],
              'gf': _doubles(g._f32),
              'gi': g._i32,
            },
        ],
      };

  factory CitySiteFrame.fromJson(Map<String, dynamic> j) {
    final basis = [for (final v in j['basis'] as List) (v as num).toDouble()];
    return CitySiteFrame(
      colonyId: j['colony'] as String,
      bodyId: j['body'] as String,
      sitesRev: (j['rev'] as num).toInt(),
      geometryStamp: (j['stamp'] as num).toInt(),
      datumRadiusM: (j['datum'] as num).toDouble(),
      up: Vector3(basis[0], basis[1], basis[2]),
      east: Vector3(basis[3], basis[4], basis[5]),
      north: Vector3(basis[6], basis[7], basis[8]),
      chunks: [
        for (final c in (j['chunks'] as List).cast<Map<String, dynamic>>())
          () {
            final plan = SiteAccessChunk.adopt(
              siteId: [for (final s in c['ids'] as List) s as String],
              f64: Float64List.fromList(_undoubles(c['f64'] as List)),
              f32: Float32List.fromList(_undoubles(c['f32'] as List)),
              i32: Int32List.fromList(_ints(c['i32'] as List)),
              u8: Uint8List.fromList(_ints(c['u8'] as List)),
              offsets: Int32List.fromList(_ints(c['off'] as List)),
            );
            return SiteChunkGeometry.adopt(
              plan: plan,
              chunkIndex: (c['i'] as num).toInt(),
              f32: Float32List.fromList(_undoubles(c['gf'] as List)),
              i32: Int32List.fromList(_ints(c['gi'] as List)),
            );
          }(),
      ],
    );
  }

  /// JSON has no NaN or infinity: those go as strings.
  static List<Object> _doubles(List<double> xs) => [
        for (final x in xs) x.isFinite ? x : x.toString(),
      ];

  static List<double> _undoubles(List xs) => [
        for (final x in xs)
          x is num ? x.toDouble() : double.parse(x as String),
      ];

  static List<int> _ints(List xs) => [for (final x in xs) (x as num).toInt()];
}

/// Where a PLAN-SERVED building stands (docs/plans/site-access.md §5.2 R4,
/// §6.1): on its plan's envelope, turned to face its access road.
///
/// Everything here is read off the plan, so the building, the envelope, the
/// gate and the door cannot disagree: the renderer re-derives none of it.
class SitePlacement {
  const SitePlacement({
    required this.slot,
    required this.centreE,
    required this.centreN,
    required this.widthM,
    required this.depthM,
    required this.headingRad,
    required this.gateXM,
    required this.gateWM,
  });

  /// The book slot (`BuildingSnapshot.siteSlot`).
  final int slot;

  /// The envelope's centre in colony-local east/north metres.
  final double centreE, centreN;

  /// The envelope across the frontage (the building's local X) and into the
  /// lot (local Y). Zero on a plan whose envelope is empty — a degenerate or
  /// fully paved site — which keeps the legacy footprint.
  final double widthM, depthM;

  /// `SiteFrame.buildingHeading`: the building is spun by MINUS this (§3.1).
  final double headingRad;

  /// The plan's gate on the envelope's front edge: along local X from the
  /// envelope centre, and its width (0: none).
  final double gateXM, gateWM;

  /// Whether this plan actually carries an envelope to stand on.
  bool get hasEnvelope => widthM > 0 && depthM > 0;
}

/// Builds a colony's [CitySiteFrame] and its roads' kerb cuts for the
/// capture, from a cache that hangs off the colony (see the library docs).
class SiteCapture {
  SiteCapture._(this._city);

  static final Expando<SiteCapture> _cache = Expando<SiteCapture>('SiteCapture');

  /// Pad points of a draped lot this far from its centroid take a ground
  /// sample of their own (§6.4).
  static const double padReachM = 24.0;

  /// Work counted for tests and profiling: chunk geometries built, and
  /// canonical kerb-cut tables built.
  static int geometriesBuilt = 0, cutTablesBuilt = 0;

  /// Whether a plan-served building is placed on its plan's ENVELOPE, turned
  /// to face its access road (§5.2 R4, §6.2), rather than on the legacy
  /// centroid-and-`Parcel.heading` path. OFF by default.
  ///
  /// This is the storage behind `CityNodes.siteAccess`, the renderer's name
  /// for the same knob: placement happens here, in the capture, and the
  /// tiles must key what the capture placed. Off, a served building's
  /// position, orientation and site size are exactly what they were — only
  /// its slot and gate ride the wire, which no legacy path reads.
  static bool envelopePlacement = false;

  final CitySim _city;

  // ---- chunk set and cut table ------------------------------------------------------
  List<SiteAccessChunk> _chunks = const [];
  RoadGraph? _graph;

  /// The road ids of the last few graphs seen, by structure stamp: what a
  /// stale plan's road numbers are read through.
  final List<(int, List<String>)> _graphIds = [];

  /// Canonical cuts by road id (built with the chunk set), and aligned to
  /// the layout's road order (built with it and the roads revision).
  final Map<String, (Float64List, double)> _canonById = {};
  int _cutHash = 0;

  /// The [_cutHash] the held frame's `geometryStamp` was taken with: the
  /// cut table can move without the chunks, `sitesRev` or the ground (the
  /// book's graph swapped under unchanged chunks, e.g. a one-way reversed
  /// after the capture already saw the new roads revision).
  int _frameCutHash = 0;
  List<(Float64List, double)?> _canonByIndex = const [];
  int _indexedRoadsRev = -1, _indexedRoadCount = -1;
  bool _indexStale = true;

  /// The drawn copy per layout road index, and the drape points it was
  /// drawn for.
  List<Float64List?> _drawn = const [];
  List<Object?> _drawnFor = const [];

  // ---- geometry ---------------------------------------------------------------------
  List<SiteChunkGeometry?> _geos = const [];
  List<int> _geoHash = const [];
  int _groundShaped = -2, _groundEdits = -2, _drapeRev = -2;
  Object? _groundStore;
  CitySiteFrame? _frame;

  /// The cache of [city], refreshed for this frame, or null when its book
  /// has published nothing (no plan: every building is legacy, and no road
  /// carries a cut).
  static SiteCapture? begin(CitySim city) {
    final book = city.siteAccess;
    final chunks = book.chunks;
    final g = book.graph;
    if (chunks.isEmpty || g == null) {
      _cache[city]?._frame = null;
      return null;
    }
    final c = _cache[city] ??= SiteCapture._(city);
    c._refresh(book, chunks, g);
    return c;
  }

  void _refresh(SiteAccessBook book, List<SiteAccessChunk> chunks, RoadGraph g) {
    var moved = chunks.length != _chunks.length || !identical(g, _graph);
    if (!moved) {
      for (var i = 0; i < chunks.length; i++) {
        if (!identical(chunks[i], _chunks[i])) {
          moved = true;
          break;
        }
      }
    }
    if (moved) {
      if (!identical(g, _graph)) _noteGraph(g);
      _graph = g;
      _chunks = List.of(chunks, growable: false);
      _buildCuts(g);
      _indexStale = true;
    }
    final roads = _city.layout.roads;
    if (_indexStale ||
        _indexedRoadsRev != _city.roadsRevision ||
        _indexedRoadCount != roads.length) {
      _canonByIndex = [
        for (final r in roads) _canonById[r.id],
      ];
      _drawn = List<Float64List?>.filled(roads.length, null);
      _drawnFor = List<Object?>.filled(roads.length, null);
      _indexedRoadsRev = _city.roadsRevision;
      _indexedRoadCount = roads.length;
      _indexStale = false;
    }
  }

  void _noteGraph(RoadGraph g) {
    final stamp = g.structureStamp;
    for (final (s, _) in _graphIds) {
      if (s == stamp) return;
    }
    _graphIds.add((stamp, [for (final r in g.roads) r.id]));
    if (_graphIds.length > 4) _graphIds.removeAt(0);
  }

  List<String>? _idsAt(int stamp) {
    for (final (s, ids) in _graphIds) {
      if (s == stamp) return ids;
    }
    return null;
  }

  void _buildCuts(RoadGraph g) {
    cutTablesBuilt++;
    final canon = KerbCuts.canonicalOf(_chunks, g, roadIdsAt: _idsAt);
    _canonById.clear();
    var h = kFnvOffset32;
    for (var r = 0; r < canon.length; r++) {
      final c = canon[r];
      if (c == null) continue;
      final id = g.roads[r].id;
      _canonById[id] = (c, g.roadRecs[r].lengthM);
      h = fnv1aU32(h, fnv1a32(id));
      for (var i = 0; i < c.length; i++) {
        h = fnv1aU32(h, (c[i] * 100).round());
      }
    }
    _cutHash = h;
  }

  /// The drawn kerb cuts of layout road [index] ([road], flipped on the frame
  /// when `reversed`), drawn along [drapePts]; empty for a road with none.
  /// One list index per road on a steady frame.
  List<double> kerbCutsFor(
      int index, bool reversed, List<Vec2> drapePts) {
    if (index >= _canonByIndex.length) return const <double>[];
    final canon = _canonByIndex[index];
    if (canon == null) return const <double>[];
    final held = _drawn[index];
    if (held != null && identical(_drawnFor[index], drapePts)) return held;
    var len = 0.0;
    for (var i = 1; i < drapePts.length; i++) {
      len += drapePts[i].distanceTo(drapePts[i - 1]);
    }
    final drawn = KerbCuts.toDrawn(canon.$1,
        indexLengthM: canon.$2, drawnLengthM: len, reversed: reversed);
    _drawn[index] = drawn;
    _drawnFor[index] = drapePts;
    return drawn;
  }

  /// [siteId]'s book slot and the plan's gate, for its building: slot −1
  /// (legacy) when it has no published plan, or when the book's slot table
  /// and the chunks this capture holds disagree on the row (the book moved
  /// since [begin]). `gateXM` is along the building's local X from the
  /// envelope centre.
  (int, double, double) buildingSiteOf(String siteId) {
    final p = placementOf(siteId);
    return p == null ? (-1, 0, 0) : (p.slot, p.gateXM, p.gateWM);
  }

  /// [siteId]'s plan-served placement (§5.2 R4), or null when it has none:
  /// the envelope it stands on, the heading it takes and its gate, all read
  /// off the published plan.
  ///
  /// Null on the same terms as [buildingSiteOf]: no published plan, or the
  /// book's slot table and the chunks this capture holds disagree on the row
  /// (the book moved since [begin]).
  SitePlacement? placementOf(String siteId) {
    final book = _city.siteAccess;
    final slot = book.slotOf(siteId);
    if (slot < 0) return null;
    final c = slot ~/ kSitesPerChunk;
    final row = book.rowOfSlot(slot);
    if (row < 0 ||
        c >= _chunks.length ||
        row >= _chunks[c].siteCount ||
        _chunks[c].siteId(row) != siteId) {
      return null;
    }
    final chunk = _chunks[c];
    final gw = chunk.gateW(row);
    final centreX = (chunk.envX0(row) + chunk.envX1(row)) / 2;
    final (e, n) = CitySiteFrame.envelopeCentreLocal(chunk, row);
    return SitePlacement(
      slot: slot,
      centreE: e,
      centreN: n,
      widthM: chunk.envX1(row) - chunk.envX0(row),
      depthM: chunk.envY1(row) - chunk.envY0(row),
      headingRad: CitySiteFrame.buildingHeadingOf(chunk, row),
      gateXM: gw > 0 ? chunk.gateX(row) - centreX : 0,
      gateWM: gw > 0 ? gw : 0,
    );
  }

  /// This frame's [CitySiteFrame] for the colony on [bodyId] (datum
  /// [datumRadiusM]): the held one on a steady frame. [groundFor] and
  /// [cellRadius] are the capture's own cached ground reads; [siteRadiusM]
  /// stands in for a site whose lot is gone.
  CitySiteFrame frame({
    required String bodyId,
    required double datumRadiusM,
    required double siteRadiusM,
    required double Function(String key, Vec2 local) groundFor,
    required double Function(int cell) cellRadius,
  }) {
    final city = _city;
    final groundMoved = _groundShaped != city.groundCacheShaped ||
        _groundEdits != city.groundCacheEditCount ||
        !identical(_groundStore, city.groundCacheEditStore) ||
        _drapeRev != city.drapeCacheRevision;
    final held = _frame;
    final book = city.siteAccess;
    if (held != null &&
        !groundMoved &&
        _frameCutHash == _cutHash &&
        held.bodyId == bodyId &&
        held.sitesRev == book.sitesRev &&
        _geos.length == _chunks.length) {
      var current = true;
      for (var c = 0; c < _chunks.length; c++) {
        if (!identical(_geos[c]?.plan, _chunks[c])) {
          current = false;
          break;
        }
      }
      if (current) return held;
    }
    _groundShaped = city.groundCacheShaped;
    _groundEdits = city.groundCacheEditCount;
    _groundStore = city.groundCacheEditStore;
    _drapeRev = city.drapeCacheRevision;

    final n = _chunks.length;
    final geos = List<SiteChunkGeometry?>.filled(n, null);
    final hashes = List<int>.filled(n, 0);
    var same = held != null && _geos.length == n;
    final arcs = <String, Float64List>{};
    for (var c = 0; c < n; c++) {
      final chunk = _chunks[c];
      final old = c < _geos.length ? _geos[c] : null;
      if (!groundMoved && old != null && identical(old.plan, chunk)) {
        geos[c] = old;
        hashes[c] = _geoHash[c];
        continue;
      }
      final built = _build(chunk, c, book, datumRadiusM, siteRadiusM,
          groundFor, cellRadius, arcs);
      final h = _hashOf(built);
      if (old != null &&
          identical(old.plan, chunk) &&
          c < _geoHash.length &&
          _geoHash[c] == h &&
          _sameF32(old._f32, built._f32)) {
        geos[c] = old;
      } else {
        geos[c] = built;
        same = false;
      }
      hashes[c] = h;
    }
    var stamp = fnv1aU32(kFnvOffset32, _cutHash);
    for (final h in hashes) {
      stamp = fnv1aU32(stamp, h);
    }
    stamp = stamp.toSigned(32);
    _geos = geos;
    _geoHash = hashes;
    if (held != null &&
        same &&
        _frameCutHash == _cutHash &&
        held.geometryStamp == stamp &&
        held.bodyId == bodyId &&
        held.sitesRev == book.sitesRev) {
      return held;
    }
    final up = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: 1);
    final east = city.localToBodyFixed(const Vec2(1, 0), bodyRadiusM: 1) - up;
    final north = city.localToBodyFixed(const Vec2(0, 1), bodyRadiusM: 1) - up;
    _frameCutHash = _cutHash;
    return _frame = CitySiteFrame(
      colonyId: city.id,
      bodyId: bodyId,
      sitesRev: book.sitesRev,
      geometryStamp: stamp,
      datumRadiusM: datumRadiusM,
      up: up,
      east: east,
      north: north,
      chunks: [for (final g in geos) g!],
    );
  }

  static bool _sameF32(Float32List a, Float32List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _hashOf(SiteChunkGeometry g) {
    var h = fnv1aU32(kFnvOffset32, g.siteCount);
    for (var k = 0; k < g.siteCount; k++) {
      h = fnv1aU32(h, g.siteKey(k));
      h = fnv1aU32(h, g.siteSlot(k));
    }
    return h;
  }

  /// The ground radius of road [roadId]'s drape at index arc [s], or null
  /// with no drape. [arcs] holds each drape's cumulative plan arc for the
  /// rebuild.
  double? _kerbRadius(String roadId, double s, Map<String, Float64List> arcs) {
    final d = _city.drapeCache[roadId];
    final g = _graph;
    if (d == null || g == null) return null;
    final pts = d.pts;
    final n = pts.length;
    if (n < 2 || d.radii.length != n) return null;
    final arc = arcs[roadId] ??= () {
      final a = Float64List(n);
      for (var i = 1; i < n; i++) {
        a[i] = a[i - 1] + pts[i].distanceTo(pts[i - 1]);
      }
      return a;
    }();
    final r = g.roadNoOf(roadId);
    final indexLen = r == null ? 0.0 : g.roadRecs[r].lengthM;
    final total = arc[n - 1];
    var x = indexLen > 0 ? s * total / indexLen : s;
    if (x < 0) x = 0;
    if (x > total) x = total;
    var lo = 0, hi = n - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (arc[mid] <= x) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final span = arc[lo + 1] - arc[lo];
    final u = span > 0 ? (x - arc[lo]) / span : 0.0;
    return d.radii[lo] + (d.radii[lo + 1] - d.radii[lo]) * u;
  }

  /// The road id join [row] of [chunk]'s site [site] names, or null.
  String? _roadIdOf(SiteAccessChunk chunk, int site, int row) {
    final g = _graph;
    if (g == null) return null;
    final r = chunk.joinRoadNo(row);
    if (chunk.graphStamp(site) == g.structureStamp) {
      return r >= 0 && r < g.roadCount ? g.roads[r].id : null;
    }
    final ids = _idsAt(chunk.graphStamp(site));
    return ids != null && r >= 0 && r < ids.length ? ids[r] : null;
  }

  SiteChunkGeometry _build(
    SiteAccessChunk chunk,
    int c,
    SiteAccessBook book,
    double datum,
    double siteRadius,
    double Function(String key, Vec2 local) groundFor,
    double Function(int cell) cellRadius,
    Map<String, Float64List> arcs,
  ) {
    geometriesBuilt++;
    final nS = chunk.siteCount;
    final nP = chunk.ptStart(nS), nSt = chunk.stallStart(nS);
    final f32 = Float32List(nP + nSt + nS);
    final i32 = Int32List(2 * nS);
    for (var s = c * kSitesPerChunk; s < (c + 1) * kSitesPerChunk; s++) {
      final row = book.rowOfSlot(s);
      if (row >= 0 && row < nS) i32[nS + row] = s;
    }
    final layout = _city.layout;
    for (var k = 0; k < nS; k++) {
      final id = chunk.siteId(k);
      final cell = CitySim.cellOfSiteId(id);
      var pad = siteRadius;
      var graded = true;
      Vec2? centroid;
      if (cell != null) {
        pad = cellRadius(cell);
      } else {
        final parcel = layout.parcelById(id);
        if (parcel != null) {
          final at = parcel.centroid;
          centroid = at;
          graded = parcel.graded;
          pad = groundFor('lot:$id', at);
        }
      }
      // Kerb radius per join, off its road's drape; the pad without one.
      final j0 = chunk.joinStart(k), nJ = chunk.joinCountOf(k);
      final kerb = Float64List(nJ);
      for (var j = 0; j < nJ; j++) {
        final roadId = _roadIdOf(chunk, k, j0 + j);
        final r = roadId == null
            ? null
            : _kerbRadius(roadId, chunk.joinRoadS(j0 + j), arcs);
        kerb[j] = r ?? pad;
      }
      final p0 = chunk.ptStart(k), p1 = chunk.ptStart(k + 1);
      for (var p = p0; p < p1; p++) {
        final e = chunk.ptE(p), nn = chunk.ptN(p);
        final hj = chunk.ptHJoin(p);
        final kerbR = hj < nJ ? kerb[hj] : pad;
        double radius;
        switch (chunk.ptHRef(p)) {
          case SiteHeightRef.pad:
            if (!graded && centroid != null) {
              final de = e - centroid.e, dn = nn - centroid.n;
              radius = de * de + dn * dn > padReachM * padReachM
                  ? groundFor('site:$id:${p - p0}', Vec2(e, nn))
                  : pad;
            } else {
              radius = pad;
            }
          case SiteHeightRef.kerb:
            radius = kerbR;
          case SiteHeightRef.blend:
            radius = pad + (kerbR - pad) * chunk.ptHT(p);
        }
        f32[p] = radius + chunk.ptDz(p) - datum;
      }
      // Stalls: the pave under each, along its segment's polyline.
      final plan = chunk.plan(k);
      final st0 = chunk.stallStart(k), st1 = chunk.stallStart(k + 1);
      for (var st = st0; st < st1; st++) {
        f32[nP + st] = _upAlong(chunk, plan, f32, p0,
            chunk.stallSeg(st), chunk.stallS(st));
      }
      // The steepest drive, over every segment's consecutive points.
      var grade = 0.0;
      for (var sg = 0; sg < plan.segCount; sg++) {
        final m = plan.segPointCount(sg);
        for (var i = 1; i < m; i++) {
          final a = p0 + plan.segPoint(sg, i - 1), b = p0 + plan.segPoint(sg, i);
          final de = chunk.ptE(b) - chunk.ptE(a), dn = chunk.ptN(b) - chunk.ptN(a);
          final run = de * de + dn * dn;
          if (run < 0.25) continue;
          final rise = (f32[b] - f32[a]).abs();
          final gr = rise / _sqrt(run);
          if (gr > grade) grade = gr;
        }
      }
      f32[nP + nSt + k] = grade;
      // The key: rev and the heights to the centimetre.
      var h = fnv1aU32(kFnvOffset32, chunk.rev(k));
      h = fnv1aU32(h, chunk.flags(k));
      h = fnv1aU32(h, chunk.program(k).index);
      for (var p = p0; p < p1; p++) {
        h = fnv1aU32(h, (f32[p] * 100).round());
      }
      for (var st = st0; st < st1; st++) {
        h = fnv1aU32(h, (f32[nP + st] * 100).round());
      }
      i32[k] = h == 0 ? 1 : h.toSigned(32);
    }
    return SiteChunkGeometry._(chunk, c, f32, i32);
  }

  /// The height of segment [seg]'s polyline [s] metres from its first
  /// point, from the point heights already written into [f32].
  static double _upAlong(SiteAccessChunk chunk, SiteAccessPlan plan,
      Float32List f32, int p0, int seg, double s) {
    if (seg < 0 || seg >= plan.segCount) return 0;
    final m = plan.segPointCount(seg);
    var at = 0.0;
    for (var i = 1; i < m; i++) {
      final a = p0 + plan.segPoint(seg, i - 1), b = p0 + plan.segPoint(seg, i);
      final de = chunk.ptE(b) - chunk.ptE(a), dn = chunk.ptN(b) - chunk.ptN(a);
      final len = _sqrt(de * de + dn * dn);
      if (s <= at + len || i == m - 1) {
        final u = len > 0 ? ((s - at) / len).clamp(0.0, 1.0) : 0.0;
        return f32[a] + (f32[b] - f32[a]) * u;
      }
      at += len;
    }
    return f32[p0 + plan.segPoint(seg, 0)];
  }

  static double _sqrt(double x) => x <= 0 ? 0 : math.sqrt(x);
}
