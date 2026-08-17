// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Automated supply shuttles: real vessels, flown by the landing guidance,
/// onto the colony's real pads.
///
/// The old system was a cosmetic timeline — a sprite "descended" over 12% of
/// an animation and cargo appeared. These are vessels in the same repository
/// as the player's craft, integrated by the same physics, landed by
/// [LandingGuidance] and unloaded by the same pad-side cargo service. A
/// shuttle can be watched down from the cockpit, and a badly sited pad genuinely
/// makes for harder deliveries.
///
/// One abstraction is kept, on purpose: shuttles spawn a few kilometres above
/// the pad, already subsonic, rather than flying a full orbital reentry. The
/// interesting part — the powered descent onto a pad the player built — is
/// genuinely flown; the part that would need a heat-shield model is not.
library;

import 'dart:math' as math;

import '../../dynamics/state_vector.dart';
import '../../shared/quaternion.dart';
import '../../shared/vector3.dart';
import '../../universe/celestial_body.dart';
import '../../vessel/part.dart';
import '../../vessel/propulsion.dart';
import '../../vessel/resource_container.dart';
import '../../vessel/stage.dart';
import '../../vessel/vessel.dart';

/// Where a run is in its round trip.
enum ShuttleRunPhase {
  /// Flying the powered descent onto the pad.
  inbound,

  /// On the pad. The cargo service unloads it; the dwell is the turnaround.
  unloading,

  /// Climbing out. Past the departure altitude the vessel is recovered.
  departing,

  /// Finished (delivered, or lost) — the slot is free for the next dispatch.
  done,
}

/// One shuttle's round trip to one pad.
class ShuttleRun {
  ShuttleRun({
    required this.vesselId,
    required this.colonyId,
    required this.padId,
  });

  final String vesselId;
  final String colonyId;

  /// The parcel id of the pad this run serves.
  final String padId;

  ShuttleRunPhase phase = ShuttleRunPhase.inbound;

  /// Remaining turnaround time on the pad, seconds.
  double dwell = 12;

  bool get active => phase != ShuttleRunPhase.done;

  Map<String, dynamic> toJson() => {
        'vessel': vesselId,
        'colony': colonyId,
        'pad': padId,
        'phase': phase.index,
        'dwell': dwell,
      };

  factory ShuttleRun.fromJson(Map<String, dynamic> j) => ShuttleRun(
        vesselId: j['vessel'] as String,
        colonyId: j['colony'] as String,
        padId: j['pad'] as String,
      )
        ..phase = ShuttleRunPhase.values[(j['phase'] as num).toInt()]
        ..dwell = (j['dwell'] as num).toDouble();
}

/// Builds the shuttle vessels the dispatcher launches.
class ColonyShuttleFactory {
  const ColonyShuttleFactory();

  /// Thrust the guidance may assume, N. The factory owns the number so the
  /// dispatcher does not reach into the part tree to rediscover it.
  ///
  /// Sized for a lander, not a launcher: ~TWR 8 loaded on the Moon, ~1.5 at
  /// Earth landing mass. The guidance's descent schedule steepens with thrust,
  /// and a TWR-40 engine writes a schedule it then cannot track through the
  /// last hundred metres — the first flight test crashed exactly that way.
  static const double maxThrust = 110000;

  /// Spawn height above the pad, metres. High enough that the whole braking
  /// and terminal profile is flown, low enough to skip the reentry the sim has
  /// no heat shield for.
  static const double spawnAltM = 16000;

  /// Initial sink rate at spawn, m/s.
  static const double spawnDescentRate = 60;

  /// A loaded supply shuttle a few kilometres above [padBF], co-rotating with
  /// the body and already descending.
  ///
  /// Co-rotation matters: spawning at inertial rest over a spinning body is
  /// spawning with hundreds of m/s of sideways surface velocity, and the
  /// guidance would spend its margin killing a drift the dispatcher invented.
  Vessel build({
    required String id,
    required CelestialBody body,
    required Vector3 padBF,
    required Quaternion bodyOrientation,
  }) {
    final upBF = padBF.normalized;
    final posBF = upBF * (padBF.length + spawnAltM);
    final period = body.siderealRotationPeriod;
    final omega = period.abs() < 1
        ? Vector3.zero
        : Vector3(0, 0, 2 * math.pi / period);
    final velBF = omega.cross(posBF) - upBF * spawnDescentRate;

    final tank = ResourceContainer(
      type: ResourceType.liquidFuel,
      // Sized from a MEASURED round trip, not the rocket equation: the sim's
      // burn model spends roughly twice the ideal-Isp figure, and the pad-side
      // unload siphons the tank down to its reserve fraction on top. 1200
      // units lands, keeps its reserve, and climbs out with margin.
      capacity: 1200,
      amount: 1200,
      unitMass: 5,
    );
    // The care package. The pad-side cargo service maps these onto the colony
    // stockpile and leaves the propellant reserve aboard.
    ResourceContainer cargo(ResourceType t, double amount) => ResourceContainer(
          type: t,
          capacity: amount,
          amount: amount,
          unitMass: 1,
        );

    final hull = Part(
      id: PartId('$id-hull'),
      name: 'Supply Shuttle',
      dryMass: 2200,
      inertiaContribution: Vector3(2600, 2600, 1400),
      engine: const Engine(
        name: 'Lander Cluster',
        maxThrustVacuum: maxThrust,
        maxThrustSeaLevel: 95000,
        ispVacuum: 315,
        ispSeaLevel: 260,
      ),
      resources: [
        tank,
        cargo(ResourceType.food, 160),
        cargo(ResourceType.water, 160),
        cargo(ResourceType.oxygen, 120),
        cargo(ResourceType.ore, 120),
      ],
      crossSectionArea: 2.0,
      // No thermal parts, deliberately: the overheat check skips a vessel with
      // none, and a shuttle that spawns subsonic has no reentry to survive.
    );

    return Vessel(
      id: VesselId(id),
      name: 'Supply Shuttle',
      ownerId: 'logistics',
      state: StateVector(
        position: bodyOrientation.rotate(posBF),
        velocity: bodyOrientation.rotate(velBF),
        attitude: Quaternion.identity,
      ),
      dominantBody: body.id,
      stages: [
        Stage(index: 0, parts: [hull]),
      ],
    );
  }
}
