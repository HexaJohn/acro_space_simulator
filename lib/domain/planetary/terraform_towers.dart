// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The terraforming tower family, as the planet sees it
/// (docs/plans/terraforming.md §4, phase 3).
///
/// One `terraformer` used to stand for everything a colony could do to a sky.
/// Each tower now does ONE thing to ONE gas, because the interesting game is
/// in the trade-offs between them: the Greenhouse Factory warms Mars, which
/// frees CO2 from its caps; the Regolith Baker frees more from the rock; the
/// Oxygenator turns that CO2 into the oxygen people breathe — and in doing so
/// thins the very greenhouse the factory paid for. None of that exists if one
/// building adds "terraforming".
///
/// This file is the planet's half: the spec ids the colony's production step
/// sums throttles under, and the running totals it hands to the atmosphere.
/// What each tower does to the inventory is `PlanetAtmosphereService`'s.
library;

/// The tower family's spec ids. The colony catalogue (`kUtilCatalog`) holds
/// the specs themselves; these are the stable ids saves and the planet both
/// key on.
abstract final class TerraformTowers {
  /// The Oxygenator: CO2 → O2. Keeps the id the single tower always had, so
  /// every save that holds one still does.
  static const String oxygenator = 'terraformer';

  /// Emits a super-greenhouse agent (PFCs).
  static const String greenhouseFactory = 'greenhousefactory';

  /// Bakes CO2 and N2 out of the carbonates and nitrates in the soil.
  static const String regolithBaker = 'regolithbaker';

  /// Takes CO2 out of the sky into rock.
  static const String carbonSequestrator = 'sequestrator';

  /// Suppresses escape on its whole world: a magnetosphere generator and
  /// upper-atmosphere containment (§7 Q2).
  static const String retentionArray = 'retentionarray';

  /// Every tower id, the oxygenator first.
  static const List<String> all = [
    oxygenator,
    greenhouseFactory,
    regolithBaker,
    carbonSequestrator,
    retentionArray,
  ];

  /// Whether [type] is one of the family.
  static bool isTower(String type) => all.contains(type);
}

/// What a colony's towers ran at in one step: Σ throttle per kind, so two
/// half-staffed factories count as one. A tower counted merely for EXISTING
/// would change a planet from a dark, empty building.
class TowerRuns {
  double oxygenator = 0;
  double greenhouse = 0;
  double baker = 0;
  double sequestrator = 0;
  double retention = 0;

  /// Back to nothing running — the start of a production step.
  void reset() {
    oxygenator = 0;
    greenhouse = 0;
    baker = 0;
    sequestrator = 0;
    retention = 0;
  }

  /// Count a building of [type] that ran at [run] (0..1). Anything that is
  /// not a tower is ignored, so the production loop can call this for every
  /// building it runs.
  void add(String type, double run) {
    if (run <= 0) return;
    switch (type) {
      case TerraformTowers.oxygenator:
        oxygenator += run;
      case TerraformTowers.greenhouseFactory:
        greenhouse += run;
      case TerraformTowers.regolithBaker:
        baker += run;
      case TerraformTowers.carbonSequestrator:
        sequestrator += run;
      case TerraformTowers.retentionArray:
        retention += run;
    }
  }

  bool get isEmpty =>
      oxygenator == 0 &&
      greenhouse == 0 &&
      baker == 0 &&
      sequestrator == 0 &&
      retention == 0;
}
