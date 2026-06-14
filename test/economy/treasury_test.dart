import 'package:acro_space_simulator/domain/economy/treasury.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('earning funds increases the balance and logs the transaction', () {
    final t = Treasury(balance: 1000);
    t.earn(500, reason: 'contract: first orbit');
    expect(t.balance, 1500);
    expect(t.ledger.last.amount, 500);
    expect(t.ledger.last.reason, contains('first orbit'));
  });

  test('spending within budget succeeds and records a negative entry', () {
    final t = Treasury(balance: 1000);
    final ok = t.spend(300, reason: 'launch: probe');
    expect(ok, isTrue);
    expect(t.balance, 700);
    expect(t.ledger.last.amount, -300);
  });

  test('spending beyond the balance is rejected and changes nothing', () {
    final t = Treasury(balance: 100);
    final ok = t.spend(500, reason: 'too expensive');
    expect(ok, isFalse);
    expect(t.balance, 100);
    expect(t.ledger, isEmpty);
  });

  test('canAfford reflects the current balance', () {
    final t = Treasury(balance: 250);
    expect(t.canAfford(250), isTrue);
    expect(t.canAfford(251), isFalse);
  });

  test('the ledger preserves chronological order', () {
    final t = Treasury(balance: 0);
    t.earn(100, reason: 'a');
    t.earn(50, reason: 'b');
    t.spend(30, reason: 'c');
    expect(t.ledger.map((e) => e.reason).toList(), ['a', 'b', 'c']);
    expect(t.balance, 120);
  });
}
