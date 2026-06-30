import '../simulation/domain_event.dart';

/// A single goal within a contract. Mutable [done] flag flips when a matching
/// domain event arrives. Sealed so the tracker handles every objective type.
sealed class Objective {
  bool done = false;

  /// Whether [event] satisfies this objective.
  bool matches(DomainEvent event);
}

/// Completed by entering a particular flight situation (e.g. 'lowOrbit:moon').
class ReachSituationObjective extends Objective {
  final String situation;
  ReachSituationObjective({required this.situation});

  @override
  bool matches(DomainEvent event) =>
      event is SituationEntered && event.situation == situation;
}

/// Completed by mining a given resource anywhere.
class MineResourceObjective extends Objective {
  final String resource; // ResourceType.name
  MineResourceObjective({required this.resource});

  @override
  bool matches(DomainEvent event) => event is ResourceMined;
}

/// Completed by docking any two vessels.
class DockObjective extends Objective {
  @override
  bool matches(DomainEvent event) => event is DockingCompleted;
}

/// A contract: a set of objectives and the reward for completing them all.
/// Aggregate root for the contracts context.
class Contract {
  final String id;
  final String title;
  final double rewardFunds;
  final double rewardScience;
  final List<Objective> objectives;
  bool rewarded = false;

  Contract({
    required this.id,
    required this.title,
    required this.rewardFunds,
    required this.rewardScience,
    required this.objectives,
  });

  bool get isComplete => objectives.every((o) => o.done);
}
