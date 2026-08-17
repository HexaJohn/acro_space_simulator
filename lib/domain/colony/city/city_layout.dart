// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'parcel.dart';

/// Player-facing knobs for how land is cut up.
///
/// These are the settings the parcels are "dynamically drawn" from: change the
/// frontage and the same road re-subdivides into wider or narrower lots on the
/// next regeneration, without any of the fixed-cell rounding a grid imposes.
class ParcelSettings {
  /// Street frontage per lot, in metres. Narrow (10 m) gives terraced housing;
  /// wide (60 m) gives suburban plots or industrial units.
  final double frontageM;

  /// How far a lot extends back from the street.
  final double depthM;

  /// Verge + footway between the carriageway edge and the property line.
  final double sidewalkM;

  /// Lots shorter than this fraction of [frontageM] are dropped rather than
  /// left as slivers at the end of a run.
  final double minFrontageFraction;

  /// Keep-clear distance around a junction, so lots do not get cut across the
  /// mouth of an intersection.
  final double cornerClearM;

  /// Subdivide both sides of a road, or only the left.
  final bool bothSides;

  const ParcelSettings({
    this.frontageM = 24,
    this.depthM = 32,
    this.sidewalkM = 3,
    this.minFrontageFraction = 0.6,
    this.cornerClearM = 12,
    this.bothSides = true,
  });

  ParcelSettings copyWith({
    double? frontageM,
    double? depthM,
    double? sidewalkM,
    double? minFrontageFraction,
    double? cornerClearM,
    bool? bothSides,
  }) =>
      ParcelSettings(
        frontageM: frontageM ?? this.frontageM,
        depthM: depthM ?? this.depthM,
        sidewalkM: sidewalkM ?? this.sidewalkM,
        minFrontageFraction: minFrontageFraction ?? this.minFrontageFraction,
        cornerClearM: cornerClearM ?? this.cornerClearM,
        bothSides: bothSides ?? this.bothSides,
      );
}

/// The colony's roads, its parcels, and the rule that derives one from the
/// other.
///
/// Auto parcels are regenerated wholesale whenever the network or the settings
/// change; manual parcels are never touched, and auto parcels that would clash
/// with them (or with a carriageway) are simply not emitted. That combination
/// is what lets a street grid and a two-kilometre solar farm share a colony.
class CityLayout {
  CityLayout({ParcelSettings settings = const ParcelSettings()})
      : _settings = settings;

  final Map<String, RoadSpline> _roads = {};
  final List<Parcel> _manual = [];
  List<Parcel> _auto = const [];
  ParcelSettings _settings;
  int _nextId = 0;

  /// Bumped on every [regenerate], which every mutation goes through.
  /// The connectivity cache is keyed on it, so the graph walk runs when a
  /// road is drawn, not every tick.
  int version = 0;

  ParcelSettings get settings => _settings;

  set settings(ParcelSettings value) {
    _settings = value;
    regenerate();
  }

  Iterable<RoadSpline> get roads => _roads.values;

  /// Every parcel, manual first so an override wins any ambiguous hit test.
  List<Parcel> get parcels => [..._manual, ..._auto];

  List<Parcel> get autoParcels => List.unmodifiable(_auto);
  List<Parcel> get manualParcels => List.unmodifiable(_manual);

  void addRoad(RoadSpline road) {
    _roads[road.id] = road;
    regenerate();
  }

  void removeRoad(String id) {
    _roads.remove(id);
    regenerate();
  }

  /// Add a hand-drawn lot. Returns null (and adds nothing) if it would sit on a
  /// carriageway or overlap an existing manual lot — the caller shows that as a
  /// blocked placement.
  Parcel? addManualParcel(List<Vec2> polygon, {ParcelUse use = ParcelUse.unzoned}) {
    final p = Parcel(
      id: 'lot-m${_nextId++}',
      polygon: polygon,
      use: use,
      manual: true,
    );
    if (_hitsRoad(p)) return null;
    for (final other in _manual) {
      if (p.overlaps(other)) return null;
    }
    _manual.add(p);
    regenerate();
    return p;
  }

  void removeParcel(String id) {
    _manual.removeWhere((p) => p.id == id);
    regenerate();
  }

  /// Zone a parcel.
  ///
  /// Parcels are immutable values, so this replaces the entry rather than
  /// mutating it — which also means a regenerate wipes the zoning of AUTO
  /// lots, exactly as it wipes the lots themselves. Manual lots keep theirs.
  bool setUse(String id, ParcelUse use) {
    for (var i = 0; i < _manual.length; i++) {
      if (_manual[i].id == id) {
        _manual[i] = _manual[i].copyWith(use: use);
        return true;
      }
    }
    final auto = List.of(_auto);
    for (var i = 0; i < auto.length; i++) {
      if (auto[i].id == id) {
        auto[i] = auto[i].copyWith(use: use);
        _auto = auto;
        return true;
      }
    }
    return false;
  }

  /// The parcel under a point, or null. Manual lots win.
  Parcel? parcelAt(Vec2 p) {
    for (final parcel in parcels) {
      if (parcel.contains(p)) return parcel;
    }
    return null;
  }

  /// Re-cut every auto parcel from the current roads and settings.
  void regenerate() {
    version++;
    final out = <Parcel>[];
    for (final road in _roads.values) {
      out.addAll(_subdivide(road, out));
    }
    _auto = out;
  }

  /// Lay lots along one road.
  ///
  /// The centreline is walked at a fine step and lots are emitted whenever a
  /// full frontage of arc length has accumulated. Working in arc length rather
  /// than in control-point spans is what keeps lot widths even around a curve —
  /// stepping by parameter instead would make outside-of-the-bend lots wider
  /// than inside ones.
  List<Parcel> _subdivide(RoadSpline road, List<Parcel> soFar) {
    final pts = road.sample(stepM: 2.0);
    if (pts.length < 2) return const [];
    // Cumulative arc length, so cuts land at exact frontage distances instead
    // of snapping to whichever sample happened to cross the threshold — that
    // rounding is what would make lot widths drift by up to a sample step.
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    final total = cum.last;
    final start = _settings.cornerClearM;
    final end = total - _settings.cornerClearM;
    if (end - start < _settings.frontageM * _settings.minFrontageFraction) {
      return const [];
    }

    final out = <Parcel>[];
    final sides = _settings.bothSides ? [1.0, -1.0] : [1.0];
    final setback = road.halfWidth + _settings.sidewalkM;

    for (final side in sides) {
      var s = start;
      while (s < end - 1e-6) {
        var s1 = s + _settings.frontageM;
        if (s1 > end) {
          // Trailing remainder: keep it only if it is a usable lot, else stop.
          if (end - s < _settings.frontageM * _settings.minFrontageFraction) {
            break;
          }
          s1 = end;
        }
        final parcel = _lot(
          road,
          _pointAt(pts, cum, s),
          _pointAt(pts, cum, s1),
          side,
          setback,
        );
        if (parcel != null &&
            !_hitsRoad(parcel, exclude: road.id) &&
            !_clashes(parcel, [...soFar, ...out, ..._manual])) {
          out.add(parcel);
        }
        s = s1;
      }
    }
    return out;
  }

  /// Point at arc length [s] along the sampled polyline.
  static Vec2 _pointAt(List<Vec2> pts, List<double> cum, double s) {
    if (s <= 0) return pts.first;
    if (s >= cum.last) return pts.last;
    // Linear scan: roads have a few hundred samples and this runs only on
    // regeneration, so a binary search buys nothing worth the complexity.
    for (var i = 1; i < pts.length; i++) {
      if (cum[i] >= s) {
        final segLen = cum[i] - cum[i - 1];
        final t = segLen <= 1e-9 ? 0.0 : (s - cum[i - 1]) / segLen;
        return pts[i - 1] + (pts[i] - pts[i - 1]) * t;
      }
    }
    return pts.last;
  }

  /// Build one lot quad spanning centreline points [a]..[b] on [side].
  Parcel? _lot(RoadSpline road, Vec2 a, Vec2 b, double side, double setback) {
    final along = (b - a);
    if (along.length < 1e-6) return null;
    // Outward normal for this side of the road.
    final outward = along.normalized.perp * side;
    final frontA = a + outward * setback;
    final frontB = b + outward * setback;
    final backB = frontB + outward * _settings.depthM;
    final backA = frontA + outward * _settings.depthM;
    // Wind counter-clockwise: on the -1 side the frontage runs the other way.
    final poly = side > 0
        ? [frontA, frontB, backB, backA]
        : [frontB, frontA, backA, backB];
    final frontage = side > 0 ? (frontA, frontB) : (frontB, frontA);
    return Parcel(
      id: 'lot-${road.id}-${_nextId++}',
      polygon: poly,
      roadId: road.id,
      frontage: frontage,
    );
  }

  /// Does this parcel sit on any carriageway? Tested against the road centre
  /// lines so a lot can never be cut across the road it fronts.
  bool _hitsRoad(Parcel p, {String? exclude}) {
    for (final road in _roads.values) {
      final clearance = road.halfWidth + _settings.sidewalkM * 0.5;
      for (final v in p.polygon) {
        if (road.distanceTo(v) < clearance) {
          // Its own frontage edge sits exactly at the setback, which is outside
          // the carriageway — only a genuine incursion counts.
          if (road.id == exclude &&
              road.distanceTo(v) >= road.halfWidth + _settings.sidewalkM - 0.5) {
            continue;
          }
          return true;
        }
      }
      // A long thin lot can straddle a road without any corner being close to
      // it, so also check the centre.
      if (road.distanceTo(p.centroid) < clearance) return true;
    }
    return false;
  }

  bool _clashes(Parcel p, List<Parcel> others) {
    for (final o in others) {
      if (p.overlaps(o)) return true;
    }
    return false;
  }

  /// Total buildable land, in m².
  double get totalArea =>
      parcels.fold(0.0, (s, p) => s + p.area);

  /// Furthest extent of the built area from the colony centre, in metres —
  /// what the renderer uses to size the terrain pad under the city.
  double get radius {
    var r = 0.0;
    for (final p in parcels) {
      for (final v in p.polygon) {
        r = math.max(r, v.length);
      }
    }
    for (final road in _roads.values) {
      for (final v in road.sample(stepM: 8)) {
        r = math.max(r, v.length + road.halfWidth);
      }
    }
    return r;
  }
}
