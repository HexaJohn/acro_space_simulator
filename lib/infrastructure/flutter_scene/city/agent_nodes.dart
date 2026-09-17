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
// - A draw uploads only what MOVED. Every instanced draw in the process
//   emplaces its matrices into one shared host buffer
//   (`instance_packing.dart`), and the engine packs an item afresh whenever
//   its `InstancedMesh` version moves — so a batch whose poses were not
//   rewritten is left alone here rather than written back identical, and
//   the buffer sees a layout that stands still.
//
// The SITE cars (T4a, site-access.md §7.4) are drawn beside them, in the
// same models, off the poses [SiteCarPass] works out from the frame's own
// site columns. No lot geometry is derived here, and nothing asks the
// ground (D19/D20).

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

  /// The buffer this draw last uploaded and the revision it was at. A
  /// batch that did not move is not written into the mesh again: the write
  /// itself is cheap, but it bumps `InstancedMesh.version`, and that is
  /// what makes the engine repack every instance and re-emplace it into the
  /// shared buffer (§13.8).
  TrafficBuffer? uploaded;
  int uploadedRev = -1;
}

/// Everything the agent draws keep between frames.
class _AgentLayer {
  final Map<String, _AgentSlot> slots = {};

  /// Per colony: its pose pass (and render clock), and its signal heads.
  final Map<String, AgentTrafficPass> passes = {};
  final Map<String, SignalHeadLayer> heads = {};

  /// Per colony: the cars inside its sites and parked on its stalls.
  final Map<String, SiteCarPass> siteCars = {};

  /// The frame each colony was last seen in.
  final Map<String, int> seen = {};
  int frame = 0;

  /// What the draws cost the shared instance buffer this frame: the
  /// instances the agent draws hold, and the matrices actually written into
  /// a mesh (and so repacked). On a steady scene the second stays far under
  /// the first; the panel reads both.
  int instances = 0;
  int written = 0;

  /// The render clocks' wall time.
  final Stopwatch wall = Stopwatch()..start();
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
    layer.instances = 0;
    layer.written = 0;
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
            CityMaterials.facade, b.poses, b.rev, b.near);
        _agentDraw(layer, '$key/glazing', root.node, mesh.glazing,
            CityMaterials.glazing, b.poses, b.rev, b.near);
      }
      // The cars inside the colony's sites, and the ones parked on its
      // stalls: the same models, placed off the site frame rather than the
      // road geometry (§7.4). Here rather than in _syncAgentExtras because
      // this is where the focus is, and the bands are the same bands.
      final draws = layer.siteCars.putIfAbsent(f.colonyId, SiteCarPass.new);
      placed += draws.place(f, root.anchorBF, focusBF);
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
              CityMaterials.facade, poses, batches.rev, near);
          _agentDraw(layer, '$key/glazing', root.node, mesh.glazing,
              CityMaterials.glazing, poses, batches.rev, near);
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
    CityNodes.phaseCount['agent.instances'] = layer.instances;
    CityNodes.phaseCount['agent.written'] = layer.written;
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

  /// Moves the draw [key] to [poses] at revision [rev], making it — under
  /// [parent], with [material] — when it has none. [near] draws cast
  /// shadows.
  ///
  /// The instances are written only when [rev] moved (§13.8). A batch
  /// rewritten with the very matrices it held would still bump the mesh's
  /// version, and that version is what the engine packs by: it would repack
  /// every instance and emplace it into the process-wide instance buffer
  /// again, for a picture that did not change.
  void _agentDraw(_AgentLayer layer, String key, fs.Node parent,
      fs.MeshGeometry? geometry, fs.Material material, TrafficBuffer poses,
      int rev, bool near) {
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
    layer.instances += poses.count;
    if (!identical(slot.uploaded, poses) || slot.uploadedRev != rev) {
      CityNodes._setInstances(slot.mesh, poses);
      slot.uploaded = poses;
      slot.uploadedRev = rev;
      layer.written += poses.count;
    }
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
