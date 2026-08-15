// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// When a colony's lights come on, and where they are.
///
/// Driven by the REAL sun direction rather than a clock, because in this sim
/// that is the thing that actually varies: a colony near a pole gets months of
/// dusk, a tidally locked one never sees night on its day side, and a moon in
/// its primary's shadow goes dark mid-afternoon. A time-of-day curve would get
/// all three wrong.
library;

import 'dart:math' as math;

import '../colony/city/city_sim.dart';
import '../colony/city/parcel.dart';
import 'building_massing.dart';

/// A lamp column: a road light, a car-park mast, or a pad floodlight.
class StreetLamp {
  /// Position in colony-local east/north metres.
  final Vec2 position;

  /// Column height in metres.
  final double heightM;

  /// Illuminated radius on the ground.
  final double radiusM;

  /// Warm sodium (true) or cold LED/industrial (false). Roads and car parks
  /// read differently at night, and it is nearly free to say which.
  final bool warm;

  const StreetLamp({
    required this.position,
    this.heightM = 9,
    this.radiusM = 22,
    this.warm = true,
  });
}

/// Everything the night pass needs for one colony this frame.
class LightingState {
  /// Sun elevation above the local horizon, radians. Negative is below.
  final double sunElevation;

  /// 0 in full day, 1 in full night, ramping through twilight.
  final double nightFactor;

  /// Whether street lighting is energised.
  final bool lampsOn;

  /// Fraction of a building's windows that are lit, 0..1.
  final double windowLitFraction;

  /// Dimming applied when the colony cannot meet its power demand — a
  /// brownout should be visible from orbit, not just in a readout.
  final double powerDim;

  const LightingState({
    required this.sunElevation,
    required this.nightFactor,
    required this.lampsOn,
    required this.windowLitFraction,
    required this.powerDim,
  });

  /// Final emissive multiplier for lamp heads.
  double get lampIntensity => lampsOn ? nightFactor * powerDim : 0;
}

class CityLighting {
  const CityLighting({
    this.rules = const BuildingMassingRules(),
    this.lampSpacingM = 34,
    this.dawnElevation = 0.10,
    this.duskElevation = -0.12,
    this.lampOnElevation = -0.02,
    this.lampOffElevation = 0.05,
  });

  /// Massing rules, shared with the building generator so car-park masts land
  /// where the generated lots actually are.
  final BuildingMassingRules rules;

  /// Along-road spacing between lamp columns on a street. Wider roads get
  /// proportionally wider spacing (and taller columns) below.
  final double lampSpacingM;

  /// Elevations (radians) bounding the twilight ramp.
  final double dawnElevation;
  final double duskElevation;

  /// Street lighting switches ON below [lampOnElevation] and OFF above
  /// [lampOffElevation]. The gap is deliberate hysteresis: with a single
  /// threshold, a colony sitting near it — which a high-latitude or slowly
  /// rotating one does for a long time — would flicker its whole grid every
  /// frame as the elevation dithered across the line.
  final double lampOnElevation;
  final double lampOffElevation;

  /// Lamp columns for every road in [city], plus the car-park masts the
  /// building generator placed.
  List<StreetLamp> lamps(CitySim city) {
    final out = <StreetLamp>[];
    for (final road in city.layout.roads) {
      final pts = road.sample(stepM: 2);
      if (pts.length < 2) continue;
      // Spacing and column height scale with the road: a highway lit on street
      // spacing is a runway, and a street lit on highway spacing is a tunnel
      // with holes in it.
      final scale = road.roadClass.width / RoadClass.street.width;
      final spacing = lampSpacingM * math.sqrt(scale);
      final height = 9.0 * math.sqrt(scale);
      final offset = road.halfWidth + 1.2;

      var travelled = 0.0;
      var next = spacing * 0.5;
      // Streets are lit from alternating sides (cheaper, and it is what real
      // residential streets do); anything wider is lit from both.
      var side = 1.0;
      final both = road.roadClass != RoadClass.street;
      for (var i = 1; i < pts.length; i++) {
        final seg = pts[i].distanceTo(pts[i - 1]);
        travelled += seg;
        if (travelled < next) continue;
        next += spacing;
        final dir = (pts[i] - pts[i - 1]).normalized;
        final perp = dir.perp;
        if (both) {
          out.add(StreetLamp(
              position: pts[i] + perp * offset, heightM: height));
          out.add(StreetLamp(
              position: pts[i] - perp * offset, heightM: height));
        } else {
          out.add(StreetLamp(
              position: pts[i] + perp * (offset * side), heightM: height));
          side = -side;
        }
      }
    }

    // Car-park masts: cold light, wider throw, taller columns. The massing is
    // re-derived rather than read back off the colony, so the lighting pass
    // does not force a dependency from the city sim onto the architecture
    // layer — the rules are deterministic, so both agree by construction.
    for (final (parcel, spec) in city.buildingParcels()) {
      final lot = rules.massFor(spec, parcel).parking;
      if (lot == null) continue;
      final centre = parcel.centroid;
      final facing = parcel.facing;
      final right = facing.perp;
      for (final (lx, ly) in lot.lampPosts) {
        // Building-local (x along frontage, y away from street) into colony
        // local, using the parcel's own frame.
        out.add(StreetLamp(
          position: centre + right * lx + facing * -ly,
          heightM: 12,
          radiusM: 30,
          warm: false,
        ));
      }
    }
    return out;
  }

  /// Lighting state for [city] given the sun's direction in the colony's local
  /// frame ([sunUpComponent] is the dot product of the sun direction with local
  /// up, i.e. the sine of its elevation).
  LightingState stateFor(
    CitySim city, {
    required double sunUpComponent,
    bool? previousLampsOn,
  }) {
    final elevation = math.asin(sunUpComponent.clamp(-1.0, 1.0));

    // Twilight ramp. Smoothstep so lights fade up over dusk instead of
    // snapping on with the first shadow.
    double night;
    if (elevation >= dawnElevation) {
      night = 0;
    } else if (elevation <= duskElevation) {
      night = 1;
    } else {
      final t = (dawnElevation - elevation) / (dawnElevation - duskElevation);
      night = t * t * (3 - 2 * t);
    }

    final wasOn = previousLampsOn ?? false;
    final lampsOn = wasOn
        ? elevation < lampOffElevation
        : elevation < lampOnElevation;

    // Occupancy drives how many windows are lit: an empty tower is a dark
    // tower. Never fully lit — some proportion of any building is unoccupied
    // at any hour, and a 100% lit facade reads as a texture, not a building.
    final occupancy = city.housing <= 0
        ? 0.0
        : (city.population / city.housing).clamp(0.0, 1.0);
    final lit = night * (0.18 + 0.5 * occupancy);

    // Brownouts dim everything.
    final ratio = city.powerDraw <= 0
        ? 1.0
        : (city.powerOut / city.powerDraw).clamp(0.0, 1.0);
    final dim = 0.25 + 0.75 * ratio;

    return LightingState(
      sunElevation: elevation,
      nightFactor: night,
      lampsOn: lampsOn,
      windowLitFraction: lit * dim,
      powerDim: dim,
    );
  }
}
