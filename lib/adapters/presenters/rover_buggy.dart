// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

/// A dune buggy on four sprung wheels, driven over a height field.
///
/// Pure: no Flutter, no scene, no clock. The ground arrives as a callback and
/// the pose comes out as numbers, which is what lets the suspension be
/// exercised in a test with a hand-drawn ramp instead of a planet.
///
/// **Frame.** Position is (east, north) metres in a tangent plane, heading is
/// a yaw where 0 faces north and positive turns toward east — the same
/// convention the studios' walker uses, so the buggy can take over from the
/// walker where it stands. Height is in whatever datum [heightAt] answers in
/// (the studios hand it a RADIUS from the body's centre; a test hands it an
/// altitude); pitch and roll are small angles off that datum's tangent plane.
///
/// **Model.** A kinematic bicycle for the horizontal motion (no tyre model —
/// the buggy goes where the front wheels point, which is what an arcade
/// driver expects) under a real 3-DOF spring-mass body for heave, pitch and
/// roll: each wheel is a spring + damper between its ground contact and the
/// mount plane, the sum of their forces lifts the chassis against gravity and
/// their moments rock it. Squat under throttle and lean in a corner come from
/// the centre of mass sitting above the mount plane. Airborne it keeps its
/// velocity, loses its steering, and rights itself gently so a jump lands on
/// its wheels.
class RoverSpec {
  const RoverSpec({
    this.massKg = 820,
    this.wheelBaseM = 2.6,
    this.trackM = 1.75,
    this.wheelRadiusM = 0.42,
    this.travelM = 0.45,
    this.springNPerM = 19000,
    this.damperNsPerM = 1700,
    this.cgHeightM = 0.35,
    this.topSpeedMs = 26,
    this.reverseTopMs = 7,
    this.driveAccelMs2 = 7.5,
    this.brakeDecelMs2 = 11,
    this.rollingDecelMs2 = 0.7,
    this.dragPerM = 0.010,
    this.maxSteerRad = 0.52,
    this.steerRateRadPerS = 2.8,
    this.steerReturnRadPerS = 4.0,
    this.gripG = 0.9,
  });

  final double massKg;

  /// Front-to-rear axle distance and left-to-right wheel distance, metres.
  final double wheelBaseM;
  final double trackM;
  final double wheelRadiusM;

  /// Suspension travel: the spring's free length between the mount plane and
  /// the wheel centre. Compression runs 0 (hanging, off the ground) to this
  /// (on the bump stop).
  final double travelM;

  /// Per-wheel spring rate and damping. The defaults put the heave mode near
  /// 1.5 Hz at 0.4 critical — soft enough to see, firm enough to land.
  final double springNPerM;
  final double damperNsPerM;

  /// Centre of mass above the mount plane: the lever that squats the tail
  /// under throttle and leans the body in a corner.
  final double cgHeightM;

  final double topSpeedMs;
  final double reverseTopMs;
  final double driveAccelMs2;
  final double brakeDecelMs2;

  /// Coast-down: rolling resistance (constant) and aero drag (per m/s²).
  final double rollingDecelMs2;
  final double dragPerM;

  final double maxSteerRad;
  final double steerRateRadPerS;
  final double steerReturnRadPerS;

  /// Lateral grip in g: the most the tyres can corner at before the front
  /// pushes wide. A kinematic bicycle would otherwise corner at ANY g (3 g
  /// at 60 km/h, wheels in the air); on dirt a buggy holds about 0.9.
  final double gripG;

  /// Rotational inertia about the pitch (lateral) and roll (longitudinal)
  /// axes — a box the size of the wheel footprint.
  double get pitchInertia => massKg * wheelBaseM * wheelBaseM / 10;
  double get rollInertia => massKg * trackM * trackM / 8;

  /// Spring compression with the buggy at rest in [gravity].
  double staticCompression(double gravity) =>
      massKg * gravity / (4 * springNPerM);

  /// Mount-plane height above the ground contact with the buggy at rest.
  double restMountHeight(double gravity) =>
      wheelRadiusM + travelM - staticCompression(gravity);

  /// Wheel [i]'s offset from the mount-plane centre in the chassis frame:
  /// x right, y forward. Order: front-left, front-right, rear-left,
  /// rear-right.
  (double x, double y) wheelOffset(int i) => (
        (i.isEven ? -1 : 1) * trackM / 2,
        (i < 2 ? 1 : -1) * wheelBaseM / 2,
      );

  static const int wheelCount = 4;
}

/// What the driver is holding this frame.
class RoverInput {
  const RoverInput({this.throttle = 0, this.steer = 0, this.brake = false});

  /// -1 (reverse / brake) .. 1 (drive).
  final double throttle;

  /// -1 (left) .. 1 (right).
  final double steer;

  /// Hard stop, all four wheels.
  final bool brake;

  static const RoverInput none = RoverInput();
}

/// The buggy's live state. Mutated in place by [stepRover]; everything a
/// renderer needs to draw the chassis, the wheels and the dust is here.
class RoverState {
  RoverState({
    required this.e,
    required this.n,
    required this.yaw,
    required this.height,
  });

  /// Parked on the ground at ([e], [n]) with the springs settled — no bounce
  /// on entry.
  factory RoverState.resting({
    required double e,
    required double n,
    required double yaw,
    required double groundHeight,
    required double gravity,
    RoverSpec spec = const RoverSpec(),
  }) {
    final s = RoverState(
      e: e,
      n: n,
      yaw: yaw,
      height: groundHeight + spec.restMountHeight(gravity),
    );
    final c = spec.staticCompression(gravity);
    for (var i = 0; i < RoverSpec.wheelCount; i++) {
      s.compression[i] = c;
      s.contact[i] = true;
    }
    return s;
  }

  /// Mount-plane centre in the tangent plane, metres.
  double e, n;

  /// Heading: 0 north, positive toward east.
  double yaw;

  /// Signed speed along the heading, m/s (negative = reversing).
  double speed = 0;

  /// Front-wheel steer angle, radians, positive right.
  double steer = 0;

  /// Mount-plane height in the ground datum, and its rate.
  double height;
  double vertVel = 0;

  /// Chassis attitude off the tangent plane: pitch positive nose-up, roll
  /// positive right-side-down.
  double pitch = 0, roll = 0;
  double pitchRate = 0, rollRate = 0;

  /// Yaw rate (rad/s) and longitudinal acceleration (m/s²) of the last step
  /// — what the body leans against.
  double yawRate = 0;
  double accelLong = 0;

  /// Per wheel (see [RoverSpec.wheelOffset] for the order).
  final List<double> compression = List.filled(RoverSpec.wheelCount, 0);
  final List<double> wheelSpin = List.filled(RoverSpec.wheelCount, 0);
  final List<bool> contact = List.filled(RoverSpec.wheelCount, false);

  /// How hard each wheel is throwing dust, 0..1: rolling speed, plus a lot
  /// more for spinning up, skidding and cornering.
  final List<double> dust = List.filled(RoverSpec.wheelCount, 0);

  /// Impact speed (m/s) of a wheel that touched down during the last step,
  /// zero for wheels that did not — one puff per landing.
  final List<double> landing = List.filled(RoverSpec.wheelCount, 0);

  /// Seconds with no wheel on the ground.
  double airTime = 0;

  bool get grounded => contact.any((c) => c);
  int get wheelsDown => contact.where((c) => c).length;

  /// Wheel [i]'s centre in the chassis frame (x right, y forward, z up from
  /// the mount plane), metres.
  (double x, double y, double z) wheelCentre(int i, RoverSpec spec) {
    final (x, y) = spec.wheelOffset(i);
    return (x, y, -(spec.travelM - compression[i]));
  }
}

/// Advance the buggy by [dt] seconds.
///
/// [heightAt] answers the ground height under a tangent-plane point. It is
/// sampled under every wheel ONCE per call (not per sub-step: in a town cut
/// by a thousand grading brushes one sample is the expensive part, and a
/// frame's travel is under half a metre), and it must be the SAME field the
/// ground is drawn from — the studios hand it the edited terrain field in
/// the body-fixed frame (see the walker's frame trap).
///
/// Integration is semi-implicit Euler in sub-steps of at most 5 ms; a frame
/// longer than 100 ms is clamped, so a stall never launches the buggy.
void stepRover(
  RoverState s,
  RoverInput input, {
  required double dt,
  required double gravity,
  required double Function(double e, double n) heightAt,
  RoverSpec spec = const RoverSpec(),
}) {
  if (!dt.isFinite || dt <= 0) return;
  final frame = math.min(dt, 0.1);
  final sub = (frame / 0.005).ceil().clamp(1, 32);
  final h = frame / sub;
  for (var i = 0; i < RoverSpec.wheelCount; i++) {
    s.landing[i] = 0;
  }
  // Ground under each wheel, where the frame begins.
  final sy = math.sin(s.yaw), cy = math.cos(s.yaw);
  for (var i = 0; i < RoverSpec.wheelCount; i++) {
    final (x, y) = spec.wheelOffset(i);
    // Chassis (x right, y forward) → tangent plane (east, north).
    _ground[i] = heightAt(s.e + cy * x + sy * y, s.n - sy * x + cy * y);
  }
  for (var k = 0; k < sub; k++) {
    _substep(s, input, h, gravity, spec);
  }
}

// Scratch, reused across sub-steps (no per-step allocation).
final List<double> _ground = List.filled(RoverSpec.wheelCount, 0);
final List<double> _force = List.filled(RoverSpec.wheelCount, 0);

void _substep(
  RoverState s,
  RoverInput input,
  double h,
  double g,
  RoverSpec spec,
) {
  final m = spec.massKg;
  final throttle = input.throttle.clamp(-1.0, 1.0);
  final wasGrounded = s.grounded;
  final vertVel0 = s.vertVel;

  // ---- Steering: rate-limited toward the stick, returning faster than it
  // turns, and softened with speed so the buggy is not twitchy flat out.
  final softness = 1.0 / (1.0 + s.speed.abs() / 18.0);
  final target = input.steer.clamp(-1.0, 1.0) * spec.maxSteerRad * softness;
  final rate = input.steer.abs() > 1e-3
      ? spec.steerRateRadPerS
      : spec.steerReturnRadPerS;
  final dSteer = target - s.steer;
  s.steer += dSteer.clamp(-rate * h, rate * h);

  // ---- Wheels: compression against the sampled ground, spring + damper.
  final sy = math.sin(s.yaw), cy = math.cos(s.yaw);
  final sinP = math.sin(s.pitch), sinR = math.sin(s.roll);
  var sumF = 0.0, torqueP = 0.0, torqueR = 0.0;
  for (var i = 0; i < RoverSpec.wheelCount; i++) {
    final (x, y) = spec.wheelOffset(i);
    final ground = _ground[i];
    final mount = s.height + sinP * y - sinR * x;
    final raw = ground + spec.wheelRadiusM + spec.travelM - mount;
    final touching = raw > 0;
    final c = raw.clamp(0.0, spec.travelM);
    final excess = math.max(0.0, raw - spec.travelM);
    var f = 0.0;
    if (touching) {
      // The damper works against the CHASSIS's motion at the mount, not the
      // ground's: a bump is a spring event, and the damper then settles the
      // body it launched. Force floors at zero — the ground pushes, it does
      // not pull. The bump stop is a stiffer spring past full travel.
      final mountVel = s.vertVel + s.pitchRate * y - s.rollRate * x;
      f = spec.springNPerM * c +
          spec.springNPerM * 6.0 * excess -
          spec.damperNsPerM * mountVel;
      if (f < 0) f = 0;
      if (!s.contact[i] && vertVel0 < -1.5) {
        s.landing[i] = math.max(s.landing[i], -vertVel0);
      }
    }
    s.contact[i] = touching;
    s.compression[i] = c;
    _force[i] = f;
    sumF += f;
    torqueP += f * y;
    torqueR -= f * x;
  }
  final grounded = s.wheelsDown >= 1;
  final planted = s.wheelsDown >= 2;

  // ---- Longitudinal: drive, brake, coast, and gravity along the slope the
  // wheels are standing on (rear-to-front ground difference over the base).
  var a = 0.0;
  final slope = math.atan2(
      (_ground[0] + _ground[1] - _ground[2] - _ground[3]) / 2, spec.wheelBaseM);
  if (planted) a -= g * math.sin(slope);
  final speed0 = s.speed;
  final sign = speed0 > 0 ? 1.0 : (speed0 < 0 ? -1.0 : 0.0);
  var braking = false;
  var powered = false;
  if (grounded) {
    if (input.brake) {
      a -= sign * spec.brakeDecelMs2;
      braking = true;
    } else if (throttle > 0) {
      if (speed0 >= 0) {
        // The drive curve is NET of the running losses: full throttle pulls
        // hardest from rest, fades to nothing at the top speed, and holds
        // the buggy back past it (a downhill run under power).
        final headroom = (1 - speed0 / spec.topSpeedMs).clamp(-1.0, 1.0);
        a += throttle * spec.driveAccelMs2 * headroom;
        powered = true;
      } else {
        a += throttle * spec.brakeDecelMs2;
        braking = true;
      }
    } else if (throttle < 0) {
      if (speed0 > 0.5) {
        a += throttle * spec.brakeDecelMs2;
        braking = true;
      } else {
        final headroom =
            (1 - speed0.abs() / spec.reverseTopMs).clamp(-1.0, 1.0);
        a += throttle * spec.driveAccelMs2 * headroom;
        powered = true;
      }
    }
  }
  // Coasting and braking feel the running losses the drive curve absorbs.
  if (!powered) {
    if (grounded) a -= sign * spec.rollingDecelMs2;
    a -= sign * spec.dragPerM * speed0 * speed0;
  }
  s.accelLong = a;
  var speed = speed0 + a * h;
  // Resistance stops a buggy; it does not reverse it.
  if (grounded && (input.brake || braking || throttle == 0) &&
      speed * speed0 < 0) {
    speed = 0;
  }
  if (throttle == 0 && !input.brake && speed.abs() < 0.03 && slope.abs() < 0.02) {
    speed = 0;
  }
  s.speed = speed.clamp(-spec.reverseTopMs * 1.3, spec.topSpeedMs * 1.3);

  // ---- Yaw: the bicycle model while the wheels can bite, capped at what
  // the tyres can hold (past it the buggy understeers, sliding); in the air
  // the turn it left the ground with decays.
  var sliding = false;
  if (grounded) {
    var yr = s.speed / spec.wheelBaseM * math.tan(s.steer);
    final maxYr = spec.gripG * g / math.max(s.speed.abs(), 0.5);
    if (yr.abs() > maxYr) {
      yr = yr.sign * maxYr;
      sliding = true;
    }
    s.yawRate = yr;
  } else {
    s.yawRate *= math.max(0.0, 1 - 2 * h);
  }
  s.yaw += s.yawRate * h;

  // ---- Position, along the heading the step began with.
  s.e += sy * s.speed * h;
  s.n += cy * s.speed * h;

  // ---- Heave / pitch / roll from the wheel forces; the centre of mass
  // above the mount plane turns acceleration into squat and cornering into
  // lean. Light angular damping always; in the air a gentle self-righting
  // so a jump comes down on its wheels.
  final aLat = s.speed * s.yawRate;
  s.vertVel += (sumF / m - g) * h;
  s.height += s.vertVel * h;

  final ip = spec.pitchInertia, ir = spec.rollInertia;
  torqueP += m * s.accelLong * spec.cgHeightM;
  torqueR -= m * aLat * spec.cgHeightM;
  torqueP -= ip * 1.5 * s.pitchRate;
  torqueR -= ir * 1.5 * s.rollRate;
  if (!grounded) {
    torqueP -= ip * 4.0 * s.pitch;
    torqueR -= ir * 4.0 * s.roll;
  }
  s.pitchRate += torqueP / ip * h;
  s.rollRate += torqueR / ir * h;
  s.pitch += s.pitchRate * h;
  s.roll += s.rollRate * h;
  const maxTilt = 0.6;
  if (s.pitch.abs() > maxTilt) {
    s.pitch = s.pitch.sign * maxTilt;
    s.pitchRate = 0;
  }
  if (s.roll.abs() > maxTilt) {
    s.roll = s.roll.sign * maxTilt;
    s.rollRate = 0;
  }

  // ---- Wheels turn with the ground speed; airborne they keep turning.
  final spin = s.speed / spec.wheelRadiusM * h;
  for (var i = 0; i < RoverSpec.wheelCount; i++) {
    s.wheelSpin[i] += spin;
  }
  s.airTime = grounded ? 0 : s.airTime + h;
  if (!wasGrounded && grounded) s.airTime = 0;

  // ---- Dust: a little from rolling, a lot from any wheel that is fighting
  // the ground — spinning up from a standstill, skidding under the brakes,
  // or being dragged sideways through a corner. Rear (driven) wheels throw
  // more.
  final absSpeed = s.speed.abs();
  final rolling = (absSpeed / spec.topSpeedMs).clamp(0.0, 1.0);
  var slip = 0.0;
  if (grounded) {
    slip += (aLat.abs() / math.max(g, 0.1) * 1.6).clamp(0.0, 1.0);
    if (throttle != 0 && absSpeed < 6) {
      slip += 0.6 * throttle.abs() * (1 - absSpeed / 6);
    }
    if (braking && absSpeed > 3) slip += 0.7;
    if (sliding) slip += 0.6;
  }
  for (var i = 0; i < RoverSpec.wheelCount; i++) {
    if (!s.contact[i] || (absSpeed < 0.3 && slip < 0.05)) {
      s.dust[i] = 0;
      continue;
    }
    final rear = i >= 2 ? 1.0 : 0.7;
    s.dust[i] = ((rolling * 0.55 + slip * 0.8) * rear).clamp(0.0, 1.0);
  }
}

/// Wrap an angle difference into (-π, π].
double wrapAngle(double a) {
  var x = a % (2 * math.pi);
  if (x > math.pi) x -= 2 * math.pi;
  if (x <= -math.pi) x += 2 * math.pi;
  return x;
}
