// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How a plant's operator reacts to its books (docs/plans/factory-floors.md
/// §3 "When a firm struggles", §7 Q9-Q11).
///
/// User decisions (2026-10-12):
/// - A private firm builds only what pays back within [kFirmPaybackYears]
///   game-years ([firmWillBuild]); the rest needs a subsidy or a state
///   contract. Real firms buy forklifts when labour is dear: with the cash
///   and a short payback, a firm INVESTS before it cuts.
/// - A losing firm lays off (handlers first), then idles stations, then
///   closes. A closed plant is offered to the state (nationalise) or sold
///   to a new firm.
/// - A state plant never closes; its loss is charged to `funds` as the
///   industry deficit ([FirmBook.industryDeficitPerS]).
///
/// The books are a ROLLING window (an exponential average over
/// [kFirmWindowSec]) so one bad week of brownout doesn't fire anyone, and
/// health moves with HYSTERESIS: the margin that pushes a firm into a state
/// is worse than the one that lets it out, so a plant sitting at a
/// threshold doesn't flap between "strained" and "healthy" every tick.
/// Actions are spaced by [kFirmActionCooldownSec] so a cut can show in the
/// books before the next one.
library;

import 'dart:math' as math;

import 'economy_clock.dart';
import 'economy_contracts.dart';

/// Time constant of the rolling P&L, colony seconds: a month.
const double kFirmWindowSec = 30 * kColonyDaySec;

/// Margin (profit ÷ revenue) below which a healthy firm is strained, and
/// above which a strained one recovers. The 5-point gap is the hysteresis.
const double kStrainEnterMargin = -0.02;
const double kStrainExitMargin = 0.03;

/// Margin below which a firm is distressed, and above which it is merely
/// strained again.
const double kDistressEnterMargin = -0.15;
const double kDistressExitMargin = -0.05;

/// Colony seconds between a firm's actions: a week, long enough for a
/// layoff to show in the rolling books.
const double kFirmActionCooldownSec = 7 * kColonyDaySec;

/// Colony seconds a distressed firm with nothing left to cut keeps trading
/// before it closes: a month.
const double kCloseGraceSec = 30 * kColonyDaySec;

/// Whether a private firm will pay [capex] credits for a change that saves
/// [savingsPerS] credits per colony second: payback within
/// [kFirmPaybackYears] game-years ([kGameYearSec]).
bool firmWillBuild({required double capex, required double savingsPerS}) {
  if (savingsPerS <= 0) return false;
  if (capex <= 0) return true;
  return capex / savingsPerS <= kFirmPaybackYears * kGameYearSec;
}

/// An improvement a firm could buy: automation, a forklift, a crane bay.
class Investment {
  const Investment({required this.capex, required this.savingsPerS});
  final double capex;
  final double savingsPerS;
}

/// What can be done with a closed plant.
enum ClosureOption { nationalise, sellToNewFirm }

/// The offer a closed plant makes, by economy: communism has no buyers.
List<ClosureOption> closureOptions(EconomyKind e) => e == EconomyKind.communism
    ? const [ClosureOption.nationalise]
    : const [ClosureOption.nationalise, ClosureOption.sellToNewFirm];

/// One plant operator's books and health.
class FirmBook {
  FirmBook({
    required this.owner,
    this.health = FirmHealth.healthy,
    this.cash = 0,
    this.revenuePerS = 0,
    this.costPerS = 0,
    this.taxPerS = 0,
    this.sinceActionS = kFirmActionCooldownSec,
    this.distressedForS = 0,
  });

  Ownership owner;
  FirmHealth health;

  /// Retained profit after tax (private only), credits: what an investment
  /// is paid from.
  double cash;

  /// Rolling rates, credits per colony second.
  double revenuePerS;
  double costPerS;
  double taxPerS;

  /// Seconds since the firm last acted; and how long it has been distressed.
  double sinceActionS;
  double distressedForS;

  double get profitPerS => revenuePerS - costPerS - taxPerS;

  /// Profit as a share of revenue; −1 for a plant with costs and no sales.
  double get margin => revenuePerS > 0
      ? profitPerS / revenuePerS
      : (costPerS > 0 ? -1 : 0);

  /// What a STATE plant's loss charges to `funds` per second (0 when it
  /// profits, and always 0 for a private one).
  double get industryDeficitPerS =>
      owner.isState ? math.max(0, costPerS - revenuePerS) : 0;

  bool get isClosed => health == FirmHealth.closed;

  /// Folds one period's [pnl] into the rolling books and updates health.
  void record(PlantPnL pnl) {
    final s = pnl.seconds;
    if (s <= 0 || isClosed) return;
    final a = 1 - math.exp(-s / kFirmWindowSec);
    revenuePerS += (pnl.revenue / s - revenuePerS) * a;
    costPerS += (pnl.costs / s - costPerS) * a;
    taxPerS += (pnl.tax / s - taxPerS) * a;
    if (!owner.isState) cash += pnl.profit;
    sinceActionS += s;
    health = _next(health, margin);
    distressedForS = health == FirmHealth.distressed ? distressedForS + s : 0;
  }

  static FirmHealth _next(FirmHealth h, double m) {
    switch (h) {
      case FirmHealth.closed:
        return h;
      case FirmHealth.healthy:
        if (m < kDistressEnterMargin) return FirmHealth.distressed;
        return m < kStrainEnterMargin ? FirmHealth.strained : h;
      case FirmHealth.strained:
        if (m < kDistressEnterMargin) return FirmHealth.distressed;
        return m > kStrainExitMargin ? FirmHealth.healthy : h;
      case FirmHealth.distressed:
        if (m > kStrainExitMargin) return FirmHealth.healthy;
        return m > kDistressExitMargin ? FirmHealth.strained : h;
    }
  }

  /// This period's action, and its effect on the books: an investment is
  /// paid from [cash]; a close sets [health] to closed. In order: invest if
  /// [investment] pays back and cash allows; else, when losing, lay off
  /// handlers ([canLayOff]), then idle stations ([canIdle]), then close
  /// once distressed for [kCloseGraceSec] with nothing left to cut.
  ///
  /// A state plant never acts: the player runs it, and its loss is the
  /// industry deficit.
  FirmAction decide({
    Investment? investment,
    bool canLayOff = false,
    bool canIdle = false,
  }) {
    if (isClosed || owner.isState) return FirmAction.none;
    if (sinceActionS < kFirmActionCooldownSec) return FirmAction.none;
    final inv = investment;
    if (inv != null &&
        cash >= inv.capex &&
        firmWillBuild(capex: inv.capex, savingsPerS: inv.savingsPerS)) {
      cash -= inv.capex;
      sinceActionS = 0;
      return FirmAction.invest;
    }
    if (health == FirmHealth.healthy) return FirmAction.none;
    if (canLayOff) {
      sinceActionS = 0;
      return FirmAction.layoff;
    }
    if (canIdle) {
      sinceActionS = 0;
      return FirmAction.idleStations;
    }
    if (health == FirmHealth.distressed && distressedForS >= kCloseGraceSec) {
      health = FirmHealth.closed;
      sinceActionS = 0;
      return FirmAction.close;
    }
    return FirmAction.none;
  }

  /// The offer a closed plant makes; empty while it trades.
  List<ClosureOption> offer(EconomyKind e) =>
      isClosed ? closureOptions(e) : const [];

  /// The plant reopened under its new owner, with fresh books. [newFirmId]
  /// names the buyer when [choice] is a sale.
  FirmBook reopen(ClosureOption choice, {String? newFirmId}) => FirmBook(
        owner: choice == ClosureOption.nationalise
            ? const Ownership.state()
            : Ownership.private(newFirmId ?? '${owner.firmId ?? 'firm'}+'),
      );

  Map<String, Object?> toJson() => {
        'o': owner.toJson(),
        'h': health.name,
        'cash': cash,
        'rev': revenuePerS,
        'cost': costPerS,
        'tax': taxPerS,
        'act': sinceActionS,
        'dis': distressedForS,
      };

  static FirmBook fromJson(Map<String, Object?> j) {
    double d(String k, double or) => (j[k] as num?)?.toDouble() ?? or;
    return FirmBook(
      owner: Ownership.fromJson((j['o'] as Map).cast<String, Object?>()),
      health: FirmHealth.values.byName(j['h'] as String? ?? 'healthy'),
      cash: d('cash', 0),
      revenuePerS: d('rev', 0),
      costPerS: d('cost', 0),
      taxPerS: d('tax', 0),
      sinceActionS: d('act', kFirmActionCooldownSec),
      distressedForS: d('dis', 0),
    );
  }
}
