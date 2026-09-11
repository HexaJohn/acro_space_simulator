// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the colony's traffic tells everything else.
///
/// The sim's growth, fire and tax lines, the Traffic Routes view and the
/// lot readouts all read the traffic through [CityTrafficReadout] — never
/// through the model that computes it. The routed trip model
/// (`CityRoadTraffic`, road_traffic_model.dart) answers today; a
/// simulation of individual vehicles can answer tomorrow by implementing
/// this, and not one consumer changes.
///
/// Every answer is the last COMPLETE picture of the traffic: readers never
/// see a pass half done. Before there is one, the answers are the ones that
/// punish nothing — no congestion, every lot reached, a tax factor of 1.
library;

import 'parcel.dart';

/// Why a vehicle is on the road. The Traffic Routes view filters by it.
enum TripKind { commuter, shopper, goods, service }

/// One routed trip, as the Traffic Routes view draws it.
class TripRoute {
  const TripRoute({
    required this.kind,
    required this.weight,
    required this.roadIds,
    required this.polyline,
  });

  final TripKind kind;

  /// Vehicles per peak on it: its origin stretch's trips of [kind] to its
  /// destination stretch — never scaled.
  final double weight;

  /// The roads it uses, in order, each once per visit.
  final List<String> roadIds;

  /// Its path, colony-local metres, from where it leaves its origin's road
  /// to where it stops on its destination's.
  final List<Vec2> polyline;
}

/// The colony's traffic, as the sim and the views read it.
abstract interface class CityTrafficReadout {
  /// Whether there is a picture of the traffic yet — until then the sim
  /// keeps its own frontage-local congestion.
  bool get hasRun;

  /// How many pictures have been published: it moves whenever the answers
  /// may have changed, and never goes back, so a view can key what it drew
  /// from them on it (the Traffic Routes view's lines). 0 before the first.
  int get passes;

  /// The worst road's load against its lanes, 0..1. 0 before a picture.
  double get peakCongestion;

  /// Congestion averaged over the vehicles: what a typical trip meets.
  double get averageCongestion;

  /// Load over capacity on [roadId] (its worst stretch); 0 for a road the
  /// picture does not know.
  double congestionOf(String roadId);

  /// Vehicles per peak on [roadId] (its busiest stretch).
  double volumeOf(String roadId);

  /// The trips that use [roadId], heaviest first — at most [limit] of them,
  /// of [kinds] (all when null).
  List<TripRoute> routesThrough(String roadId,
      {Set<TripKind>? kinds, int limit = 64});

  /// Whether a police car, fire engine or ambulance reaches [lotId] the
  /// way the one-way streets run. True before a picture, and for a lot it
  /// does not know: no lot is punished for not having been looked at.
  bool serviceReach(String lotId);

  /// Whether a vehicle from a station with safety cover — the police, a
  /// fire station, the barracks: the cover a fire is put out with — reaches
  /// [lotId] the way the one-way streets run. A clinic's ambulance counts
  /// for [serviceReach], not here: it puts no fire out. True before a
  /// picture, and for a lot it does not know.
  bool fireReach(String lotId);

  /// Whether goods reach [lotId] the way the one-way streets run. True
  /// before a picture, and for a lot it does not know.
  bool deliveryReach(String lotId);

  /// Traffic noise at [lotId], 0..1 (0 before a picture).
  double noiseOf(String lotId);

  /// Land value of [lotId], 0..1, in the colony's air.
  double landValueOf(String lotId);

  /// Land value averaged over the built lots, in the colony's air.
  double get averageLandValue;

  /// The multiplier the land the roads make puts on the tax take,
  /// 0.85..1.15 — exactly 1 while no built lot has been valued.
  double get taxLandValueFactor;
}
