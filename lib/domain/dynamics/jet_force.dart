import '../shared/vector3.dart';
import '../universe/atmosphere_model.dart';
import '../vessel/resource_container.dart';
import '../vessel/vessel.dart';
import 'force.dart';
import 'force_model.dart';
import 'mass_properties.dart';
import 'state_vector.dart';

/// Air-breathing thrust from a vessel's jet engines. Force contributor injected
/// when an aircraft with jet engines is inside an atmosphere. Thrust depends on
/// ambient density, Mach number, intake air, and throttle (see [JetEngine]);
/// burns liquid fuel (no oxidizer — it breathes air). Thrust acts along the
/// vessel's forward (+Z) axis.
class JetForce implements ForceContributor {
  final Vessel vessel;
  final AtmosphereSample atmosphere;
  final double dt;

  /// Fuel mass (kg) burned per newton-second of thrust — a TSFC-like figure.
  final double fuelPerNewtonSecond;

  const JetForce({
    required this.vessel,
    required this.atmosphere,
    required this.dt,
    this.fuelPerNewtonSecond = 3.0e-5,
  });

  @override
  GeneralizedForce evaluate(StateVector state, MassProperties mass) {
    if (vessel.jetEngines.isEmpty || vessel.throttle <= 0) {
      return GeneralizedForce.zero;
    }
    if (atmosphere.density <= 0) return GeneralizedForce.zero;

    final speed = state.velocity.length;
    final mach = atmosphere.speedOfSound > 0 ? speed / atmosphere.speedOfSound : 0.0;

    var totalThrust = 0.0;
    for (final jet in vessel.jetEngines) {
      totalThrust += jet.thrust(
        ambient: atmosphere,
        machNumber: mach,
        throttle: vessel.throttle,
        intakeAirAvailable: vessel.totalIntakeArea,
      );
    }
    if (totalThrust <= 0) return GeneralizedForce.zero;

    // Burn fuel proportional to thrust*time. If dry, scale thrust to what fuel
    // allowed (or zero).
    final fuelNeeded = totalThrust * dt * fuelPerNewtonSecond;
    final drawn = _drawFuel(vessel, fuelNeeded);
    if (drawn <= 0) return GeneralizedForce.zero;
    final ratio = fuelNeeded > 0 ? (drawn / fuelNeeded).clamp(0.0, 1.0) : 1.0;

    final dir = state.attitude.rotate(Vector3.unitZ);
    return GeneralizedForce(dir * (totalThrust * ratio), Vector3.zero);
  }

  double _drawFuel(Vessel vessel, double kg) {
    var remaining = kg;
    var drawn = 0.0;
    for (final p in vessel.allParts) {
      if (remaining <= 0) break;
      for (final c in p.resources) {
        if (c.type != ResourceType.liquidFuel) continue;
        // draw() works in units; convert kg<->units via unitMass.
        final unitsWanted = c.unitMass > 0 ? remaining / c.unitMass : 0.0;
        final tookUnits = c.draw(unitsWanted);
        final tookKg = tookUnits * c.unitMass;
        drawn += tookKg;
        remaining -= tookKg;
        if (remaining <= 0) break;
      }
    }
    return drawn;
  }
}
