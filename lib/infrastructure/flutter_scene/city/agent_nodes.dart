// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

part of 'city_nodes.dart';

// The agents' draws (docs/plans/agent-traffic.md §13.8, E20): an agent
// colony's vehicles, placed by its [AgentTrafficPass], and its live signal
// heads — drawn by slots of their own beside the cosmetic traffic, never
// through it.
//
// A part of city_nodes.dart so it reaches the scene, the body roots and the
// vehicle meshes without widening their API; its state hangs off the
// CityNodes in an Expando, so all it costs that file is its hooks.
//
// - Every draw hangs under its body's root node, whose transform is the
//   anchor every pose is relative to. A turning planet moves them with the
//   root's one write, and when the roots go — the colony out of range, a
//   frame with no city, the nodes disposed — the draws go with them.
// - Independent of the cosmetic `traffic` toggle, which hides scenery, not
//   the simulation: [AgentTrafficPass.drawn] is the agents' own switch.
// - Near draws cast shadows; far ones do not.
// - A draw's instance count only grows, in steps of 64, so vehicles coming
//   and going move matrices in place rather than clearing the draw.
//
// The SITE cars (T4a, site-access.md §7.4) are drawn beside them, in the
// same models: a car inside a lot is on no road element, so its pose comes
// from the frame's own site columns — worked out by the capture off the
// plan the simulation drives and the heights R3 published for it — and a
// parked car from the stall pose of the plan its row names. No lot geometry
// is derived here, and nothing asks the ground (D19/D20).

/// Parked cars drawn per colony (§7.4's ceiling). They are not range-culled
/// in T4a: a lot car exists only where the agents manage the parking, which
/// E36 stage 1 keeps to the sites they actually run, so the draw is rewritten
/// when a car comes or goes and at no other time. T4b, which switches every
/// baked car off, adds the 1.5 km ring with the rest of that list.
const int _kParkedRenderCap = 1500;

/// The agent state of each [CityNodes].
final Expando<_AgentLayer> _agentLayers = Expando<_AgentLayer>('agentNodes');

/// One resident agent draw: a model, near or far, solid or glazing.
class _AgentSlot {
  _AgentSlot(this.node, this.mesh, this.parent, this.material);
  final fs.Node node;
  final fs.InstancedMesh mesh;

  /// The root it hangs under, and the material it was made with. A root
  /// made again, or the material cache reset, makes a new draw: the old one
  /// left with its root, or holds a material nothing binds any more.
  final fs.Node parent;
  final fs.Material material;

  /// Used this frame.
  bool touched = false;
}

/// Everything the agent draws keep between frames.
class _AgentLayer {
  final Map<String, _AgentSlot> slots = {};

  /// Per colony: its pose pass (and render clock), and its signal heads.
  final Map<String, AgentTrafficPass> passes = {};
  final Map<String, SignalHeadLayer> heads = {};

  /// Per colony: the cars inside its sites and parked on its stalls.
  final Map<String, _SiteCarDraws> siteCars = {};

  /// The frame each colony was last seen in.
  final Map<String, int> seen = {};
  int frame = 0;

  /// The render clocks' wall time.
  final Stopwatch wall = Stopwatch()..start();
}

/// One colony's site-car poses: a buffer per model and band, with the same
/// growing high-water mark the road draws keep, so cars coming and going
/// move matrices in place rather than clearing the draw (§13.8).
class _SiteCarBatches {
  static const int _bucket = AgentDrawBatch.bucket;

  final List<TrafficBuffer?> poses =
      List<TrafficBuffer?>.filled(VehicleKind.values.length * 2, null);
  final Int32List highWater = Int32List(VehicleKind.values.length * 2);
  final Int32List live = Int32List(VehicleKind.values.length * 2);

  /// The buffer of [kind], [near] or far: `kind.index * 2 (+ 1)`.
  TrafficBuffer bufOf(VehicleKind kind, bool near) {
    final i = kind.index * 2 + (near ? 0 : 1);
    return poses[i] ??= TrafficBuffer();
  }

  void begin() {
    for (var i = 0; i < poses.length; i++) {
      poses[i]?.reset();
    }
    live.fillRange(0, live.length, 0);
  }

  /// Every buffer padded out to its high-water mark with zero-scale
  /// matrices, so a draw's instance count stands still.
  void finish() {
    for (var i = 0; i < poses.length; i++) {
      final b = poses[i];
      if (b == null) continue;
      live[i] = b.count;
      if (b.count == 0) continue;
      final want = (b.count + _bucket - 1) ~/ _bucket * _bucket;
      if (want > highWater[i]) highWater[i] = want;
      while (b.count < highWater[i]) {
        b.next().setZero();
      }
    }
  }

  void resetHighWater() => highWater.fillRange(0, highWater.length, 0);
}

/// What one colony's site cars keep between frames.
class _SiteCarDraws {
  /// The cars inside its sites: rewritten every frame, because they move.
  final _SiteCarBatches vehicles = _SiteCarBatches();

  /// The cars parked on its stalls: rewritten only when a car came or went,
  /// the site geometry moved, or the anchor did (§7.4) — nothing else can
  /// change where a parked car stands.
  final _SiteCarBatches parked = _SiteCarBatches();
  Object? parkedFrom;
  Object? parkedSites;
  Vector3? parkedAnchor;

  void dropHighWater() {
    vehicles.resetHighWater();
    parked.resetHighWater();
    parkedFrom = null;
    parkedSites = null;
    parkedAnchor = null;
  }
}

/// Writes into [m] the instance matrix of a car whose centre stands at
/// colony-local ([e], [n]), [up] metres above [sf]'s datum, its nose along
/// ([dirE], [dirN]) — the pose the capture published — relative to
/// [anchorBF]. False when the basis is degenerate.
///
/// The basis is the road pass's: up is the radial at the car, side is
/// forward × up, and up is taken again as side × forward, so the car pitches
/// with the ground it stands on and the matrix is never mirrored.
bool _writeSiteCarPose(vm.Matrix4 m, CitySiteFrame sf, Vector3 anchorBF,
    double e, double n, double up, double dirE, double dirN) {
  final r = sf.datumRadiusM + up;
  final px = sf.up.x * r + sf.east.x * e + sf.north.x * n;
  final py = sf.up.y * r + sf.east.y * e + sf.north.y * n;
  final pz = sf.up.z * r + sf.east.z * e + sf.north.z * n;
  final pl = math.sqrt(px * px + py * py + pz * pz);
  if (pl == 0) return false;
  final ux = px / pl, uy = py / pl, uz = pz / pl;
  var fx = sf.east.x * dirE + sf.north.x * dirN;
  var fy = sf.east.y * dirE + sf.north.y * dirN;
  var fz = sf.east.z * dirE + sf.north.z * dirN;
  final fl = math.sqrt(fx * fx + fy * fy + fz * fz);
  if (fl < 1e-9) return false;
  fx /= fl;
  fy /= fl;
  fz /= fl;
  var sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
  final sl = math.sqrt(sx * sx + sy * sy + sz * sz);
  if (sl < 1e-9) return false;
  sx /= sl;
  sy /= sl;
  sz /= sl;
  final bx = sy * fz - sz * fy, by = sz * fx - sx * fz, bz = sx * fy - sy * fx;
  TrafficRoad.writePose(m, px - anchorBF.x, py - anchorBF.y, pz - anchorBF.z,
      sx, sy, sz, fx, fy, fz, bx, by, bz);
  return true;
}

extension _AgentNodes on CityNodes {
  _AgentLayer get _agentLayer => _agentLayers[this] ??= _AgentLayer();

  /// The vehicles of every agent colony in [snap]. Runs after the cosmetic
  /// traffic, whatever its toggle says.
  void _syncAgents(WorldSnapshot snap, FloatingOrigin origin,
      Map<String, bool> moved, Vector3 focusWorld) {
    final sw = Stopwatch()..start();
    final layer = _agentLayer;
    if (snap.cityTraffic.isEmpty) {
      if (layer.passes.isNotEmpty || layer.slots.isNotEmpty) {
        _dropAgents(layer);
      }
      return;
    }
    final frame = ++layer.frame;
    for (final slot in layer.slots.values) {
      slot.touched = false;
    }
    final wallS = layer.wall.elapsedMicroseconds / 1e6;
    var placed = 0;
    for (final f in snap.cityTraffic) {
      layer.seen[f.colonyId] = frame;
      final pass = layer.passes.putIfAbsent(f.colonyId, AgentTrafficPass.new);
      final root = _roots[f.bodyId];
      final body = snap.bodies[f.bodyId];
      if (root == null || body == null || !AgentTrafficPass.drawn) {
        // Not drawn, but the clock keeps time: the signal heads read it.
        pass.clock.advance(f.agents, wallS, warp: AgentTrafficPass.simWarp);
        continue;
      }
      final focusBF = CityNodes.focusInBodyFrame(
          focusWorld,
          Vector3(body.px, body.py, body.pz),
          Quaternion(body.qw, body.qx, body.qy, body.qz));
      placed += pass.place(f, root.anchorBF, focusBF, wallNowS: wallS);
      for (final b in pass.batches) {
        if (b == null || b.live == 0) continue;
        final mesh = _vehicleMesh(b.kind);
        final band = b.near ? 'near' : 'far';
        final key = '${f.bodyId}/agent/${f.colonyId}/${b.kind.name}/$band';
        _agentDraw(layer, '$key/solid', root.node, mesh.solid,
            CityMaterials.facade, b.poses, b.near);
        _agentDraw(layer, '$key/glazing', root.node, mesh.glazing,
            CityMaterials.glazing, b.poses, b.near);
      }
      // The cars inside the colony's sites, and the ones parked on its
      // stalls: the same models, placed off the site frame rather than the
      // road geometry (§7.4). Here rather than in _syncAgentExtras because
      // this is where the focus is, and the bands are the same bands.
      final draws =
          layer.siteCars.putIfAbsent(f.colonyId, _SiteCarDraws.new);
      placed += _placeSiteCars(f, root.anchorBF, focusBF, draws);
      for (final batches in [draws.vehicles, draws.parked]) {
        final what = identical(batches, draws.parked) ? 'parked' : 'site';
        for (var i = 0; i < batches.poses.length; i++) {
          final poses = batches.poses[i];
          if (poses == null || batches.live[i] == 0) continue;
          final kind = VehicleKind.values[i >> 1];
          final near = i.isEven;
          final mesh = _vehicleMesh(kind);
          final band = near ? 'near' : 'far';
          final key =
              '${f.bodyId}/agent/${f.colonyId}/$what/${kind.name}/$band';
          _agentDraw(layer, '$key/solid', root.node, mesh.solid,
              CityMaterials.facade, poses, near);
          _agentDraw(layer, '$key/glazing', root.node, mesh.glazing,
              CityMaterials.glazing, poses, near);
        }
      }
    }
    // A draw nothing used this frame hides rather than dies: it will be
    // wanted again, and its instance count with it.
    for (final slot in layer.slots.values) {
      if (!slot.touched) slot.node.visible = false;
    }
    if (!AgentTrafficPass.drawn && layer.slots.isNotEmpty) {
      _dropAgentDraws(layer);
    }
    // A colony gone from the frame takes its pass and its clock with it.
    layer.passes.removeWhere((id, _) => layer.seen[id] != frame);
    layer.siteCars.removeWhere((id, _) => layer.seen[id] != frame);
    layer.seen.removeWhere((id, at) => at != frame);
    CityNodes.phaseCount['agents'] = placed;
    CityNodes.phaseMs['city.agents'] = sw.elapsedMicroseconds / 1000;
  }

  /// What the agents draw beyond their vehicles: the live signal heads.
  /// Runs after the road overlay.
  void _syncAgentExtras(
      WorldSnapshot snap, FloatingOrigin origin, Map<String, bool> moved) {
    final layer = _agentLayer;
    if (snap.cityTraffic.isEmpty) {
      _dropAgentHeads(layer);
      return;
    }
    for (final f in snap.cityTraffic) {
      final root = _roots[f.bodyId];
      final pass = layer.passes[f.colonyId];
      if (root == null || pass == null) continue;
      layer.heads
          .putIfAbsent(f.colonyId, SignalHeadLayer.new)
          .sync(root.node, f.net, f.geometry, root.anchorBF,
              pass.clock.renderTimeUs);
    }
    layer.heads.removeWhere((id, heads) {
      if (layer.seen[id] == layer.frame) return false;
      heads.drop();
      return true;
    });
  }

  /// The cars inside [f]'s sites and parked on its stalls, into [draws];
  /// returns how many were placed.
  ///
  /// Both are drawn only while their columns' site revision is the site
  /// frame's (§7.4): a site lane and a stall index mean something against
  /// one revision's plan and nothing against another's, so a frame whose
  /// two disagree keeps the parked draw exactly as it stands and leaves the
  /// moving cars out, rather than putting either somewhere wrong.
  int _placeSiteCars(CityTrafficFrame f, Vector3 anchorBF, Vector3 focusBF,
      _SiteCarDraws draws) {
    final sf = f.sites;
    final poses = f.sitePoses;
    final agents = f.agents;
    draws.vehicles.begin();
    if (sf == null) {
      draws.vehicles.finish();
      return 0;
    }
    final qx = focusBF.x - anchorBF.x;
    final qy = focusBF.y - anchorBF.y;
    final qz = focusBF.z - anchorBF.z;
    final shadow2 =
        AgentTrafficPass.shadowRangeM * AgentTrafficPass.shadowRangeM;
    final range2 = AgentTrafficPass.rangeM * AgentTrafficPass.rangeM;
    var placed = 0;
    if (poses.sitesRev == sf.sitesRev) {
      final cap = AgentTrafficPass.renderCap;
      for (var i = 0; i < poses.count && placed < cap; i++) {
        final row = poses.row[i];
        if (row < 0 || row >= agents.count) continue;
        final kind = agentVehicleKind(agents.kind[row], agents.variant[row],
            sealed: poses.sealed);
        if (kind == null) continue;
        placed += _placeOneSiteCar(draws.vehicles, sf, anchorBF, kind, poses.e[i],
            poses.n[i], poses.up[i], poses.dirE[i], poses.dirN[i], qx, qy, qz,
            shadow2, range2);
      }
    }
    draws.vehicles.finish();
    // The parked cars: only when something actually moved them.
    final parked = f.parked;
    if (parked.sitesRev == sf.sitesRev &&
        (!identical(draws.parkedFrom, parked) ||
            !identical(draws.parkedSites, sf) ||
            draws.parkedAnchor != anchorBF)) {
      draws.parked.begin();
      var n = 0;
      for (var i = 0; i < parked.lotCount && n < _kParkedRenderCap; i++) {
        final kind = agentVehicleKind(parked.lotKind[i], parked.lotVariant[i],
            sealed: poses.sealed);
        if (kind == null) continue;
        n += _placeOneSiteCar(draws.parked, sf, anchorBF, kind, parked.lotE[i],
            parked.lotN[i], parked.lotUp[i], parked.lotDirE[i],
            parked.lotDirN[i], qx, qy, qz, shadow2, double.infinity);
      }
      draws.parked.finish();
      draws.parkedFrom = parked;
      draws.parkedSites = sf;
      draws.parkedAnchor = anchorBF;
    }
    return placed;
  }

  /// One car of [batches], in its band; 1 when it was placed.
  int _placeOneSiteCar(
      _SiteCarBatches batches,
      CitySiteFrame sf,
      Vector3 anchorBF,
      VehicleKind kind,
      double e,
      double n,
      double up,
      double dirE,
      double dirN,
      double qx,
      double qy,
      double qz,
      double shadow2,
      double range2) {
    // Written into the near buffer first, because how far away it is can
    // only be read off the pose the write works out.
    final near = batches.bufOf(kind, true);
    final at = near.count;
    if (!_writeSiteCarPose(near.next(), sf, anchorBF, e, n, up, dirE, dirN)) {
      near.count = at;
      return 0;
    }
    final m = near.matrices[at];
    final dx = m.storage[12] - qx;
    final dy = m.storage[13] - qy;
    final dz = m.storage[14] - qz;
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 > range2) {
      near.count = at;
      return 0;
    }
    if (d2 < shadow2) return 1;
    near.count = at;
    batches.bufOf(kind, false).next().setFrom(m);
    return 1;
  }

  /// Moves the draw [key] to [poses], making it — under [parent], with
  /// [material] — when it has none. [near] draws cast shadows.
  void _agentDraw(_AgentLayer layer, String key, fs.Node parent,
      fs.MeshGeometry? geometry, fs.Material material, TrafficBuffer poses,
      bool near) {
    if (geometry == null) return;
    var slot = layer.slots[key];
    if (slot != null &&
        (!identical(slot.parent, parent) ||
            !identical(slot.material, material))) {
      slot.parent.remove(slot.node);
      layer.slots.remove(key);
      slot = null;
    }
    slot ??= layer.slots[key] = () {
      final mesh = fs.InstancedMesh(geometry: geometry, material: material);
      // Never frustum culled, like the cosmetic draws: moving every
      // instance every frame would refit a culled node's bounds each time.
      final node = fs.Node()
        ..addComponent(fs.InstancedMeshComponent(mesh))
        ..frustumCulled = false
        ..castsShadow = near;
      parent.add(node);
      return _AgentSlot(node, mesh, parent, material);
    }();
    slot.touched = true;
    CityNodes._setInstances(slot.mesh, poses);
    slot.node.visible = true;
  }

  /// The vehicle draws out of the scene, and their high-water marks with
  /// them; the passes and their clocks stay.
  void _dropAgentDraws(_AgentLayer layer) {
    for (final slot in layer.slots.values) {
      slot.parent.remove(slot.node);
    }
    layer.slots.clear();
    for (final pass in layer.passes.values) {
      pass.resetHighWater();
    }
    for (final draws in layer.siteCars.values) {
      draws.dropHighWater();
    }
  }

  void _dropAgentHeads(_AgentLayer layer) {
    for (final heads in layer.heads.values) {
      heads.drop();
    }
    layer.heads.clear();
  }

  /// Everything the agents draw, gone: no colony in the frame has agents.
  void _dropAgents(_AgentLayer layer) {
    _dropAgentDraws(layer);
    _dropAgentHeads(layer);
    layer.passes.clear();
    layer.siteCars.clear();
    layer.seen.clear();
  }
}
