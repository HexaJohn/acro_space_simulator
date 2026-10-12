// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The open colony as a flat map in the live view: the city studio's plat
// (`screens/city_plat_view.dart`) over the world, toggled from the editor's
// toolbar (M with no craft focused; Esc leaves). The colony runs on under it:
// the plat is cut again as roads, lots and buildings change, a click on a
// building opens the same site sheet the 3D view does, and a battle there or
// a silo salvo coming down is drawn on it in the colony's own metres.
part of 'simulation_view.dart';

class _CityMapState {
  /// Where the map looks, per colony: kept across toggles, as the studio's.
  final Map<String, CityPlatCamera> cameras = {};
}

final Expando<_CityMapState> _cityMapStates = Expando<_CityMapState>('cityMap');

extension _SimulationViewCityMap on _SimulationViewState {
  _CityMapState get _cityMap => _cityMapStates[this] ??= _CityMapState();

  bool get _cityMapOn => _editingCity != null && _cityEdit.mapView;

  /// What the plat is cut from: moves when a road, lot or building does.
  static int _mapRevision(CitySim c) => Object.hash(
        c.roadsRevision,
        c.layout.parcels.length,
        c.parcelBuildings.length,
        c.utils.length,
      );

  /// The map over the world, or null when it is not open.
  Widget? _cityMapLayer() {
    final city = _editingCity;
    if (city == null || !_cityEdit.mapView) return null;
    final cam = _cityMap.cameras.putIfAbsent(city.id, () => CityPlatCamera()..fit(1800));
    return Positioned.fill(
      key: const Key('city-map'),
      child: CityPlatView(
        sim: city,
        camera: cam,
        extentM: 1800,
        revision: _mapRevision(city),
        onCameraChanged: () => rebuild(() {}),
        onTapLocal: (e, n) => _cityMapTap(city, e, n),
        overlay: (cam, size) => _cityMapOverlay(city, cam, size),
      ),
    );
  }

  /// A click on the map: the missile strike being aimed takes it as its
  /// target; otherwise the building there opens its site sheet.
  void _cityMapTap(CitySim city, double e, double n) {
    final st = _combatState;
    if (st.missileFrom != null) {
      final body = _universe.current().body(city.body.id);
      if (body == null) return;
      rebuild(() => st.missileAimDir = city.localToBodyFixed(Vec2(e, n), bodyRadiusM: body.radius).normalized);
      return;
    }
    final found = city.siteAt(Vec2(e, n));
    if (found == null) return;
    showCitySiteMenu(
      context: context,
      sim: city,
      site: found.$1,
      spec: found.$3,
      onChanged: () => rebuild(() {}),
      hooks: _worldSiteHooks(city),
    );
  }

  /// The colony's battle and the salvos over it, in the map's frame.
  Widget _cityMapOverlay(CitySim city, CityPlatCamera cam, Size size) {
    final mpp = cam.metresPerPx <= 0 ? 1.0 : cam.metresPerPx;
    Offset at(double e, double n) => cam.toScreen(e, n, size);
    final layers = <Widget>[];

    Operation? op;
    for (final o in _operations.operations.reversed) {
      if (o.targetColonyId != city.id || o.phase == OperationPhase.mustering) continue;
      if (o.resolved && o.seconds - o.resolvedAtStep > 60) continue;
      op = o;
      break;
    }
    if (op != null) {
      layers.add(CustomPaint(
        size: size,
        painter: BattleOverlayPainter(
          frame: CombatFrame.of(op),
          project: (e, n) => at(e, n),
          scale: (e, n) => 1 / mpp,
          timeS: _clock.epoch.seconds,
        ),
      ));
    }

    final body = _universe.current().body(city.body.id);
    final marks = <MissileMark>[];
    final arcs = <List<Offset>>[];
    if (body != null) {
      final cepPx = strikeCepM(kSiloSlantM) / mpp;
      final now = _clock.epoch.seconds;
      final q = body.orientationAt(_clock.epoch).conjugate;
      for (final m in _operations.missiles) {
        final aim = m.aimBF, silo = m.siloBF;
        if (m.state != MissileState.flying || aim == null || m.bodyId != city.body.id.value) continue;
        final (ae, an) = CombatPhase.localOf(city, aim);
        marks.add(MissileMark(at(ae, an), cepPx, 'Missile salvo · impact in ${math.max(0, m.impactEpochS - now).round()} s'));
        if (silo != null) {
          final (se, sn) = CombatPhase.localOf(city, silo);
          arcs.add([at(se, sn), at(ae, an)]);
        }
        final v = _vessels.byId(VesselId(m.vesselId));
        if (v != null) {
          final (ve, vn) = CombatPhase.localOf(city, q.rotate(v.state.position));
          marks.add(MissileMark(at(ve, vn), 6, 'Salvo', craft: true));
        }
      }
      final pv = _missilePreview();
      final plan = pv?.plan;
      if (pv != null && plan != null && pv.home.body.id == city.body.id) {
        final (ae, an) = CombatPhase.localOf(city, plan.aimBF);
        final (se, sn) = CombatPhase.localOf(city, plan.siloBF);
        marks.add(MissileMark(at(ae, an), cepPx, plan.why == null ? 'Strike here' : 'Out of reach', preview: true));
        if (plan.why == null) arcs.add([at(se, sn), at(ae, an)]);
      }
    }
    if (marks.isNotEmpty || arcs.isNotEmpty) {
      layers.add(CustomPaint(size: size, painter: MissileOverlayPainter(marks, arcs)));
    }
    return Stack(children: layers);
  }
}
