// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/craft/craft_balance.dart';
import '../../../../domain/craft/craft_design.dart';
import '../../../../domain/shared/units.dart';
import '../../../../domain/vessel/vessel.dart';
import '../app_theme.dart';
import 'craft_editor_controller.dart';
import 'craft_launch.dart';

/// One staging group's rocket-equation budget, in the order it fires.
///
/// [stage] indexes [CraftDesign.stages]; the HIGHEST index burns and separates
/// first, because `Vessel.activeStage` is `stages.last` and `separateStage()`
/// drops the last. A list of these therefore reads top-down as the flight plan.
class StageBudget {
  final int stage;

  /// Mass aboard when this group lights: every part in this group and every
  /// group below it, wet. Groups above it have already gone. (kg)
  final double startMassKg;

  /// Everything in this group's tanks, which is what the burn spends. (kg)
  final double propellantKg;

  /// Summed vacuum rating of this group's rocket engines. (N)
  final double thrustN;

  /// Tsiolkovsky over [startMassKg] and [propellantKg] at the group's vacuum
  /// Isp, or 0 when the group has no rocket engine or nothing to burn. (m/s)
  final double deltaV;

  const StageBudget({
    required this.stage,
    required this.startMassKg,
    required this.propellantKg,
    required this.thrustN,
    required this.deltaV,
  });

  /// Fuel with no engine to burn it — almost always a staging mistake, and
  /// invisible in a single "Δv" number.
  bool get isDeadWeight => deltaV <= 0 && propellantKg > 0;

  /// An engine with nothing in its group to feed it.
  bool get isDry => thrustN > 0 && propellantKg <= 0;

  @override
  String toString() =>
      'StageBudget(S$stage, ${deltaV.toStringAsFixed(0)} m/s)';
}

/// The readout: the assembled vessel's headline numbers, where the craft
/// balances, and what each staging group is actually worth.
///
/// ## Why per-stage delta-v is not optional
///
/// `Vessel.deltaVCapacity()` reports the ACTIVE stage only, and
/// `CraftDesign.attachPart` defaults a part's stage to its parent's — so a
/// whole stacked craft built without staging lands in group 0 and one number
/// under the label "Δv" silently means something different depending on how the
/// craft was assembled. The headline tile is kept exactly as it was; the STAGING
/// section underneath is what makes it unambiguous.
class CraftStatsPane extends StatelessWidget {
  const CraftStatsPane({super.key, required this.controller});

  final CraftEditorController controller;

  /// Per-group budgets in FIRING ORDER — highest stage index first.
  ///
  /// Mirrors `Vessel.deltaVCapacity()` term for term so the top entry equals
  /// what the flight model will report the moment the craft launches: mass is
  /// the whole vehicle at or below the group, propellant is every resource in
  /// the group's own parts, and Isp comes from the first rocket engine in the
  /// group in design order — the same part `Stage.engines.first` resolves to,
  /// since `Part.isEngine` counts rocket engines only.
  ///
  /// A jet-powered group reports zero: a `JetEngine` carries no vacuum Isp and
  /// its thrust is Mach- and altitude-dependent, so there is no honest single
  /// number for it here.
  static List<StageBudget> budgets(CraftDesign design) {
    final out = <StageBudget>[];
    for (final group in design.stages.reversed) {
      var startMass = 0.0;
      var propellant = 0.0;
      var thrust = 0.0;
      double? isp;
      for (final p in design.parts) {
        if (p.stage > group) continue; // already separated by the time we burn
        startMass += CraftBalance.partMass(p.def);
        if (p.stage != group) continue;
        propellant += p.def.resources.fold(0.0, (s, r) => s + r.mass);
        final engine = p.def.rocketEngine;
        if (engine == null) continue;
        thrust += engine.maxThrustVacuum;
        isp ??= engine.ispVacuum;
      }
      final burnout = startMass - propellant;
      final vacIsp = isp ?? 0;
      final deltaV = vacIsp <= 0 || burnout <= 0 || startMass <= burnout
          ? 0.0
          : vacIsp * standardGravity * math.log(startMass / burnout);
      out.add(StageBudget(
        stage: group,
        startMassKg: startMass,
        propellantKg: propellant,
        thrustN: thrust,
        deltaV: deltaV,
      ));
    }
    return out;
  }

  /// A bordered label/value tile, the shape every number in this editor wears.
  static Widget statTile(String label, String value, [Color? color]) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF223247)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: AppTheme.dim),
            Text(value,
                style: AppTheme.mono
                    .copyWith(color: color ?? AppTheme.text, fontSize: 14)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _pane(),
      );

  Widget _pane() {
    final design = controller.design;
    final v = CraftLaunch.preview(design);
    if (v == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Add parts to begin.',
              textAlign: TextAlign.center, style: AppTheme.dim),
        ),
      );
    }
    // A ListView, not a Column: the tile Wrap reflows but the three sections
    // together are taller than a phone in landscape, and the pane must scroll
    // INSIDE itself — the screen around it never scrolls.
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _stats(v),
        const SizedBox(height: 14),
        _balance(design),
        const SizedBox(height: 14),
        _staging(design),
      ],
    );
  }

  Widget _stats(Vessel v) {
    final dv = v.deltaVCapacity();
    final crew = v.crew?.count ?? 0;
    final partCount = v.allParts.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('VESSEL STATS', style: AppTheme.heading),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          statTile('Mass', '${(v.mass / 1000).toStringAsFixed(2)} t'),
          statTile('Δv', '${dv.toStringAsFixed(0)} m/s', AppTheme.accent2),
          statTile('Parts', '$partCount'),
          statTile('Stages', '${v.stages.length}'),
          statTile('Crew', '$crew'),
          statTile('Wing area', '${v.totalWingArea.toStringAsFixed(1)} m²'),
        ]),
      ],
    );
  }

  /// Where the craft balances and where it pushes.
  ///
  /// The gap between the wet and dry centres of mass is how far the balance
  /// point travels during a burn: a craft that is stable full and unstable empty
  /// is a craft that flips at staging, and neither number alone shows it.
  Widget _balance(CraftDesign design) {
    final com = CraftBalance.centreOfMass(design);
    final dry = CraftBalance.dryCentreOfMass(design);
    final thrust = CraftBalance.thrust(design);
    final lateral = math.sqrt(com.x * com.x + com.y * com.y);
    final offAxisDeg = _thrustOffAxisDeg(design);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('BALANCE', style: AppTheme.heading),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 8, children: [
          statTile('CoM', 'z ${com.z.toStringAsFixed(2)} m'),
          statTile('Off axis', '${lateral.toStringAsFixed(2)} m',
              lateral > 0.01 ? AppTheme.warn : null),
          statTile('Dry CoM', 'z ${dry.z.toStringAsFixed(2)} m'),
          statTile('CoM shift', '${(com.z - dry.z).toStringAsFixed(2)} m'),
          if (thrust != null)
            statTile('CoT', 'z ${thrust.origin.z.toStringAsFixed(2)} m'),
          if (thrust != null)
            statTile('Thrust', '${(thrust.thrustN / 1000).toStringAsFixed(0)} kN',
                AppTheme.accent2),
        ]),
        const SizedBox(height: 8),
        _alignmentNote(design, offAxisDeg, thrust != null),
      ],
    );
  }

  Widget _alignmentNote(CraftDesign design, double? offAxisDeg, bool hasThrust) {
    if (!hasThrust) {
      final jets = design.parts.any((p) => p.def.jetEngine != null);
      return _note(
        Icons.info_outline,
        AppTheme.textDim,
        jets
            ? 'Jets carry no vacuum rating, so this craft has no thrust marker.'
            : 'No rocket engine — nothing to line up against the centre of mass.',
      );
    }
    if (offAxisDeg == null) {
      return _note(Icons.check_circle_outline, AppTheme.accent2,
          'Engines sit on the centre of mass.');
    }
    if (offAxisDeg > 5) {
      return _note(
        Icons.warning_amber_rounded,
        AppTheme.warn,
        'Thrust line misses the centre of mass by '
        '${offAxisDeg.toStringAsFixed(1)}° — the craft will torque under power.',
      );
    }
    return _note(Icons.check_circle_outline, AppTheme.accent2,
        'Thrust line runs through the centre of mass '
        '(${offAxisDeg.toStringAsFixed(1)}° off).');
  }

  Widget _staging(CraftDesign design) {
    final rows = budgets(design);
    final total = rows.fold(0.0, (s, b) => s + b.deltaV);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The total takes the rest of the line and right-aligns into it rather
        // than being pushed there by a Spacer: this pane is laid out at the
        // inspector's width, and two inflexible Texts either side of a Spacer
        // have a hard minimum width that the narrow column cannot meet.
        Row(
          children: [
            const Text('STAGING', style: AppTheme.heading),
            const SizedBox(width: 8),
            Expanded(
              child: Text('total Δv ${total.toStringAsFixed(0)} m/s',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < rows.length; i++) _stageRow(rows[i], first: i == 0),
      ],
    );
  }

  Widget _stageRow(StageBudget b, {required bool first}) {
    // The head of the list is the group that lights on the pad: the flight
    // model burns and drops the HIGHEST index first, which is the opposite of
    // the order a player reads a rocket in.
    final hint = b.isDeadWeight
        ? 'no engine'
        : b.isDry
            ? 'no propellant'
            : first
                ? 'fires first'
                : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text('S${b.stage}',
                style: AppTheme.mono.copyWith(color: AppTheme.warn)),
          ),
          SizedBox(
            width: 92,
            child: Text('${b.deltaV.toStringAsFixed(0)} m/s',
                style: AppTheme.mono.copyWith(
                    color: b.deltaV > 0 ? AppTheme.text : AppTheme.textDim)),
          ),
          // Both the detail and the flag are flexible, and neither may be the
          // reason the row has a minimum width: an inflexible 'no propellant'
          // beside two fixed columns overflows the narrow inspector, and it
          // only appears once a craft is badly staged — i.e. exactly when the
          // player most needs to read the row. 3:2 keeps the numbers legible
          // while leaving the flag room to say which it is.
          Expanded(
            flex: 3,
            child: Text(
              '${(b.startMassKg / 1000).toStringAsFixed(2)} t  ·  '
              '${(b.propellantKg / 1000).toStringAsFixed(2)} t prop  ·  '
              '${(b.thrustN / 1000).toStringAsFixed(0)} kN',
              style: AppTheme.dim,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hint != null)
            Flexible(
              flex: 2,
              child: Text(hint,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.dim.copyWith(
                      color: b.deltaV > 0 ? AppTheme.accent : AppTheme.warn)),
            ),
        ],
      ),
    );
  }

  static Widget _note(IconData icon, Color color, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: AppTheme.dim.copyWith(color: color))),
        ],
      );

  /// Angle between the thrust LINE and the line from the engines to the centre
  /// of mass, in degrees, or null when the two points coincide.
  ///
  /// Compared sign-free — folded into `[0, 90]` — on purpose.
  /// `CraftBalance.thrust().direction` is the EXHAUST axis, so the push on the
  /// craft is along `-direction`; treating the pair as a line means the readout
  /// is right whichever end of it a future caller hands over.
  static double? _thrustOffAxisDeg(CraftDesign design) {
    final t = CraftBalance.thrust(design);
    if (t == null) return null;
    final lever = CraftBalance.centreOfMass(design) - t.origin;
    if (lever.length < 1e-6) return null;
    final push = -t.direction;
    final cosine = lever.normalized.dot(push).clamp(-1.0, 1.0).abs();
    return math.acos(cosine) * 180 / math.pi;
  }
}
