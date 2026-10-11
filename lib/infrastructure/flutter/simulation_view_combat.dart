// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The in-world view's combat surface (docs/plans/combat.md §7.9, §7A): the
// operation chip and its drawer, the planner from the spaceport's site sheet
// and the Force row, the occupation orders, and the dev hook. Kept as an extension in the same library, like the colony
// surface; its little state lives in an Expando, not on the view.

part of 'simulation_view.dart';

/// What the combat surface remembers between frames.
class _CombatViewState {
  /// Operations whose result the player has been told.
  final Set<int> announced = {};
}

final Expando<_CombatViewState> _combatViewStates = Expando<_CombatViewState>('combat');

extension _SimulationViewCombat on _SimulationViewState {
  _CombatViewState get _combatState =>
      _combatViewStates[this] ??= _CombatViewState();

  OperationRegistry get _operations => _session.operations;

  /// The site-sheet row that opens the planner, on a port the rebels hold.
  List<Widget> _combatSiteRows(CitySim city, String site, CityBuildingSpec spec) {
    if (spec.type != 'spaceport' || !city.loyalty.portSeized) return const [];
    final running = _operations.runningAgainst(city.id);
    return [
      citySiteAction(
        context,
        Icons.shield_outlined,
        running == null ? 'Retake the port by force' : 'Operation under way',
        running == null
            ? 'Send troopers from your other colonies. Force wins no loyalty.'
            : 'Troopers are already fighting for this port.',
        running == null ? AppTheme.warn : AppTheme.textDim,
        () => running == null ? _openForcePlanner(city) : _openOperationDrawer(running),
      ),
    ];
  }

  /// What the colony panels may ask of the war while this view is mounted
  /// (`CombatHooks`): every order is a command on the registry's inbox.
  void _installCombatHooks() {
    CombatHooks.openForce = (ctx, city) {
      final running = _operations.runningAgainst(city.id);
      if (running != null) {
        _openOperationDrawer(running);
      } else {
        _openForcePlanner(city);
      }
    };
    CombatHooks.forceStatus = (city) {
      final running = _operations.runningAgainst(city.id);
      return running == null ? null : _chipLine(running);
    };
    CombatHooks.restoreCharter = (city) => _operations.inbox
        .enqueue(RestoreCharterCommand(const PlayerId('player'), 0, city.id));
    CombatHooks.withdrawGarrison = (city) => _operations.inbox
        .enqueue(WithdrawGarrisonCommand(const PlayerId('player'), 0, city.id));
  }

  void _openForcePlanner(CitySim city) {
    showOperationPlanner(
      context,
      target: city,
      sources: forceSourcesFor(city, _cities.all()),
      registry: _operations,
    );
  }

  String _colonyName(String id) {
    for (final c in _cities.all()) {
      if (c.id == id) return c.name;
    }
    return id;
  }

  static String _bandLabel(OutcomeBand b) => switch (b) {
        OutcomeBand.decisiveVictory => 'Decisive victory',
        OutcomeBand.closeVictory => 'Close victory',
        OutcomeBand.pyrrhicVictory => 'Pyrrhic victory',
        OutcomeBand.valiantDefeat => 'Valiant defeat',
        OutcomeBand.closeDefeat => 'Close defeat',
        OutcomeBand.decisiveDefeat => 'Decisive defeat',
        OutcomeBand.none => 'No decision',
      };

  static bool _assault(Operation op) => op.kind == OperationKind.colonyAssault;

  static String _outcomeLabel(Operation op) => switch (op.outcome) {
        OperationOutcome.won => _assault(op) ? 'Colony taken' : 'Spaceport retaken',
        OperationOutcome.lost => _assault(op) ? 'Assault repulsed' : 'Attack repulsed',
        OperationOutcome.withdrawn => 'Withdrawn',
        OperationOutcome.ceasefire => 'Ceasefire: no decision',
        OperationOutcome.rejoined => 'The colony rejoined',
        OperationOutcome.overtaken => 'Overtaken by events',
        null => '',
      };

  String _chipLine(Operation op) {
    final where = _colonyName(op.targetColonyId);
    switch (op.phase) {
      case OperationPhase.mustering:
        return 'Mustering for $where';
      case OperationPhase.transit:
        return 'In transit to $where';
      case OperationPhase.engaged:
        final day = (op.seconds - op.engagedAtStep) / op.tuning.daySec;
        return _assault(op)
            ? 'Fighting for $where · day ${day.toStringAsFixed(1)}'
            : 'Fighting for $where\'s spaceport · day ${day.toStringAsFixed(1)}';
      case OperationPhase.resolved:
        final band = op.band == OutcomeBand.none ? '' : ' · ${_bandLabel(op.band)}';
        return '${_outcomeLabel(op)} at $where$band';
    }
  }

  /// The operation chips: every running operation, and results not yet seen.
  Widget? _combatChips() {
    final ops = _operations.operations;
    if (ops.isEmpty) return null;
    final shown = [
      for (final op in ops)
        if (!op.resolved || !_combatState.announced.contains(op.id)) op,
    ];
    if (shown.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final op in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: AppTheme.panel.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                key: Key('combat-chip-${op.id}'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => _openOperationDrawer(op),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(op.resolved ? Icons.flag_outlined : Icons.shield_outlined,
                        size: 16,
                        color: op.outcome == OperationOutcome.won
                            ? AppTheme.accent2
                            : (op.resolved ? AppTheme.textDim : AppTheme.warn)),
                    const SizedBox(width: 6),
                    Text(_chipLine(op), style: AppTheme.body),
                    if (op.phase == OperationPhase.engaged) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 60,
                        child: LinearProgressIndicator(
                          value: ((op.graph.byId(op.goalId)?.control ?? -1) + 1) / 2,
                          minHeight: 5,
                          color: AppTheme.accent2,
                          backgroundColor: AppTheme.danger.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _openOperationDrawer(Operation op) {
    // Only a result is seen by opening it: a look at the fight mid-way must
    // not hide the chip that will say how it ended.
    if (op.resolved) _combatState.announced.add(op.id);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Widget line(String a, String b) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(child: Text(a, style: AppTheme.body)),
                Text(b, style: AppTheme.mono),
              ]),
            );
        final attackers = op.formations.where((f) => f.side == CombatSide.attacker).toList();
        final defenders = op.formations.where((f) => f.side == CombatSide.defender).toList();
        String place(String at) => switch (op.graph.byId(at)?.kind) {
              ObjectiveKind.lz => 'the landing zone',
              ObjectiveKind.port => 'the port',
              ObjectiveKind.seat => 'the seat',
              ObjectiveKind.lifeSupport => 'life support',
              ObjectiveKind.power => 'the power plant',
              ObjectiveKind.depot => 'the depot',
              ObjectiveKind.airfield => 'the airfield',
              null => at,
            };
        int pct(String id) => (((op.graph.byId(id)?.control ?? -1) + 1) * 50).round();
        // A marching squad is already booked at where it is going.
        String where(Formation f) => f.broken
            ? 'broken'
            : (f.at == FormationAt.transit
                ? 'in transit'
                : (op.clock.steps < f.arriveStep ? 'marching on ${place(f.at)}' : 'at ${place(f.at)}'));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_chipLine(op), style: AppTheme.heading),
                const SizedBox(height: 8),
                if (op.phase == OperationPhase.engaged || op.resolved)
                  for (final id in _assault(op) ? op.path.skip(1) : [op.goalId])
                    line('Control of ${place(id)}', '${pct(id)}%'),
                line('Your troopers', '${op.attackerAlive} fit · ${op.attackerWounded} wounded · ${op.attackerDead} dead'),
                line(_assault(op) ? 'Defenders' : 'Rebels', '${op.defenderRemoved} fallen of ${op.defenderRaised} · '
                    '${op.militia.total} still at home'),
                if (op.defenderSurrendered > 0) line('Surrendered', '${op.defenderSurrendered}'),
                const SizedBox(height: 8),
                Text('Your squads', style: AppTheme.dim),
                for (final f in attackers)
                  if (f.alive || f.wounded > 0)
                    line('  ${f.count} ${f.kind.name} · ${where(f)}',
                        'morale ${(f.morale * 100).round()}% · ${f.kitDays.toStringAsFixed(1)} d kit'),
                const SizedBox(height: 6),
                Text(_assault(op) ? 'Its defenders' : 'Rebel squads', style: AppTheme.dim),
                for (final f in defenders)
                  if (f.alive)
                    line('  ${f.count} ${f.kind.name} · ${where(f)}',
                        'morale ${(f.morale * 100).round()}%'),
                const SizedBox(height: 12),
                Row(children: [
                  const Spacer(),
                  if (!op.resolved)
                    TextButton(
                      key: const Key('combat-withdraw'),
                      onPressed: () {
                        _operations.inbox.enqueue(
                            WithdrawOperationCommand(const PlayerId('player'), 0, op.id));
                        Navigator.of(ctx).maybePop();
                      },
                      child: Text('Withdraw', style: AppTheme.body.copyWith(color: AppTheme.warn)),
                    ),
                  TextButton(
                      onPressed: () => Navigator.of(ctx).maybePop(), child: const Text('Close')),
                ]),
              ]),
            ),
          ),
        );
      }),
    );
  }

  /// `ext.acro.combat` (docs/plans/combat.md §7.9): the operation surface,
  /// driven by name for a headless check.
  ///   status                      operations as JSON
  ///   fixture=portSeizedPair      the open colony's rebels seize its port, and
  ///                               a supplied source colony with 3 barracks is
  ///                               founded beside it
  ///   fixture=independent         the open colony has seceded (three revolts),
  ///                               with the same source beside it
  ///   launch=1[&garrison=N][&kit=D][&roe=standard]
  ///                               launch every ready trooper at the open colony
  ///   panel=independence|occupation  open the colony's panel
  ///   charter=ready               an occupied colony has held the line 11 days
  ///   step=S                      run S seconds of world ticks now
  ///   planner=open | drawer=ID    open the planner, or an operation's drawer
  ///   dismiss=1                   close the open sheet
  Map<String, Object?> _combatHook(Map<String, String> p) {
    final did = <String, Object?>{};
    final target = _editingCity ?? (_cities.all().isEmpty ? null : _cities.all().first);
    if (p['fixture'] == 'portSeizedPair' && target != null) {
      did['fixture'] = _combatFixture(target);
    }
    if (p['fixture'] == 'independent' && target != null) {
      did['fixture'] = _combatFixture(target, independent: true);
    }
    if (p['charter'] == 'ready' && target != null && target.loyalty.occupied) {
      target.loyalty
        ..level = 0.7
        ..charterSinceS = target.loyalty.colonyTimeS - 11 * target.loyalty.tuning.daySec;
      did['charter'] = 'ready';
    }
    if (p['launch'] != null && target != null) {
      final sources = forceSourcesFor(target, _cities.all());
      final draws = [
        for (final s in sources)
          for (final t in s.trooperSources())
            if (t.ready) (colonyId: s.id, siteId: t.siteId, count: t.available),
      ];
      _operations.inbox.enqueue(LaunchOperationCommand(const PlayerId('player'), 0,
          targetColonyId: target.id,
          draws: draws,
          kitDays: double.tryParse(p['kit'] ?? '') ??
              (target.loyalty.allegiance == Allegiance.independent ? 6 : 3),
          roe: p['roe'] ?? 'restrained',
          garrison: int.tryParse(p['garrison'] ?? '') ?? 2));
      did['launch'] = {'troopers': draws.fold<int>(0, (a, d) => a + d.count)};
    }
    final step = double.tryParse(p['step'] ?? '');
    if (step != null && step > 0) {
      final n = (step / _clock.fixedStep).round();
      for (var i = 0; i < n; i++) {
        _session.step();
        for (final c in _cities.all()) {
          c.agents.endFrame();
        }
      }
      did['step'] = n;
      if (mounted) rebuild(() {});
    }
    if (p['dismiss'] != null) Navigator.of(context).maybePop();
    if (p['planner'] == 'open' && target != null) _openForcePlanner(target);
    if (p['panel'] == 'independence' && target != null) showIndependence(context, target);
    if (p['panel'] == 'occupation' && target != null) showOccupation(context, target);
    final drawer = int.tryParse(p['drawer'] ?? '');
    if (drawer != null) {
      final op = _operations.byId(drawer);
      if (op != null) _openOperationDrawer(op);
    }
    return {
      if (did.isNotEmpty) 'did': did,
      'refusal': _operations.lastRefusal,
      'operations': [
        for (final op in _operations.operations)
          {
            'id': op.id,
            'target': op.targetColonyId,
            'phase': op.phase.name,
            'outcome': op.outcome?.name,
            'band': op.band.name,
            'seconds': op.seconds,
            'control': op.graph.byId(op.goalId)?.control,
            'attackers': {'alive': op.attackerAlive, 'wounded': op.attackerWounded, 'dead': op.attackerDead},
            'defenders': {'raised': op.defenderRaised, 'removed': op.defenderRemoved, 'surrendered': op.defenderSurrendered},
          },
      ],
      if (target != null)
        'target': {
          'id': target.id,
          'portSeized': target.loyalty.portSeized,
          'stage': target.loyalty.stage.name,
          'allegiance': target.loyalty.allegiance.name,
          'garrison': target.war.garrison?.count,
          'occupation': target.war.garrison?.occupation ?? false,
          'level': target.loyalty.level,
          'charterReady': target.loyalty.charterReady,
          'population': target.population,
        },
    };
  }

  /// The open colony's rebels take its port, and a supplied source colony is
  /// founded on the same body: the two-colony world every force check needs.
  Map<String, Object?> _combatFixture(CitySim target, {bool independent = false}) {
    if (independent) {
      final t = target.loyalty.colonyTimeS;
      target.loyalty
        ..allegiance = Allegiance.independent
        ..stage = LoyaltyStage.seceded
        ..level = 0
        ..portSeized = false
        ..impoundPending = false
        ..independentAtS = t
        ..independenceCauses = 'no orders for 40 days; 3 revolts in 15 days'
        ..reclaim.grievance = const Grievance(neglectDays: 40, rebellion: 1, revolts: 3);
    } else {
      target.loyalty
        ..level = 0.05
        ..desperation = 0.6
        ..stage = LoyaltyStage.standoff
        ..portSeized = true
        ..impoundPending = true;
      target.loyalty.tuning = const CityLoyaltyTuning(independenceBar: 5);
    }
    var src = _cities.byId('src-dev');
    if (src == null) {
      src = CityStarterKit.found(
        bodies: _universe.current().all.where((b) => !b.isStar).toList(),
        config: CityConfig(
            bodyId: target.body.id.value,
            latitude: target.cityLat + 0.2,
            longitude: target.cityLon + 0.2),
        id: 'src-dev',
        name: 'Garrison Town',
      )
        ..hostility = 0
        ..autoDisasterTimer = 1e9;
      final barracks = kUtilCatalog.firstWhere((s) => s.type == 'barracks');
      var placed = 0;
      for (final lot in [...src.layout.autoParcels]) {
        if (placed == 3) break;
        if (src.parcelBuildings.containsKey(lot.id)) continue;
        if (src.placeOnParcel(lot.id, barracks)) placed++;
      }
      _cities.add(src);
    }
    src.stock[Commodity.rations] = 400;
    src.stock[Commodity.guns] = 80;
    src.stock[Commodity.ammo] = 400;
    src.population = 300;
    return {'target': target.id, 'source': src.id};
  }
}
