/// Crew aboard a vessel and their life-support consumption rates. Carried by
/// the vessel aggregate; the [LifeSupportService] draws their consumables each
/// tick. Mutable [count] so the crew can be lost when supplies run out.
class CrewModule {
  int count;
  final double foodPerCrewPerSecond;
  final double oxygenPerCrewPerSecond;
  final double waterPerCrewPerSecond;

  /// Cumulative absorbed radiation dose (sieverts).
  double accumulatedDose;

  /// Dose (Sv) above which crew develop radiation sickness.
  final double sicknessThresholdSv;

  /// Dose (Sv) that is lethal.
  final double lethalDoseSv;

  /// True once sickness has been flagged (so the event fires once).
  bool sick;

  CrewModule({
    required this.count,
    this.foodPerCrewPerSecond = 0.0,
    this.oxygenPerCrewPerSecond = 0.0,
    this.waterPerCrewPerSecond = 0.0,
    this.accumulatedDose = 0.0,
    this.sicknessThresholdSv = 1.0, // ~1 Sv = acute radiation syndrome onset
    this.lethalDoseSv = 8.0, // ~8 Sv ~ near-certain death
    this.sick = false,
  });

  bool get isAlive => count > 0;
}
