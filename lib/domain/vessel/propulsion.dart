import 'dart:math' as math;

import '../shared/units.dart';
import '../shared/vector3.dart';
import 'resource_container.dart';

/// An engine. Thrust and propellant flow follow the rocket model: effective
/// exhaust velocity v_e = Isp * g0, mass flow = thrust / v_e. Atmospheric Isp
/// differs from vacuum Isp; the aerodynamics/atmosphere context supplies the
/// ambient pressure used to interpolate.
class Engine {
  final String name;
  final double maxThrustVacuum; // N
  final double maxThrustSeaLevel; // N
  final double ispVacuum; // s
  final double ispSeaLevel; // s
  final ResourceType propellant;
  final double oxidizerRatio; // units oxidizer per unit fuel (0 = none)

  /// Maximum gimbal deflection (rad) the engine can vector its thrust, for
  /// steering during a burn. 0 = fixed nozzle.
  final double gimbalRange;

  const Engine({
    required this.name,
    required this.maxThrustVacuum,
    required this.maxThrustSeaLevel,
    required this.ispVacuum,
    required this.ispSeaLevel,
    this.propellant = ResourceType.liquidFuel,
    this.oxidizerRatio = 1.1,
    this.gimbalRange = 0,
  });

  /// Thrust direction after gimballing: tilts [thrustAxis] toward [steerToward],
  /// capped at [gimbalRange]. Both arguments are unit vectors in the same frame;
  /// returns a unit vector. A fixed engine (gimbalRange 0) returns [thrustAxis].
  Vector3 gimballedDirection({
    required Vector3 thrustAxis,
    required Vector3 steerToward,
  }) {
    final axis = thrustAxis.normalized;
    if (gimbalRange <= 0) return axis;

    final target = steerToward.normalized;
    final cosAngle = axis.dot(target).clamp(-1.0, 1.0);
    final angle = math.acos(cosAngle);
    if (angle < 1e-9) return axis; // already aligned

    final step = math.min(angle, gimbalRange);
    // Rotation axis perpendicular to both; deflect [axis] by [step] toward target.
    var rotAxis = axis.cross(target);
    if (rotAxis.length < 1e-9) {
      rotAxis = axis.cross(Vector3.unitX);
      if (rotAxis.length < 1e-9) rotAxis = axis.cross(Vector3.unitY);
    }
    rotAxis = rotAxis.normalized;
    // Rodrigues' rotation of [axis] about [rotAxis] by [step].
    final cosS = math.cos(step), sinS = math.sin(step);
    return (axis * cosS + rotAxis.cross(axis) * sinS + rotAxis * (rotAxis.dot(axis) * (1 - cosS)))
        .normalized;
  }

  /// Linear-interpolate a quantity between sea level and vacuum by ambient
  /// pressure fraction [pFraction] in [0,1] (1 = sea level, 0 = vacuum).
  double _lerpByPressure(double sea, double vac, double pFraction) =>
      vac + (sea - vac) * pFraction.clamp(0.0, 1.0);

  double thrustAt(double pressureFraction, double throttle) =>
      _lerpByPressure(maxThrustSeaLevel, maxThrustVacuum, pressureFraction) *
      throttle.clamp(0.0, 1.0);

  double ispAt(double pressureFraction) =>
      _lerpByPressure(ispSeaLevel, ispVacuum, pressureFraction);

  /// Propellant mass flow (kg/s) for a given thrust and Isp.
  double massFlow(double thrust, double isp) =>
      isp <= 0 ? 0 : thrust / (isp * standardGravity);
}
