// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool's side of the colony: a road the player has drawn, what it
/// would cost, and why it cannot be built.
///
/// The generator and the starter kit lay roads for free through
/// `CitySim.commitRoad`; a PLAYER builds through `CitySim.buildRoad`, which
/// prices the road first. The price is not the length alone: the stretch a
/// raised road carries on piers, the stretch of it tall enough to be a
/// bridge and the stretch a sunk road runs underground each cost multiples
/// of the road at grade (see [RoadCosts]), and which stretch is which is
/// decided by walking the deck against the ground ([surveyDeck]) — the same
/// survey the renderer's piers and the shaper's corridor are drawn from, so
/// the bill, the picture and the ground can never disagree.
///
/// Pure: [quoteRoadBuild] takes the treasury and the unlock as numbers and
/// touches nothing, so the editor can price a road on every mouse move.
library;

import 'dart:math' as math;

import 'parcel.dart';
import 'road_catalog.dart';
import 'road_elevation.dart';

/// Why a road cannot be built (or upgraded, reversed, re-laid).
enum RoadRefusal {
  /// Shorter than a cell: nothing worth a junction.
  tooShort,

  /// Steeper than the type's grade limit.
  tooSteep,

  /// An end raised past [RoadElevation.maxHeightM].
  tooHigh,

  /// An end sunk past [RoadElevation.maxDepthM].
  tooDeep,

  /// It would run underground, and the type cannot (a gravel road).
  noTunnel,

  /// It would be raised, and the type's class already fixes its height.
  noElevation,

  /// The colony has not reached the type's milestone.
  locked,

  /// The treasury cannot pay for it.
  funds,

  /// The road it names is gone.
  notFound,

  /// Only a one-way road has a direction to reverse.
  notOneWay,
}

/// A road the player has drawn and wants built.
class RoadBuildRequest {
  const RoadBuildRequest({
    required this.controls,
    required this.type,
    this.startElevationM = 0,
    this.endElevationM = 0,
    this.startHeightM,
    this.endHeightM,
    this.snapStart = true,
    this.snapEnd = true,
  });

  /// Control points, first to last: the direction it was drawn in and, for
  /// a one-way type, the direction its traffic runs. Either the controls
  /// of a centripetal Catmull-Rom spline or a dense polyline (a curve the
  /// tool already evaluated) — sampled at 2 m, both come out as the line
  /// they describe.
  final List<Vec2> controls;

  final RoadType type;

  /// The tool's elevation at each end: metres above the ground under it
  /// (negative below), in PAGE UP / PAGE DOWN steps.
  final double startElevationM, endElevationM;

  /// Absolute deck height at an end, metres above the body datum, where it
  /// joins an existing RAISED or SUNK road (`CitySim.deckHeightAt`) — the
  /// new road meets that deck where it is, whatever the ground under it.
  /// Overrides the elevation at that end. Leave null where an end joins a
  /// road laid on the ground: an end at grade meets it there anyway.
  final double? startHeightM, endHeightM;

  /// Whether each end may snap onto a road it is drawn near (15 m).
  final bool snapStart, snapEnd;

  /// Both ends on the ground and nothing asked of the deck: the road is
  /// DRAPED, as every road was before the tool could lift one.
  bool get atGrade =>
      startElevationM.abs() < 1e-9 &&
      endElevationM.abs() < 1e-9 &&
      startHeightM == null &&
      endHeightM == null;
}

/// What a road would cost, and whether it can be built.
class RoadQuote {
  const RoadQuote({
    required this.type,
    this.lengthM = 0,
    this.cost = 0,
    this.upkeepPerWeek = 0,
    this.structureM = 0,
    this.bridgeM = 0,
    this.tunnelM = 0,
    this.gradePct = 0,
    this.gradeLimitPct = 0,
    this.deck,
    this.refusal,
  });

  /// A refusal with nothing priced: the road it names is gone, a two-way
  /// road cannot be reversed.
  factory RoadQuote.refused(RoadType type, RoadRefusal refusal) => RoadQuote(
      type: type, gradeLimitPct: type.roadClass.maxGradePct, refusal: refusal);

  final RoadType type;

  /// Centreline length, metres.
  final double lengthM;

  /// Construction, §. For an upgrade, the difference; for a re-laid end,
  /// the road as re-laid less the road it replaces.
  final double cost;

  /// What it will cost to keep, § per week.
  final double upkeepPerWeek;

  /// Metres of it on piers, of that tall enough to be a bridge, and
  /// underground.
  final double structureM, bridgeM, tunnelM;

  /// Steepest grade found (the deck's, for a raised or sunk road), and the
  /// type's limit, percent.
  final double gradePct, gradeLimitPct;

  /// Where it runs when it is raised or sunk; null for a road laid on the
  /// ground. What `CitySim.buildRoad` hands the layout.
  final RoadDeck? deck;

  /// Why it cannot be built, or null when it can.
  final RoadRefusal? refusal;

  bool get ok => refusal == null;

  /// The refusal as the player reads it; empty when [ok].
  String get reason => switch (refusal) {
        null => '',
        RoadRefusal.tooShort =>
          'Too short: a road needs at least ${kMinRoadLengthM.round()} m',
        RoadRefusal.tooSteep => 'Slope too steep for ${_article(type.label)} '
            '${type.label} (${gradePct.toStringAsFixed(1)}% of '
            '${_pct(gradeLimitPct)}%)',
        RoadRefusal.tooHigh => 'Too high: a road may stand at most '
            '${RoadElevation.maxHeightM.round()} m above the ground',
        RoadRefusal.tooDeep => 'Too deep: a tunnel may run at most '
            '${RoadElevation.maxDepthM.round()} m below the ground',
        RoadRefusal.noTunnel => type.roadClass == RoadClass.path
            ? 'Gravel roads cannot go underground'
            : '${_article(type.label, capital: true)} ${type.label} cannot '
                'go underground',
        RoadRefusal.noElevation =>
          '${_article(type.label, capital: true)} ${type.label} is built at '
              'its own height and cannot be raised',
        RoadRefusal.locked => 'Opens at ${type.unlockPop} population',
        RoadRefusal.funds => 'Not enough money: ${formatMoney(cost)} needed',
        RoadRefusal.notFound => 'That road is no longer there',
        RoadRefusal.notOneWay =>
          'Only a one-way road has a direction to reverse',
      };

  RoadQuote copyWith({
    double? cost,
    RoadRefusal? refusal,
    bool clearRefusal = false,
  }) =>
      RoadQuote(
        type: type,
        lengthM: lengthM,
        cost: cost ?? this.cost,
        upkeepPerWeek: upkeepPerWeek,
        structureM: structureM,
        bridgeM: bridgeM,
        tunnelM: tunnelM,
        gradePct: gradePct,
        gradeLimitPct: gradeLimitPct,
        deck: deck,
        refusal: clearRefusal ? null : (refusal ?? this.refusal),
      );

  @override
  String toString() => 'RoadQuote(${type.id}, ${lengthM.toStringAsFixed(1)} m, '
      '§${cost.toStringAsFixed(0)}${ok ? '' : ', ${refusal!.name}'})';
}

/// The shortest road the tool lays: one of the 8 m cells it is priced per.
/// Anything shorter is a click, not a road — and the layout drops a piece
/// shorter than a car's length anyway.
const double kMinRoadLengthM = RoadCosts.cellM;

/// Price [r] and say whether it can be built.
///
/// The controls are sampled at 2 m (centripetal Catmull-Rom — a dense
/// polyline samples to itself). A road with both ends at grade and no
/// absolute heights is DRAPED: no deck, priced at grade, and grade-checked
/// against the ground only when [gradeGate] is set and [groundAt] given —
/// the free-build default ignores the slope under a road that follows the
/// land. Anything else gets a DECK: each end's height is its absolute
/// height when given, else the ground there plus its elevation; the deck
/// is surveyed against [groundAt] (null: flat ground at the datum) into
/// its pier and tunnel stretches, which price it, and [checkDeck] refuses
/// what cannot stand.
///
/// [groundAt] is the natural ground's height in metres above the BODY
/// DATUM under a colony-local point. [funds] and [unlocked] are the
/// treasury and the type's unlock, passed in so this stays pure.
RoadQuote quoteRoadBuild(
  RoadBuildRequest r, {
  double Function(Vec2)? groundAt,
  bool gradeGate = false,
  double funds = double.infinity,
  bool unlocked = true,
}) {
  final type = r.type;
  final cls = type.roadClass;
  final pts = r.controls.length < 2
      ? List<Vec2>.of(r.controls)
      : RoadSpline(id: 'quote', controls: r.controls, roadClass: cls)
          .sample(stepM: 2);
  var lengthM = 0.0;
  for (var i = 1; i < pts.length; i++) {
    lengthM += pts[i].distanceTo(pts[i - 1]);
  }
  if (pts.length < 2 || lengthM < kMinRoadLengthM) {
    return RoadQuote(
      type: type,
      lengthM: lengthM,
      gradeLimitPct: cls.maxGradePct,
      refusal: RoadRefusal.tooShort,
    );
  }

  RoadDeck? deck;
  var survey = DeckSurvey.flat;
  var gradePct = 0.0;
  RoadRefusal? refusal;
  if (r.atGrade) {
    if (gradeGate && groundAt != null) {
      final g = RoadGradeCheck.of(pts, groundAt, cls);
      gradePct = g.maxPct;
      if (!g.ok) refusal = RoadRefusal.tooSteep;
    }
  } else {
    final ground = groundAt ?? _flatGround;
    final g0 = ground(pts.first), g1 = ground(pts.last);
    final startM = r.startHeightM ?? g0 + r.startElevationM;
    final endM = r.endHeightM ?? g1 + r.endElevationM;
    survey = surveyDeck(pts, startM: startM, endM: endM, groundAt: ground);
    deck = RoadDeck(
      startM: startM,
      endM: endM,
      startOffsetM: startM - g0,
      endOffsetM: endM - g1,
      structures: survey.structures,
      tunnels: survey.tunnels,
    );
    gradePct = deck.gradePct(lengthM);
    refusal = switch (checkDeck(
      cls,
      startM: startM,
      endM: endM,
      startOffsetM: startM - g0,
      endOffsetM: endM - g1,
      lengthM: lengthM,
      survey: survey,
    )) {
      null => null,
      DeckRefusal.tooSteep => RoadRefusal.tooSteep,
      DeckRefusal.tooHigh => RoadRefusal.tooHigh,
      DeckRefusal.tooDeep => RoadRefusal.tooDeep,
      DeckRefusal.noTunnel => RoadRefusal.noTunnel,
      DeckRefusal.noElevation => RoadRefusal.noElevation,
    };
  }

  final cost = RoadCosts.construction(
    type,
    lengthM: lengthM,
    structureM: survey.structureM,
    bridgeM: survey.bridgeM,
    tunnelM: survey.tunnelM,
  );
  final upkeep = RoadCosts.upkeepPerWeek(
    type,
    lengthM: lengthM,
    structureM: survey.structureM,
    tunnelM: survey.tunnelM,
  );
  // What the road IS comes first — a road too steep to stand is too steep
  // whatever the treasury says — then whether the colony may and can pay.
  refusal ??= !unlocked
      ? RoadRefusal.locked
      : (cost > funds + 1e-9 ? RoadRefusal.funds : null);
  return RoadQuote(
    type: type,
    lengthM: lengthM,
    cost: cost,
    upkeepPerWeek: upkeep,
    structureM: survey.structureM,
    bridgeM: survey.bridgeM,
    tunnelM: survey.tunnelM,
    gradePct: gradePct,
    gradeLimitPct: cls.maxGradePct,
    deck: deck,
    refusal: refusal,
  );
}

/// Metres of [deck]'s pier stretches standing taller than a bridge on a
/// road [lengthM] long, with no ground to ask: estimated from the height it
/// was laid at each end ([RoadDeck.offsetAt]). A last resort — the ends say
/// nothing of a valley between them, so a bridge over one whose ends are
/// at grade estimates as no bridge at all; with the ground, see
/// [measureBridgeM].
double estimateBridgeM(RoadDeck deck, double lengthM) =>
    _tallM(deck, (s) => deck.offsetAt(s, lengthM));

/// Metres of [deck]'s pier stretches standing taller than a bridge over
/// [groundAt] (metres above the body datum), the road running along
/// [polyline] (colony-local, first point to last, the line the deck's
/// ranges are measured on). What the survey that priced the road counted
/// as bridge, measured again over the stretches the deck stands on — so an
/// upgrade prices a bridge as a bridge.
double measureBridgeM(
    RoadDeck deck, List<Vec2> polyline, double Function(Vec2) groundAt) {
  if (polyline.length < 2) return 0;
  final cum = <double>[0];
  for (var i = 1; i < polyline.length; i++) {
    cum.add(cum[i - 1] + polyline[i].distanceTo(polyline[i - 1]));
  }
  final lengthM = cum.last;
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

  return _tallM(
      deck, (s) => deck.heightAt(s, lengthM) - groundAt(pointAt(s)));
}

/// Metres of [deck]'s structures where [clearanceAt] (deck above the
/// ground at an arc) passes the bridge height, sampled every 4 m.
double _tallM(RoadDeck deck, double Function(double s) clearanceAt) {
  var total = 0.0;
  for (final (a, b) in deck.structures) {
    final span = b - a;
    if (span <= 0) continue;
    final n = math.max(1, (span / 4).ceil());
    var tall = 0;
    for (var k = 0; k < n; k++) {
      final s = a + span * (k + 0.5) / n;
      if (clearanceAt(s) > RoadElevation.bridgeHeightM) tall++;
    }
    total += span * tall / n;
  }
  return total;
}

/// How far past the point an end is dragged back to a road's own interior
/// control is dropped with the stretch it stood on ([controlsWithMovedEnd]):
/// a cell, which is also the shortest piece the layout keeps. A control
/// kept closer would turn the new end through a kink over a metre or two.
const double kRelayClearM = RoadCosts.cellM;

/// [controls] with the end [atStart] (the FIRST control, else the last)
/// moved to [to] — Adjust Roads' re-laid line.
///
/// Where [to] lies back ALONG the road — it projects onto the road's own
/// line inside it — the stretch between the old end and that point is
/// given up: every interior control on it (and within [kRelayClearM]
/// beyond it) is dropped, and the road runs from [to] on through the
/// controls past it. Only swapping the end control, a curved road's end
/// dragged back 25 m ran from [to] BACK through the controls it passed
/// and on again — a Z folded over itself, platted on both folds and
/// priced as added length. Where [to] projects off the end (the road is
/// dragged longer) only the end control moves, as it always did — and so
/// it does where [to] is nearer another arm of the road than the stretch
/// by the end: the projection is looked for only as far round the road
/// as a drag that long could have come back along it.
///
/// The controls are a centripetal Catmull-Rom spline's or a dense
/// polyline's, as the layout keeps them; the other end is never moved.
List<Vec2> controlsWithMovedEnd(
  List<Vec2> controls, {
  required bool atStart,
  required Vec2 to,
}) {
  if (controls.length < 2) return [to];
  // Work from the moved end: the spline through the controls reversed is
  // the same line walked the other way.
  final cs = atStart ? controls : controls.reversed.toList();
  List<Vec2> finish(List<Vec2> out) => atStart ? out : out.reversed.toList();
  final swapped = [to, ...cs.skip(1)];
  if (cs.length == 2) return finish(swapped);

  // The line as the layout samples it, and where each control lies on it:
  // `RoadSpline.sample` lays max(1, ceil(chord / step)) points per span,
  // the first of them ON the span's first control.
  const stepM = 2.0;
  final pts = RoadSpline(id: 'relay', controls: cs).sample(stepM: stepM);
  final at = <int>[0];
  for (var i = 0; i + 1 < cs.length; i++) {
    at.add(at.last + math.max(1, (cs[i].distanceTo(cs[i + 1]) / stepM).ceil()));
  }
  if (at.last != pts.length - 1) return finish(swapped); // not the layout's
  final cum = <double>[0];
  for (var i = 1; i < pts.length; i++) {
    cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
  }

  // Where [to] projects onto the line NEAR the moved end. An end dragged
  // [drag] metres back along the road can have passed at most the arc of a
  // semicircle on that chord; the line further on is another arm of the
  // road, not the stretch it was dragged back over. Searched to the far
  // end, the start of a U nudged 30 m aside toward its own far arm
  // projected 250 m round the road, dropped every control before it and
  // re-laid the road as a 10 m stub — every lot along it gone, for free.
  final drag = to.distanceTo(cs.first);
  final reach = drag * math.pi / 2 + kRelayClearM;
  var best = double.infinity;
  var sTo = 0.0;
  for (var i = 1; i < pts.length && cum[i - 1] <= reach; i++) {
    final a = pts[i - 1], ab = pts[i] - a;
    final len2 = ab.dot(ab);
    final t = len2 <= 1e-12
        ? 0.0
        : ((to - a).dot(ab) / len2).clamp(0.0, 1.0).toDouble();
    final d = to.distanceTo(a + ab * t);
    if (d < best) {
      best = d;
      sTo = cum[i - 1] + (cum[i] - cum[i - 1]) * t;
    }
  }
  if (sTo <= 1e-6) return finish(swapped); // dragged off the end: longer

  var k = 1; // the first control kept past the stretch given up
  while (k < cs.length - 1 && cum[at[k]] <= sTo + kRelayClearM) {
    k++;
  }
  // The net under the search's bound: the road runs from [to] straight to
  // the first control kept, so it is that much shorter than it was. A
  // drag can give up no more than the arc it could have passed; a road
  // cut far shorter than that is not what the player dragged, and only
  // the end moves.
  final shortened = cum[at[k]] - to.distanceTo(cs[k]);
  if (shortened > reach + kRelayClearM) return finish(swapped);

  return finish([to, ...cs.skip(k)]);
}

/// § as the HUD prints it: rounded up to the whole coin — a bill of
/// §1,239.20 needs §1,240 in the bank — with thousands separated.
String formatMoney(double amount) {
  final whole = amount.isFinite ? amount.ceil().abs() : 0;
  final digits = whole.toString();
  final out = StringBuffer(amount < 0 ? '-§' : '§');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

double _flatGround(Vec2 _) => 0;

String _pct(double v) => (v - v.roundToDouble()).abs() < 1e-9
    ? v.toStringAsFixed(0)
    : v.toStringAsFixed(1);

/// 'a' or 'an' for a road type's label: 'an Alley', 'an 8-Lane Expressway'.
String _article(String label, {bool capital = false}) {
  final an = label.isNotEmpty && 'AEIOUaeiou8'.contains(label[0]);
  final word = an ? 'an' : 'a';
  return capital ? '${word[0].toUpperCase()}${word.substring(1)}' : word;
}
