// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The encounter planner, lifted out of the flight view (same `part` rationale
// as the debug panel: an extension keeps the state's private fields reachable
// while the file stays navigable).
//
// The planner is a trial maneuver node — burn epoch + prograde/normal/radial
// delta-v — evaluated by the domain [EncounterPlannerService] against a target
// moon or craft, and rendered as a plane aligned with the planned orbit plus
// the planned trajectory, burn marker, AN/DN line, and closest-approach pair.
part of 'simulation_view.dart';

extension SimulationViewPlanner on _SimulationViewState {
  static const double _dvMax = 2500.0; // m/s at full slider deflection

  void _togglePlanner() {
    rebuild(() {
      _plannerActive = !_plannerActive;
      if (_plannerActive) {
        _plannerBurnEpoch = _clock.epoch + 300.0;
        if (_plannerTargetIndex < 0) {
          _plannerTargetIndex = _defaultPlannerTarget();
        }
        _plannerDirty = true;
      } else {
        _plan = null;
        _plannerOverlay = null;
      }
    });
  }

  /// First moon of the craft's dominant body (the classic transfer target),
  /// else the first OTHER craft (rendezvous), else no target.
  int _defaultPlannerTarget() {
    final vId = _focusVessel;
    final v = vId == null ? null : _vessels.byId(vId);
    if (v == null) return -1;
    final system = _universe.current();
    for (var i = 0; i < _targets.length; i++) {
      final b = _targets[i].b;
      if (b == null) continue;
      final cb = system.body(b);
      if (cb != null && cb.parent == v.dominantBody) return i;
    }
    for (var i = 0; i < _targets.length; i++) {
      final tv = _targets[i].v;
      if (tv != null && tv != vId) return i;
    }
    return -1;
  }

  /// Recompute the plan + render overlay. Called every frame; throttled so
  /// slider drags feel live while the (patched-conic + closest-approach)
  /// search never runs more than a few times a second.
  void _updatePlannerPlan() {
    if (!_plannerActive) {
      _plan = null;
      _plannerOverlay = null;
      return;
    }
    final vId = _focusVessel;
    final v = vId == null ? null : _vessels.byId(vId);
    if (v == null || v.landed) {
      _plan = null;
      _plannerOverlay = null;
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (!_plannerDirty && nowMs - _plannerComputedMs < 500) return;
    _plannerDirty = false;
    _plannerComputedMs = nowMs;

    final system = _universe.current();
    final body = system.body(v.dominantBody);
    if (body == null) {
      _plan = null;
      _plannerOverlay = null;
      return;
    }

    // A node whose epoch has passed sticks to "now" (the service clamps too;
    // clamping the stored epoch keeps the T+ readout honest).
    var burn = _plannerBurnEpoch ?? (_clock.epoch + 300.0);
    if (burn < _clock.epoch) burn = _clock.epoch;
    _plannerBurnEpoch = burn;

    BodyId? targetBody;
    TargetCraftState? targetCraft;
    if (_plannerTargetIndex >= 0 && _plannerTargetIndex < _targets.length) {
      final t = _targets[_plannerTargetIndex];
      if (t.b != null && t.b != v.dominantBody) targetBody = t.b;
      final tvId = t.v;
      if (tvId != null && tvId != vId) {
        final tv = _vessels.byId(tvId);
        if (tv != null && !tv.landed) {
          targetCraft = TargetCraftState(
            position: tv.state.position,
            velocity: tv.state.velocity,
            body: tv.dominantBody,
          );
        }
      }
    }

    final plan = const EncounterPlannerService().plan(
      position: v.state.position,
      velocity: v.state.velocity,
      body: body,
      system: system,
      epoch: _clock.epoch,
      node: ManeuverNode(
        executeAt: burn,
        deltaV: Vector3(_dvPrograde, _dvNormal, _dvRadial),
      ),
      targetBody: targetBody,
      targetCraft: targetCraft,
    );
    _plan = plan;
    if (plan == null) {
      _plannerOverlay = null;
      return;
    }

    // Plane radius: cover the planned orbit and — when the target orbits the
    // planning body — the target's orbit, capped at the SOI.
    var radius = 3.0 * body.radius;
    final ap = plan.postOrbit.apoapsis;
    if (ap.isFinite && ap > 0) radius = math.max(radius, ap);
    if (targetBody != null) {
      final tgt = system.body(targetBody);
      if (tgt != null && tgt.parent == body.id && tgt.orbitRadius > 0) {
        radius = math.max(
            radius, tgt.orbitRadius * (1 + tgt.orbitEccentricity));
      }
    }
    if (targetCraft != null && targetCraft.body == v.dominantBody) {
      radius = math.max(radius, targetCraft.position.length);
    }
    if (body.soiRadius.isFinite && body.soiRadius > 0) {
      radius = math.min(radius, body.soiRadius);
    }
    radius *= 1.06;

    _plannerOverlay = PlannerOverlay(
      frameBody: body.id.value,
      planeNormal: plan.planeNormal,
      planeRadiusM: radius,
      legs: [
        for (final p in plan.patches)
          PlannerLegOverlay(
            body: p.body.value,
            points: [
              for (final q in p.points) ...[q.x, q.y, q.z]
            ],
            closed: p.end == PatchEndKind.closed,
          ),
      ],
      nodePosition: plan.burnPosition,
      nodeLineDirection: plan.nodeLineDirection,
      closeApproachCraft: plan.closeApproach?.craftPosition,
      closeApproachTarget: plan.closeApproach?.targetPosition,
      encounterBody: plan.encounterBody?.value,
    );
  }

  /// Burn-slider horizon: two revolutions of the CURRENT orbit (stable while
  /// the delta-v sliders move), with a floor/fallback for tight or escape
  /// orbits.
  double _plannerHorizonS() {
    final vId = _focusVessel;
    final v = vId == null ? null : _vessels.byId(vId);
    if (v == null) return 6 * 3600.0;
    final body = _universe.current().body(v.dominantBody);
    if (body == null) return 6 * 3600.0;
    final orbit = const StateVectorOrbitConverter().toOrbit(
      position: v.state.position,
      velocity: v.state.velocity,
      body: body,
      epoch: _clock.epoch,
    );
    final p = orbit.period;
    if (p.isFinite && p > 0) return math.max(2 * p, 3600.0);
    return 6 * 3600.0;
  }

  Widget _plannerPanel() {
    final plan = _plan;
    final system = _universe.current();
    final burnOff = math.max(
        0.0, (_plannerBurnEpoch?.seconds ?? 0) - _clock.epoch.seconds);
    final horizon = _plannerHorizonS();
    final burnFrac = (math.sqrt(burnOff / horizon)).clamp(0.0, 1.0);

    const labelStyle = TextStyle(
        color: Color(0xFF8FA8C0), fontSize: 11, fontWeight: FontWeight.bold);
    const valueStyle = TextStyle(color: Colors.white, fontSize: 12);

    Widget ro(String k, String v, {Color c = Colors.white}) => Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(children: [
            SizedBox(width: 86, child: Text(k, style: labelStyle)),
            Expanded(
                child: Text(v,
                    style: valueStyle.copyWith(color: c),
                    overflow: TextOverflow.ellipsis)),
          ]),
        );

    Widget dvRow(String label, double value, void Function(double) set) {
      final x = value == 0
          ? 0.0
          : (value.isNegative ? -1.0 : 1.0) *
              math.pow(value.abs() / _dvMax, 1 / 3).toDouble();
      return Row(children: [
        SizedBox(width: 34, child: Text(label, style: labelStyle)),
        Expanded(
          child: Slider(
            value: x.clamp(-1.0, 1.0),
            min: -1,
            max: 1,
            activeColor: const Color(0xFFE0A040),
            inactiveColor: const Color(0xFF3A4A5A),
            onChanged: (nx) => rebuild(() {
              set(nx * nx * nx * _dvMax);
              _plannerDirty = true;
            }),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text('${value.toStringAsFixed(value.abs() < 10 ? 1 : 0)} m/s',
              style: valueStyle, textAlign: TextAlign.right),
        ),
      ]);
    }

    String dist(double m) => m >= 1e6
        ? '${(m / 1e6).toStringAsFixed(2)} Mm'
        : m >= 1e3
            ? '${(m / 1e3).toStringAsFixed(1)} km'
            : '${m.toStringAsFixed(0)} m';

    final ca = plan?.closeApproach;
    final enc = plan?.encounterBody == null
        ? null
        : system.body(plan!.encounterBody!)?.name ?? plan.encounterBody!.value;
    final relInc = plan?.relativeInclination;
    final apo = plan?.postOrbit.apoapsis ?? double.nan;
    final peri = plan?.postOrbit.periapsis ?? double.nan;
    final bodyRadius = () {
      final vId = _focusVessel;
      final v = vId == null ? null : _vessels.byId(vId);
      return v == null ? 0.0 : (system.body(v.dominantBody)?.radius ?? 0.0);
    }();

    return Container(
      width: 316,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xE61A2530),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE0A040), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.route, size: 16, color: Color(0xFFE0A040)),
            const SizedBox(width: 6),
            const Text('ENCOUNTER PLANNER',
                style: TextStyle(
                    color: Color(0xFFE0A040),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1)),
            const Spacer(),
            InkWell(
              onTap: _togglePlanner,
              child: const Icon(Icons.close, size: 16, color: Colors.white70),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const SizedBox(width: 34, child: Text('TGT', style: labelStyle)),
            Expanded(
              child: DropdownButton<int>(
                value: _plannerTargetIndex,
                isExpanded: true,
                dropdownColor: const Color(0xFF1A2530),
                iconEnabledColor: Colors.white70,
                underline: const SizedBox.shrink(),
                style: valueStyle,
                onChanged: (i) => rebuild(() {
                  _plannerTargetIndex = i ?? -1;
                  _plannerDirty = true;
                }),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('— none —')),
                  for (var i = 0; i < _targets.length; i++)
                    if (_targets[i].v != _focusVessel || _targets[i].v == null)
                      DropdownMenuItem(
                          value: i, child: Text(_targets[i].label)),
                ],
              ),
            ),
          ]),
          Row(children: [
            SizedBox(
                width: 34,
                child: Text('BURN', style: labelStyle)),
            Expanded(
              child: Slider(
                value: burnFrac,
                activeColor: const Color(0xFF7FE0A0),
                inactiveColor: const Color(0xFF3A4A5A),
                onChanged: (f) => rebuild(() {
                  _plannerBurnEpoch = _clock.epoch + f * f * horizon;
                  _plannerDirty = true;
                }),
              ),
            ),
            SizedBox(
              width: 56,
              child: Text('T+${_SimulationViewState._fmtCountdown(burnOff)}',
                  style: valueStyle, textAlign: TextAlign.right),
            ),
          ]),
          dvRow('PGD', _dvPrograde, (x) => _dvPrograde = x),
          dvRow('NRM', _dvNormal, (x) => _dvNormal = x),
          dvRow('RAD', _dvRadial, (x) => _dvRadial = x),
          const Divider(color: Color(0xFF3A4A5A), height: 12),
          if (plan == null)
            const Text('No conic to plan on (landed / degenerate orbit).',
                style: TextStyle(color: Colors.white54, fontSize: 11))
          else ...[
            ro('Δv TOTAL',
                '${plan.node.deltaV.length.toStringAsFixed(1)} m/s'),
            ro(
                'POST AP/PE',
                plan.postOrbit.elements.eccentricity >= 1
                    ? 'escape'
                    : '${dist(math.max(0, apo - bodyRadius))} / '
                        '${dist(math.max(0, peri - bodyRadius))}'),
            if (ca != null)
              ro(
                  'CLOSEST',
                  '${dist(ca.distanceMeters)}  @ T+'
                      '${_SimulationViewState._fmtCountdown(math.max(0, ca.epochSeconds - _clock.epoch.seconds))}',
                  c: const Color(0xFFFFC04D)),
            if (enc != null)
              ro('ENCOUNTER', '→ $enc SOI', c: const Color(0xFF7FE0A0)),
            if (relInc != null)
              ro('REL INC',
                  '${(relInc * 180 / math.pi).toStringAsFixed(2)}°'),
          ],
          const SizedBox(height: 8),
          Row(children: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2A3A4A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              onPressed: burnOff > 90
                  ? () => rebuild(() {
                        // Auto-warp to one minute before the burn (same
                        // mechanism as warp-to-apsis).
                        _warpTarget = _plannerBurnEpoch! - 60.0;
                        _warpTargetLabel = 'NODE';
                      })
                  : null,
              child: const Text('WARP → BURN', style: TextStyle(fontSize: 11)),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2A3A4A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              onPressed: () => rebuild(() {
                _dvPrograde = 0;
                _dvNormal = 0;
                _dvRadial = 0;
                _plannerBurnEpoch = _clock.epoch + 300.0;
                _plannerDirty = true;
              }),
              child: const Text('RESET', style: TextStyle(fontSize: 11)),
            ),
          ]),
        ],
      ),
    );
  }
}
