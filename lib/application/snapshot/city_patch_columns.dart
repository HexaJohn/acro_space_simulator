// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Colony ground patches as typed columns rather than objects.
///
/// A big colony's frame carried six hundred thousand [CityPatchSnapshot]
/// objects — eleven fields each, plus the list that held them — and they
/// were the largest single population the old-generation marker walked
/// every time a tile landed: the hundred-millisecond collections the city
/// studio measured while zooming were, in good part, the marker touching
/// every one of them to learn that nothing had changed. A patch is nine
/// numbers, a kind and two names that repeat across the whole colony, so
/// the same frame as [CityPatchColumns] is a dozen typed lists — a dozen
/// heap objects, whatever the count — and the marker skips their bytes
/// entirely. Rotation and extent are stored at float precision: the
/// renderer converts them to single floats before they reach a vertex, so
/// the double they came from was never used past the seventh digit.
/// Positions stay double — body-fixed metres at a planet's radius need the
/// full mantissa or a patch lands a metre from its building.
///
/// Readers with a hot loop take the columns directly; anything that wants
/// a patch as an object gets a transient one from [CityPatchColumns.at] or
/// by iterating — the columns are an [Iterable] so a frame's `for (final p
/// in snap.patches)` still reads, and allocates only what the loop body is
/// holding.
library;

import 'dart:collection';
import 'dart:typed_data';

/// A flat patch of colony ground: a road tile, a zoned-but-not-yet-built lot,
/// or a support platform.
///
/// Without these a freshly zoned colony renders as empty ground — the frame
/// only ever carried BUILDINGS, and a zone holds nothing until it grows. From
/// the cockpit that reads as the editor being broken rather than as a city
/// waiting to be built.
///
/// A frame does not hold these: it holds [CityPatchColumns], and hands one
/// of these out on request — a view of one row, made for the caller and
/// dropped when the caller is done.
class CityPatchSnapshot {
  /// What the patch is. Index into the renderer's ground palette, so a client
  /// needs no spec table to colour it.
  static const int kindRoad = 0;
  static const int kindResidential = 1;
  static const int kindCommercial = 2;
  static const int kindIndustrial = 3;
  static const int kindSupport = 4;

  final String colonyId;
  final String body;
  final double px, py, pz;
  final double qw, qx, qy, qz;

  /// Extent in metres, along the patch's own east (width) and north (depth)
  /// axes. Grid cells are square; parcels are not.
  final double sizeM;
  final double depthM;

  /// The palette band, with [builtFlag] possibly set. Read [zoneKind] for the
  /// band alone and [built] for the flag.
  final int kind;

  /// Bit set on [kind] when something already STANDS on this lot.
  ///
  /// Packed into the kind rather than carried as a column of its own: it IS
  /// part of what the patch is, the columns already ship kind as an Int32, and
  /// a parallel byte column would have to be threaded through every grow,
  /// gather and sublist in this file to say one bit.
  static const int builtFlag = 0x100;

  /// Bit set on [kind] for a lot NOBODY HAS ZONED.
  ///
  /// Not the same fact as "support-coloured": the grid city draws its real
  /// support decks in the same band, and those are structure, not an empty
  /// plot. An unzoned lot is the plat's blank page — every street is lined
  /// with them — and the renderer hides them unless zoning is under way.
  static const int unzonedFlag = 0x200;

  /// Bit set on [kind] for every PLAT LOT — as opposed to a road cell or a
  /// support deck, which share the palette but are structure.
  ///
  /// Lots are drawn by their own node, rebuilt the frame they change, not by
  /// the city tiles: zoning is interactive, and the tiles re-mesh on a worker
  /// pool in the background — seconds of lag between a zone stroke and its
  /// colour. This bit is how the tile mesher knows which patches are not its.
  static const int lotFlag = 0x400;

  /// The palette band alone.
  int get zoneKind => kind & 0xFF;

  /// Whether this patch is a plat lot (see [lotFlag]).
  bool get isLot => (kind & lotFlag) != 0;

  /// Whether this is a lot nobody has zoned yet.
  bool get unzoned => (kind & unzonedFlag) != 0;

  /// Whether something already stands here.
  ///
  /// The zone colour is an authoring affordance — it says what a piece of
  /// ground is FOR — and once a building is on it, the building says that
  /// better than a coloured slab underneath. The renderer paints a built lot
  /// only when the zoning overlay is up; every lot is emitted either way,
  /// because the overlay wants the whole plat and not just its empty half.
  bool get built => (kind & builtFlag) != 0;

  const CityPatchSnapshot({
    required this.colonyId,
    required this.body,
    required this.px,
    required this.py,
    required this.pz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.sizeM,
    required this.kind,
    double? depthM,
  }) : depthM = depthM ?? sizeM;

  /// The kind band with [builtFlag] and [unzonedFlag] applied — what an
  /// emitter packs.
  static int packKind(int kind,
          {required bool built, bool unzoned = false, bool lot = false}) =>
      kind |
      (built ? builtFlag : 0) |
      (unzoned ? unzonedFlag : 0) |
      (lot ? lotFlag : 0);

  Map<String, dynamic> toJson() => {
        'colony': colonyId,
        'body': body,
        'p': [px, py, pz],
        'q': [qw, qx, qy, qz],
        's': sizeM,
        'd': depthM,
        'k': kind,
      };

  factory CityPatchSnapshot.fromJson(Map<String, dynamic> j) {
    final p = (j['p'] as List).cast<num>();
    final q = (j['q'] as List).cast<num>();
    return CityPatchSnapshot(
      colonyId: j['colony'] as String,
      body: j['body'] as String,
      px: p[0].toDouble(),
      py: p[1].toDouble(),
      pz: p[2].toDouble(),
      qw: q[0].toDouble(),
      qx: q[1].toDouble(),
      qy: q[2].toDouble(),
      qz: q[3].toDouble(),
      sizeM: (j['s'] as num).toDouble(),
      depthM: (j['d'] as num?)?.toDouble(),
      kind: (j['k'] as num).toInt(),
    );
  }
}

/// A frame's ground patches, one typed column per field.
///
/// Immutable once built: a frame is captured, not edited, and the renderer
/// keys its tiles on the identity of the columns it last bucketed. Build
/// one through a [CityPatchColumnsBuilder] (what capture and the wire do),
/// from objects with [CityPatchColumns.of] (tests, and anything that still
/// thinks in patches), or as a subset of another with [gather] (a tile's
/// share of the frame).
class CityPatchColumns extends IterableBase<CityPatchSnapshot> {
  CityPatchColumns._({
    required this.strings,
    required this.colonyIndex,
    required this.bodyIndex,
    required this.px,
    required this.py,
    required this.pz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.sizeM,
    required this.depthM,
    required this.kind,
  });

  /// No patches at all: the default for a frame that carries none. One
  /// shared instance, so an empty frame allocates nothing for its patches.
  static final CityPatchColumns empty = CityPatchColumns._(
    strings: const [],
    colonyIndex: Int32List(0),
    bodyIndex: Int32List(0),
    px: Float64List(0),
    py: Float64List(0),
    pz: Float64List(0),
    qw: Float32List(0),
    qx: Float32List(0),
    qy: Float32List(0),
    qz: Float32List(0),
    sizeM: Float32List(0),
    depthM: Float32List(0),
    kind: Int32List(0),
  );

  /// The columns of [patches], in order.
  factory CityPatchColumns.of(Iterable<CityPatchSnapshot> patches) {
    final b = CityPatchColumnsBuilder(
        capacity: patches is List ? patches.length : 0);
    for (final p in patches) {
      b.add(
        colonyId: p.colonyId,
        body: p.body,
        px: p.px,
        py: p.py,
        pz: p.pz,
        qw: p.qw,
        qx: p.qx,
        qy: p.qy,
        qz: p.qz,
        sizeM: p.sizeM,
        depthM: p.depthM,
        kind: p.kind,
      );
    }
    return b.build();
  }

  /// The wire's list of patch maps, as columns. The inverse of [toJsonList].
  factory CityPatchColumns.fromJsonList(List<dynamic> list) {
    final b = CityPatchColumnsBuilder(capacity: list.length);
    for (final e in list) {
      final j = e as Map<String, dynamic>;
      final p = (j['p'] as List).cast<num>();
      final q = (j['q'] as List).cast<num>();
      final s = (j['s'] as num).toDouble();
      b.add(
        colonyId: j['colony'] as String,
        body: j['body'] as String,
        px: p[0].toDouble(),
        py: p[1].toDouble(),
        pz: p[2].toDouble(),
        qw: q[0].toDouble(),
        qx: q[1].toDouble(),
        qy: q[2].toDouble(),
        qz: q[3].toDouble(),
        sizeM: s,
        depthM: (j['d'] as num?)?.toDouble() ?? s,
        kind: (j['k'] as num).toInt(),
      );
    }
    return b.build();
  }

  /// Each distinct colony id and body name, once. [colonyIndex] and
  /// [bodyIndex] point into it.
  final List<String> strings;

  /// Per patch: the colony's and the body's index in [strings].
  final Int32List colonyIndex, bodyIndex;

  /// Per patch: body-fixed centre, metres. Double, for the reason the
  /// library comment gives.
  final Float64List px, py, pz;

  /// Per patch: the orientation quaternion, w then x, y, z.
  final Float32List qw, qx, qy, qz;

  /// Per patch: extent along the patch's own east and north axes, metres.
  final Float32List sizeM, depthM;

  /// Per patch: [CityPatchSnapshot.kindRoad] and its siblings.
  final Int32List kind;

  @override
  int get length => kind.length;

  @override
  bool get isEmpty => kind.isEmpty;

  @override
  bool get isNotEmpty => kind.isNotEmpty;

  @override
  CityPatchSnapshot elementAt(int index) => at(index);

  @override
  Iterator<CityPatchSnapshot> get iterator => _CityPatchIterator(this);

  String colonyIdAt(int i) => strings[colonyIndex[i]];
  String bodyAt(int i) => strings[bodyIndex[i]];

  /// Row [i] as an object. Made for the call; nothing retains it.
  CityPatchSnapshot at(int i) => CityPatchSnapshot(
        colonyId: strings[colonyIndex[i]],
        body: strings[bodyIndex[i]],
        px: px[i],
        py: py[i],
        pz: pz[i],
        qw: qw[i],
        qx: qx[i],
        qy: qy[i],
        qz: qz[i],
        sizeM: sizeM[i],
        depthM: depthM[i],
        kind: kind[i],
      );

  /// The rows at [indices], in that order, as columns of their own.
  ///
  /// The string table is rebuilt from only the names those rows use, so a
  /// tile's subset carries its own two or three names and no reference to
  /// the frame's columns — what lets it cross to a worker on its own.
  CityPatchColumns gather(Int32List indices) {
    final n = indices.length;
    if (n == 0) return empty;
    final b = CityPatchColumnsBuilder(capacity: n);
    // A remap from the source's string indices to the subset's, filled as
    // rows are met: interning by index rather than by string keeps this
    // loop off the hash of every name.
    final remap = Int32List(strings.length)..fillRange(0, strings.length, -1);
    int intern(int src) {
      var dst = remap[src];
      if (dst < 0) dst = remap[src] = b.internString(strings[src]);
      return dst;
    }

    for (var k = 0; k < n; k++) {
      final i = indices[k];
      b.addInterned(
        colony: intern(colonyIndex[i]),
        body: intern(bodyIndex[i]),
        px: px[i],
        py: py[i],
        pz: pz[i],
        qw: qw[i],
        qx: qx[i],
        qy: qy[i],
        qz: qz[i],
        sizeM: sizeM[i],
        depthM: depthM[i],
        kind: kind[i],
      );
    }
    return b.build();
  }

  /// Bytes in the typed columns: what an isolate send copies as blocks.
  int get typedBytes =>
      colonyIndex.lengthInBytes +
      bodyIndex.lengthInBytes +
      px.lengthInBytes +
      py.lengthInBytes +
      pz.lengthInBytes +
      qw.lengthInBytes +
      qx.lengthInBytes +
      qy.lengthInBytes +
      qz.lengthInBytes +
      sizeM.lengthInBytes +
      depthM.lengthInBytes +
      kind.lengthInBytes;

  /// Whether every row of [other] is this row for row — by the names a row
  /// resolves to, not by string-table index, so two tables built in a
  /// different order still compare equal.
  bool contentEquals(CityPatchColumns other) {
    final n = length;
    if (other.length != n) return false;
    for (var i = 0; i < n; i++) {
      if (colonyIdAt(i) != other.colonyIdAt(i) ||
          bodyAt(i) != other.bodyAt(i) ||
          px[i] != other.px[i] ||
          py[i] != other.py[i] ||
          pz[i] != other.pz[i] ||
          qw[i] != other.qw[i] ||
          qx[i] != other.qx[i] ||
          qy[i] != other.qy[i] ||
          qz[i] != other.qz[i] ||
          sizeM[i] != other.sizeM[i] ||
          depthM[i] != other.depthM[i] ||
          kind[i] != other.kind[i]) {
        return false;
      }
    }
    return true;
  }

  /// The wire's list of patch maps — the same maps
  /// [CityPatchSnapshot.toJson] makes, in row order.
  List<Map<String, dynamic>> toJsonList() =>
      [for (var i = 0; i < length; i++) at(i).toJson()];
}

class _CityPatchIterator implements Iterator<CityPatchSnapshot> {
  _CityPatchIterator(this._columns);
  final CityPatchColumns _columns;
  int _i = -1;

  @override
  CityPatchSnapshot get current => _columns.at(_i);

  @override
  bool moveNext() => ++_i < _columns.length;
}

/// Fills a [CityPatchColumns] one row at a time.
///
/// Capture does not know how many patches a colony will emit until it has
/// walked it — a built lot yields a ring of up to four strips, a bare lot
/// one — so the builder grows: [reserve] takes an upper bound where the
/// caller has one, and [add] doubles the columns when they run out. The
/// finished columns are trimmed to what was added (see [build]).
class CityPatchColumnsBuilder {
  CityPatchColumnsBuilder({int capacity = 0}) {
    _alloc(capacity < 16 ? 16 : capacity);
  }

  /// Below this share of the capacity in use, [build] copies the rows into
  /// exactly-sized columns rather than viewing the over-allocated ones: a
  /// view keeps every unused byte alive for the life of the frame, and a
  /// copy at this size is a handful of memcpys. Knob, so the trade can be
  /// tried either way: 1.0 always copies, 0.0 always views.
  static double trimBelowFill = 0.5;

  final List<String> _strings = [];
  final Map<String, int> _index = {};
  late Int32List _colony, _body, _kind;
  late Float64List _px, _py, _pz;
  late Float32List _qw, _qx, _qy, _qz, _sizeM, _depthM;
  int _n = 0;

  int get length => _n;

  void _alloc(int cap) {
    _colony = Int32List(cap);
    _body = Int32List(cap);
    _kind = Int32List(cap);
    _px = Float64List(cap);
    _py = Float64List(cap);
    _pz = Float64List(cap);
    _qw = Float32List(cap);
    _qx = Float32List(cap);
    _qy = Float32List(cap);
    _qz = Float32List(cap);
    _sizeM = Float32List(cap);
    _depthM = Float32List(cap);
  }

  /// Make room for [extra] more rows without another growth.
  void reserve(int extra) {
    final need = _n + extra;
    if (need > _kind.length) _grow(need);
  }

  void _grow(int atLeast) {
    var cap = _kind.length * 2;
    if (cap < atLeast) cap = atLeast;
    final colony = _colony, body = _body, kind = _kind;
    final px = _px, py = _py, pz = _pz;
    final qw = _qw, qx = _qx, qy = _qy, qz = _qz;
    final sizeM = _sizeM, depthM = _depthM;
    _alloc(cap);
    _colony.setRange(0, _n, colony);
    _body.setRange(0, _n, body);
    _kind.setRange(0, _n, kind);
    _px.setRange(0, _n, px);
    _py.setRange(0, _n, py);
    _pz.setRange(0, _n, pz);
    _qw.setRange(0, _n, qw);
    _qx.setRange(0, _n, qx);
    _qy.setRange(0, _n, qy);
    _qz.setRange(0, _n, qz);
    _sizeM.setRange(0, _n, sizeM);
    _depthM.setRange(0, _n, depthM);
  }

  /// The index [s] will have in the built columns' string table.
  int internString(String s) => _index.putIfAbsent(s, () {
        _strings.add(s);
        return _strings.length - 1;
      });

  void add({
    required String colonyId,
    required String body,
    required double px,
    required double py,
    required double pz,
    required double qw,
    required double qx,
    required double qy,
    required double qz,
    required double sizeM,
    required double depthM,
    required int kind,
  }) =>
      addInterned(
        colony: internString(colonyId),
        body: internString(body),
        px: px,
        py: py,
        pz: pz,
        qw: qw,
        qx: qx,
        qy: qy,
        qz: qz,
        sizeM: sizeM,
        depthM: depthM,
        kind: kind,
      );

  /// [add] with the names already interned through [internString]: the
  /// path for a caller that adds many rows sharing two names and would
  /// rather not hash them each time.
  void addInterned({
    required int colony,
    required int body,
    required double px,
    required double py,
    required double pz,
    required double qw,
    required double qx,
    required double qy,
    required double qz,
    required double sizeM,
    required double depthM,
    required int kind,
  }) {
    if (_n == _kind.length) _grow(_n + 1);
    final i = _n++;
    _colony[i] = colony;
    _body[i] = body;
    _kind[i] = kind;
    _px[i] = px;
    _py[i] = py;
    _pz[i] = pz;
    _qw[i] = qw;
    _qx[i] = qx;
    _qy[i] = qy;
    _qz[i] = qz;
    _sizeM[i] = sizeM;
    _depthM[i] = depthM;
  }

  /// The columns so far. The builder is spent afterwards: its buffers may
  /// now be the columns' own.
  CityPatchColumns build() {
    final n = _n;
    if (n == 0) return CityPatchColumns.empty;
    final cap = _kind.length;
    final copy = n < cap * trimBelowFill;
    Int32List ints(Int32List a) =>
        n == cap ? a : copy ? a.sublist(0, n) : Int32List.sublistView(a, 0, n);
    Float64List d(Float64List a) => n == cap
        ? a
        : copy
            ? a.sublist(0, n)
            : Float64List.sublistView(a, 0, n);
    Float32List f(Float32List a) => n == cap
        ? a
        : copy
            ? a.sublist(0, n)
            : Float32List.sublistView(a, 0, n);
    return CityPatchColumns._(
      strings: List<String>.of(_strings, growable: false),
      colonyIndex: ints(_colony),
      bodyIndex: ints(_body),
      px: d(_px),
      py: d(_py),
      pz: d(_pz),
      qw: f(_qw),
      qx: f(_qx),
      qy: f(_qy),
      qz: f(_qz),
      sizeM: f(_sizeM),
      depthM: f(_depthM),
      kind: ints(_kind),
    );
  }
}
