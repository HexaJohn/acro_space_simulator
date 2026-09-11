// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What controls a junction, and the rule that decides it.
///
/// A junction is a place where road ENDS meet — the layout splits every
/// road at its crossings, the sprawl plan splits its own, so the topology
/// is real and a junction is simply three or more ends on one point. What
/// it LOOKS like — a plate with stop bars, a signal mast on every corner, a
/// roundabout with an island — is decided here, once, from the classes of
/// the roads meeting, the way a traffic engineer's warrant does: a crossing
/// of two arterials gets signals whether it is downtown or at the mile
/// grid, and the renderer that draws the core and the one that draws the
/// suburbs ask the same question and get the same answer.
library;

import 'parcel.dart';

/// How a junction is controlled.
enum JunctionControl {
  /// Two ends meeting: a road carrying on round a corner, or a change of
  /// class mid-run. Nothing is drawn.
  none,

  /// A ramp leaving or joining a limited-access road: a taper and a gore,
  /// no plate, nothing to stop for.
  merge,

  /// An all-way stop: a plate, stop bars and a sign on every leg. Local
  /// streets crossing each other.
  stop,

  /// A signalised crossing: plate, stop bars, zebras and a mast per leg.
  signals,

  /// A roundabout: a circular plate round a raised island, yield lines on
  /// the approaches, no signals.
  roundabout,
}

/// The control a junction of [legs] gets.
///
/// [roundaboutPreferred] is the planner's say — a subdivision's collectors
/// cross at a roundabout because that is what a subdivision builds, not
/// because the classes demand it — and it is honoured only where a
/// roundabout is possible: three or more legs, none of them fast.
JunctionControl junctionControlFor(
  List<RoadClass> legs, {
  bool roundaboutPreferred = false,
}) {
  if (legs.length < 3) {
    // A ramp meeting an expressway end-on is a merge even as two legs: the
    // expressway is split there, so the mainline is two legs and the ramp
    // a third — but a ramp landing exactly on the end of one is still a
    // merge, not a corner.
    if (legs.length == 2 && legs.any((c) => c.limitedAccess)) {
      return JunctionControl.merge;
    }
    return JunctionControl.none;
  }
  final limited = legs.where((c) => c.limitedAccess).length;
  // An expressway ENDING at an arterial — one limited-access leg among
  // ordinary ones, none of them ramps — is where the expressway ends, and
  // a real one ends at a signal.
  if (limited == 1 &&
      legs.length >= 3 &&
      !legs.any((c) => c == RoadClass.ramp) &&
      legs.where((c) => c.arterial).length >= 2) {
    return JunctionControl.signals;
  }
  if (limited > 0) return JunctionControl.merge;
  if (roundaboutPreferred && legs.every((c) => !c.arterial || c == RoadClass.avenue)) {
    return JunctionControl.roundabout;
  }
  // Two arterial legs — the through road of a T, or both roads of a
  // crossing — warrant signals. A ramp terminal on an avenue is exactly
  // this: the avenue runs through, the ramp is the third leg.
  final arterials = legs.where((c) => c.arterial).length;
  if (arterials >= 2) return JunctionControl.signals;
  return JunctionControl.stop;
}

// ---- The player's warrant: legs, directions, overrides ---------------------

/// One road END at a junction, as the warrant needs to see it.
///
/// Junctions are where road ends meet, and the city-builder rules for
/// traffic lights turn on more than the classes meeting: a one-way road
/// LEAVING a four-lane road does not get a light, and neither — in some
/// cases — does a two-lane road drawn away from it. So a leg carries which
/// end of its road this is: [startsHere] is true when the road's FIRST
/// point (in the direction of travel, for a one-way road) is at the
/// junction.
class JunctionLeg {
  const JunctionLeg(this.roadClass, {this.startsHere = false, this.heading = 0});

  final RoadClass roadClass;

  /// The road's first point — its start, and the start of travel on a
  /// one-way road — is at this junction.
  final bool startsHere;

  /// Direction of the leg AWAY from the junction, radians, north toward
  /// east ([Vec2.heading]'s convention). What a stop-sign override names a
  /// leg by, since road ids change every time a road is split.
  final double heading;

  bool get oneWay => roadClass.oneWay;

  /// Traffic on this leg only ever leaves the junction.
  bool get outgoing => oneWay && startsHere;

  /// Traffic arrives at the junction along this leg.
  bool get inbound => !outgoing;
}

/// A junction's control and which of its legs stop.
class JunctionPlan {
  const JunctionPlan(this.control, [this.stopLegs = const {}]);

  final JunctionControl control;

  /// Indices into the legs that carry a STOP sign — meaningful only when
  /// [control] is [JunctionControl.stop] (no lights). An outgoing one-way
  /// leg never stops: nothing arrives along it.
  final Set<int> stopLegs;

  bool get lights => control == JunctionControl.signals;
}

/// A player's say over one junction, from the Junctions view: lights on or
/// off, and which legs stop. Keyed by WHERE the junction is — road ids
/// change whenever a road is split, a junction's place does not.
class JunctionOverride {
  const JunctionOverride({required this.at, this.lights, this.stopHeadings});

  /// The junction, colony-local metres.
  final Vec2 at;

  /// Lights forced on (true) or off (false); null leaves the warrant's.
  final bool? lights;

  /// Headings ([JunctionLeg.heading]) of the legs that stop; null leaves
  /// the default stop legs.
  final List<double>? stopHeadings;

  /// How near a junction must be to [at] to be this one. Wider than a
  /// junction's own spread (its ends meet within a few metres), narrower
  /// than the gap between two junctions a block apart.
  static const double matchM = 6.0;

  /// How near a leg's heading must be to a stored one to be that leg.
  static const double headingMatchRad = 25 * 3.141592653589793 / 180;

  /// A map key for [at]: whole metres.
  static String keyFor(Vec2 at) => '${at.e.round()},${at.n.round()}';
  String get key => keyFor(at);

  bool get isEmpty => lights == null && stopHeadings == null;

  bool matches(Vec2 p) => p.distanceTo(at) <= matchM;

  JunctionOverride copyWith({
    bool? lights,
    bool clearLights = false,
    List<double>? stopHeadings,
    bool clearStops = false,
  }) =>
      JunctionOverride(
        at: at,
        lights: clearLights ? null : (lights ?? this.lights),
        stopHeadings: clearStops ? null : (stopHeadings ?? this.stopHeadings),
      );

  Map<String, dynamic> toJson() => {
        'at': [at.e, at.n],
        if (lights != null) 'lights': lights,
        if (stopHeadings != null) 'stops': stopHeadings,
      };

  factory JunctionOverride.fromJson(Map<String, dynamic> j) {
    final at = (j['at'] as List).cast<num>();
    return JunctionOverride(
      at: Vec2(at[0].toDouble(), at[1].toDouble()),
      lights: j['lights'] as bool?,
      stopHeadings: (j['stops'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
    );
  }
}

/// The control a junction of [legs] gets by the city-builder's rules.
///
/// - A road meeting only two-lane roads (one way or two) gets no lights.
/// - A FOUR-LANE road gets lights at its crossings, except where the other
///   roads are one-way roads leaving it or two-lane two-way roads drawn
///   away from it — and this rule overrides every other road's no-lights
///   rule, so a four-lane road meeting a highway does get lights.
/// - A SIX-LANE road gets lights at every crossing except one-way roads
///   leaving it.
/// - A HIGHWAY gets no lights where everything it meets is one way, and
///   lights where it is not.
/// - A two-lane roundabout (the planner's collectors) never has lights.
///
/// Limited-access roads — the generator's expressways and viaducts — keep
/// the merge warrant of [junctionControlFor]; nothing the player builds is
/// limited-access.
JunctionControl junctionControlForLegs(
  List<JunctionLeg> legs, {
  bool roundaboutPreferred = false,
}) {
  final cars = [
    for (final l in legs)
      if (l.roadClass.carriesCars) l
  ];
  if (cars.length < 3) {
    if (cars.length == 2 && cars.any((l) => l.roadClass.limitedAccess)) {
      return JunctionControl.merge;
    }
    return JunctionControl.none;
  }
  if (cars.any((l) => l.roadClass.limitedAccess)) {
    return junctionControlFor([for (final l in cars) l.roadClass],
        roundaboutPreferred: roundaboutPreferred);
  }
  if (roundaboutPreferred &&
      cars.every((l) =>
          l.roadClass.tier == RoadTier.minor ||
          l.roadClass == RoadClass.avenue)) {
    return JunctionControl.roundabout;
  }
  return trafficLightsByRule(cars)
      ? JunctionControl.signals
      : JunctionControl.stop;
}

/// Whether the city-builder's rules put traffic lights on a junction of
/// [legs] (all of them car roads, three or more). See
/// [junctionControlForLegs].
bool trafficLightsByRule(List<JunctionLeg> legs) {
  bool tierOf(JunctionLeg l, RoadTier t) => l.roadClass.tier == t;

  // Four-lane roads: lights, unless every other leg is a one-way road
  // leaving (a highway is a highway, never an exception) or a two-lane
  // two-way road drawn away from the four-lane. Overrides every no-lights
  // rule below.
  final medium = legs.where((l) => tierOf(l, RoadTier.medium)).length;
  if (medium > 0) {
    if (medium >= 3) return true;
    for (final l in legs) {
      if (tierOf(l, RoadTier.medium)) continue;
      final leavingOneWay = l.outgoing && !tierOf(l, RoadTier.highway);
      final drawnAway = !l.oneWay && l.startsHere && tierOf(l, RoadTier.minor);
      if (!leavingOneWay && !drawnAway) return true;
    }
    return false;
  }

  // Six-lane roads: lights, unless every other leg is a one-way road
  // leaving.
  final large = legs.where((l) => tierOf(l, RoadTier.large)).length;
  if (large > 0) {
    if (large >= 3) return true;
    return legs.any((l) => !tierOf(l, RoadTier.large) && !l.outgoing);
  }

  // Highways: no lights where everything else is one way.
  if (legs.any((l) => tierOf(l, RoadTier.highway))) {
    return legs.any((l) => !tierOf(l, RoadTier.highway) && !l.oneWay);
  }

  // Two-lane roads never make lights.
  return false;
}

/// The legs that stop at a junction without lights: every inbound leg
/// when they are all the same size of road (an all-way stop), else the
/// inbound legs smaller than the biggest road there (they give way to it).
///
/// "All the same size" is every car leg, the ones leaving included. Asked
/// of the inbound legs alone, a ramp or a one-way street LEAVING a highway
/// or a four-lane road left only the through road arriving — all of it
/// the top size — so the through road was stopped at its own exit, where
/// nothing crosses it.
Set<int> defaultStopLegs(List<JunctionLeg> legs) {
  int rank(JunctionLeg l) => l.roadClass.tier.rank;
  var top = -1;
  for (final l in legs) {
    if (l.roadClass.carriesCars && rank(l) > top) top = rank(l);
  }
  final inbound = [
    for (var i = 0; i < legs.length; i++)
      if (legs[i].inbound && legs[i].roadClass.carriesCars) i
  ];
  if (legs.every((l) => !l.roadClass.carriesCars || rank(l) == top)) {
    return inbound.toSet();
  }
  return {
    for (final i in inbound)
      if (rank(legs[i]) < top) i
  };
}

/// Everything a junction of [legs] is: the control (the warrant, or the
/// player's [override]) and the legs that stop.
JunctionPlan junctionPlanFor(
  List<JunctionLeg> legs, {
  bool roundaboutPreferred = false,
  JunctionOverride? override,
}) {
  var control =
      junctionControlForLegs(legs, roundaboutPreferred: roundaboutPreferred);
  if (override != null &&
      (control == JunctionControl.stop || control == JunctionControl.signals)) {
    if (override.lights == true) control = JunctionControl.signals;
    if (override.lights == false) control = JunctionControl.stop;
  }
  if (control != JunctionControl.stop) return JunctionPlan(control);
  final headings = override?.stopHeadings;
  if (headings == null) return JunctionPlan(control, defaultStopLegs(legs));
  return JunctionPlan(control, {
    for (var i = 0; i < legs.length; i++)
      if (legs[i].inbound &&
          legs[i].roadClass.carriesCars &&
          headings.any((h) =>
              _angleBetween(h, legs[i].heading) <=
              JunctionOverride.headingMatchRad))
        i
  });
}

double _angleBetween(double a, double b) {
  const tau = 2 * 3.141592653589793;
  var d = (a - b) % tau;
  if (d < 0) d += tau;
  return d > tau / 2 ? tau - d : d;
}

// ---- One warrant for the tiles and the sim ---------------------------------

/// Whether [cls] is a road only the road tool lays — one the generator never
/// has — so that a junction with a leg of it is the tool's to decide (see
/// [keepsClassWarrant]). Exhaustive on purpose: a class appended to the menu
/// must say whether the generator lays it too.
bool roadToolOnly(RoadClass cls) => switch (cls) {
      RoadClass.streetOneWay || RoadClass.boulevard || RoadClass.motorway =>
        true,
      RoadClass.street ||
      RoadClass.avenue ||
      RoadClass.highway ||
      RoadClass.path ||
      RoadClass.alley ||
      RoadClass.elevated ||
      RoadClass.transit ||
      RoadClass.trunk ||
      RoadClass.rail ||
      RoadClass.expressway4 ||
      RoadClass.expressway6 ||
      RoadClass.expressway8 ||
      RoadClass.ramp =>
        false,
    };

/// Whether a junction of [legs] keeps the class-only warrant the
/// generator's towns have always had ([junctionControlFor]): true unless
/// the road tool had a hand in it — a leg of a class only the tool lays
/// ([roadToolOnly]), or a leg on a deck ([lifted]; the generator's roads lie
/// on the ground, so any deck is the tool's).
///
/// The leg-aware warrant ([junctionPlanFor]) reads which way each road was
/// DRAWN — a two-lane road drawn away from a four-lane one makes no lights —
/// and that is the player's say: the tool draws a road the way its traffic
/// runs. The generator draws its two-way streets in no particular
/// direction, so read by that warrant its avenue T's would get lights at one
/// corner and a stop sign at the next, at random.
bool keepsClassWarrant(List<JunctionLeg> legs, {bool lifted = false}) =>
    !lifted && !legs.any((l) => roadToolOnly(l.roadClass));

/// The plan a junction of [legs] is drawn by in the tiles AND timed by in
/// the sim's road graph — the one question both ask, so a light the player
/// sees is a light the traffic waits at.
///
/// The class-only warrant, every arriving leg stopping, where
/// [keepsClassWarrant] keeps it; the leg-aware [junctionPlanFor] where the
/// tool had a hand. A player's [override] applies over whichever warrant
/// the legs chose — lights forced on or off where there is a stop or a
/// signal, and at a stop the legs its [JunctionOverride.stopHeadings] name —
/// so choosing the stop signs never swaps the warrant under the player.
JunctionPlan junctionPlanForNetwork(
  List<JunctionLeg> legs, {
  bool lifted = false,
  bool roundaboutPreferred = false,
  JunctionOverride? override,
}) {
  if (!keepsClassWarrant(legs, lifted: lifted)) {
    return junctionPlanFor(legs,
        roundaboutPreferred: roundaboutPreferred, override: override);
  }
  var control = junctionControlFor([for (final l in legs) l.roadClass],
      roundaboutPreferred: roundaboutPreferred);
  if (override != null &&
      (control == JunctionControl.stop || control == JunctionControl.signals)) {
    if (override.lights == true) control = JunctionControl.signals;
    if (override.lights == false) control = JunctionControl.stop;
  }
  if (control != JunctionControl.stop) return JunctionPlan(control);
  final headings = override?.stopHeadings;
  return JunctionPlan(control, {
    for (var i = 0; i < legs.length; i++)
      if (legs[i].inbound &&
          (headings == null ||
              (legs[i].roadClass.carriesCars &&
                  headings.any((h) =>
                      _angleBetween(h, legs[i].heading) <=
                      JunctionOverride.headingMatchRad))))
        i
  });
}
