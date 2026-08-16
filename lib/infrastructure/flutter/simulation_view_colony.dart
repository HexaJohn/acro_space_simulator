// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Founding and editing a colony from the cockpit.
//
// Grouped out of the flight view because it is a whole feature that happens to
// need the camera and the frame: founding, siting, ground picking, and the
// in-world editor's tap handling. Kept as an extension in the same library so
// it can still read the focus, the clock and the scene snapshot directly — the
// alternative, threading those through a constructor, would be a bigger change
// than the split is worth today.
part of 'simulation_view.dart';

extension SimulationViewColony on _SimulationViewState {
  /// Found a colony where the landed [v] sits.
  ///
  /// The colony is registered with the WORLD, not handed to a screen. It then
  /// advances on the same tick as the craft that founded it and appears in the
  /// scene under the ship — which is the whole point of the merge. Opening the
  /// builder afterwards is a VIEW of that live colony, not a second one.
  void _foundColony(Vessel v) {
    final system = _universe.current();
    final body = system.body(v.dominantBody);
    if (body == null) return;

    // The craft's surface point, in degrees — in the BODY-FIXED frame.
    //
    // `state.position` is body-centred INERTIAL, and a colony's lat/lon is
    // body-fixed by definition: the ground turns under the inertial frame.
    // Reading the longitude straight off the inertial vector planted the town
    // at whatever longitude happened to face that direction at epoch zero,
    // which on Earth is up to half a planet from the craft that founded it.
    // Everything downstream then agreed with each other and disagreed with
    // reality — the buildings rendered (far away, so at block detail) and every
    // tap resolved to a cell outside the map, so nothing could be placed.
    final bf = body.orientationAt(_clock.epoch).conjugate.rotate(v.state.position);
    final dir = bf.normalized;
    final latDeg = math.asin(dir.z.clamp(-1.0, 1.0)) * 180 / math.pi;
    final lonDeg = math.atan2(dir.y, dir.x) * 180 / math.pi;

    // One colony per site: founding twice on the same spot should open the
    // existing town, not stack a second one on top of it.
    final existing = _colonyNear(body.id.value, latDeg, lonDeg);
    final colony = existing ??
        CitySim.found(
          CityConfig(
            bodyId: body.id.value,
            latitude: latDeg,
            longitude: lonDeg,
          ),
          bodies: system.all.where((b) => !b.isStar).toList(),
          id: 'colony-${_cities.all().length + 1}',
          name: '${body.name} Colony',
        );
    if (existing == null) _cities.add(colony);

    // Edit it IN THE WORLD. The 2D builder stays one button away for the
    // panels that have no 3D equivalent — politics, budgets, stockpiles.
    rebuild(() {
      _editingCity = colony;
      _cityEdit.set(CityEditTool.zone);
    });
  }

  /// The colony already sited within ~5 km of this point, if any.
  CitySim? _colonyNear(String bodyId, double latDeg, double lonDeg) {
    for (final c in _cities.all()) {
      if (c.body.id.value != bodyId) continue;
      final dLat = (c.cityLat - latDeg).abs();
      final dLon = (c.cityLon - lonDeg).abs();
      if (dLat < 0.05 && dLon < 0.05) return c;
    }
    return null;
  }

  /// The world point the scene's floating origin is centred on.
  ///
  /// Mirrors `SceneSync`'s own rule rather than approximating it: the camera
  /// reports its eye RELATIVE to this point, so any disagreement between the
  /// two would offset every pick by the difference.
  Vector3? _focusWorldForPick(WorldSnapshot snap) {
    if (_freecam) return _freecamWorld;
    final vid = _focusVessel?.value;
    if (vid != null) {
      final v = snap.vessels[vid];
      if (v != null) {
        final b = snap.bodies[v.body];
        return b == null
            ? Vector3(v.px, v.py, v.pz)
            : Vector3(b.px + v.px, b.py + v.py, b.pz + v.pz);
      }
    }
    final bid = _focusBody?.value;
    if (bid != null) {
      final b = snap.bodies[bid];
      if (b != null) return Vector3(b.px, b.py, b.pz);
    }
    return null;
  }

  /// Apply the held city tool to the ground under [local].
  ///
  /// The tap resolves to a real point on the planet — the same ground the craft
  /// is standing on — rather than to a cell in a separate top-down map. Body
  /// transforms come from the SNAPSHOT the renderer drew, so the cell the
  /// player clicks is the cell they saw.
  /// Move the ground cursor without editing anything.
  ///
  /// Split from [_editCityAt] because hover fires on every mouse move: it must
  /// never apply a tool, and it must not call setState — the cursor lives in
  /// the renderer, so moving it costs one static write and no rebuild.
  void _hoverCityAt(Offset local) {
    final hit = _pickCityGround(local);
    final city = _editingCity;
    if (hit == null || city == null) {
      CityNodes.cursorBF = null;
      return;
    }
    CityNodes.cursorBF = hit.bodyFixed;
    CityNodes.cursorBodyId = city.body.id.value;
    CityNodes.cursorSizeM = _cityEdit.tool == CityEditTool.utility
        ? _cityEdit.selectedUtil.siteMetres(cellM: CitySim.cellM).width
        : CitySim.cellM;
  }

  /// The ground point under [local], or null if the tap missed the planet.
  SurfaceHit? _pickCityGround(Offset local) {
    final city = _editingCity;
    final snap = _sceneWorld;
    if (city == null || snap == null) return null;
    final body = snap.bodies[city.body.id.value];
    final focus = _focusWorldForPick(snap);
    if (body == null || focus == null) return null;
    return const SurfacePicker().pick(
      tapX: local.dx,
      tapY: local.dy,
      viewportW: _screenW,
      viewportH: _screenH,
      camera: _camera,
      focusWorld: focus,
      bodyWorld: Vector3(body.px, body.py, body.pz),
      bodyOrientation: Quaternion(body.qw, body.qx, body.qy, body.qz),
      groundRadiusM: body.radius,
      colonyLatDeg: city.cityLat,
      colonyLonDeg: city.cityLon,
    );
  }

  void _editCityAt(Offset local) {
    final city = _editingCity;
    if (city == null) return;
    final hit = _pickCityGround(local);
    if (hit == null) return;
    _hoverCityAt(local);

    final cell = const SurfacePicker().cellAt(
      east: hit.east,
      north: hit.north,
      grid: city.grid,
      cellM: CitySim.cellM,
    );
    if (cell == null) return;
    rebuild(() {
      _cityEdit.setHover(cell);
      _cityEdit.applyTo(city, cell);
    });
  }

  /// Open the builder as a view onto a live colony.
  ///
  /// `driveLocally: false` matters: the authoritative tick is already
  /// advancing this colony, and letting the screen advance it too would run
  /// the city at double speed for as long as it was open.
  void _openCity(CitySim colony) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CityBuilderScreen(sim: colony, driveLocally: false),
      ),
    );
  }
}
