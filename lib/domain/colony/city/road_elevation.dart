// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Elevated roads, bridges and tunnels: the rules, and the survey that
/// decides which stretch of a road is which.
///
/// The road tool raises and lowers a road in steps (PAGE UP / PAGE DOWN,
/// 3, 6 or 12 m) above the ground at each end it places. A road that leaves
/// grade gets a DECK ([RoadDeck]): a straight grade line between its two
/// end heights. Where that line runs close to the ground the ground is cut
/// or filled to meet it; where it stands clear of the ground it is carried
/// on piers (and above [RoadElevation.bridgeHeightM] it is a bridge); where
/// it runs deep under the ground it is a tunnel. The same arithmetic prices
/// it (a structure and a tunnel cost multiples of the road at grade) and
/// the renderer draws it, so the three can never disagree about which
/// stretch is which.
///
/// Heights are metres above the BODY DATUM (the body's mean radius), never
/// above the colony site: the site's ground is re-sampled from an edited
/// field, while a save re-grades pristine ground on load — a deck stored
/// relative to either would move.
library;

import 'dart:math' as math;

import 'parcel.dart';

/// The limits and thresholds. Cities: Skylines' numbers where it has them
/// (steps of 3/6/12 m, 60 m up, 36 m down).
class RoadElevation {
  const RoadElevation._();

  /// The elevation steps PAGE UP / PAGE DOWN move by.
  static const List<double> stepChoicesM = [3, 6, 12];
  static const double defaultStepM = 12;

  /// Highest a road end may be raised above the ground under it.
  static const double maxHeightM = 60;

  /// Deepest a road end may be sunk below it.
  static const double maxDepthM = 36;

  /// A deck more than this above the ground is carried on piers rather than
  /// on fill — no embankment is built taller than a storey.
  static const double structureClearM = 2.5;

  /// A structure taller than this is a BRIDGE: longer spans, heavier
  /// girders, a higher price.
  static const double bridgeHeightM = 15;

  /// A deck more than this below the ground is in a tunnel; less, and the
  /// ground is cut down to it (a cutting, open to the sky).
  static const double tunnelCoverM = 5;

  /// Two roads whose decks cross this far apart vertically pass one over
  /// the other: no junction, neither cut.
  static const double gradeSeparationM = 4.5;

  /// Two road ends this close in height (and in plan) are the same node.
  static const double nodeMatchM = 2.0;

  /// Spacing of the ground samples a survey takes.
  static const double surveyStepM = 8;

  /// The lowest and highest offset the tool may set for [cls].
  static double minOffsetFor(RoadClass cls) => cls.canTunnel ? -maxDepthM : 0;
  static double maxOffsetFor(RoadClass cls) => cls.canElevate ? maxHeightM : 0;

  /// [current] moved one [stepM] in [direction] (+1 up, -1 down) and
  /// clamped to what [cls] allows. The step lands on a multiple of itself,
  /// so +3 from +6 on the 12 m step goes to +12, not +18.
  static double step(
      double current, int direction, double stepM, RoadClass cls) {
    final lo = minOffsetFor(cls), hi = maxOffsetFor(cls);
    final snapped = direction > 0
        ? ((current + 1e-6) / stepM).floor() * stepM + stepM
        : ((current - 1e-6) / stepM).ceil() * stepM - stepM;
    return snapped.clamp(lo, hi).toDouble();
  }

  /// What a deck [deckMinusGroundM] above the ground (negative: below) is.
  static RoadStretch stretchFor(double deckMinusGroundM) {
    if (deckMinusGroundM > structureClearM) return RoadStretch.structure;
    if (deckMinusGroundM < -tunnelCoverM) return RoadStretch.tunnel;
    return RoadStretch.graded;
  }
}

/// What a stretch of deck is.
enum RoadStretch {
  /// Near the ground: the ground is cut or filled to meet it.
  graded,

  /// Clear of the ground, on piers (a bridge above
  /// [RoadElevation.bridgeHeightM]).
  structure,

  /// Deep under it.
  tunnel,
}

/// Why a raised or sunk road was refused.
enum DeckRefusal { tooSteep, tooHigh, tooDeep, noTunnel, noElevation }

/// A deck walked against the ground: its structure and tunnel ranges, and
/// how much of it is which.
class DeckSurvey {
  const DeckSurvey({
    required this.lengthM,
    this.structures = const [],
    this.tunnels = const [],
    this.bridgeM = 0,
    this.maxClearanceM = 0,
    this.maxCoverM = 0,
  });

  /// A road that never leaves grade.
  static const DeckSurvey flat = DeckSurvey(lengthM: 0);

  final double lengthM;

  /// Arc ranges (metres from the road's first point) on piers, and
  /// underground.
  final List<(double, double)> structures;
  final List<(double, double)> tunnels;

  /// Metres of the structures tall enough to be bridges.
  final double bridgeM;

  /// Highest the deck stands above the ground, and deepest it runs below.
  final double maxClearanceM;
  final double maxCoverM;

  double get structureM => _total(structures);
  double get tunnelM => _total(tunnels);

  static double _total(List<(double, double)> r) =>
      r.fold(0.0, (s, x) => s + (x.$2 - x.$1));
}

/// Walk [polyline] (colony-local, first point to last) with a straight deck
/// from [startM] to [endM] (above the body datum) against [groundAt] (the
/// natural ground's height above the datum under a local point), sampling
/// every [stepM], and classify every stretch.
///
/// A boundary between two kinds falls half way between the samples that
/// disagree; ranges of one kind shorter than a sample step are kept — a
/// short bridge over a ditch is still a bridge.
DeckSurvey surveyDeck(
  List<Vec2> polyline, {
  required double startM,
  required double endM,
  required double Function(Vec2) groundAt,
  double stepM = RoadElevation.surveyStepM,
}) {
  if (polyline.length < 2) return DeckSurvey.flat;
  final cum = <double>[0];
  for (var i = 1; i < polyline.length; i++) {
    cum.add(cum[i - 1] + polyline[i].distanceTo(polyline[i - 1]));
  }
  final total = cum.last;
  if (total <= 1e-9) return DeckSurvey.flat;

  Vec2 pointAt(double s) {
    for (var i = 1; i < polyline.length; i++) {
      if (cum[i] >= s) {
        final seg = cum[i] - cum[i - 1];
        final t = seg <= 1e-12 ? 0.0 : (s - cum[i - 1]) / seg;
        return polyline[i - 1] + (polyline[i] - polyline[i - 1]) * t;
      }
    }
    return polyline.last;
  }

  final n = math.max(1, (total / stepM).ceil());
  final ss = [for (var k = 0; k <= n; k++) total * k / n];
  final kinds = <RoadStretch>[];
  final above = <double>[];
  for (final s in ss) {
    final deck = startM + (endM - startM) * (s / total);
    final d = deck - groundAt(pointAt(s));
    above.add(d);
    kinds.add(RoadElevation.stretchFor(d));
  }

  final structures = <(double, double)>[];
  final tunnels = <(double, double)>[];
  var bridgeM = 0.0;
  var runStart = 0;
  for (var k = 1; k <= ss.length; k++) {
    if (k < ss.length && kinds[k] == kinds[runStart]) continue;
    final a = runStart == 0 ? 0.0 : (ss[runStart - 1] + ss[runStart]) / 2;
    final b = k == ss.length ? total : (ss[k - 1] + ss[k]) / 2;
    switch (kinds[runStart]) {
      case RoadStretch.structure:
        structures.add((a, b));
        // Bridge metres: the samples in the run standing above the bridge
        // height, each worth its share of the run.
        final count = k - runStart;
        final tall = [
          for (var j = runStart; j < k; j++)
            if (above[j] > RoadElevation.bridgeHeightM) j
        ].length;
        bridgeM += (b - a) * tall / count;
      case RoadStretch.tunnel:
        tunnels.add((a, b));
      case RoadStretch.graded:
        break;
    }
    runStart = k;
  }
  return DeckSurvey(
    lengthM: total,
    structures: structures,
    tunnels: tunnels,
    bridgeM: bridgeM,
    maxClearanceM: above.fold(0.0, math.max),
    maxCoverM: above.fold(0.0, (m, d) => math.max(m, -d)),
  );
}

/// Why [startOffsetM]/[endOffsetM] (above the ground at each end) with a
/// deck [startM]..[endM] over [lengthM] and its [survey] cannot be built as
/// [cls], or null when it can.
DeckRefusal? checkDeck(
  RoadClass cls, {
  required double startM,
  required double endM,
  required double startOffsetM,
  required double endOffsetM,
  required double lengthM,
  required DeckSurvey survey,
}) {
  final hi = math.max(startOffsetM, endOffsetM);
  final lo = math.min(startOffsetM, endOffsetM);
  if (hi > 1e-6 && !cls.canElevate) return DeckRefusal.noElevation;
  if (hi > RoadElevation.maxHeightM + 1e-6) return DeckRefusal.tooHigh;
  if (lo < -RoadElevation.maxDepthM - 1e-6) return DeckRefusal.tooDeep;
  if (survey.tunnels.isNotEmpty && !cls.canTunnel) return DeckRefusal.noTunnel;
  if (lengthM > 1e-6 &&
      (endM - startM).abs() / lengthM * 100 > cls.maxGradePct + 1e-9) {
    return DeckRefusal.tooSteep;
  }
  return null;
}
