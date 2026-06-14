import 'colony.dart';

/// Runs a colony's production/consumption for one tick. Domain service.
///
/// Each building consumes inputs from and deposits outputs to the shared
/// stockpile, scaled by efficiency (staffing * supply * power). Population
/// drifts toward housing capacity when jobs and food/power are satisfied — the
/// Cities-Skylines growth loop, abstracted.
class SupplyChain {
  const SupplyChain();

  void advance(Colony colony, double dt) {
    final workforceRatio =
        colony.jobs == 0 ? 1.0 : colony.workforce / colony.jobs;
    final powerRatio = colony.powerRatio;

    final network = colony.network;
    for (final b in colony.buildings) {
      // Disconnected from the road/utility network -> shut down entirely.
      if (network != null && !network.isConnected(b.id)) {
        b.efficiency = 0;
        continue;
      }

      // Efficiency limited by staffing, power supply, and input availability.
      var eff = workforceRatio.clamp(0.0, 1.0).toDouble();
      if (b.spec.powerDraw > 0) eff *= powerRatio; // brownout throttling

      // Check inputs are available; if short, throttle efficiency.
      b.spec.inputsPerSecond.forEach((type, rate) {
        final need = rate * dt * eff;
        final have = colony.stockpile[type]?.amount ?? 0;
        if (need > 0 && have < need) {
          eff = eff * (have / need).clamp(0.0, 1.0);
        }
      });
      b.efficiency = eff;

      // Consume inputs.
      b.spec.inputsPerSecond.forEach((type, rate) {
        colony.stockpile[type]?.draw(rate * dt * eff);
      });
      // Produce outputs.
      b.spec.outputsPerSecond.forEach((type, rate) {
        colony.stockpile[type]?.fill(rate * dt * eff);
      });
    }

    _growPopulation(colony, dt);
  }

  void _growPopulation(Colony colony, double dt) {
    final cap = colony.housingCapacity;
    if (colony.population < cap) {
      // simple logistic-ish growth toward housing capacity
      final growth = (cap - colony.population) * 0.01 * dt;
      colony.population += growth.round();
      if (colony.population > cap) colony.population = cap;
    }
  }
}
