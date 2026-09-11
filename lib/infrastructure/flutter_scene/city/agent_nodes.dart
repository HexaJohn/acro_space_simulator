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

  /// The frame each colony was last seen in.
  final Map<String, int> seen = {};
  int frame = 0;

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
            CityMaterials.facade, b);
        _agentDraw(layer, '$key/glazing', root.node, mesh.glazing,
            CityMaterials.glazing, b);
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

  /// Moves the draw [key] to [b]'s poses, making it — under [parent], with
  /// [material] — when it has none.
  void _agentDraw(_AgentLayer layer, String key, fs.Node parent,
      fs.MeshGeometry? geometry, fs.Material material, AgentDrawBatch b) {
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
        ..castsShadow = b.near;
      parent.add(node);
      return _AgentSlot(node, mesh, parent, material);
    }();
    slot.touched = true;
    CityNodes._setInstances(slot.mesh, b.poses);
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
    layer.seen.clear();
  }
}
