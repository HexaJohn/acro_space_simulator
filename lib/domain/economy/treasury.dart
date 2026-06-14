/// One funds movement. Positive [amount] = income, negative = spending.
class Transaction {
  final double amount;
  final String reason;
  const Transaction(this.amount, this.reason);
}

/// The player's funds, with an append-only transaction ledger. Aggregate root
/// for the economy context — contracts deposit rewards, launches/parts and
/// upkeep withdraw, mined resources can be sold here.
class Treasury {
  double _balance;
  final List<Transaction> _ledger = [];

  Treasury({double balance = 0}) : _balance = balance;

  double get balance => _balance;
  List<Transaction> get ledger => List.unmodifiable(_ledger);

  bool canAfford(double amount) => _balance >= amount;

  /// Add income.
  void earn(double amount, {required String reason}) {
    if (amount <= 0) return;
    _balance += amount;
    _ledger.add(Transaction(amount, reason));
  }

  /// Spend funds if affordable. Returns false (no change) when short.
  bool spend(double amount, {required String reason}) {
    if (amount <= 0) return true;
    if (!canAfford(amount)) return false;
    _balance -= amount;
    _ledger.add(Transaction(-amount, reason));
    return true;
  }
}
