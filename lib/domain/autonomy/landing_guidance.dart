// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Powered-descent guidance: fly a real vessel from orbit onto a colony pad.
///
/// The colony's shuttles used to be a cosmetic timeline — a craft "descended"
/// over 12% of an animation and dropped cargo. Landing them for real means the
/// same physics the player flies, so a pad can be missed, a shuttle can run out
/// of propellant on the way down, and a spaceport built on a slope is a harder
/// place to land.
///
/// This is a CONTINUOUS law, unlike the impulsive maneuver nodes
/// [AutopilotUpdater] executes: it is asked for a throttle and an attitude every
/// step, so it can close the loop on where the pad actually is.
library;

import 'dart:math' as math;

import '../shared/vector3.dart';

enum LandingPhase {
  /// In orbit, burning retrograde to drop the periapsis into the atmosphere or
  /// the ground.
  deorbit,

  /// Falling, engine off, waiting for the braking altitude.
  coast,

  /// The suicide burn: full thrust retrograde, killing orbital velocity as late
  /// as fuel-optimally possible.
  brake,

  /// Below the braking phase — flying a controlled descent onto the pad.
  terminal,

  /// Down.
  touchdown,

  /// The vehicle cannot stop before the ground with the thrust it has.
  unrecoverable,
}

/// What the guidance wants the vehicle to do this step.
class LandingCommand {
  /// 0..1 throttle setting.
  final double throttle;

  /// Desired thrust direction, body-fixed unit vector.
  final Vector3 facing;

  final LandingPhase phase;

  /// Horizontal distance to the pad, metres.
  final double crossRangeM;

  /// Height above the pad, metres.
  final double altitudeM;

  const LandingCommand({
    required this.throttle,
    required this.facing,
    required this.phase,
    required this.crossRangeM,
    required this.altitudeM,
  });

  bool get isDown => phase == LandingPhase.touchdown;
}

class LandingGuidance {
  const LandingGuidance({
    this.touchdownSpeed = 2.0,
    this.brakeMargin = 1.12,
    this.terminalAltM = 250,
    this.deorbitSpeedFraction = 0.72,
    this.maxLateralSpeed = 60,
    this.lateralGain = 0.09,
    this.padToleranceM = 8,
  });

  /// Vertical speed to arrive with, m/s.
  final double touchdownSpeed;

  /// How much earlier than the theoretical minimum to start the braking burn.
  ///
  /// The ideal suicide burn starts at exactly `v^2 / 2a` and leaves nothing in
  /// hand; throttle limits, a mass that keeps dropping and any steering error
  /// then put the vehicle into the ground. 12% early is enough to absorb all
  /// three without costing much propellant.
  final double brakeMargin;

  /// Altitude below which guidance switches from killing velocity to flying the
  /// vehicle onto the pad.
  final double terminalAltM;

  /// Deorbit burn ends when horizontal speed falls to this fraction of circular
  /// — low enough that the trajectory intersects the surface well short of a
  /// full orbit.
  final double deorbitSpeedFraction;

  /// Cap on the closing speed toward the pad during terminal descent.
  final double maxLateralSpeed;

  /// Proportional gain from cross-range distance to desired closing speed.
  final double lateralGain;

  /// Horizontal distance within which the pad counts as reached.
  final double padToleranceM;

  /// Guidance for one step.
  ///
  /// All vectors are BODY-FIXED. [velBF] must be relative to the ROTATING
  /// surface, not inertial: the pad turns with the planet, and guiding on
  /// inertial velocity would fly the vehicle at a target that is no longer
  /// where the maths thinks it is — hundreds of metres of miss at equatorial
  /// rotation rates.
  LandingCommand command({
    required Vector3 posBF,
    required Vector3 velBF,
    required Vector3 padBF,
    required double mu,
    required double mass,
    required double maxThrust,
  }) {
    final r = posBF.length;
    final up = r <= 1e-9 ? Vector3.unitZ : posBF * (1 / r);
    final padRadius = padBF.length;
    final altitude = r - padRadius;

    // Split velocity into vertical and horizontal parts about the local up.
    final vVert = velBF.dot(up);
    final vHoriz = velBF - up * vVert;

    // Cross-range: the pad, projected into the local horizontal plane.
    final toPad = padBF - up * padBF.dot(up) - (posBF - up * posBF.dot(up));
    final crossRange = toPad.length;

    final g = mu / (r * r);
    final aMax = mass <= 0 ? 0.0 : maxThrust / mass;

    // Net deceleration available while fighting gravity. If thrust cannot beat
    // weight there is no landing to fly.
    final aNet = aMax - g;
    if (aNet <= 0.05 && altitude > 1) {
      return LandingCommand(
        throttle: 1,
        facing: velBF.length > 1e-6 ? velBF.normalized * -1 : up,
        phase: LandingPhase.unrecoverable,
        crossRangeM: crossRange,
        altitudeM: altitude,
      );
    }

    // Down. The whole velocity is checked, not just the vertical part: a
    // vehicle that arrives over the pad still sliding sideways has landed on
    // its side, not on its legs.
    if (altitude <= 0.6 && velBF.length < touchdownSpeed * 2.5) {
      return LandingCommand(
        throttle: 0,
        facing: up,
        phase: LandingPhase.touchdown,
        crossRangeM: crossRange,
        altitudeM: altitude,
      );
    }

    final speed = velBF.length;
    final circular = math.sqrt(mu / r);
    final horizSpeed = vHoriz.length;

    // ---- Deorbit ---------------------------------------------------------
    // Still going round rather than coming down: burn retrograde until the
    // trajectory will intersect the surface.
    if (altitude > terminalAltM * 4 &&
        horizSpeed > circular * deorbitSpeedFraction &&
        vVert > -20) {
      return LandingCommand(
        throttle: 1,
        facing: vHoriz.length > 1e-6 ? vHoriz.normalized * -1 : up,
        phase: LandingPhase.deorbit,
        crossRangeM: crossRange,
        altitudeM: altitude,
      );
    }

    // ---- Descent schedule ------------------------------------------------
    // The speed the vehicle should have at this height: fast high up, easing
    // to the touchdown speed at the pad. Square root rather than linear because
    // that is the constant-deceleration profile — a linear taper either wastes
    // propellant hovering or arrives hot. Only 45% of the available
    // deceleration is scheduled, so there is authority left to correct with.
    final targetDescent = math.max(
      touchdownSpeed,
      math.sqrt(math.max(0.0, 2 * aNet * 0.45 * altitude)),
    );

    // ---- Brake / coast ---------------------------------------------------
    // The phase boundary is the SCHEDULE, not a fixed altitude. Handing a
    // vehicle to the terminal controller at a set height regardless of speed is
    // how a descent arrives at 250 m still doing 100 m/s, with no room left to
    // stop; braking instead continues until the vehicle is back on profile,
    // whatever height that happens at. The margin is hysteresis, so it does not
    // chatter between full thrust and free fall across the boundary.
    final tooFast = speed > targetDescent * brakeMargin;

    if (tooFast) {
      // Velocity-to-be-gained steering, not plain retrograde.
      //
      // Burning straight retrograde kills the closing velocity along with
      // everything else, which stops the vehicle dead — correctly, softly, and
      // kilometres short of the pad. Steering at the DIFFERENCE between the
      // velocity wanted and the velocity held spends the same burn removing
      // cross-range, so the descent arrives over the pad instead of near it.
      final wantClose = math.min(
        speed,
        math.sqrt(2 * aNet * 0.6 * math.max(0.0, crossRange - padToleranceM)),
      );
      final wantVel = (crossRange > padToleranceM
              ? toPad.normalized * wantClose
              : Vector3.zero) +
          up * -targetDescent;
      final vGain = wantVel - velBF;
      return LandingCommand(
        throttle: 1,
        facing: vGain.length > 1e-6 ? vGain.normalized : up,
        phase: LandingPhase.brake,
        crossRangeM: crossRange,
        altitudeM: altitude,
      );
    }

    if (altitude > terminalAltM) {
      // On profile and still high: fall for free. Burning here to hold the
      // schedule would be pure loss — gravity is doing the work.
      return LandingCommand(
        throttle: 0,
        facing: speed > 1e-6 ? velBF.normalized * -1 : up,
        phase: LandingPhase.coast,
        crossRangeM: crossRange,
        altitudeM: altitude,
      );
    }

    // ---- Terminal --------------------------------------------------------
    // Hold height until lined up. Descending onto a pad the vehicle is not over
    // yet is how a lander touches down intact and useless, a few hundred metres
    // from the spaceport it was supposed to reach.
    final linedUp = crossRange <= padToleranceM * 3;
    final descentNow = (!linedUp && altitude < 80) ? 0.0 : targetDescent;
    final vertError = -descentNow - vVert; // >0 means "descending too fast"

    // Desired horizontal velocity: close on the pad, but never faster than the
    // vehicle can null before it arrives.
    // Also bounded by what can be nulled before arrival, so the vehicle
    // decelerates INTO the pad rather than arriving over it still sliding and
    // touching down sideways.
    final closeStop = math.sqrt(
        2 * aMax * 0.33 * math.max(0.0, crossRange - padToleranceM));
    final desiredClose = math.min(
      math.min(maxLateralSpeed, crossRange * lateralGain),
      closeStop,
    );
    final desiredHoriz =
        crossRange > 1e-6 ? toPad.normalized * desiredClose : Vector3.zero;
    final horizError = desiredHoriz - vHoriz;

    // Required acceleration: hold altitude schedule (plus weight) and correct
    // laterally.
    // Feed-forward: the schedule itself is decelerating (that is what the
    // square root encodes), so holding it needs 0.45*aNet ON TOP of weight.
    // Without this the controller only reacts once the vehicle has already
    // fallen behind, which shows up as the descent chattering between full
    // thrust and idle all the way to the pad.
    final schedDecel = targetDescent > touchdownSpeed ? 0.45 * aNet : 0.0;
    // Never below zero: if the vehicle is descending slower than the schedule
    // the answer is to close the throttle and let gravity do it, not to thrust
    // at the ground. A signed term here would have the lander firing downward
    // to make its own schedule, which burns propellant to arrive faster.
    final aVert = math.max(0.0, g + schedDecel + vertError * 1.5);
    // Cross-range correction, capped at a third of full thrust. Altitude
    // control has priority: a lander that tips over to chase the pad stops
    // holding itself up, and the ground is a harder deadline than the pad
    // markings are.
    final maxLateralAccel = aMax * 0.33;
    var aLat = horizError * 0.5;
    if (aLat.length > maxLateralAccel) {
      aLat = aLat.normalized * maxLateralAccel;
    }
    final want = up * aVert + aLat;
    final wantMag = want.length;

    return LandingCommand(
      throttle: aMax <= 0 ? 0 : (wantMag / aMax).clamp(0.0, 1.0),
      facing: wantMag > 1e-6 ? want.normalized : up,
      phase: LandingPhase.terminal,
      crossRangeM: crossRange,
      altitudeM: altitude,
    );
  }
}
