import '../simulation/domain_event.dart';
import 'contract.dart';

/// A reward payout: funds and science granted on contract completion.
class ContractReward {
  final double funds;
  final double science;
  const ContractReward(this.funds, this.science);
  static const ContractReward none = ContractReward(0, 0);
}

/// Advances a single contract's objectives against a domain event. Domain
/// service — stateless; mutates the contract's objective flags.
class ContractTracker {
  const ContractTracker();

  void handleEvent(Contract contract, DomainEvent event) {
    for (final objective in contract.objectives) {
      if (!objective.done && objective.matches(event)) {
        objective.done = true;
      }
    }
  }
}

/// Tracks a set of active contracts and pays out rewards exactly once each as
/// they complete. Aggregate root for the contracts context.
class ContractBoard {
  final List<Contract> contracts;
  final ContractTracker _tracker;

  ContractBoard({required this.contracts, ContractTracker? tracker})
      : _tracker = tracker ?? const ContractTracker();

  Iterable<Contract> get active =>
      contracts.where((c) => !c.isComplete);
  Iterable<Contract> get completed =>
      contracts.where((c) => c.isComplete);

  /// Feed an event to every contract and return the total reward newly earned
  /// this call (0 if nothing completed for the first time).
  ContractReward process(DomainEvent event) {
    var funds = 0.0;
    var science = 0.0;
    for (final c in contracts) {
      _tracker.handleEvent(c, event);
      if (c.isComplete && !c.rewarded) {
        c.rewarded = true;
        funds += c.rewardFunds;
        science += c.rewardScience;
      }
    }
    return ContractReward(funds, science);
  }
}
