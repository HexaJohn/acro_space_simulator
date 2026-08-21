// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Founding, editing and RUNNING a colony from the cockpit.
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

    // Edit it IN THE WORLD — all of it. There is no longer a button out to a
    // flat map: the readouts that used to live there (status, politics,
    // stockpile, world) are drawers on the in-world toolbar, and everything you
    // can do to a building is on the building itself.
    rebuild(() {
      _editingCity = colony;
      _cityEdit.groundAt = (p) => _groundAtLocal(colony, p);
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
    // The ghost is the site the placement will actually stake out — width AND
    // depth, because a starport is 1800 x 2600, not a square — and it turns
    // red where that site cannot go.
    final held = _cityEdit.selectedUtil;
    if (_cityEdit.tool == CityEditTool.utility) {
      final site = held.siteMetres(cellM: CitySim.cellM);
      CityNodes.cursorSizeM = site.width;
      CityNodes.cursorDepthM = site.depth;
      CityNodes.cursorBad = held.claimsOwnSite &&
          _siteStatusAt(city, held, Vec2(hit.east, hit.north)) != 0;
    } else {
      CityNodes.cursorSizeM = CitySim.cellM;
      CityNodes.cursorDepthM = CitySim.cellM;
      CityNodes.cursorBad = false;
    }
    _syncSiteHeatmap(city, Vec2(hit.east, hit.north));
    // While a road is being drawn, the ghost follows the mouse: the next
    // segment is visible BEFORE it is clicked, which is the whole difference
    // between placing a road and discovering one.
    if (_cityEdit.tool == CityEditTool.roadSpline &&
        _cityEdit.pending.isNotEmpty) {
      _syncRoutePreview(city, hover: Vec2(hit.east, hit.north));
    }
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
      // The REAL ground at the site, matching what the snapshot placed the
      // colony on. Picking against the datum sphere while the buildings stand
      // on terrain puts the cursor under the hill they are on.
      groundRadiusM: _colonySiteRadius(city),
      colonyLatDeg: city.cityLat,
      colonyLonDeg: city.cityLon,
    );
  }

  /// Ground radius under a colony-local point, terrain edits included — so
  /// the preview and the grade check both read the same ground a committed
  /// road would be graded against.
  double _groundAtLocal(CitySim city, Vec2 p) {
    final body = _universe.current().body(city.body.id);
    if (body == null) return 0;
    final dir = city
        .localToBodyFixed(p, bodyRadiusM: body.radius)
        .normalized;
    final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
    return field?.groundRadiusAt(dir.x, dir.y, dir.z) ?? body.radius;
  }

  /// Grade a claimed site may sit on, as relief across its own span.
  ///
  /// A pad cuts and fills to level its plot, so what makes ground unsuitable
  /// is not steepness in the abstract but how much earth the cut would move
  /// relative to how big the site is. 10% across the short side is a serious
  /// terrace and about the limit of what reads as built rather than gouged.
  static const double _siteMaxGradePct = 10.0;

  /// Can [spec] stand centred on [centre]? 0 placeable, 1 too steep, 2 blocked.
  ///
  /// Layout validity is the colony's own question and lives in the domain; the
  /// GRADE is this layer's, because only the view holds the terrain field.
  int _siteStatusAt(CitySim city, CityBuildingSpec spec, Vec2 centre) {
    if (city.siteBlockedReason(spec, centre) != null) return 2;
    final poly = city.siteFootprint(spec, centre);
    var lo = double.infinity, hi = -double.infinity;
    for (final v in [...poly, centre]) {
      final r = _groundAtLocal(city, v);
      if (r < lo) lo = r;
      if (r > hi) hi = r;
    }
    final site = spec.siteMetres(cellM: CitySim.cellM);
    final span = math.min(site.width, site.depth);
    if (span <= 0) return 0;
    return (hi - lo) / span * 100 > _siteMaxGradePct ? 1 : 0;
  }

  /// Paint where the held installation could go.
  ///
  /// Only for the specs that bring their own plot — an ordinary building takes
  /// whatever lot you tap, so there is nothing to survey. Recomputed when the
  /// cursor has moved a cell rather than every frame: each sample runs the
  /// full placement test, and a hundred of them per mouse-move would be felt.
  void _syncSiteHeatmap(CitySim city, Vec2 centre) {
    final spec = _cityEdit.selectedUtil;
    if (_cityEdit.tool != CityEditTool.utility || !spec.claimsOwnSite) {
      CityNodes.heatBF = const [];
      CityNodes.heatKind = const [];
      CityNodes.heatCellM = 0;
      _heatAt = null;
      return;
    }
    final site = spec.siteMetres(cellM: CitySim.cellM);
    final cell = math.max(24.0, math.min(site.width, site.depth) / 2);
    final last = _heatAt;
    if (last != null &&
        _heatSpec == spec.label &&
        (last - centre).length < cell / 2) {
      return; // still describing the same ground
    }
    _heatAt = centre;
    _heatSpec = spec.label;

    const half = 4; // 9 x 9 candidates around the cursor
    final ground = _colonySiteRadius(city);
    final pts = <Vector3>[];
    final kinds = <int>[];
    for (var iy = -half; iy <= half; iy++) {
      for (var ix = -half; ix <= half; ix++) {
        final p = Vec2(centre.e + ix * cell, centre.n + iy * cell);
        kinds.add(_siteStatusAt(city, spec, p));
        pts.add(city.localToBodyFixed(p, bodyRadiusM: ground));
      }
    }
    CityNodes.heatBF = pts;
    CityNodes.heatKind = kinds;
    CityNodes.heatCellM = cell;
  }

  /// Keep the renderer's editor ghosts in step with the editor's own state.
  ///
  /// Committing or discarding a spline empties `pending` but cannot clear the
  /// ghost itself — the toolbar that does both knows nothing about the scene,
  /// so a finished road went on haunting the view. Listening for the change is
  /// the one hook both paths share.
  void _onCityEditChanged() {
    final city = _editingCity;
    // A different tool or a different building means a different survey.
    _heatAt = null;
    if (city == null) {
      CityNodes.heatBF = const [];
      CityNodes.heatKind = const [];
      CityNodes.heatCellM = 0;
    }
    if (city == null || _cityEdit.pending.isEmpty) {
      CityNodes.pendingRouteBF = const [];
      CityNodes.pendingRouteBad = false;
      _cityEdit.previewGradePct = null;
      return;
    }
    _syncRoutePreview(city);
  }

  /// Push the in-progress road into the renderer: the true SPLINE through the
  /// placed points (plus the hover point as a ghost segment), draped point by
  /// point on the real ground, red when the grade check refuses it.
  void _syncRoutePreview(CitySim city, {Vec2? hover}) {
    final body = _universe.current().body(city.body.id);
    if (body == null) return;
    final controls = [
      ..._cityEdit.pending,
      if (hover != null) hover,
    ];
    if (controls.length < 2) {
      CityNodes.pendingRouteBF = const [];
      CityNodes.pendingRouteBad = false;
      _cityEdit.previewGradePct = null;
      return;
    }
    final samples = RoadSpline(
      id: 'preview',
      controls: controls,
      roadClass: _cityEdit.roadClass,
    ).sample(stepM: 8);
    final grade = RoadGradeCheck.of(
        samples, (p) => _groundAtLocal(city, p), _cityEdit.roadClass);
    _cityEdit.previewGradePct = grade.maxPct;
    CityNodes.pendingRouteBad = !grade.ok;
    CityNodes.pendingWidthM = _cityEdit.roadClass.width;
    CityNodes.pendingRouteBF = [
      for (final p in samples)
        city.localToBodyFixed(p, bodyRadiusM: _groundAtLocal(city, p)),
    ];
  }

  /// A pad centre in body-fixed metres, standing on the real ground.
  Vector3 _padPointBF(CitySim city, Vec2 local) {
    final body = _universe.current().body(city.body.id);
    final dir = city
        .localToBodyFixed(local, bodyRadiusM: body?.radius ?? 0)
        .normalized;
    final field = body?.terrainFieldWith(_terrainEdits.forBody(body.id));
    final ground = field?.groundRadiusAt(dir.x, dir.y, dir.z) ??
        (body?.radius ?? 0);
    return dir * ground;
  }

  /// Ground radius under [city]'s site, or the body datum if it has no terrain.
  double _colonySiteRadius(CitySim city) {
    final body = _universe.current().body(city.body.id);
    if (body == null) return 0;
    final lat = city.cityLat * math.pi / 180.0;
    final lon = city.cityLon * math.pi / 180.0;
    final dir = Vector3(math.cos(lat) * math.cos(lon),
        math.cos(lat) * math.sin(lon), math.sin(lat));
    final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
    return field?.groundRadiusAt(dir.x, dir.y, dir.z) ?? body.radius;
  }

  void _editCityAt(Offset local) {
    final city = _editingCity;
    if (city == null) return;
    final hit = _pickCityGround(local);
    if (hit == null) return;
    _hoverCityAt(local);

    // Road drawing works in continuous metres — no cell involved. Points
    // near an existing road SNAP onto it, so drawing toward a street joins it
    // (and the commit splits it there: a junction).
    if (_cityEdit.tool == CityEditTool.roadSpline) {
      var p = Vec2(hit.east, hit.north);
      final near = city.layout.nearestRoadPoint(p, withinM: 15);
      if (near != null) p = near.point;
      _cityEdit.addSplinePoint(p);
      _syncRoutePreview(city);
      return;
    }

    // A sprawling installation brings its OWN plot. No subdivided lot could
    // hold a 780 m solar farm, which is why the ghost and the placed building
    // used to disagree so wildly — the ghost drew the real site and placement
    // shrank it to whatever lot it landed on.
    final held = _cityEdit.selectedUtil;
    if (_cityEdit.tool == CityEditTool.utility && held.claimsOwnSite) {
      final centre = Vec2(hit.east, hit.north);
      rebuild(() {
        if (!city.unlocked(held)) {
          _cityEdit.blocked =
              '${held.label} needs ${held.unlockPop} population.';
          return;
        }
        final claimed = city.claimSite(held, centre);
        _cityEdit.blocked = claimed == null ? city.blocked : null;
      });
      return;
    }

    // Every other tool acts on the LOT under the tap.
    //
    // The in-flight editor is parcel-only. The cell grid is still the legacy
    // 2D builder's model, and still what the economy is keyed on, but nothing
    // new is created on it here — so a colony founded in flight is
    // parcel-native from the moment it exists.
    final lot = city.layout.parcelAt(Vec2(hit.east, hit.north));
    if (lot == null) {
      rebuild(() => _cityEdit.blocked =
          'No lot here — draw a road to subdivide the ground first.');
      return;
    }
    rebuild(() => _cityEdit.applyToLot(city, lot.id));
  }

  /// The built site under [local], or null over bare ground.
  ///
  /// Runs on every hit test while the editor is open (see `_PickGate`), so it
  /// stays a ray pick plus one polygon scan — no allocation, no state.
  (String, CityBuildingSpec)? _siteUnder(Offset local) {
    final city = _editingCity;
    if (city == null) return null;
    final hit = _pickCityGround(local);
    if (hit == null) return null;
    final found = city.siteAt(Vec2(hit.east, hit.north));
    return found == null ? null : (found.$1, found.$3);
  }

  /// Open the action sheet for the building under [local].
  ///
  /// This is what the Look tool is FOR. It used to do nothing at all: tapping a
  /// spaceport you were standing in front of had no effect, and everything you
  /// could actually do with one lived behind a button that left the world.
  void _inspectCityAt(Offset local) {
    final city = _editingCity;
    final found = _siteUnder(local);
    if (city == null || found == null) return;
    showCitySiteMenu(
      context: context,
      sim: city,
      site: found.$1,
      spec: found.$2,
      onChanged: () => rebuild(() {}),
      hooks: _worldSiteHooks(city),
    );
  }

  /// The in-world host's contributions to the site sheet.
  ///
  /// No "pilot a landing" and no "launch in 3D sim": both exist to carry you
  /// from the flat map into the world, and you are already here. What replaces
  /// them is pad targeting — pointing the craft you are flying at this port.
  CitySiteHooks _worldSiteHooks(CitySim city) {
    final id = _focusVessel;
    final vessel = id == null ? null : _vessels.byId(id);
    final hint = vessel == null
        ? 'Lock the camera onto a craft first — guidance needs one to fly.'
        : vessel.dominantBody != city.body.id
            ? 'Your craft is not at ${city.body.name}.'
            : vessel.landed
                ? 'Already on the ground — lift off first.'
                : null;
    return CitySiteHooks(
      onOpenVab: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CraftAssemblyScreen(
            bodyId: city.body.id.value,
            launchSites: cityLaunchSites(city),
            latitude: city.cityLat,
            longitude: city.cityLon,
          ),
        ),
      ),
      onTargetPad: (site) => _targetPad(city, site),
      targetPadHint: hint,
    );
  }

  /// Aim the focused craft's landing guidance at [site]'s pad.
  ///
  /// The pad is stored BODY-FIXED, which is the whole reason this works from
  /// orbit: an inertial point would slide off the spaceport as the planet
  /// turned under the descent. From here the ordinary tick flies it down with
  /// the same law the colony's own shuttles use.
  void _targetPad(CitySim city, String site) {
    final id = _focusVessel;
    final vessel = id == null ? null : _vessels.byId(id);
    final parcel = city.siteParcel(site);
    if (vessel == null || parcel == null) return;
    // The pad stands on the GROUND, and the ground is not the datum sphere.
    // Aiming at the datum under a site 300 m up a hill points the descent
    // through the hillside: guidance reads several hundred metres of altitude
    // still in hand while the craft is already in the dirt. Take the radius at
    // the lot's own direction, not the colony centre's — a spaceport is large
    // enough to sit across a slope.
    final padBF = _padPointBF(city, parcel.centroid);
    rebuild(() {
      vessel.landingTarget = LandingTarget(
        bodyId: city.body.id.value,
        padBF: padBF,
        colonyId: city.id,
        site: site,
      );
      // Guidance and hand-flying are exclusive: leaving manual on would fight
      // the descent for the throttle every frame.
      _manualControl = false;
    });
  }
}

/// A hit-test gate: the pointer passes straight through unless [pick] says
/// there is something here to hit.
///
/// The Look tool must not swallow taps meant for the HUD underneath it, but a
/// gesture arena picks a winner before anyone knows WHAT was tapped. Deciding
/// in `hitTest` — where the position is known and the arena has not formed yet
/// — is the only place the answer can be right.
class _PickGate extends SingleChildRenderObjectWidget {
  const _PickGate({required this.pick, required Widget super.child});

  final bool Function(Offset local) pick;

  @override
  _RenderPickGate createRenderObject(BuildContext context) =>
      _RenderPickGate(pick);

  @override
  void updateRenderObject(BuildContext context, _RenderPickGate renderObject) {
    renderObject.pick = pick;
  }
}

class _RenderPickGate extends RenderProxyBox {
  _RenderPickGate(this.pick);

  bool Function(Offset local) pick;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      pick(position) && super.hitTest(result, position: position);
}
