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

  /// Each operation's ground radius under its target, m: sampled once (a
  /// terrain query is ~16 ms in a graded town), never per frame.
  final Map<int, double> groundR = {};

  /// The real ground under each objective, `<op>:<objective>`: a port on a
  /// graded pad stands tens of metres off the colony centre's height, and
  /// smoke drawn at the centre's sat inside the hill. One sample a frame at
  /// most, each kept.
  final Map<String, double> objectiveGround = {};
  bool sampledThisFrame = false;

  /// The terrain edit count the samples were taken under: the colony's own
  /// grading cuts its platforms tens or hundreds of metres into the ground
  /// after it is founded, and a height sampled before that hung the battle
  /// in the air (combat.md §7B, found live: 310 m on the Moon fixture).
  int sampledUnderEdits = -1;

  /// Operations the player has dismissed from the map (resolved ones fade
  /// on their own).
  final Set<int> hidden = {};

  /// Each assigned vessel's next pass over its battle (§7E), with the epoch
  /// second it was worked out at: UI state, recomputed at most once a game
  /// minute, never read by the sim.
  final Map<String, (double, StrikeWindow?)> windows = {};

  /// Spike S item 5's frame timings while a measurement runs (§7F), ms.
  final List<double> spikeFrames = [];
  TimingsCallback? spikeTimings;

  // ---- the soldier (§7G) ----

  /// Each running operation's frozen ground, baking or baked.
  final Map<int, BattleRaster> rasters = {};
  final Map<int, List<int>> bakeOrders = {};
  final Map<int, int> bakeNext = {};
  final Map<int, TerrainField> bakeFields = {};
  int bakesInFlight = 0;
  GroundSamplePool? pool;

  /// The battle the player has joined, if any.
  LiveBattle? live;

  /// The primary button is down on the world (the rifle's trigger).
  bool trigger = false;

  /// The smoothed (drawn − raster) offset under the walker (Spike S item 3).
  double drawnOffset = 0;

  /// Each live unit's ground as drawn, sampled once: units never move.
  final Map<String, double> unitGround = {};

  /// The colony's flat local frame for the bubble: origin, east, north.
  int frameOp = -1;
  Vector3 frameO = Vector3.zero, frameE = Vector3.unitX, frameN = Vector3.unitY;

  /// Dev only: aim at the nearest defender and hold the trigger.
  bool devAutofire = false;

  /// The cannon's blasts as smoke sites, this frame.
  List<CombatFxSite> blastSites = const [];

  /// Spike S item 4 (§7F): 48 soldiers and a full load of tracers drawn in
  /// front of the walker, to price the renderer.
  bool devStress = false;

  /// The player's eye and aim as the last step saw them (local frame), for
  /// the squad's "take the objective under the crosshair".
  (double, double, double) lastEye = (0, 0, 1.7);
  (double, double, double) lastAim = (1, 0, 0);

  // ---- the gamepad (§7K) ----

  Gamepad? pad;
  final GamepadMapper padMapper = GamepadMapper();

  /// This frame's pad: the trigger and reload it holds, read by the step.
  bool padFire = false;
  bool padReload = false;

  // ---- the command view (§7J) ----

  /// The battle the command view is over; null when it is not open.
  int? commandOp;
  final List<int> selected = [];
  final Map<int, List<int>> groups = {};
  Offset? dragFrom, dragTo;

  /// The overlay's projection and frame, this frame: what picks read.
  Offset? Function(double e, double n)? project;
  CombatFrame? lastFrame;

  /// Turn to face this objective a few frames after joining (the walker's
  /// gravity frame settles first).
  String? faceObjective;
  int faceInFrames = 0;
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
        OperationOutcome.won => switch (op.kind) {
            OperationKind.uprising => 'The rising took the Seat',
            OperationKind.raid => 'Raiders took the Seat',
            OperationKind.colonyAssault => 'Colony taken',
            OperationKind.portRetake => 'Spaceport retaken',
          },
        OperationOutcome.lost => switch (op.kind) {
            OperationKind.uprising => 'Rising crushed',
            OperationKind.raid => 'Raiders beaten off',
            OperationKind.colonyAssault => 'Assault repulsed',
            OperationKind.portRetake => 'Attack repulsed',
          },
        OperationOutcome.withdrawn => 'Withdrawn',
        OperationOutcome.ceasefire => switch (op.kind) {
            OperationKind.uprising => 'The rising melted away',
            OperationKind.raid => 'The raiders gave up',
            _ => 'Ceasefire: no decision',
          },
        OperationOutcome.rejoined => 'The colony rejoined',
        OperationOutcome.overtaken => 'Overtaken by events',
        null => '',
      };

  String _chipLine(Operation op) {
    final where = _colonyName(op.targetColonyId);
    switch (op.phase) {
      case OperationPhase.mustering:
        return 'Mustering for $where';
      case OperationPhase.transit when op.kind == OperationKind.raid:
        return 'Raiders crossing to $where';
      case OperationPhase.transit:
        final down = op.landers.where((l) => l.state == LanderState.landed).length;
        return op.landers.isEmpty
            ? 'In transit to $where'
            : (op.landers.any((l) => l.state == LanderState.descending)
                ? 'Landers descending on $where · $down of ${op.landers.length} down · warp held at 1×'
                : 'In transit to $where');
      case OperationPhase.engaged:
        final day = (op.seconds - op.engagedAtStep) / op.tuning.daySec;
        if (op.kind == OperationKind.uprising) return 'Rising at $where · day ${day.toStringAsFixed(1)}';
        if (op.kind == OperationKind.raid) return 'Raiders at $where · day ${day.toStringAsFixed(1)}';
        return _assault(op)
            ? 'Fighting for $where · day ${day.toStringAsFixed(1)}'
            : 'Fighting for $where\'s spaceport · day ${day.toStringAsFixed(1)}';
      case OperationPhase.resolved:
        final band = op.band == OutcomeBand.none ? '' : ' · ${_bandLabel(op.band)}';
        return '${_outcomeLabel(op)} at $where$band';
    }
  }

  /// The operation chips: every running operation, and results not yet seen.
  Widget? _combatChips({bool alignLeft = false}) {
    final ops = _operations.operations;
    if (ops.isEmpty) return null;
    final shown = [
      for (final op in ops)
        if (!op.resolved || !_combatState.announced.contains(op.id)) op,
    ];
    if (shown.isEmpty) return null;
    return Column(
      crossAxisAlignment: alignLeft ? CrossAxisAlignment.start : CrossAxisAlignment.end,
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
                        color: op.playerWon
                            ? AppTheme.accent2
                            : (op.resolved ? AppTheme.textDim : AppTheme.warn)),
                    const SizedBox(width: 6),
                    Text(_chipLine(op), style: AppTheme.body),
                    if (op.phase == OperationPhase.engaged) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 60,
                        child: LinearProgressIndicator(
                          // The player's hold: of the goal attacking, of the
                          // Seat defending.
                          value: op.defensive
                              ? (1 - (op.graph.byId(op.goalId)?.control ?? -1)) / 2
                              : ((op.graph.byId(op.goalId)?.control ?? -1) + 1) / 2,
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

  /// The operation to draw over the view, if any: the one against the colony
  /// in front of the camera — the open colony in city mode, otherwise any
  /// colony within 30 km of the focus — running, or resolved less than a
  /// minute of operation time ago.
  ({Operation op, CitySim city})? _battleInView(WorldSnapshot snap) {
    final focus = _focusWorldForPick(snap);
    for (final op in _operations.operations.reversed) {
      if (_combatState.hidden.contains(op.id)) continue;
      if (op.resolved && op.seconds - op.resolvedAtStep > 60) continue;
      if (op.phase == OperationPhase.mustering) continue;
      CitySim? city;
      for (final c in _cities.all()) {
        if (c.id == op.targetColonyId) city = c;
      }
      if (city == null) continue;
      if (widget.cityMode) {
        if (city.id == _editingCity?.id) return (op: op, city: city);
        continue;
      }
      final body = snap.bodies[city.body.id.value];
      if (body == null || focus == null) continue;
      final site = Vector3(body.px, body.py, body.pz) +
          Quaternion(body.qw, body.qx, body.qy, body.qz).rotate(city.localToBodyFixed(
              const Vec2(0, 0),
              bodyRadiusM: _universe.current().body(city.body.id)?.radius ?? 0));
      if ((site - focus).length < 30000) return (op: op, city: city);
    }
    return null;
  }

  /// Drops every height sample once the ground under the colonies moved.
  void _checkGroundEdits(CitySim city) {
    final body = _universe.current().body(city.body.id);
    final n = body == null ? 0 : (_terrainEdits.forBody(body.id)?.length ?? 0);
    if (n == _combatState.sampledUnderEdits) return;
    _combatState
      ..sampledUnderEdits = n
      ..groundR.clear()
      ..objectiveGround.clear();
  }

  double _battleGround(Operation op, CitySim city) => _combatState.groundR[op.id] ??= () {
        final body = _universe.current().body(city.body.id);
        if (body == null) return 0.0;
        final lat = city.cityLat * math.pi / 180.0;
        final lon = city.cityLon * math.pi / 180.0;
        final dir = Vector3(math.cos(lat) * math.cos(lon),
            math.cos(lat) * math.sin(lon), math.sin(lat));
        final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
        return field?.groundRadiusAt(dir.x, dir.y, dir.z) ?? body.radius;
      }();

  /// The ground radius under [op]'s objective [o], sampled once (at most one
  /// a frame; the colony's own until then).
  double _objectiveGround(Operation op, CitySim city, Objective o) {
    final key = '${op.id}:${o.id}';
    final have = _combatState.objectiveGround[key];
    if (have != null) return have;
    final fallback = _battleGround(op, city);
    if (_combatState.sampledThisFrame) return fallback;
    _combatState.sampledThisFrame = true;
    final body = _universe.current().body(city.body.id);
    if (body == null) return fallback;
    final dir = city.localToBodyFixed(Vec2(o.e, o.n), bodyRadiusM: body.radius).normalized;
    final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
    return _combatState.objectiveGround[key] =
        field?.groundRadiusAt(dir.x, dir.y, dir.z) ?? fallback;
  }

  /// The battle overlay over [snap], or null with no battle in view. Also
  /// tells the scene where to put the smoke ([CombatFxState]).
  Widget? _battleOverlay(WorldSnapshot? snap) {
    _combatState.sampledThisFrame = false;
    if (snap == null) {
      CombatFxState.sites = const [];
      return null;
    }
    final hit = _battleInView(snap);
    if (hit == null) {
      CombatFxState.sites = const [];
      return null;
    }
    _checkGroundEdits(hit.city);
    final frame = CombatFrame.of(hit.op);
    final grounds = [
      for (final o in hit.op.graph.objectives) (o.e, o.n, _objectiveGround(hit.op, hit.city, o)),
    ];
    // Any point stands on its nearest objective's ground: close enough for a
    // pip or an arrow, exact for a ring or the smoke.
    double groundAt(double e, double n) {
      var best = grounds.isEmpty ? _battleGround(hit.op, hit.city) : grounds.first.$3;
      var bestD = double.infinity;
      for (final g in grounds) {
        final d = (g.$1 - e) * (g.$1 - e) + (g.$2 - n) * (g.$2 - n);
        if (d < bestD) {
          bestD = d;
          best = g.$3;
        }
      }
      return best;
    }

    CombatFxState.sites = [
      for (final o in frame.objectives)
        if (o.contested)
          CombatFxSite('${hit.op.id}:${o.id}', hit.city.body.id.value,
              hit.city.localToBodyFixed(Vec2(o.e, o.n), bodyRadiusM: groundAt(o.e, o.n)), o.heat),
      ..._combatState.blastSites,
      // A strike's dust and smoke, for a while after it lands.
      for (final s in frame.strikes)
        if (!s.incoming && s.ageS < 12)
          CombatFxSite('${hit.op.id}:strike:${s.e}:${s.n}', hit.city.body.id.value,
              hit.city.localToBodyFixed(Vec2(s.e, s.n), bodyRadiusM: groundAt(s.e, s.n)),
              (1 - s.ageS / 12).clamp(0.2, 1.0)),
    ];
    final body = snap.bodies[hit.city.body.id.value];
    final focus = _focusWorldForPick(snap);
    if (body == null || focus == null) return null;
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final q = Quaternion(body.qw, body.qx, body.qy, body.qz);
    final cam = _camera;
    // A few metres up, so a ring on a slope is not under the slope.
    Vector3 rel(double e, double n) =>
        bodyWorld +
        q.rotate(hit.city.localToBodyFixed(Vec2(e, n), bodyRadiusM: groundAt(e, n) + 3)) -
        focus;
    Offset? project(double e, double n) {
      final p = cam.projectPx(rel(e, n));
      if (p == null) return null;
      return Offset(_screenW / 2 + p.x, _screenH / 2 - p.y);
    }

    double scale(double e, double n) => cam.radiusPx(rel(e, n), 1.0);
    final st = _combatState
      ..project = project
      ..lastFrame = frame;
    final from = st.dragFrom, to = st.dragTo;
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          key: Key('battle-overlay-${hit.op.id}'),
          painter: BattleOverlayPainter(
            frame: frame,
            project: project,
            scale: scale,
            timeS: _clock.epoch.seconds,
            selected: st.commandOp == hit.op.id ? st.selected : const [],
            marquee: from != null && to != null ? Rect.fromPoints(from, to) : null,
          ),
        ),
      ),
    );
  }

  /// Frames the camera on [op]'s battle: the city rig's freecam anchor,
  /// parked over the battle's centre, backed off to take all of it in — or,
  /// given an [objective], close over that one.
  void _watchBattle(Operation op, {String? objective}) {
    CitySim? city;
    for (final c in _cities.all()) {
      if (c.id == op.targetColonyId) city = c;
    }
    if (city == null) return;
    final o = objective == null ? null : op.graph.byId(objective);
    final b = o != null ? (e: o.e, n: o.n, radius: 80.0) : CombatFrame.of(op).bounds;
    _combatState.hidden.remove(op.id);
    _checkGroundEdits(city);
    // On the ground of the objective nearest the centre: the colony centre's
    // height is not the battle's (its graded platforms are cut deep).
    var near = o ?? (op.graph.objectives.isEmpty ? null : op.graph.objectives.first);
    var nearD = double.infinity;
    if (o == null) {
      for (final x in op.graph.objectives) {
        final d = (x.e - b.e) * (x.e - b.e) + (x.n - b.n) * (x.n - b.n);
        if (d < nearD) {
          nearD = d;
          near = x;
        }
      }
    }
    _combatState.sampledThisFrame = false;
    final ground = near == null ? _battleGround(op, city) : _objectiveGround(op, city, near);
    rebuild(() {
      _freecamRef = city!.body.id;
      _freecamRelLocal = city.localToBodyFixed(Vec2(b.e, b.n), bodyRadiusM: ground);
      _freecam = true;
      _craftCam = false;
      _walkMode = false;
      _upMode = CameraUpMode.gravity;
      _view = _view.copyWith(elevation: 0.9, roll: 0);
      _range = o != null ? 260.0 : (b.radius * 3.2).clamp(700.0, 8000.0);
    });
  }

  void _baseOrder(Operation op, String action,
          {ModuleKind? kind, SocketKind? ring, int? socket, int? site, String? value}) =>
      _operations.inbox.enqueue(BaseOrderCommand(const PlayerId('player'), 0, op.id, action,
          module: kind?.name, ring: ring?.name, socket: socket, site: site, value: value));

  /// The drawer's Base section (combat.md §7C): what it has, what it is
  /// building, and a button for each module an empty socket can take.
  List<Widget> _baseRows(
      Operation op, ForwardBase b, BuildContext ctx, Widget Function(String, String) line) {
    String units(int c) => (c / 100).floor().toString();
    final c = b.core;
    final status = b.overrun
        ? 'Overrun${b.spareCore ? ' · a spare core is aboard' : ''}'
        : b.lost
            ? 'Core lost with its lander${b.spareCore ? ' · a spare core is aboard' : ''}'
            : !b.deployed
                ? (b.deployAtStep < 0
                    ? 'Deploys once the squads are down'
                    : 'Deploying · ${(b.deployAtStep - op.clock.steps).clamp(0, 999)} s')
                : '${c == null ? '' : (c.outpost ? 'Spare core (outpost-sized)' : tierSpec(c.tier).label)}'
                    ' · ${b.modules.length} built';
    final rows = <Widget>[
      const SizedBox(height: 10),
      Text('Forward base', style: AppTheme.dim),
      line('Status', status),
      if (b.deployed && b.standing) ...[
        line('Materiel', '${units(b.materielC)} (+${(b.unpackC / 100).toStringAsFixed(1)}/s) · '
            '${units(b.palletsC)} on pallets'),
        line('Power', '${b.powerDemand.round()}/${b.powerSupply.round()} kW'),
        line('Personnel', '${b.crewAssigned} crew · ${b.reserve} spare · '
            '${b.supportDead} dead · ${b.supportWounded} wounded'),
        line('Stock', 'rations ${units(b.stockOf('rations'))} · ammo ${units(b.stockOf('ammo'))} · '
            'guns ${units(b.stockOf('guns'))} · fuel ${units(b.stockOf('fuel'))} · '
            'medicine ${units(b.stockOf('medicine'))} · steel ${units(b.stockOf('steel'))}'),
        if (b.recoveredTotal > 0) line('Recovered wounded', '${b.recoveredTotal} waiting for the pod'),
        Wrap(spacing: 6, children: [
          for (final d in Doctrine.values)
            ChoiceChip(
              key: Key('base-doctrine-${d.name}'),
              label: Text(doctrineLabel(d)),
              selected: b.doctrine == d,
              onSelected: (_) {
                _baseOrder(op, 'doctrine', value: d.name);
                Navigator.of(ctx).maybePop();
              },
            ),
        ]),
        line('Next supply run',
            b.runs.any((r) => r.arriveStep >= 0) ? 'landing soon' : 'in ${(b.nextRunStep - op.clock.steps).clamp(0, 99999)} s'),
        for (var si = 0; si < b.sites.length; si++)
          if (!b.sites[si].razed) ...[
            if (si > 0 || b.sites[si].outpost)
              Text('  ${b.sites[si].outpost ? 'Outpost beside the ${b.sites[si].objectiveId}' : 'Core'}',
                  style: AppTheme.dim),
            for (var li = 0; li < b.sites[si].lines.length; li++)
              if (b.sites[si].lines[li] case final j?)
                Row(children: [
                  Expanded(
                      child: Text('  Line ${li + 1}: ${j.label} · ${j.remainingS} s',
                          style: AppTheme.body)),
                  TextButton(
                    key: Key('base-cancel-$si-$li'),
                    onPressed: () {
                      _baseOrder(op, 'cancel', site: si, socket: li);
                      Navigator.of(ctx).maybePop();
                    },
                    child: const Text('Cancel (half back)'),
                  ),
                ]),
            for (final ring in SocketKind.values)
              for (var i = 0; i < b.sites[si].socketsOf(ring); i++) _socketRow(op, b, ring, i, ctx, site: si),
          ],
        if (c != null && !c.outpost && c.tier != BaseTier.fortress)
          Builder(builder: (_) {
            final next = BaseTier.values[c.tier.index + 1];
            final t = tierSpec(next);
            final why = b.whyNotUpgrade(next);
            return Tooltip(
              message: why ?? '${t.materiel} Materiel${t.steel > 0 ? ' + ${t.steel} steel' : ''} · ${t.buildS} s',
              child: TextButton(
                key: const Key('base-upgrade'),
                onPressed: why == null
                    ? () {
                        _baseOrder(op, 'upgrade', value: next.name);
                        Navigator.of(ctx).maybePop();
                      }
                    : null,
                child: Text('Upgrade to ${t.label} (${t.materiel})'),
              ),
            );
          }),
        Wrap(spacing: 4, children: [
          for (final o in op.graph.objectives)
            if (o.kind != ObjectiveKind.lz && b.whyNotOutpost(op, o.id) == null)
              TextButton(
                key: Key('base-outpost-${o.id}'),
                onPressed: () {
                  _baseOrder(op, 'outpost', value: o.id);
                  Navigator.of(ctx).maybePop();
                },
                child: Text('Open an outpost beside the ${o.id} ($kOutpostMateriel)'),
              ),
        ]),
        if (b.podOnline)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('base-form-squad'),
              onPressed: b.reserve > 0 && b.stockOf('guns') >= 100
                  ? () {
                      _baseOrder(op, 'formSquad');
                      Navigator.of(ctx).maybePop();
                    }
                  : null,
              child: Text('Form a squad from the spare (${b.reserve})'),
            ),
          ),
      ],
    ];
    return rows;
  }

  /// What a squad line calls [f]: a turret's crew are not an emplacement.
  static String _kindLabel(Formation f) => switch (f.kind) {
        FormationKind.infantry => 'troopers',
        FormationKind.regular => 'regulars',
        FormationKind.militia => 'militia',
        FormationKind.emplacement => f.side == CombatSide.attacker ? 'turret crew' : 'gun emplacement',
        FormationKind.armour => 'APC crew',
        FormationKind.air => 'gunship',
      };

  Widget _socketRow(Operation op, ForwardBase b, SocketKind ring, int i, BuildContext ctx,
      {int site = 0}) {
    final s = b.sites[site];
    BaseModule? here;
    for (final m in s.modules) {
      if (m.spec.socket == ring && m.socket == i) here = m;
    }
    final label = ForwardBase.socketLabel(ring, i);
    if (here != null) {
      return Row(children: [
        Expanded(
            child: Text('  $label: ${here.spec.label}${here.crewed ? '' : ' (no crew)'}',
                style: AppTheme.body)),
        if (!(site == 0 && ring == SocketKind.turret && i == 0))
          TextButton(
            key: Key('base-demolish-$site-${ring.name}-$i'),
            onPressed: () {
              _baseOrder(op, 'demolish', ring: ring, socket: i, site: site);
              Navigator.of(ctx).maybePop();
            },
            child: const Text('Demolish'),
          ),
      ]);
    }
    if (s.lines.any((j) => j != null && j.kind != null && j.socket == i && moduleSpec(j.kind!).socket == ring)) {
      return Text('  $label: building', style: AppTheme.dim);
    }
    if (s.blocked(ring, i)) return Text('  $label: no room (a building stands there)', style: AppTheme.dim);
    final options = [
      for (final s in kBaseModules)
        if (s.socket == ring) s,
    ];
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
      Text('  $label: empty', style: AppTheme.dim),
      for (final s in options)
        Tooltip(
          message: b.whyNot(s.kind, i, site: site) ??
              '${s.materiel} Materiel${s.steel > 0 ? ' + ${s.steel} steel' : ''} · ${s.buildS} s · '
                  '${s.crew} crew · ${s.powerKw < 0 ? '+${-s.powerKw.round()}' : s.powerKw.round()} kW',
          child: TextButton(
            key: Key('base-build-$site-${s.kind.name}-$i'),
            onPressed: b.whyNot(s.kind, i, site: site) == null
                ? () {
                    _baseOrder(op, 'build', kind: s.kind, ring: ring, socket: i, site: site);
                    Navigator.of(ctx).maybePop();
                  }
                : null,
            child: Text('${s.label} (${s.materiel})'),
          ),
        ),
    ]);
  }

  void _order(Operation op, String order, {String? target}) => _operations.inbox.enqueue(
      OrderOperationCommand(const PlayerId('player'), 0, op.id, order, target: target));

  void _power(Operation op, String power, {String? target}) => _operations.inbox.enqueue(
      CommanderPowerCommand(const PlayerId('player'), 0, op.id, power, target: target));

  /// Spike S items 1 and 3 (§7F) over the battle square: the cost of the
  /// raster's per-cell query (`surfaceRadiusAt`), the share of cells under a
  /// brush, and the drawn mesh against the field on 200 points.
  Map<String, Object?> _spikeGround(CitySim city) {
    final body = _universe.current().body(city.body.id);
    if (body == null) return {'error': 'no body'};
    final edits = _terrainEdits.forBody(body.id);
    final field = body.terrainFieldWith(edits);
    if (field == null) return {'error': 'no terrain field'};
    final op = _operations.runningAgainst(city.id);
    final b = op == null ? null : CombatFrame.of(op).bounds;
    final ce = b?.e ?? 0, cn = b?.n ?? 0;
    const side = 1200.0, cell = 8.0;
    const n = 150;
    Vector3 dirAt(double e, double nn) =>
        city.localToBodyFixed(Vec2(e, nn), bodyRadiusM: body.radius).normalized;
    // Item 1: every 5th cell each way (900 of the 22,500), timed one by one.
    final costs = <double>[];
    var brushed = 0, cells = 0;
    final sw = Stopwatch();
    for (var i = 0; i < n; i += 5) {
      for (var j = 0; j < n; j += 5) {
        final d = dirAt(ce - side / 2 + (i + 0.5) * cell, cn - side / 2 + (j + 0.5) * cell);
        cells++;
        if (edits != null && edits.at(d).isNotEmpty) brushed++;
        sw
          ..reset()
          ..start();
        field.surfaceRadiusAt(d.x, d.y, d.z);
        sw.stop();
        costs.add(sw.elapsedMicroseconds / 1000);
      }
    }
    costs.sort();
    final mean = costs.fold(0.0, (a, v) => a + v) / costs.length;
    // Item 3: the drawn mesh against the field, 200 points on a 15 × 14 grid.
    final errs = <double>[];
    var noMesh = 0;
    final drawn = SceneSync.drawnGround;
    for (var i = 0; i < 15; i++) {
      for (var j = 0; j < 14 && errs.length + noMesh < 200; j++) {
        final d = dirAt(ce - side / 2 + (i + 0.5) * side / 15, cn - side / 2 + (j + 0.5) * side / 14);
        final m = drawn?.call(d);
        if (m == null) {
          noMesh++;
          continue;
        }
        errs.add((m - field.surfaceRadiusAt(d.x, d.y, d.z)).abs());
      }
    }
    errs.sort();
    double q(List<double> v, double k) => v.isEmpty ? double.nan : v[((v.length - 1) * k).round()];
    return {
      'centre': [ce.round(), cn.round()],
      'item1': {
        'cellsTimed': cells,
        'brushedShare': brushed / cells,
        'meanMs': mean,
        'p95Ms': q(costs, 0.95),
        'bakeSingleThreadS': mean * 22500 / 1000,
        'bake4WorkersS': mean * 22500 / 1000 / 4,
      },
      'item3terrain': {'points': errs.length, 'noMesh': noMesh, 'p50M': q(errs, 0.5), 'p95M': q(errs, 0.95)},
    };
  }

  // ---- the soldier (§7G) --------------------------------------------------------

  CitySim? _cityById(String id) {
    for (final c in _cities.all()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Bakes every running operation's battle raster on the ground-sample pool,
  /// objectives first, three jobs of 500 cells in flight at most. Called each
  /// frame; costs the main thread only the directions it packs.
  void _pumpRasterBake() {
    final st = _combatState;
    for (final op in _operations.operations) {
      if (op.resolved) continue;
      final city = _cityById(op.targetColonyId);
      if (city == null) continue;
      var r = st.rasters[op.id];
      if (r == null) {
        final lz = op.graph.byId(op.lzId), goal = op.graph.byId(op.goalId);
        if (lz == null || goal == null) continue;
        final (ce, cn) = BattleRaster.centreFor(lz.e, lz.n, goal.e, goal.n);
        r = st.rasters[op.id] = BattleRaster(ce, cn);
        st.bakeOrders[op.id] = r.bakeOrder([for (final o in op.graph.objectives) (o.e, o.n)]);
        st.bakeNext[op.id] = 0;
      }
      final body = _universe.current().body(city.body.id);
      if (body == null) continue;
      final order = st.bakeOrders[op.id]!;
      final raster = r;
      if (st.bakeFields[op.id] == null) {
        final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
        if (field == null) {
          // A body with no relief: the ground is its sphere.
          for (var k = 0; k < raster.radii.length; k++) {
            raster.put(k, body.radius);
          }
          st.bakeNext[op.id] = order.length;
          continue;
        }
        st.bakeFields[op.id] = field;
      }
      while (st.bakesInFlight < 3 && st.bakeNext[op.id]! < order.length) {
        final field = st.bakeFields[op.id]!;
        final from = st.bakeNext[op.id]!;
        final batch = order.sublist(from, math.min(from + 500, order.length));
        st.bakeNext[op.id] = from + batch.length;
        final dirs = Float64List(batch.length * 3);
        for (var i = 0; i < batch.length; i++) {
          final (e, n) = raster.cellCentre(batch[i]);
          final bf = city.localToBodyFixed(Vec2(e, n), bodyRadiusM: body.radius);
          dirs[3 * i] = bf.x;
          dirs[3 * i + 1] = bf.y;
          dirs[3 * i + 2] = bf.z;
        }
        st.bakesInFlight++;
        (st.pool ??= GroundSamplePool.platform()).sample(field, dirs).then((radii) {
          for (var i = 0; i < batch.length; i++) {
            raster.put(batch[i], radii[i]);
          }
        }).whenComplete(() => st.bakesInFlight--);
      }
    }
  }

  BattleRaster? _rasterFor(Operation op) {
    final r = _combatState.rasters[op.id];
    return r != null && r.complete ? r : null;
  }

  /// Why the player cannot join [op] now, or null.
  String? _whyNotJoin(Operation op) {
    if (op.defensive) return 'Defensive fights are fought from the map.';
    if (op.resolved || op.phase != OperationPhase.engaged) return 'Not until the squads are down.';
    final r = _combatState.rasters[op.id];
    if (r == null || !r.complete) return 'Mapping the ground: ${((r?.progress ?? 0) * 100).round()}%';
    if (_squadAtLz(op) == null) return 'No squad of yours is left to join.';
    return null;
  }

  /// The squad the player fights as one of: [prefer] while it has anyone
  /// left, else the first of the operation's living infantry. Wherever it
  /// is, the player steps out at the LZ.
  Formation? _squadAtLz(Operation op, {int? prefer}) {
    Formation? best;
    for (final f in op.formations) {
      // A trooper's squad: not a turret's crew, not an APC's.
      if (f.side != CombatSide.attacker || f.kind == FormationKind.emplacement || f.kind == FormationKind.armour) {
        continue;
      }
      if (!f.alive || f.at == FormationAt.transit) continue;
      if (f.id == prefer) return f;
      best ??= f;
    }
    return best;
  }

  /// Turns the walker's head toward [objectiveId] (a coarse search over the
  /// look angles, then left level).
  void _faceToward(Operation op, CitySim city, String objectiveId) {
    final o = op.graph.byId(objectiveId);
    final body = _universe.current().body(city.body.id);
    if (o == null || body == null) return;
    final at = city.localToBodyFixed(Vec2(o.e, o.n), bodyRadiusM: _freecamRelLocal.length);
    final want = _refBodyQuat().rotate((at - _freecamRelLocal).normalized);
    var best = _view;
    var score = -2.0;
    for (var a = 0; a < 72; a++) {
      for (var el = -3; el <= 3; el++) {
        _view = _view.copyWith(azimuth: a * math.pi / 36, elevation: el * 0.1);
        final s = _camera.forward.dot(want);
        if (s > score) {
          score = s;
          best = _view;
        }
      }
    }
    rebuild(() => _view = best);
  }

  void _localFrame(Operation op, CitySim city, double radius) {
    final st = _combatState;
    if (st.frameOp == op.id) return;
    st.frameOp = op.id;
    st.frameO = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: radius);
    st.frameE = (city.localToBodyFixed(const Vec2(100, 0), bodyRadiusM: radius) - st.frameO).normalized;
    st.frameN = (city.localToBodyFixed(const Vec2(0, 100), bodyRadiusM: radius) - st.frameO).normalized;
  }

  /// Body-fixed point [e], [n], [h] metres above the battle's ground.
  Vector3 _liveBF(CitySim city, BattleRaster r, double radius, double e, double n, double h) =>
      city.localToBodyFixed(Vec2(e, n), bodyRadiusM: (r.radiusAt(e, n) ?? radius) + h);

  /// Puts the walker at the LZ, on the battle's ground.
  void _standAtLz(Operation op, CitySim city, BattleRaster r, double radius) {
    final lz = op.graph.byId(op.lzId)!;
    final e = lz.e - 12, n = lz.n - 6;
    final dir = city.localToBodyFixed(Vec2(e, n), bodyRadiusM: radius).normalized;
    _freecamRelLocal = dir * ((r.radiusAt(e, n) ?? radius) + walkEyeHeight);
    _walkVertVel = 0;
    _walkGrounded = true;
  }

  /// Joins [op] as a trooper of its first squad at the LZ (§7G) — or, from
  /// the command view, of [squadId] where it stands (§7J).
  void _joinFight(Operation op, {int? squadId}) {
    final city = _cityById(op.targetColonyId);
    final r = _rasterFor(op);
    final squad = _squadAtLz(op, prefer: squadId);
    final body = city == null ? null : _universe.current().body(city.body.id);
    if (city == null || r == null || squad == null || body == null) return;
    final st = _combatState
      ..live = (LiveBattle(opId: op.id, seed: op.seed ^ 0x5eed, playerFormationId: squad.id)
        ..nav = NavGrid(r, op.orbital.walls))
      ..unitGround.clear()
      ..drawnOffset = 0
      ..trigger = false;
    st
      ..frameOp = -1
      ..faceObjective = op.goalId
      ..faceInFrames = 5;
    rebuild(() {
      _freecamRef = city.body.id;
      _freecam = true;
      _craftCam = false;
      _standAtLz(op, city, r, body.radius);
    });
    if (!_walkMode) _toggleWalk();
    _thirdPerson = false;
    _standAtLz(op, city, r, body.radius);
    // Possessed from the command view: where the squad stands, if it stands
    // on the battle's ground.
    final mark = st.lastFrame?.squads.where((s) => s.id == squad.id).firstOrNull;
    if (squadId != null && mark != null && r.contains(mark.e, mark.n)) {
      final dir = city.localToBodyFixed(Vec2(mark.e - 4, mark.n - 4), bodyRadiusM: body.radius).normalized;
      _freecamRelLocal = dir * ((r.radiusAt(mark.e - 4, mark.n - 4) ?? body.radius) + walkEyeHeight);
    }
    st.commandOp = null;
    // Your squad is the bubble's while you fight with it (§7H).
    _operations.inbox.enqueue(LiveSquadCommand(const PlayerId('player'), 0, op.id, squad.id));
  }

  /// Follows the lead troop lander still coming down (§7M): the chase
  /// camera on it; M takes manual control as for any vessel.
  void _rideLander(Operation op) {
    final l = op.landers.where((l) => l.state == LanderState.descending).firstOrNull;
    if (l == null) return;
    final v = _vessels.byId(VesselId(l.vesselId));
    if (v == null) return;
    rebuild(() {
      if (_walkMode) _toggleWalk();
      _freecam = false;
      _focusVessel = v.id;
      _focusBody = null;
      _craftCam = true;
    });
  }

  /// F: into the nearest of your APCs within reach, or out of the one you
  /// drive (§7L).
  void _boardOrAlight() {
    final st = _combatState;
    final live = st.live;
    final op = live == null ? null : _operations.byId(live.opId);
    final city = op == null ? null : _cityById(op.targetColonyId);
    final r = op == null ? null : _rasterFor(op);
    final body = city == null ? null : _universe.current().body(city.body.id);
    if (live == null || city == null || r == null || body == null) return;
    if (live.driving != null) {
      final at = live.alight();
      if (at != null) {
        final dir = city.localToBodyFixed(Vec2(at.$1, at.$2), bodyRadiusM: body.radius).normalized;
        _freecamRelLocal = dir * ((r.radiusAt(at.$1, at.$2) ?? body.radius) + walkEyeHeight);
      }
      return;
    }
    live.board(st.lastEye.$1, st.lastEye.$2);
  }

  /// A squad order from the number keys (§7H): 1 follow, 2 hold, 3 take the
  /// objective nearest the crosshair's line.
  void _squadOrder(SquadOrder o) {
    final live = _combatState.live;
    final op = live == null ? null : _operations.byId(live.opId);
    if (live == null || op == null) return;
    if (o != SquadOrder.attack) {
      live.command(o);
      return;
    }
    final (ee, en, _) = _combatState.lastEye;
    final (ae, an, _) = _combatState.lastAim;
    final al = math.max(1e-6, math.sqrt(ae * ae + an * an));
    String? best;
    var bestCos = 0.9;
    for (final ob in op.graph.objectives) {
      if (ob.kind == ObjectiveKind.lz) continue;
      final de = ob.e - ee, dn = ob.n - en;
      final dl = math.sqrt(de * de + dn * dn);
      if (dl < 1 || dl > 1200) continue;
      final c = (de * ae + dn * an) / (dl * al);
      if (c > bestCos) {
        bestCos = c;
        best = ob.id;
      }
    }
    if (best != null) live.command(SquadOrder.attack, objectiveId: best);
  }

  /// X: every ready trooper in as reinforcements (§7H).
  void _callReinforcements() {
    final live = _combatState.live;
    final op = live == null ? null : _operations.byId(live.opId);
    if (op == null) return;
    final draws = _readyDraws(op.targetColonyId);
    if (draws.isEmpty) return;
    _operations.inbox.enqueue(ReinforceOperationCommand(const PlayerId('player'), 0, op.id,
        draws: draws, kitDays: op.kind == OperationKind.colonyAssault ? 6 : 3));
  }

  void _leaveFight() {
    final st = _combatState;
    if (st.live == null) return;
    final left = st.live!.casualties;
    if (left.isNotEmpty) {
      _operations.inbox.enqueue(LiveCasualtiesCommand(const PlayerId('player'), 0, st.live!.opId, [...left]));
    }
    _operations.inbox.enqueue(LiveSquadCommand(
        const PlayerId('player'), 0, st.live!.opId, st.live!.playerFormationId,
        own: false));
    st
      ..live = null
      ..trigger = false
      ..devAutofire = false;
    CombatUnitState.clear();
    if (_walkMode) _toggleWalk();
  }

  bool get _liveJoined => _combatState.live != null;
  bool get _liveDead => _combatState.live?.dead ?? false;

  /// The walker's ground while joined: the raster plus the smoothed drawn
  /// offset (Spike S item 3) — never a field sample. Null when not joined or
  /// off the raster.
  double? _liveGround(Vector3 posBF) {
    final live = _combatState.live;
    if (live == null) return null;
    final op = _operations.byId(live.opId);
    final city = op == null ? null : _cityById(op.targetColonyId);
    final r = op == null ? null : _rasterFor(op);
    if (city == null || r == null) return null;
    final st = _combatState;
    final d = posBF - st.frameO;
    final g = r.radiusAt(d.dot(st.frameE), d.dot(st.frameN));
    return g == null ? null : g + st.drawnOffset;
  }

  /// One frame of the joined battle: the bubble mirrors the operation, the
  /// rifle and the defence fire, casualties go to the battle as a command, a
  /// fallen player redeploys, and the units and tracers go to the scene.
  void _stepLive(double frameDt) {
    _pumpRasterBake();
    final st = _combatState;
    final live = st.live;
    if (live == null) return;
    final op = _operations.byId(live.opId);
    final city = op == null ? null : _cityById(op.targetColonyId);
    final body = city == null ? null : _universe.current().body(city.body.id);
    final r = op == null ? null : _rasterFor(op);
    if (op == null || op.resolved || city == null || body == null || r == null || !_walkMode) {
      _leaveFight();
      return;
    }
    _localFrame(op, city, body.radius);
    // Driving: the keys drive the APC and the eye rides its turret (§7L).
    final car = live.driving;
    if (car != null) {
      double key(LogicalKeyboardKey k) => _keysDown.contains(k) ? 1.0 : 0.0;
      live.drive(frameDt.clamp(0.0, 0.1), key(LogicalKeyboardKey.keyW) - key(LogicalKeyboardKey.keyS),
          key(LogicalKeyboardKey.keyA) - key(LogicalKeyboardKey.keyD));
      final dir = city.localToBodyFixed(Vec2(car.e, car.n), bodyRadiusM: body.radius).normalized;
      _freecamRelLocal = dir * ((r.radiusAt(car.e, car.n) ?? body.radius) + 2.8);
      _walkVertVel = 0;
      _walkGrounded = true;
    }
    if (st.faceObjective != null && --st.faceInFrames <= 0) {
      _faceToward(op, city, st.faceObjective!);
      st.faceObjective = null;
    }
    final p = _freecamRelLocal;
    final d = p - st.frameO;
    final e = d.dot(st.frameE), n = d.dot(st.frameN);
    final ground = r.radiusAt(e, n);
    // The drawn mesh under the walker, eased toward (Spike S item 3).
    final drawn = SceneSync.drawnGround?.call(p.normalized);
    if (drawn != null && ground != null) {
      final k = (frameDt * 4).clamp(0.0, 1.0);
      st.drawnOffset += ((drawn - ground).clamp(-2.0, 2.0) - st.drawnOffset) * k;
    }
    final h = p.length - (ground ?? p.length - walkEyeHeight) - st.drawnOffset;
    final up = p.normalized;
    final f = _refBodyQuat().conjugate.rotate(_camera.forward);
    var aim = (f.dot(st.frameE), f.dot(st.frameN), f.dot(up));
    var trigger = (st.trigger && _pointerLock.captured) || st.padFire;
    live.sync(op, r, e, n);
    if (st.devAutofire) {
      LiveUnit? best;
      var bd = double.infinity;
      for (final u in live.units) {
        if (u.side != CombatSide.defender) continue;
        final dd = (u.e - e) * (u.e - e) + (u.n - n) * (u.n - n);
        if (dd < bd) {
          bd = dd;
          best = u;
        }
      }
      if (best != null) {
        final de = best.e - e, dn = best.n - n, dh = 1.0 - h;
        final l = math.sqrt(de * de + dn * dn + dh * dh);
        aim = (de / l, dn / l, dh / l);
        trigger = true;
      }
    }
    st
      ..lastEye = (e, n, h)
      ..lastAim = aim;
    if (live.driving != null && trigger) {
      live.fireCannon(aim);
      trigger = false;
    }
    live.step(frameDt.clamp(0.0, 0.1),
        eye: (e, n, h),
        aim: aim,
        trigger: trigger,
        reload: _keysDown.contains(LogicalKeyboardKey.keyR) || st.padReload);
    if (live.squadArrived case final at?) {
      _operations.inbox.enqueue(
          LiveSquadCommand(const PlayerId('player'), 0, op.id, live.playerFormationId, at: at));
      live.squadArrived = null;
    }
    if (live.casualties.isNotEmpty) {
      _operations.inbox.enqueue(LiveCasualtiesCommand(const PlayerId('player'), 0, op.id, [...live.casualties]));
      live.casualties.clear();
    }
    if (live.redeployReady) {
      final next = _squadAtLz(op, prefer: live.playerFormationId);
      if (next == null) {
        _leaveFight();
        return;
      }
      if (next.id != live.playerFormationId) {
        _operations.inbox.enqueue(LiveSquadCommand(const PlayerId('player'), 0, op.id, live.playerFormationId,
            own: false));
        _operations.inbox.enqueue(LiveSquadCommand(const PlayerId('player'), 0, op.id, next.id));
      }
      live.redeploy(next.id);
      _standAtLz(op, city, r, body.radius);
    }
    final bodyId = city.body.id.value;
    CombatUnitState.units = [
      for (final u in live.units)
        CombatUnitMark(
          '${u.formationId}:${u.member}',
          bodyId,
          // On the battle's ground (a far unit's drawn mesh is a coarser
          // chunk than the one the offset was measured on).
          _liveBF(city, r, body.radius, u.e, u.n, 0),
          attacker: u.side == CombatSide.attacker,
          emplacement: u.kind == FormationKind.emplacement,
          moving: (u.te - u.e).abs() + (u.tn - u.n).abs() > 0.3 || u.formationId == live.drivingFormation,
          vehicleForwardBF: u.vehicle ? st.frameE * math.cos(u.heading) + st.frameN * math.sin(u.heading) : null,
        ),
    ];
    CombatUnitState.tracers = [
      for (final t in live.tracers)
        CombatTracerMark(bodyId, _liveBF(city, r, body.radius, t.fromE, t.fromN, t.fromH + st.drawnOffset),
            _liveBF(city, r, body.radius, t.toE, t.toN, t.toH + st.drawnOffset),
            attacker: t.side == CombatSide.attacker),
      for (final c in live.rounds)
        CombatTracerMark(bodyId, _liveBF(city, r, body.radius, c.e - c.de * 6, c.n - c.dn * 6, c.h - c.dh * 6),
            _liveBF(city, r, body.radius, c.e, c.n, c.h),
            attacker: c.side == CombatSide.attacker),
    ];
    st.blastSites = [
      for (final b in live.blasts)
        CombatFxSite('blast:${b.$1.round()}:${b.$2.round()}', bodyId, _liveBF(city, r, body.radius, b.$1, b.$2, 0),
            (1 - b.$3 / 1.2).clamp(0.3, 1.0)),
    ];
    if (st.devStress) {
      // Ahead of the walker along its heading: a 6 × 8 block 15–50 m out.
      final fe = aim.$1, fn = aim.$2;
      final fl = math.max(1e-6, math.sqrt(fe * fe + fn * fn));
      final ue = fe / fl, un = fn / fl;
      (double, double) at(double fwd, double side) => (e + ue * fwd - un * side, n + un * fwd + ue * side);
      CombatUnitState.units = [
        ...CombatUnitState.units,
        for (var i = 0; i < 48; i++)
          () {
            final (pe, pn) = at(15 + 5.0 * (i ~/ 6), -12.5 + 5.0 * (i % 6));
            return CombatUnitMark('stress:$i', bodyId, _liveBF(city, r, body.radius, pe, pn, st.drawnOffset),
                attacker: i.isEven);
          }(),
      ];
      final tick = (_clock.epoch.seconds * 10).floor();
      CombatUnitState.tracers = [
        for (var i = 0; i < CombatUnitNodes.maxTracers; i++)
          () {
            final (ae, an) = at(15 + 5.0 * (i % 8), -12.5 + 3.0 * ((i + tick) % 9));
            final (be, bn) = at(60 + 5.0 * (i % 5), 12.0 - 3.0 * ((i * 7 + tick) % 9));
            return CombatTracerMark(bodyId, _liveBF(city, r, body.radius, ae, an, 1.4 + st.drawnOffset),
                _liveBF(city, r, body.radius, be, bn, 1.2 + st.drawnOffset),
                attacker: i.isEven);
          }(),
      ];
    }
  }

  /// The soldier's HUD: crosshair, health, ammo, and the death screen.
  Widget? _liveHud() {
    final live = _combatState.live;
    if (live == null) return null;
    final op = _operations.byId(live.opId);
    final squad = op?.formationById(live.playerFormationId);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(children: [
          if (!live.dead)
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(BorderSide(color: Colors.white70, width: 1.5)),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 16,
            bottom: 96,
            child: Container(
              key: const Key('live-hud'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.panel.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Health ${live.hp.clamp(0, 100).round()}', style: AppTheme.body),
                const SizedBox(height: 4),
                SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(
                    value: (live.hp / 100).clamp(0.0, 1.0),
                    minHeight: 6,
                    color: live.hp > 40 ? AppTheme.accent2 : AppTheme.warn,
                    backgroundColor: AppTheme.panelLight,
                  ),
                ),
                const SizedBox(height: 6),
                if (live.driving case final car?)
                  Text('Driving the APC · hull ${car.hp.round()} · F steps out', style: AppTheme.mono)
                else
                  Text(live.reloadS > 0 ? 'Reloading…' : 'Rifle ${live.magazine} / $kRifleMagazine',
                      style: AppTheme.mono),
                Text('${live.kills} down · ${squad == null ? '' : '${squad.count} in your squad'}',
                    style: AppTheme.dim),
                Text(
                    'Squad: ${switch (live.order) {
                      SquadOrder.follow => 'following you',
                      SquadOrder.hold => 'holding',
                      SquadOrder.attack => 'taking the ${live.attackTarget ?? ''}',
                    }}',
                    style: AppTheme.body),
                Text('LMB fire · R reload · 1 follow · 2 hold · 3 take · X reinforce · L leave',
                    style: AppTheme.dim),
              ]),
            ),
          ),
          if (live.dead)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                color: Colors.black54,
                child: Text('You are down · redeploying at the LZ in ${live.deadS.ceil()} s',
                    style: AppTheme.heading.copyWith(color: AppTheme.warn)),
              ),
            ),
        ]),
      ),
    );
  }

  // ---- the gamepad (§7K) --------------------------------------------------------

  /// One frame of the pad, if one is connected and a battle wants it: the
  /// walk and look it adds (returned for the frame loop), and its buttons as
  /// the keys they stand for. Halo Wars' layout where the battle has one.
  ({double fwd, double strafe}) _padStep(double frameDt) {
    final st = _combatState;
    st
      ..padFire = false
      ..padReload = false;
    if (!_liveJoined && !_commanding) return (fwd: 0, strafe: 0);
    final s = (st.pad ??= Gamepad.platform()).read();
    if (s == null) return (fwd: 0, strafe: 0);
    final f = st.padMapper.map(s, frameDt);
    if (f.lookYaw != 0 || f.lookPitch != 0) _orbitCamera(f.lookYaw, f.lookPitch);
    if (f.tapped(PadButton.back)) _tabCommand();
    if (_liveJoined) {
      st
        ..padFire = f.fire
        ..padReload = f.tapped(PadButton.x);
      if (f.tapped(PadButton.dpadUp)) _squadOrder(SquadOrder.follow);
      if (f.tapped(PadButton.dpadLeft)) _squadOrder(SquadOrder.hold);
      if (f.tapped(PadButton.dpadRight)) _squadOrder(SquadOrder.attack);
      if (f.tapped(PadButton.y)) _callReinforcements();
      if (f.tapped(PadButton.b)) _leaveFight();
    } else if (_commanding) {
      final op = _commandOpNow();
      if (op != null && f.tapped(PadButton.y)) {
        rebuild(() => st.selected
          ..clear()
          ..addAll(_orderable(op)));
      }
      if (f.tapped(PadButton.a)) _tabCommand();
      if (f.tapped(PadButton.dpadLeft)) _orderSelected(Operation.holdHere);
      if (f.tapped(PadButton.dpadDown)) _orderSelected(null);
      if (f.tapped(PadButton.b)) _exitCommand();
    }
    return (fwd: f.moveForward, strafe: f.moveRight);
  }

  // ---- the command view (§7J) ---------------------------------------------------

  bool get _commanding => _combatState.commandOp != null;

  Operation? _commandOpNow() {
    final id = _combatState.commandOp;
    final op = id == null ? null : _operations.byId(id);
    return op == null || op.resolved ? null : op;
  }

  /// Opens the command view over [op] (leaving the fight if joined).
  void _enterCommand(Operation op) {
    if (_liveJoined) _leaveFight();
    final st = _combatState
      ..commandOp = op.id
      ..dragFrom = null
      ..dragTo = null;
    st.selected.clear();
    _watchBattle(op);
  }

  void _exitCommand() {
    final st = _combatState
      ..commandOp = null
      ..dragFrom = null
      ..dragTo = null;
    st.selected.clear();
    rebuild(() {});
  }

  /// Tab: the soldier to the command view, the view to the one squad
  /// selected (possession), or out.
  void _tabCommand() {
    final st = _combatState;
    if (!_commanding) {
      final op = _liveJoined
          ? _operations.byId(st.live!.opId)
          : _operations.operations.where((o) => !o.resolved && o.phase == OperationPhase.engaged).firstOrNull;
      if (op != null) _enterCommand(op);
      return;
    }
    final op = _commandOpNow();
    if (op == null) {
      _exitCommand();
      return;
    }
    if (st.selected.length == 1 && _whyNotJoin(op) == null) {
      _joinFight(op, squadId: st.selected.single);
      return;
    }
    _exitCommand();
  }

  /// The player's squads that can take an order.
  List<int> _orderable(Operation op) => [
        for (final f in op.formations)
          if (f.side == CombatSide.attacker && f.kind != FormationKind.emplacement && f.alive) f.id
      ];

  void _orderSelected(String? target) {
    final op = _commandOpNow();
    final st = _combatState;
    if (op == null || st.selected.isEmpty) return;
    _operations.inbox.enqueue(SquadOrderCommand(const PlayerId('player'), 0, op.id, [...st.selected], target));
  }

  /// A command-view key, or null when the view is not open or the key is not
  /// one of its own.
  KeyEventResult? _commandKey(KeyEvent e) {
    if (e is! KeyDownEvent) return null;
    if (e.logicalKey == LogicalKeyboardKey.tab) {
      _tabCommand();
      return KeyEventResult.handled;
    }
    final op = _commandOpNow();
    if (op == null) return null;
    final st = _combatState;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final digit = switch (e.logicalKey) {
      LogicalKeyboardKey.digit1 => 1,
      LogicalKeyboardKey.digit2 => 2,
      LogicalKeyboardKey.digit3 => 3,
      LogicalKeyboardKey.digit4 => 4,
      _ => null,
    };
    if (digit != null) {
      rebuild(() {
        if (ctrl) {
          st.groups[digit] = [...st.selected];
        } else {
          st.selected
            ..clear()
            ..addAll([for (final id in st.groups[digit] ?? const <int>[]) if (_orderable(op).contains(id)) id]);
        }
      });
      return KeyEventResult.handled;
    }
    switch (e.logicalKey) {
      case LogicalKeyboardKey.escape:
        _exitCommand();
      case LogicalKeyboardKey.keyY:
        rebuild(() => st.selected
          ..clear()
          ..addAll(_orderable(op)));
      case LogicalKeyboardKey.keyH:
        _orderSelected(Operation.holdHere);
      case LogicalKeyboardKey.keyP:
        _orderSelected(null);
      default:
        return null;
    }
    return KeyEventResult.handled;
  }

  /// A press on the world in the command view: the left button starts a
  /// box (or a click), the right orders the selection to the objective
  /// under it.
  bool _commandPointerDown(PointerDownEvent e) {
    if (!_commanding) return false;
    final st = _combatState;
    if (e.buttons == kSecondaryButton) {
      final op = _commandOpNow();
      final project = st.project;
      if (op == null || project == null) return true;
      String? best;
      var bd = 80.0 * 80.0;
      for (final o in op.graph.objectives) {
        final at = project(o.e, o.n);
        if (at == null) continue;
        final d = (at - e.localPosition).distanceSquared;
        if (d < bd) {
          bd = d;
          best = o.id;
        }
      }
      if (best != null) _orderSelected(best);
      return true;
    }
    if (e.buttons == kPrimaryButton) {
      st
        ..dragFrom = e.localPosition
        ..dragTo = e.localPosition;
      return true;
    }
    return false;
  }

  void _commandPointerMove(PointerMoveEvent e) {
    final st = _combatState;
    if (!_commanding || st.dragFrom == null) return;
    rebuild(() => st.dragTo = e.localPosition);
  }

  void _commandPointerUp(PointerUpEvent e) {
    final st = _combatState;
    final from = st.dragFrom, to = st.dragTo;
    if (!_commanding || from == null) return;
    st
      ..dragFrom = null
      ..dragTo = null;
    final op = _commandOpNow();
    final frame = st.lastFrame;
    final project = st.project;
    if (op == null || frame == null || project == null) return;
    final mine = _orderable(op);
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final picked = <int>[];
    if (to == null || (to - from).distance < 6) {
      // A click: the nearest of your squads within reach.
      int? best;
      var bd = 22.0 * 22.0;
      for (final s in frame.squads) {
        if (!mine.contains(s.id)) continue;
        final at = project(s.e, s.n);
        if (at == null) continue;
        final d = (at - from).distanceSquared;
        if (d < bd) {
          bd = d;
          best = s.id;
        }
      }
      if (best != null) picked.add(best);
    } else {
      final box = Rect.fromPoints(from, to);
      for (final s in frame.squads) {
        if (!mine.contains(s.id)) continue;
        final at = project(s.e, s.n);
        if (at != null && box.contains(at)) picked.add(s.id);
      }
    }
    rebuild(() {
      if (!shift) st.selected.clear();
      for (final id in picked) {
        if (!st.selected.contains(id)) st.selected.add(id);
      }
    });
  }

  String _placeOf(Operation op, String id) => switch (op.graph.byId(id)?.kind) {
        ObjectiveKind.lz => 'the LZ',
        ObjectiveKind.port => 'the port',
        ObjectiveKind.seat => 'the seat',
        ObjectiveKind.lifeSupport => 'life support',
        ObjectiveKind.power => 'the power plant',
        ObjectiveKind.depot => 'the depot',
        ObjectiveKind.airfield => 'the airfield',
        null => id,
      };

  /// The command card (§7J): the selection and what it can be told.
  Widget? _commandCard() {
    final op = _commandOpNow();
    if (op == null) return null;
    final st = _combatState;
    final n = st.selected.length;
    final directed = {for (final d in op.directed) d.$1: d.$2};
    Widget button(String key, String label, VoidCallback? on) =>
        TextButton(key: Key(key), onPressed: on, child: Text(label, style: AppTheme.body));
    return Positioned(
      right: 16,
      bottom: 96,
      child: Container(
        key: const Key('command-card'),
        width: 300,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: AppTheme.panel.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(6)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Command · ${n == 0 ? 'nothing selected' : '$n squad${n == 1 ? '' : 's'}'}', style: AppTheme.heading),
          for (final id in st.selected.take(6))
            if (op.formationById(id) case final f?)
              Text(
                  '  ${f.count} troopers · ${directed[id] == null ? 'following the plan' : directed[id] == Operation.holdHere ? 'holding' : 'taking ${_placeOf(op, directed[id]!)}'}',
                  style: AppTheme.dim),
          if (n > 0)
            Wrap(spacing: 2, children: [
              for (final o in op.graph.objectives)
                if (o.kind != ObjectiveKind.lz)
                  button('command-take-${o.id}', 'Take ${_placeOf(op, o.id)}', () => _orderSelected(o.id)),
              button('command-hold', 'Hold (H)', () => _orderSelected(Operation.holdHere)),
              button('command-plan', 'Follow the plan (P)', () => _orderSelected(null)),
              if (n == 1)
                button('command-possess', 'Possess (Tab)',
                    _whyNotJoin(op) == null ? () => _joinFight(op, squadId: st.selected.single) : null),
            ]),
          Text('Click or drag to select · Y all · right-click an objective · Ctrl+1–4 keeps a group, 1–4 recalls · '
              'Esc leaves', style: AppTheme.dim),
        ]),
      ),
    );
  }

  /// The drawer's Orbital support section (§7E): who is up there, when they
  /// next pass, the strike buttons, and arming a vessel standing on a pad.
  List<Widget> _orbitalRows(Operation op, BuildContext ctx, String Function(String) place,
      Widget Function(String, String) line) {
    CitySim? target;
    for (final c in _cities.all()) {
      if (c.id == op.targetColonyId) target = c;
    }
    if (target == null) return const [];
    final system = _universe.current();
    final sky = TickSky(_vessels, system, _clock.epoch, _cities.all());
    final bodyId = target.body.id.value;
    final o = op.orbital;
    void send(CombatCommand c) {
      _operations.inbox.enqueue(c);
      Navigator.of(ctx).maybePop();
    }

    final assignable = [
      for (final v in _vessels.all())
        if (!v.landed &&
            v.dominantBody.value == bodyId &&
            Factions.ownerIsPlayer(v.ownerId) &&
            o.byId(v.id.value) == null &&
            !op.landers.any((l) => l.vesselId == v.id.value))
          v
    ]..sort((a, b) => a.id.value.compareTo(b.id.value));
    final armable = <(Vessel, CitySim)>[
      for (final v in _vessels.all())
        if (v.landed && Factions.ownerIsPlayer(v.ownerId))
          for (final c in _cities.all())
            if ((c.loyalty.allegiance == Allegiance.colonial || c.loyalty.allegiance == Allegiance.occupied) &&
                sky.landedAtPad(v.id.value, c.id))
              (v, c)
    ];
    if (!o.any && assignable.isEmpty && armable.isEmpty) return const [];
    final t = op.clock.steps;
    final uplink = op.base?.uplinkOnline(op) ?? false;
    final rows = <Widget>[
      const SizedBox(height: 10),
      Text('Orbital support', style: AppTheme.dim),
      if (o.any)
        line('Uplink',
            op.base == null ? 'no base, no uplink' : (uplink ? 'online' : 'offline: 8 kW and 2 staff to spare')),
      for (final v in o.assigned)
        Row(children: [
          Expanded(
            child: Text(
                '  ${v.name} · ${_operations.roundsAboard(v.id)} rounds'
                '${_operations.roundsLoading(v.id) > 0 ? ' (+${_operations.roundsLoading(v.id)} loading)' : ''}'
                ' · ${v.strike ? 'overhead, ${(v.slantM / 1000).round()} km' : (v.recon ? 'low, watching' : 'below the horizon')}'
                '${t < v.readyStep ? ' · ready in ${v.readyStep - t} s' : ''}'
                ' · ${_passLine(v.id, target, o)}',
                style: AppTheme.body),
          ),
          TextButton(
            key: Key('orbital-release-${v.id}'),
            onPressed: () => send(AssignOrbitalSupportCommand(const PlayerId('player'), 0, op.id, v.id, assign: false)),
            child: const Text('Release'),
          ),
        ]),
      if (o.queued != null) line('Strike called', 'on ${place(o.queued!)} · fires at the next pass'),
      for (final s in o.inFlight) line('Round coming down', 'on ${place(s.objectiveId)} in ${s.impactStep - t} s'),
      if (o.any && op.phase == OperationPhase.engaged && o.queued == null)
        Wrap(spacing: 4, children: [
          for (final obj in op.graph.objectives)
            if (op.strikeAllowed(obj))
              Tooltip(
                message: op.whyNotStrike(obj.id) ??
                    (op.formations.any((f) => f.side == CombatSide.attacker && f.presentAt(obj.id, t))
                        ? 'Danger close: your squads there take half the blast.'
                        : 'One round: ${o.craterM.round()} m crater, scatter grows with range.'),
                child: TextButton(
                  key: Key('orbital-strike-${obj.id}'),
                  onPressed: op.whyNotStrike(obj.id) == null
                      ? () => send(CommanderPowerCommand(const PlayerId('player'), 0, op.id, 'orbitalStrike',
                          target: obj.id))
                      : null,
                  child: Text('Strike ${place(obj.id)}'),
                ),
              ),
        ]),
      for (final v in assignable)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: Key('orbital-assign-${v.id.value}'),
            onPressed: () => send(AssignOrbitalSupportCommand(const PlayerId('player'), 0, op.id, v.id.value)),
            child: Text('Assign ${v.name} (${_operations.roundsAboard(v.id.value)} rounds) · warp held at 10×'),
          ),
        ),
      for (final (v, c) in armable)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: Key('orbital-arm-${v.id.value}'),
            onPressed: () => send(ArmVesselCommand(const PlayerId('player'), 0, v.id.value, c.id, 4)),
            child: Text('Arm ${v.name} at ${c.name}: 4 rounds '
                '(${4 * kRoundSteel} steel, ${4 * kRoundElectronics} electronics)'),
          ),
        ),
      for (final n in o.notices.length > 3 ? o.notices.sublist(o.notices.length - 3) : o.notices)
        Text('  $n', style: AppTheme.dim),
      for (final n in op.air.notices.length > 3 ? op.air.notices.sublist(op.air.notices.length - 3) : op.air.notices)
        Text('  $n', style: AppTheme.dim),
    ];
    return rows;
  }

  /// "next pass in 1 h 12 min · 3 min above 30°", from the cached window.
  String _passLine(String vesselId, CitySim target, OrbitalSupport o) {
    final now = _clock.epoch.seconds;
    final cached = _combatState.windows[vesselId];
    StrikeWindow? w;
    if (cached != null && now - cached.$1 < 60) {
      w = cached.$2;
    } else {
      w = _strikeWindow(vesselId, target, o);
      _combatState.windows[vesselId] = (now, w);
    }
    if (w == null) return 'no pass in 30 days';
    String span(double s) => s < 90
        ? '${s.round()} s'
        : (s < 5400 ? '${(s / 60).round()} min' : '${(s / 3600).floor()} h ${((s % 3600) / 60).round()} min');
    if (w.startS <= now) return 'overhead ${span(w.endS - now)} more';
    return 'next pass in ${span(w.startS - now)} · ${span(w.lengthS)} above 30°';
  }

  StrikeWindow? _strikeWindow(String vesselId, CitySim target, OrbitalSupport o) {
    final v = _vessels.byId(VesselId(vesselId));
    final centre = o.centreBF;
    final body = _universe.current().body(target.body.id);
    if (v == null || centre == null || body == null || v.landed) return null;
    const conv = StateVectorOrbitConverter();
    final orbit = conv.toOrbit(
        position: v.state.position, velocity: v.state.velocity, body: body, epoch: _clock.epoch);
    return nextStrikeWindow(
      vesselAt: (t) => conv.toStateVector(orbit, Epoch(t)).position,
      groundAt: (t) => body.orientationAt(Epoch(t)).rotate(centre),
      fromS: _clock.epoch.seconds,
      stepS: 90,
    );
  }

  /// The charge and the commander powers (§7D), each with its cooldown.
  List<Widget> _abilityRows(Operation op, BuildContext ctx, String Function(String) place) {
    final t = op.clock.steps;
    String wait(int ready) => ready > t ? ' · ${ready - t} s' : '';
    final b = op.base;
    final here = [
      for (final o in op.graph.objectives)
        if (op.formations.any((f) => f.side == CombatSide.attacker && f.presentAt(o.id, t))) o.id
    ];
    final wounded = [
      for (final id in here)
        if (op.formations.any((f) => f.side == CombatSide.attacker && f.presentAt(id, t) && f.wounded > 0))
          id
    ];
    Widget button(String key, String label, VoidCallback? onPressed) => TextButton(
        key: Key(key), onPressed: onPressed, child: Text(label, style: AppTheme.body));
    return [
      const SizedBox(height: 6),
      Wrap(spacing: 4, runSpacing: 2, children: [
        for (final id in here)
          button('combat-charge-$id', 'Charge at ${place(id)}${wait(op.chargeReadyStep)}',
              t < op.chargeReadyStep
                  ? null
                  : () {
                      _order(op, 'charge', target: id);
                      Navigator.of(ctx).maybePop();
                    }),
        if (b != null && b.standing && b.hasGate('airfield'))
          for (final o in op.graph.objectives)
            if (o.kind != ObjectiveKind.lz)
              button('combat-gunship-${o.id}', 'Gunship over ${place(o.id)}${wait(op.air.gunshipReadyStep)}',
                  t < op.air.gunshipReadyStep
                      ? null
                      : () {
                          _power(op, 'gunship', target: o.id);
                          Navigator.of(ctx).maybePop();
                        }),
        if (b != null && b.standing && b.hasGate('silo'))
          for (final o in op.graph.objectives)
            if (op.strikeAllowed(o))
              button('combat-silo-${o.id}', 'Silo strike on ${place(o.id)}${wait(op.air.siloReadyStep)}',
                  t < op.air.siloReadyStep || op.air.pendingSilo != null
                      ? null
                      : () {
                          _power(op, 'silo', target: o.id);
                          Navigator.of(ctx).maybePop();
                        }),
        if (b != null && b.standing) ...[
          button('combat-supply-drop', 'Emergency supply drop${wait(op.supplyDropReadyStep)}',
              t < op.supplyDropReadyStep
                  ? null
                  : () {
                      _power(op, 'supplyDrop');
                      Navigator.of(ctx).maybePop();
                    }),
          if (b.hospitalOnline)
            for (final id in wounded)
              button('combat-medevac-$id', 'Medevac from ${place(id)}${wait(op.medevacReadyStep)}',
                  t < op.medevacReadyStep
                      ? null
                      : () {
                          _power(op, 'medevac', target: id);
                          Navigator.of(ctx).maybePop();
                        }),
        ],
      ]),
    ];
  }

  /// Every ready trooper the other colonies can send, as reinforcements.
  List<({String colonyId, String siteId, int count})> _readyDraws(String targetId) {
    CitySim? target;
    for (final c in _cities.all()) {
      if (c.id == targetId) target = c;
    }
    if (target == null) return const [];
    return [
      for (final s in forceSourcesFor(target, _cities.all()))
        for (final t in s.trooperSources())
          if (t.ready) (colonyId: s.id, siteId: t.siteId, count: t.available),
    ];
  }

  void _openOperationDrawer(Operation op) {
    // Only a result is seen by opening it: a look at the fight mid-way must
    // not hide the chip that will say how it ended.
    if (op.resolved) _combatState.announced.add(op.id);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.panel,
      // Scroll-controlled, so the orders and buttons under a long squad list
      // stay reachable: the default caps the sheet at 9/16 of the screen.
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
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
                if (op.defensive) ..._defenceRows(op, line, where) else ...[
                line('Your troopers', '${op.attackerAlive} fit · ${op.attackerWounded} wounded · ${op.attackerDead} dead'),
                line(_assault(op) ? 'Defenders' : 'Rebels', '${op.defenderRemoved} fallen of ${op.defenderRaised} · '
                    '${op.militia.total} still at home'),
                if (op.defenderSurrendered > 0) line('Surrendered', '${op.defenderSurrendered}'),
                const SizedBox(height: 8),
                Text('Your squads', style: AppTheme.dim),
                for (final f in attackers)
                  if (f.alive || f.wounded > 0)
                    line('  ${f.count} ${_kindLabel(f)} · ${where(f)}',
                        'morale ${(f.morale * 100).round()}% · ${f.kitDays.toStringAsFixed(1)} d kit'),
                const SizedBox(height: 6),
                Text(_assault(op) ? 'Its defenders' : 'Rebel squads', style: AppTheme.dim),
                for (final f in defenders)
                  if (f.alive)
                    line('  ${f.count} ${_kindLabel(f)} · ${where(f)}',
                        'morale ${(f.morale * 100).round()}%'),
                ],
                if (op.base case final b?) ..._baseRows(op, b, ctx, line),
                if (!op.resolved && !op.defensive) ..._orbitalRows(op, ctx, place, line),
                if (!op.resolved && !op.defensive && op.phase == OperationPhase.engaged) ...[
                  const SizedBox(height: 10),
                  Text('Orders', style: AppTheme.dim),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final (kind, label) in const [
                      (OrderKind.auto, 'Follow the plan'),
                      (OrderKind.hold, 'Hold'),
                      (OrderKind.fallBack, 'Fall back to the LZ'),
                    ])
                      ChoiceChip(
                        key: Key('combat-order-${kind.name}'),
                        label: Text(label),
                        selected: op.order == kind,
                        onSelected: (_) {
                          _order(op, kind.name);
                          Navigator.of(ctx).maybePop();
                        },
                      ),
                    for (final o in op.graph.objectives)
                      if (o.kind != ObjectiveKind.lz && o.control < 0.5)
                        ChoiceChip(
                          key: Key('combat-attack-${o.id}'),
                          label: Text('Attack ${place(o.id).replaceFirst('the ', '')}'),
                          selected: op.order == OrderKind.attack && op.orderTarget == o.id,
                          onSelected: (_) {
                            _order(op, 'attack', target: o.id);
                            Navigator.of(ctx).maybePop();
                          },
                        ),
                  ]),
                  ..._abilityRows(op, ctx, place),
                ],
                const SizedBox(height: 12),
                if (!op.resolved && !op.defensive && op.phase != OperationPhase.mustering)
                  Builder(builder: (_) {
                    final why = _whyNotJoin(op);
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Tooltip(
                        message: why ?? 'On foot at the LZ as one of your troopers. LMB fires, R reloads, L leaves.',
                        child: TextButton(
                          key: const Key('combat-join'),
                          onPressed: why == null
                              ? () {
                                  Navigator.of(ctx).maybePop();
                                  _joinFight(op);
                                }
                              : null,
                          child: Text(why == null ? 'Join the fight' : 'Join the fight · $why'),
                        ),
                      ),
                    );
                  }),
                if (op.landers.any((l) => l.state == LanderState.descending))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('combat-ride-lander'),
                      onPressed: () {
                        Navigator.of(ctx).maybePop();
                        _rideLander(op);
                      },
                      child: Text('Ride the lander down (M takes the controls)', style: AppTheme.body),
                    ),
                  ),
                Row(children: [
                  if (!op.resolved && op.phase != OperationPhase.mustering)
                    TextButton(
                      key: const Key('combat-watch'),
                      onPressed: () {
                        Navigator.of(ctx).maybePop();
                        _watchBattle(op);
                      },
                      child: Text('Watch', style: AppTheme.body.copyWith(color: AppTheme.accent)),
                    ),
                  if (!op.resolved && !op.defensive)
                    Builder(builder: (_) {
                      final draws = _readyDraws(op.targetColonyId);
                      final n = draws.fold<int>(0, (a, d) => a + d.count);
                      return TextButton(
                        key: const Key('combat-reinforce'),
                        onPressed: n == 0
                            ? null
                            : () {
                                _operations.inbox.enqueue(ReinforceOperationCommand(
                                    const PlayerId('player'), 0, op.id,
                                    draws: draws,
                                    kitDays: op.kind == OperationKind.colonyAssault ? 6 : 3));
                                Navigator.of(ctx).maybePop();
                              },
                        child: Text(n == 0 ? 'No reinforcements ready' : 'Reinforce ($n)'),
                      );
                    }),
                  const Spacer(),
                  if (!op.resolved && !op.defensive)
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

  /// A rising's or a raid's drawer lines (§7N): the player's side defends.
  List<Widget> _defenceRows(
      Operation op, Widget Function(String, String) line, String Function(Formation) where) {
    final rising = op.kind == OperationKind.uprising;
    final ours = op.formations.where((f) => f.side == CombatSide.defender).toList();
    final theirs = op.formations.where((f) => f.side == CombatSide.attacker).toList();
    final raider = op.raiderId;
    return [
      line(rising ? 'Your garrison' : 'Its people',
          '${op.defenderRemoved} fallen of ${op.defenderRaised} · ${op.militia.total} still at home'),
      line(rising ? 'Rebels' : 'Raiders from ${raider == null ? '?' : _colonyName(raider)}',
          '${op.attackerAlive} fit · ${op.attackerRemoved} fallen of ${op.attackerRaised}'),
      if (op.defenderSurrendered > 0) line('Laid down their arms', '${op.defenderSurrendered}'),
      const SizedBox(height: 8),
      Text(rising ? 'Your squads' : 'Its defenders', style: AppTheme.dim),
      for (final f in ours)
        if (f.alive) line('  ${f.count} ${_kindLabel(f)} · ${where(f)}', 'morale ${(f.morale * 100).round()}%'),
      const SizedBox(height: 6),
      Text(rising ? 'Rebel squads' : 'Raiding squads', style: AppTheme.dim),
      for (final f in theirs)
        if (f.alive) line('  ${f.count} ${_kindLabel(f)} · ${where(f)}', 'morale ${(f.morale * 100).round()}%'),
    ];
  }

  /// `ext.acro.combat` (docs/plans/combat.md §7.9): the operation surface,
  /// driven by name for a headless check.
  ///   status                      operations as JSON
  ///   fixture=portSeizedPair      the open colony's rebels seize its port, and
  ///                               a supplied source colony with 3 barracks is
  ///                               founded beside it
  ///   fixture=independent         the open colony has seceded (three revolts),
  ///                               with the same source beside it
  ///   launch=1[&garrison=N][&kit=D][&roe=standard][&base=MATERIEL,SUPPORT]
  ///                               launch every ready trooper at the open colony
  ///   panel=independence|occupation  open the colony's panel
  ///   watch=ID[&at=OBJ]           frame the camera on an operation's battle
  ///                               (or close over one of its objectives)
  ///   order=auto|hold|fallBack|attack:OBJ   the running operation's order
  ///   reinforce=1                 send every ready trooper as reinforcements
  ///   charter=ready               an occupied colony has held the line 11 days
  ///   rise=1                      the open colony, occupied, rises (§7N)
  ///   raidDay=1                   the clock to just before a rival's raid day
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
    // rise=1: the open colony, occupied, rises against its garrison (§7N).
    if (p['rise'] != null && target != null && target.loyalty.occupied) {
      final t = target.loyalty.colonyTimeS;
      target.loyalty.revolts.addAll([t, t, t]);
      did['rise'] = target.loyalty.revolts.length;
    }
    // raidDay=1: the operation clock to just before the next day a rival
    // raids (§7N).
    if (p['raidDay'] != null) {
      final dayUs = (const ResolverTuning().daySec * 1e6).round();
      final today = _operations.clockUs ~/ dayUs;
      for (var d = 1; d <= CombatPhase.raidEveryDays && did['raidDay'] == null; d++) {
        for (final c in _cities.all()) {
          if (c.loyalty.allegiance != Allegiance.independent ||
              c.population < CombatPhase.raidMinPopulation) {
            continue;
          }
          if ((today + d + CombatPhase.raidPhase(c.id)) % CombatPhase.raidEveryDays == 0) {
            _operations.clockUs = (today + d) * dayUs - 200000;
            did['raidDay'] = {'rival': c.id, 'day': today + d};
            break;
          }
        }
      }
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
          baseMateriel: int.tryParse((p['base'] ?? '').split(',').first) ?? 0,
          baseSupport: int.tryParse((p['base'] ?? '').split(',').last) ?? 0,
          baseDoctrine: p['doctrine'],
          baseSpareCore: p['spare'] != null,
          baseSteel: int.tryParse(p['steel'] ?? ''),
          baseElectronics: int.tryParse(p['electronics'] ?? ''),
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
    final watch = int.tryParse(p['watch'] ?? '');
    if (watch != null) {
      final op = _operations.byId(watch);
      if (op != null) _watchBattle(op, objective: p['at']);
    }
    final ordered = p['order'];
    if (ordered != null) {
      final running = target == null ? null : _operations.runningAgainst(target.id);
      if (running != null) {
        final i = ordered.indexOf(':');
        if (i < 0) {
          _order(running, ordered);
        } else {
          _order(running, ordered.substring(0, i), target: ordered.substring(i + 1));
        }
        did['order'] = ordered;
      }
    }
    // Orbital support (§7E): orbit=DEG puts a player vessel in a 100 km
    // circular orbit DEG degrees before passing straight over the battle
    // (rounds=N loads it, a dev shortcut past arming at a pad); assign=ID and
    // strike=OBJ go through the commands.
    final orbitLead = double.tryParse(p['orbit'] ?? '');
    if (orbitLead != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      final c = running?.orbital.centreBF;
      final body = _universe.current().body(target.body.id);
      if (c != null && body != null) {
        final g = body.orientationAt(_clock.epoch).rotate(c).normalized;
        final k = g.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
        final w = (k - g * k.dot(g)).normalized;
        final r = body.radius + 100e3;
        final vc = math.sqrt(body.mu / r);
        final th = -orbitLead * math.pi / 180;
        final v = SampleWorld.buildLunarOrbiter(id: 'rod-1', name: 'Lunar Rod 1');
        v.updateState(v.state.copyWith(
          position: (g * math.cos(th) + w * math.sin(th)) * r,
          velocity: (g * -math.sin(th) + w * math.cos(th)) * vc,
        ));
        v.dominantBody = body.id;
        _vessels.save(v);
        final n = int.tryParse(p['rounds'] ?? '') ?? 0;
        if (n > 0) _operations.loadRounds('rod-1', n, _operations.clockUs);
        did['orbit'] = {'vessel': 'rod-1', 'leadDeg': orbitLead, 'rounds': n};
      }
    }
    if (p['assign'] != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (running != null) {
        _operations.inbox
            .enqueue(AssignOrbitalSupportCommand(const PlayerId('player'), 0, running.id, p['assign']!));
        did['assign'] = p['assign'];
      }
    }
    if (p['strike'] != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (running != null) {
        _power(running, 'orbitalStrike', target: p['strike']);
        did['strike'] = p['strike'];
      }
    }
    // Spike S (§7F): spike=ground measures items 1 and 3 round the battle (or
    // the colony), spikeFrames=start|report item 5.
    if (p['spike'] == 'ground' && target != null) did['spike'] = _spikeGround(target);
    if (p['spikeFrames'] == 'start') {
      final st = _combatState;
      st.spikeFrames.clear();
      if (st.spikeTimings != null) SchedulerBinding.instance.removeTimingsCallback(st.spikeTimings!);
      st.spikeTimings = (List<FrameTiming> ts) {
        for (final t in ts) {
          st.spikeFrames.add(t.totalSpan.inMicroseconds / 1000);
        }
      };
      SchedulerBinding.instance.addTimingsCallback(st.spikeTimings!);
      did['spikeFrames'] = 'started';
    }
    if (p['spikeFrames'] == 'report') {
      final st = _combatState;
      if (st.spikeTimings != null) SchedulerBinding.instance.removeTimingsCallback(st.spikeTimings!);
      st.spikeTimings = null;
      final f = [...st.spikeFrames]..sort();
      double q(double k) => f.isEmpty ? 0 : f[((f.length - 1) * k).round()];
      did['spikeFrames'] = {
        'frames': f.length,
        'p50': q(0.5),
        'p75': q(0.75),
        'p95': q(0.95),
        'max': f.isEmpty ? 0 : f.last,
      };
    }
    // The soldier (§7G): join=1 steps out at the LZ of the running battle,
    // autofire=1|0 aims at the nearest defender and holds the trigger,
    // walkTo=OBJ stands 60 m short of an objective, leave=1 leaves.
    if (p['join'] != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (running != null) {
        final why = _whyNotJoin(running);
        if (why == null) _joinFight(running);
        did['join'] = why ?? 'joined';
      }
    }
    if (p['autofire'] != null) _combatState.devAutofire = p['autofire'] == '1';
    // The command view (§7J): command=1|0, select=all|ID,ID, orderTo=OBJ|hold|plan, possess=ID.
    if (p['command'] != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (p['command'] == '1' && running != null) _enterCommand(running);
      if (p['command'] == '0') _exitCommand();
      did['command'] = _combatState.commandOp;
    }
    final sel = p['select'];
    final cop = _commandOpNow();
    if (sel != null && cop != null) {
      _combatState.selected
        ..clear()
        ..addAll(sel == 'all' ? _orderable(cop) : [for (final s in sel.split(',')) if (int.tryParse(s) case final v?) v]);
      did['select'] = [..._combatState.selected];
    }
    final orderTo = p['orderTo'];
    if (orderTo != null && cop != null) {
      _orderSelected(orderTo == 'plan' ? null : (orderTo == 'hold' ? Operation.holdHere : orderTo));
      did['orderTo'] = orderTo;
    }
    final possess = int.tryParse(p['possess'] ?? '');
    if (possess != null && cop != null) {
      _joinFight(cop, squadId: possess);
      did['possess'] = possess;
    }
    if (p['stress'] != null) _combatState.devStress = p['stress'] == '1';
    // The APC (§7L): board=1 boards or steps out; apc=1 puts one at the LZ
    // (a dev shortcut past the Fortress and its bay).
    if (p['board'] != null && _liveJoined) {
      final l = _combatState.live!;
      // Dev: walk the player to the nearest of their APCs first.
      if (l.driving == null) {
        final v = l.units.where((u) => u.vehicle && u.side == CombatSide.attacker).firstOrNull;
        if (v != null) _combatState.lastEye = (v.e + 2, v.n, 1.7);
      }
      _boardOrAlight();
      did['board'] = _combatState.live?.drivingFormation;
    }
    final drive = p['drive'];
    if (drive != null) {
      for (final k in const [LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD]) {
        _keysDown.remove(k);
      }
      if (drive.contains('W')) _keysDown.add(LogicalKeyboardKey.keyW);
      if (drive.contains('A')) _keysDown.add(LogicalKeyboardKey.keyA);
      if (drive.contains('D')) _keysDown.add(LogicalKeyboardKey.keyD);
      did['drive'] = drive;
    }
    // Air and missiles (§7M), dev shortcuts past building an Airfield and a
    // Silo at home: gates=airfield,silo grants the base those sources;
    // kit=1 stocks it for a pass; missiles=N stocks the lead source;
    // rebelSilos=N arms the target.
    final gates = p['gates'];
    if (gates != null && target != null) {
      final b = _operations.runningAgainst(target.id)?.base;
      if (b != null) {
        for (final g in gates.split(',')) {
          if (!b.gates.contains(g)) b.gates.add(g);
        }
        did['gates'] = [...b.gates];
      }
    }
    if (p['kit'] == '1' && target != null) {
      final b = _operations.runningAgainst(target.id)?.base;
      if (b != null) {
        b.stockC[kBaseStock.indexOf('ammo')] = 20000;
        b.stockC[kBaseStock.indexOf('fuel')] = 20000;
        did['kit'] = true;
      }
    }
    final missiles = double.tryParse(p['missiles'] ?? '');
    if (missiles != null && target != null) {
      final b = _operations.runningAgainst(target.id)?.base;
      final home = b == null ? null : _cityById(b.homeColonyId);
      if (home != null) {
        home.stock[Commodity.missiles] = missiles;
        did['missiles'] = missiles;
      }
    }
    final silos = int.tryParse(p['rebelSilos'] ?? '');
    if (silos != null && target != null) {
      final op = _operations.runningAgainst(target.id);
      if (op != null) {
        op.air
          ..rebelSilos = silos
          ..rebelNextStep = op.clock.steps + 5;
        did['rebelSilos'] = silos;
      }
    }
    if (p['apc'] != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (running != null) {
        running.addAttacker(Formation(
          id: running.nextFormationId,
          side: CombatSide.attacker,
          faction: Factions.player,
          kind: FormationKind.armour,
          counterClass: CounterClass.arm,
          count: 3,
          quality: 1,
          morale: 0.9,
          kitDays: 3,
          at: running.lzId,
          arriveStep: running.clock.steps,
        ));
        did['apc'] = running.nextFormationId - 1;
      }
    }
    final squadOrder = p['squad'];
    if (squadOrder != null && _combatState.live != null) {
      final i = squadOrder.indexOf(':');
      final kind = SquadOrder.values.where((o) => o.name == (i < 0 ? squadOrder : squadOrder.substring(0, i))).firstOrNull;
      if (kind == SquadOrder.attack && i > 0) {
        _combatState.live!.command(kind!, objectiveId: squadOrder.substring(i + 1));
      } else if (kind != null) {
        _squadOrder(kind);
      }
      did['squad'] = squadOrder;
    }
    final walkTo = p['walkTo'];
    final liveNow = _combatState.live;
    if (walkTo != null && liveNow != null) {
      final op = _operations.byId(liveNow.opId);
      final o = op?.graph.byId(walkTo);
      final city = op == null ? null : _cityById(op.targetColonyId);
      final r = op == null ? null : _rasterFor(op);
      final body = city == null ? null : _universe.current().body(city.body.id);
      if (o != null && city != null && r != null && body != null) {
        final lz = op!.graph.byId(op.lzId)!;
        final dx = lz.e - o.e, dy = lz.n - o.n;
        final l = math.max(1.0, math.sqrt(dx * dx + dy * dy));
        final e = o.e + dx / l * 60, n = o.n + dy / l * 60;
        final dir = city.localToBodyFixed(Vec2(e, n), bodyRadiusM: body.radius).normalized;
        _freecamRelLocal = dir * ((r.radiusAt(e, n) ?? body.radius) + walkEyeHeight);
        did['walkTo'] = walkTo;
        _combatState
          ..faceObjective = walkTo
          ..faceInFrames = 3;
      }
    }
    if (p['leave'] != null) {
      _leaveFight();
      did['leave'] = true;
    }
    final power = p['power'];
    if (power != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (running != null) {
        final i = power.indexOf(':');
        _power(running, i < 0 ? power : power.substring(0, i), target: i < 0 ? null : power.substring(i + 1));
        did['power'] = power;
      }
    }
    if (p['reinforce'] != null && target != null) {
      final running = _operations.runningAgainst(target.id);
      if (running != null) {
        final draws = _readyDraws(target.id);
        _operations.inbox.enqueue(ReinforceOperationCommand(const PlayerId('player'), 0, running.id,
            draws: draws, kitDays: running.kind == OperationKind.colonyAssault ? 6 : 3));
        did['reinforce'] = draws.fold<int>(0, (a, d) => a + d.count);
      }
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
      'fx': CombatFxNodes.debugLine,
      // Each sampled objective's ground against its operation's colony centre, m.
      'groundOffsets': {
        for (final e in _combatState.objectiveGround.entries)
          e.key: (e.value - (_combatState.groundR[int.tryParse(e.key.split(':').first) ?? -1] ?? e.value))
              .roundToDouble(),
      },
      'warp': _clock.warpFactor,
      'command': {
        'op': _combatState.commandOp,
        'selected': [..._combatState.selected],
        'directed': [
          for (final op in _operations.operations)
            for (final d in op.directed) [d.$1, d.$2]
        ],
      },
      if (_combatState.live case final l?)
        'live': {
          'hp': l.hp,
          'dead': l.dead,
          'kills': l.kills,
          'magazine': l.magazine,
          'units': l.units.length,
          'defenders': l.units.where((u) => u.side == CombatSide.defender).length,
          'tracers': l.tracers.length,
          'squad': l.playerFormationId,
          'unitsMs': CombatUnitState.lastUpdateMs,
          'order': l.order.name,
          'attack': l.attackTarget,
          'squadUnits': l.units.where((u) => u.squad).length,
          'driving': l.drivingFormation,
          'vehicles': [for (final u in l.units) if (u.vehicle) [u.formationId, u.e.round(), u.n.round(), u.hp.round()]],
          'fieldsBuilt': l.nav?.built,
          // Why nobody fires: defenders in range of the player, those with
          // sight, and those with sight over the ground alone (no walls).
          'sight': () {
            final nav = l.nav;
            if (nav == null) return null;
            final bare = NavGrid(nav.raster, const []);
            final eye = _combatState.lastEye;
            var inRange = 0, seen = 0, seenBare = 0;
            for (final u in l.units) {
              if (u.side != CombatSide.defender) continue;
              final d = math.sqrt((u.e - eye.$1) * (u.e - eye.$1) + (u.n - eye.$2) * (u.n - eye.$2));
              if (d > kDefenderRangeM) continue;
              inRange++;
              if (nav.lineOfSight((u.e, u.n, 1.4), eye)) seen++;
              if (bare.lineOfSight((u.e, u.n, 1.4), eye)) seenBare++;
            }
            LiveUnit? near;
            var nd = double.infinity;
            for (final u in l.units) {
              if (u.side != CombatSide.defender) continue;
              final d = math.sqrt((u.e - eye.$1) * (u.e - eye.$1) + (u.n - eye.$2) * (u.n - eye.$2));
              if (d < nd) {
                nd = d;
                near = u;
              }
            }
            return {
              'inRange': inRange,
              'seen': seen,
              'seenOverGround': seenBare,
              'walls': nav.footprints.length,
              'eye': [eye.$1.round(), eye.$2.round(), eye.$3.toStringAsFixed(1)],
              'anchor': () {
                final st = _combatState;
                final d = _freecamRelLocal - st.frameO;
                return [d.dot(st.frameE).round(), d.dot(st.frameN).round(), _walkMode, _freecam, _cityCamera];
              }(),
              if (near != null) 'nearest': [near.e.round(), near.n.round(), near.objectiveId, nd.round()],
              'squadAt': [
                for (final u in l.units)
                  if (u.squad) [u.e.round(), u.n.round()]
              ].take(3).toList(),
            };
          }(),
          'drawnOffset': _combatState.drawnOffset,
        },
      'rasters': {
        for (final op in _operations.operations)
          if (_combatState.rasters[op.id] case final r?) '${op.id}': (r.progress * 100).round(),
      },
      'operations': [
        for (final op in _operations.operations)
          {
            'id': op.id,
            'target': op.targetColonyId,
            'phase': op.phase.name,
            'kind': op.kind.name,
            'outcome': op.outcome?.name,
            'band': op.band.name,
            'seconds': op.seconds,
            'control': op.graph.byId(op.goalId)?.control,
            'attackers': {'alive': op.attackerAlive, 'wounded': op.attackerWounded, 'dead': op.attackerDead},
            'raised': op.attackerRaised,
            if (op.base case final b?)
              'base': {
                'deployed': b.deployed,
                'standing': b.standing,
                'modules': [for (final m in b.modules) m.kind.name],
                'job': b.job?.label,
                'tier': b.core?.tier.name,
                'sites': b.sites.length,
                'doctrine': b.doctrine.name,
                'materiel': b.materielC ~/ 100,
                'pallets': b.palletsC ~/ 100,
                'reserve': b.reserve,
                'runs': b.runs.length,
                'power': '${b.powerDemand.round()}/${b.powerSupply.round()}',
                'blocked': [for (final s in b.sites) s.blockedModules.length + s.blockedTurrets.length],
                'recovered': b.recoveredTotal,
                'stock': {for (final k in kBaseStock) k: b.stockOf(k) ~/ 100},
              },
            'lz': [for (final o in op.graph.objectives) if (o.id == op.lzId) [o.e.round(), o.n.round()]],
            'orbital': {
              'assigned': [
                for (final v in op.orbital.assigned)
                  {
                    'id': v.id,
                    'strike': v.strike,
                    'recon': v.recon,
                    'slantKm': (v.slantM / 1000).round(),
                    'rounds': _operations.roundsAboard(v.id),
                    'readyIn': v.readyStep - op.clock.steps,
                  }
              ],
              'queued': op.orbital.queued,
              'inFlight': [for (final s in op.orbital.inFlight) s.impactStep - op.clock.steps],
              'craters': [for (final c in op.orbital.craters) [c.e.round(), c.n.round(), c.brush]],
              'uplink': op.base?.uplinkOnline(op),
              'notices': op.orbital.notices.length > 3
                  ? op.orbital.notices.sublist(op.orbital.notices.length - 3)
                  : op.orbital.notices,
            },
            'air': {
              'passes': [for (final p in op.air.passes) [p.$1, p.$3 - op.clock.steps]],
              'gunshipIn': op.air.gunshipReadyStep - op.clock.steps,
              'pendingSilo': op.air.pendingSilo,
              'rebelSeq': op.air.rebelSeq,
              'notices': op.air.notices.length > 4 ? op.air.notices.sublist(op.air.notices.length - 4) : op.air.notices,
            },
            'cooldowns': {
              'charge': op.chargeReadyStep - op.clock.steps,
              'drop': op.supplyDropReadyStep - op.clock.steps,
              'medevac': op.medevacReadyStep - op.clock.steps,
            },
            'order': op.order.name,
            'landers': [for (final l in op.landers) l.state.name],
            'objectives': {
              for (final o in op.graph.objectives) o.id: double.parse(o.control.toStringAsFixed(2)),
            },
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
          'postTurrets': target.war.garrison?.turrets,
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
    src.stock[Commodity.ore] = 700; // a forward base's Materiel
    src.population = 300;
    return {'target': target.id, 'source': src.id};
  }
}
