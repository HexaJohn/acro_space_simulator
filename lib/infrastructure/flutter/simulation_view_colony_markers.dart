// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The known colonies as HUD markers over the view: where each one is on its
// body, from wherever the camera is (`adapters/presenters/colony_markers.dart`
// decides what can be seen; `screens/colony_markers_painter.dart` draws it).
// A colony is in-process state here, as the battle overlay's is.
part of 'simulation_view.dart';

class _ColonyMarkerState {
  /// Each colony's ground radius at its centre, by colony id, with the count
  /// of its body's terrain edits it was sampled under: sampled once, and
  /// again when the ground under it is edited.
  final Map<String, (int, double)> groundR = {};
}

final Expando<_ColonyMarkerState> _colonyMarkerStates = Expando<_ColonyMarkerState>('colonyMarkers');

extension _SimulationViewColonyMarkers on _SimulationViewState {
  _ColonyMarkerState get _markerState => _colonyMarkerStates[this] ??= _ColonyMarkerState();

  /// The colony markers over [snap], or null with none to draw. The colony
  /// open in the editor is marked only from far out: the view is on it.
  Widget? _colonyMarkers(WorldSnapshot? snap) {
    if (snap == null || !_layers.colonyMarkers) return null;
    final cities = _cities.all();
    if (cities.isEmpty) return null;
    final focus = _focusWorldForPick(snap);
    if (focus == null) return null;
    final st = _markerState;
    // A ground sample is a march through the terrain field: at most one a
    // frame, the body's mean radius until then.
    var sampled = false;
    final inputs = <ColonyMarkerInput>[];
    for (final c in cities) {
      final body = _universe.current().body(c.body.id);
      if (body == null) continue;
      final edits = _terrainEdits.forBody(body.id)?.length ?? 0;
      var r = st.groundR[c.id];
      if ((r == null || r.$1 != edits) && !sampled) {
        sampled = true;
        r = st.groundR[c.id] = (edits, _groundAtLocal(c, const Vec2(0, 0)));
      }
      inputs.add(ColonyMarkerInput(
        id: c.id,
        name: c.name,
        bodyId: c.body.id.value,
        bodyFixed: c.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r?.$2 ?? body.radius),
        status: _markerStatus(c),
        hideWithinM: c.id == _editingCity?.id ? kOpenColonyMarkerNearM : kColonyMarkerNearM,
      ));
    }
    final cam = _camera;
    final marks = projectColonyMarkers(
      colonies: inputs,
      bodies: snap.bodies,
      focus: focus,
      eyeOffset: cam.eyeOffset,
      project: cam.projectPx,
    );
    if (marks.isEmpty) return null;
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(key: const Key('colony-markers'), painter: ColonyMarkersPainter(marks)),
      ),
    );
  }

  ColonyMarkerStatus _markerStatus(CitySim c) {
    if (_session.operations.runningAgainst(c.id) != null) return ColonyMarkerStatus.battle;
    final l = c.loyalty;
    return switch (l.allegiance) {
      Allegiance.independent => ColonyMarkerStatus.independent,
      Allegiance.occupied => ColonyMarkerStatus.occupied,
      Allegiance.colonial => l.portSeized || l.stage == LoyaltyStage.standoff
          ? ColonyMarkerStatus.unrest
          : ColonyMarkerStatus.yours,
    };
  }
}
