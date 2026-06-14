import 'city_services.dart';
import 'colony.dart';

/// Drives a city's [Colony.happiness] from its service coverage. Domain service.
///
/// Coverage for one service type = (citizens served by that type) / population,
/// capped at 1. Overall coverage is the MINIMUM across the [requiredServices]
/// (a city with great policing but no clinics is still unhappy — the weakest
/// link governs). Happiness then drifts toward that coverage each tick.
class HappinessService {
  /// Rate (per second) happiness moves toward the coverage target.
  final double adjustRate;
  const HappinessService({this.adjustRate = 0.05});

  void update(Colony colony, {required double dt}) {
    final target = serviceCoverage(colony);
    final delta = (target - colony.happiness) * adjustRate * dt;
    colony.happiness = (colony.happiness + delta).clamp(0.0, 1.0);
  }

  /// Overall service coverage 0..1 (min across required service types).
  double serviceCoverage(Colony colony) {
    final pop = colony.population <= 0 ? 1 : colony.population;
    var minCoverage = 1.0;
    for (final type in requiredServices) {
      var served = 0.0;
      for (final b in colony.buildings) {
        served += b.spec.services[type] ?? 0;
      }
      final coverage = (served / pop).clamp(0.0, 1.0);
      if (coverage < minCoverage) minCoverage = coverage;
    }
    return minCoverage;
  }
}
