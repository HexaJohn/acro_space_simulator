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
          baseMateriel: (j['baseM'] as num?)?.toInt() ?? 0,
          baseSupport: (j['baseS'] as num?)?.toInt() ?? 0,
        );
      case 'withdraw':
        return WithdrawOperationCommand(by, tick, (j['op'] as num).toInt());
      case 'withdrawGarrison':
        return WithdrawGarrisonCommand(by, tick, j['colony'] as String);
      case 'restoreCharter':
        return RestoreCharterCommand(by, tick, j['colony'] as String);
      case 'order':
        return OrderOperationCommand(by, tick, (j['op'] as num).toInt(), j['order'] as String,
            target: j['target'] as String?);
      case 'power':
        return CommanderPowerCommand(by, tick, (j['op'] as num).toInt(), j['power'] as String,
            target: j['target'] as String?);
      case 'base':
        return BaseOrderCommand(by, tick, (j['op'] as num).toInt(), j['action'] as String,
            module: j['module'] as String?,
            ring: j['ring'] as String?,
            socket: (j['socket'] as num?)?.toInt(),
            site: (j['site'] as num?)?.toInt(),
            value: j['value'] as String?);
      case 'reinforce':
        return ReinforceOperationCommand(
          by,
          tick,
          (j['op'] as num).toInt(),
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
        );
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
    this.baseMateriel = 0,
    this.baseSupport = 0,
  });

  final String targetColonyId;
  final List<({String colonyId, String siteId, int count})> draws;
  final double kitDays;

  /// Troopers to leave holding the port, or the colony, after a win.
  final int garrison;

  /// Rules of engagement, by name: `restrained` or `standard`.
  final String roe;

  /// A forward base's Materiel (ore) and support staff (combat.md §7C); both
  /// 0 for a light operation, with no base.
  final int baseMateriel;
  final int baseSupport;

  bool get withBase => baseMateriel > 0 || baseSupport > 0;

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
        if (baseMateriel != 0) 'baseM': baseMateriel,
        if (baseSupport != 0) 'baseS': baseSupport,
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

/// Give a running operation's attackers a standing order
/// (docs/plans/combat.md §7B): `auto`, `attack` [target], `hold` or
/// `fallBack`.
class OrderOperationCommand extends CombatCommand {
  const OrderOperationCommand(super.issuedBy, super.tick, this.operationId, this.order,
      {this.target});
  final int operationId;
  final String order;
  final String? target;

  @override
  String get targetAssetId => 'operation:$operationId';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'order',
        'by': issuedBy.value,
        'tick': tick,
        'op': operationId,
        'order': order,
        if (target != null) 'target': target,
      };
}

/// Send more troopers to a running operation; they land at its LZ a
/// mustering and a crossing later.
class ReinforceOperationCommand extends CombatCommand {
  const ReinforceOperationCommand(super.issuedBy, super.tick, this.operationId,
      {required this.draws, this.kitDays = 3});
  final int operationId;
  final List<({String colonyId, String siteId, int count})> draws;
  final double kitDays;

  @override
  String get targetAssetId => 'operation:$operationId';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'reinforce',
        'by': issuedBy.value,
        'tick': tick,
        'op': operationId,
        'draws': [
          for (final d in draws) {'colony': d.colonyId, 'site': d.siteId, 'n': d.count}
        ],
        'kit': kitDays,
      };
}

/// An order to an operation's forward base (combat.md §7C, §7D): `build` a
/// [module] in [ring] socket [socket] of [site], `cancel` line [socket] of
/// [site], `demolish` what stands in a socket, `formSquad` from the reserve,
/// `upgrade` to tier [value], `outpost` beside objective [value],
/// `doctrine` [value], or deploy the `spareCore` at objective [value].
class BaseOrderCommand extends CombatCommand {
  const BaseOrderCommand(super.issuedBy, super.tick, this.operationId, this.action,
      {this.module, this.ring, this.socket, this.site, this.value});
  final int operationId;
  final String action;
  final String? module;
  final String? ring;
  final int? socket;
  final int? site;
  final String? value;

  @override
  String get targetAssetId => 'operation:$operationId';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'base',
        'by': issuedBy.value,
        'tick': tick,
        'op': operationId,
        'action': action,
        if (module != null) 'module': module,
        if (ring != null) 'ring': ring,
        if (socket != null) 'socket': socket,
        if (site != null) 'site': site,
        if (value != null) 'value': value,
      };
}

/// A commander power (combat.md §7D): `supplyDrop`, or `medevac` from
/// objective [target].
class CommanderPowerCommand extends CombatCommand {
  const CommanderPowerCommand(super.issuedBy, super.tick, this.operationId, this.power,
      {this.target});
  final int operationId;
  final String power;
  final String? target;

  @override
  String get targetAssetId => 'operation:$operationId';

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'power',
        'by': issuedBy.value,
        'tick': tick,
        'op': operationId,
        'power': power,
        if (target != null) 'target': target,
      };
}
