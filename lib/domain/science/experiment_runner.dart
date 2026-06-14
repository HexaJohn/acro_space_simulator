import '../universe/celestial_body.dart';
import '../vessel/vessel.dart';
import 'research_ledger.dart';
import 'situation_service.dart';

/// Auto-runs a vessel's experiments when it enters a NEW flight situation,
/// banking the science into the shared [ResearchLedger]. Domain service that
/// ties together the science, situation, and vessel contexts — the gameplay
/// loop of "go somewhere new, get science".
class ExperimentRunner {
  final SituationService situations;
  const ExperimentRunner([this.situations = const SituationService()]);

  /// Returns the science gained this call (0 if the situation is unchanged or
  /// the vessel carries no experiments).
  double collect(Vessel vessel, CelestialBody body, ResearchLedger ledger) {
    if (vessel.experiments.isEmpty) return 0;

    final situation = situations.classify(vessel, body);
    if (situation == vessel.lastScienceSituation) return 0;

    var gained = 0.0;
    for (final exp in vessel.experiments) {
      gained += ledger.runExperiment(exp, situation: situation);
    }
    vessel.lastScienceSituation = situation;
    return gained;
  }
}
