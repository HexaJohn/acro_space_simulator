// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

part of 'command.dart';

/// Every player input a battle depends on, as a command applied at the tick
/// (docs/plans/combat.md §3, rule 2; §7.7).
///
/// One sealed family, so each exhaustive switch over [SimCommand] needs a
/// single `case CombatCommand()` and a new combat command cannot be missed
/// anywhere. Local-only for now: the live game queues them in a
/// `CommandInbox` drained by the world's combat phase; the wire codec and the
/// engine bridge refuse them until combat goes on the wire.
sealed class CombatCommand extends SimCommand {
  const CombatCommand(super.issuedBy, super.tick);

  /// For saving a command still waiting in the inbox.
  Map<String, dynamic> toJson();

  static CombatCommand? fromJson(Object? j) {
    if (j is! Map) return null;
    final by = PlayerId(j['by'] as String? ?? 'player');
    final tick = (j['tick'] as num?)?.toInt() ?? 0;
    switch (j['kind']) {
      case 'launch':
        return LaunchOperationCommand(
          by,
          tick,
          targetColonyId: j['target'] as String,
          draws: [
            for (final d in (j['draws'] as List? ?? const []))
              if (d is Map)
                (
                  colonyId: d['colony'] as String,
                  siteId: d['site'] as String,
                  count: (d['n'] as num).toInt(),
                ),
          ],
          kitDays: (j['kit'] as num?)?.toDouble() ?? 3,
          garrison: (j['garrison'] as num?)?.toInt() ?? 0,
          roe: j['roe'] as String? ?? 'restrained',
        );
      case 'withdraw':
        return WithdrawOperationCommand(by, tick, (j['op'] as num).toInt());
      case 'withdrawGarrison':
        return WithdrawGarrisonCommand(by, tick, j['colony'] as String);
      case 'restoreCharter':
        return RestoreCharterCommand(by, tick, j['colony'] as String);
    }
    return null;
  }
}

/// Launch an operation against [targetColonyId] with troopers drawn from the
/// listed buildings: to retake its seized port, or — an independent colony —
/// to take it (docs/plans/combat.md §7A).
class LaunchOperationCommand extends CombatCommand {
  const LaunchOperationCommand(
    super.issuedBy,
    super.tick, {
    required this.targetColonyId,
    required this.draws,
    this.kitDays = 3,
    this.garrison = 0,
    this.roe = 'restrained',
  });

  final String targetColonyId;
  final List<({String colonyId, String siteId, int count})> draws;
  final double kitDays;

  /// Troopers to leave holding the port, or the colony, after a win.
  final int garrison;

  /// Rules of engagement, by name: `restrained` or `standard`.
  final String roe;

  @override
  String get targetAssetId => targetColonyId;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'launch',
        'by': issuedBy.value,
        'tick': tick,
        'target': targetColonyId,
        'draws': [
          for (final d in draws) {'colony': d.colonyId, 'site': d.siteId, 'n': d.count}
        ],
        'kit': kitDays,
        'garrison': garrison,
        if (roe != 'restrained') 'roe': roe,
      };
}

/// Withdraw a running operation: survivors come home.
class WithdrawOperationCommand extends CombatCommand {
  const WithdrawOperationCommand(super.issuedBy, super.tick, this.operationId);
  final int operationId;

  @override
  String get targetAssetId => 'operation:$operationId';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'withdraw', 'by': issuedBy.value, 'tick': tick, 'op': operationId};
}

/// Bring the garrison holding [colonyId]'s port home — or, from an occupied
/// colony, end the occupation early.
class WithdrawGarrisonCommand extends CombatCommand {
  const WithdrawGarrisonCommand(super.issuedBy, super.tick, this.colonyId);
  final String colonyId;

  @override
  String get targetAssetId => colonyId;

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'withdrawGarrison', 'by': issuedBy.value, 'tick': tick, 'colony': colonyId};
}

/// Restore an occupied colony's charter, once it has earned it: colonial
/// again, and the garrison comes home (docs/plans/combat.md §7A).
class RestoreCharterCommand extends CombatCommand {
  const RestoreCharterCommand(super.issuedBy, super.tick, this.colonyId);
  final String colonyId;

  @override
  String get targetAssetId => colonyId;

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'restoreCharter', 'by': issuedBy.value, 'tick': tick, 'colony': colonyId};
}
