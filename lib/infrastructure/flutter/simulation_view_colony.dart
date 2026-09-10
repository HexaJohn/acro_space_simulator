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

  /// Whether the camera is the city-builder's own: the freecam anchor parked
  /// over a colony, rather than a walker's eye or a free flight.
  bool get _cityCamera => widget.cityMode && _freecam && !_walkMode;

  /// Eye distance from the colony's centre point, metres.
  ///
  /// Sized to the STARTER KIT, not to the streets: the crossroads is 600 m
  /// across but the pad and the solar field push the opening position out to
  /// about a kilometre and a half corner to corner, and at 900 m both of them
  /// hung off the edge of the frame. Only a starting pose — the wheel zooms
  /// and WASD flies from here.
  static const double cityCameraRangeM = 1800;

  /// Camera tilt above the horizon, radians.
  ///
  /// 55 degrees, and the number is set by the GROUND rather than by taste. A
  /// shallower rig frames more skyline, which is what gives a colony a sense
  /// of scale — but the pivot sits ON the terrain, and on any site with relief
  /// worth looking at, the ridge between the eye and the pivot rises into the
  /// line of sight: at 30 degrees the opening shot of the default site is a
  /// hillside with the town hidden behind it. This clears the near ground on
  /// rolling terrain and still reads as a city view rather than a map. Only a
  /// starting pose — the middle mouse button orbits from here.
  static const double cityCameraElevation = 0.96;

  /// How far the camera may tilt, radians above the local horizon.
  ///
  /// The floor keeps the eye out of the hill it is orbiting (the pivot sits ON
  /// the ground, so a boom swung below the horizon ends up underneath it); the
  /// ceiling stops short of straight down, where azimuth degenerates into a
  /// spin about nothing and the drag direction becomes unreadable.
  static const double cityCameraMinElevation = 0.12;
  static const double cityCameraMaxElevation = 1.45;

  /// Metres per second of pan, per metre of camera range.
  ///
  /// Proportional so the ground moves at a constant rate ON SCREEN: a fixed
  /// speed crawls when zoomed out to the whole colony and rockets when zoomed
  /// into one lot.
  static const double cityPanRate = 0.9;

  /// Slide the camera's pivot across the ground.
  ///
  /// The pivot stays ON the terrain — re-sampled at the point panned to — so
  /// the view rides up over a ridge instead of burrowing into it, and a zoom
  /// always converges on ground rather than on a point in the air above (or
  /// below) it.
  ///
  /// Directions come from the CAMERA, projected onto the local tangent plane,
  /// so W is "away from the viewer across the ground" and D is "right on
  /// screen" at any azimuth. Looking almost straight down there is no forward
  /// left to project, and screen-up stands in for it.
  void _panCityCamera(double fwd, double strafe, double frameDt) {
    final city = _editingCity;
    if (city == null || _freecamRelLocal.length < 1e-3) return;
    final up = _freecamRelLocal.normalized;
    final bodyFrame = _refBodyQuat().conjugate;
    final cam = _camera;

    Vector3 flatten(Vector3 v) {
      final t = v - up * v.dot(up);
      return t.length < 1e-6 ? Vector3.zero : t.normalized;
    }

    var ahead = flatten(bodyFrame.rotate(cam.forward));
    if (ahead == Vector3.zero) ahead = flatten(bodyFrame.rotate(cam.up));
    final right = flatten(bodyFrame.rotate(cam.right));
    if (ahead == Vector3.zero && right == Vector3.zero) return;

    final boost = _keysDown.contains(LogicalKeyboardKey.shiftLeft) ? 4.0 : 1.0;
    final speed = math.max(_range, 20.0) * cityPanRate * boost;
    final dt = frameDt.clamp(0.0, 0.1);
    final moved =
        _freecamRelLocal + (ahead * fwd + right * strafe) * (speed * dt);

    // Back onto the ground under wherever that landed. No setState: this runs
    // inside the frame, which repaints on its own once the tick is done.
    final dir = moved.normalized;
    _freecamRelLocal = dir * _cityGroundRadius(city, dir);
  }

  /// Ground radius (m from the body's centre) along a body-fixed direction,
  /// terrain edits included — the same ground the roads are graded into.
  double _cityGroundRadius(CitySim city, Vector3 dirBF) {
    final body = _universe.current().body(city.body.id);
    if (body == null) return _freecamRelLocal.length;
    final field = body.terrainFieldWith(_terrainEdits.forBody(body.id));
    return field?.groundRadiusAt(dirBF.x, dirBF.y, dirBF.z) ?? body.radius;
  }

  /// Park the camera over [city]'s crossroads, looking down at it.
  ///
  /// Uses the FREECAM anchor rather than a body or vessel lock: the anchor is
  /// body-fixed, so the town stays under the camera as the planet turns, and
  /// the freecam's WASD flight is exactly the pan a city builder wants. The
  /// anchor sits ON the ground (the eye is pushed out by the camera range),
  /// which also makes it the local vertical the gimbal reads.
  /// How much further than a walker's world the city camera sees props.
  ///
  /// The camera sits a kilometre and a half back and looks across the whole
  /// colony; at 1.0 the forest is an island around the pivot with bare ground
  /// past it. Cost grows with the AREA covered, so this is as far as it goes
  /// without a measurement to back it.
  static const double cityScatterRangeScale = 2.5;

  /// Prop cut-off altitude for the city rig, metres.
  ///
  /// The shipped 4 km is an eye height a walker or a lander reaches only on
  /// the way somewhere. A city camera zoomed out to see a district is already
  /// past it, and props vanishing wholesale at a zoom step reads as a bug.
  static const double cityScatterMaxAltitudeM = 9000;

  void _openCityCamera(CitySim city) {
    _freecamRef = city.body.id;
    _freecamRelLocal = city.localToBodyFixed(
      const Vec2(0, 0),
      bodyRadiusM: _colonySiteRadius(city),
    );
    _freecam = true;
    _craftCam = false;
    _walkMode = false;
    _upMode = CameraUpMode.gravity;
    _view = _view.copyWith(azimuth: 0, elevation: cityCameraElevation, roll: 0);
    _range = cityCameraRangeM;
  }

  /// Local time the mode opens at, as an angle before the site's local noon.
  ///
  /// Not noon itself: an overhead sun flattens a city — no shadows to read the
  /// massing by, and every facade the same brightness. Thirty degrees back is
  /// mid-morning, which lights one face of everything and lays the shadows
  /// across the streets.
  static const double cityOpenSunAngle = -math.pi / 6;

  /// Diagnostics for the city turntable, or null when it is not the camera.
  ///
  /// `pivotAltM` is the height of the pivot above the ground UNDER IT: zero is
  /// correct, negative is buried, positive is floating. `pivotOffsetM` is how
  /// far it has been panned from the colony's own site.
  Map<String, Object?>? _cityCameraStatus() {
    final city = _editingCity;
    if (!widget.cityMode || city == null) return null;
    if (_freecamRelLocal.length < 1e-3) return null;
    final dir = _freecamRelLocal.normalized;
    final ground = _cityGroundRadius(city, dir);
    final site = city.localToBodyFixed(const Vec2(0, 0),
        bodyRadiusM: _freecamRelLocal.length);
    final d = _freecamRelLocal - site;
    final up = dir;
    return {
      'cityPivotAltM': _freecamRelLocal.length - ground,
      'cityPivotOffsetM': (d - up * d.dot(up)).length,
      'cityRangeM': _range,
      'cityElevationRad': _view.elevation,
    };
  }

  /// Everything the city camera can only settle once the world has a frame.
  ///
  /// Two jobs, both one-shot, both needing state that does not exist at
  /// `initState`:
  ///
  /// * **Seat the pivot on the real ground.** The opening pose is built from
  ///   `_colonySiteRadius`, and until the terrain field for the body is
  ///   resident that answers with the DATUM. A pivot at sea level under a town
  ///   at 480 m (or the 1,600 m plateau the default used to sit on) is buried,
  ///   and a turntable aimed at a buried point misses: looking steeply down it
  ///   still frames the town, but at a playable tilt the aim lands short by
  ///   roughly the burial depth over the tangent — which is how a colony ends
  ///   up just off the edge of its own opening shot.
  /// * **Turn the world into daylight.**
  void _settleCityOpen() {
    final city = _editingCity;
    if (city == null) return;
    if (_freecamRelLocal.length > 1e-3) {
      final dir = _freecamRelLocal.normalized;
      _freecamRelLocal = dir * _cityGroundRadius(city, dir);
    }
    _alignCityDaylight();
  }

  /// Turn the world forward until the colony's mid-morning.
  ///
  /// A colony founded at epoch zero opens at whatever local time its longitude
  /// happens to give — night, half the time, which is a black screen and a
  /// solar farm producing nothing. Rather than fake the sun (the city studio
  /// rotates the star in its own snapshot, which is a DISPLAY trick), this
  /// advances the CLOCK: the planet really has turned, so daylight, solar
  /// output and shadows all agree.
  ///
  /// Only ever forward, and only once, at open — before anything is in flight.
  /// A jump this size would move a craft along its orbit, which is exactly why
  /// it does not run in a flight.
  void _alignCityDaylight() {
    final city = _editingCity;
    final snap = _sceneWorld;
    if (city == null || snap == null) return;
    final body = _universe.current().body(city.body.id);
    final b = snap.bodies[city.body.id.value];
    final star = snap.bodies[_universe.current().rootStar.value];
    // Nothing to wait for on a body that does not turn (or a frame that has
    // not resolved yet): claim the alignment so it stops being retried.
    if (body == null || b == null || star == null ||
        body.angularVelocity.abs() < 1e-12) {
      _cityDayAligned = true;
      return;
    }
    final axis = body.spinAxisInertial;
    final toStar =
        Vector3(star.px, star.py, star.pz) - Vector3(b.px, b.py, b.pz);
    // Both directions projected onto the equatorial plane: only the component
    // the spin can change is worth solving for.
    final sunP = toStar - axis * toStar.dot(axis);
    final siteWorld = _refBodyQuat().rotate(_freecamRelLocal);
    final siteP = siteWorld - axis * siteWorld.dot(axis);
    if (sunP.length < 1e-6 || siteP.length < 1e-6) {
      _cityDayAligned = true; // a pole site, or the star overhead: no meridian
      return;
    }
    final a = sunP.normalized, c = siteP.normalized;
    // Signed angle from the sun's meridian to the site's, about the spin axis.
    // Zero is local noon; the site advances through it as the body turns.
    final theta = math.atan2(axis.dot(a.cross(c)), a.dot(c));
    var turn = cityOpenSunAngle - theta;
    // Wrap into the direction the body actually spins, so the answer is always
    // a WAIT and never a rewind.
    final w = body.angularVelocity;
    if (w > 0) {
      while (turn < 0) {
        turn += 2 * math.pi;
      }
    } else {
      while (turn > 0) {
        turn -= 2 * math.pi;
      }
    }
    _clock.epoch = _clock.epoch + turn / w;
    _cityDayAligned = true;
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
    // Free build: the slope is not asked, and neither is the field — the
    // five samples below were the cost of every candidate (see
    // [CityEditController.ignoreTerrain]).
    if (_cityEdit.ignoreTerrain) return 0;
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
    if (_cityEdit.ignoreTerrain) {
      // Free build: no grade to read, and the ghost rides the site's datum
      // rather than the field — one ground sample per preview instead of
      // one per eight metres of route, each composing every brush in town.
      _cityEdit.previewGradePct = null;
      CityNodes.pendingRouteBad = false;
      CityNodes.pendingWidthM = _cityEdit.roadClass.width;
      final datum = _colonySiteRadius(city);
      CityNodes.pendingRouteBF = [
        for (final p in samples) city.localToBodyFixed(p, bodyRadiusM: datum),
      ];
      return;
    }
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
  ///
  /// Cached against the colony and its edit count: the picker asks on every
  /// mouse move, and a sample of a graded town's field — every brush in it
  /// composed — is ~16 ms, which was a stall on every hover before anything
  /// else ran. The ground under the site moves only when an edit lands.
  double _colonySiteRadius(CitySim city) {
    final body = _universe.current().body(city.body.id);
    if (body == null) return 0;
    final edits = _terrainEdits.forBody(body.id);
    final editCount = edits?.length ?? 0;
    // The site, not just the colony: ids are reused when a colony is
    // removed and another founded, and the new one may stand elsewhere.
    final site = '${city.id}@${city.cityLat},${city.cityLon}';
    if (_siteRadiusCity == site && _siteRadiusEdits == editCount) {
      return _siteRadiusM;
    }
    final lat = city.cityLat * math.pi / 180.0;
    final lon = city.cityLon * math.pi / 180.0;
    final dir = Vector3(math.cos(lat) * math.cos(lon),
        math.cos(lat) * math.sin(lon), math.sin(lat));
    final field = body.terrainFieldWith(edits);
    final r = field?.groundRadiusAt(dir.x, dir.y, dir.z) ?? body.radius;
    _siteRadiusCity = site;
    _siteRadiusEdits = editCount;
    _siteRadiusM = r;
    return r;
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
        // Graded either way: free build drops the slope gate, not the pad
        // (see [CityEditController.ignoreTerrain]).
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
