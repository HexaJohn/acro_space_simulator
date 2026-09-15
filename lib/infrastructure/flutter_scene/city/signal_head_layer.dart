// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Live signal heads (docs/plans/agent-traffic.md §13.6): red, amber and
/// green lamps on every signalised leg, lit by the simulation's own signal
/// clock.
///
/// Why they exist: the tiles bake one head per signalised leg and switch it
/// by the parity of the epoch the tile was meshed at (road_mesher.dart,
/// `_crossing`), so a drawn light does not follow the light the agents
/// obey. These do. Each lamp asks `SignalPlan.stateAt` — the very function
/// the junction arbiter asks — at the renderer's agent time, so what is
/// drawn can lag what is obeyed by at most one sub-step, well inside the
/// amber.
///
/// Three instanced draws, one per colour, each with ONE instance per head,
/// always: a lamp not showing is a zero-scale matrix. The counts never
/// change, so a light changing moves a few matrices in place and never
/// clears a draw, and a head whose light did not change is not written at
/// all.
///
/// The lamps hang on the tiles' own mast, in the head's place: while a frame
/// carries agent traffic the tiles bake the masts with no lamp heads
/// (`CityMeshKnobs.agentSignals`, C3), and this layer draws only for such a
/// frame.
///
/// [SignalHeadPlacement] is the arithmetic, testable without a renderer;
/// [SignalHeadLayer] owns the draws.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/city_traffic_frame.dart';
import '../../../domain/colony/city/traffic/agent_frame.dart';
import '../../../domain/colony/city/traffic/node_control.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_traffic.dart';
import 'road_mesher.dart';

/// Where every head's lamps are, anchor-relative, and which are lit.
class SignalHeadPlacement {
  SignalHeadPlacement(this.net, this.geometry, this.anchorBF) {
    _build();
  }

  final TrafficNetColumns net;
  final TrafficGeometry geometry;
  final Vector3 anchorBF;

  // The mast, as the tiles stand it (road_mesher.dart, `_crossing`): out
  // along the leg to [mastOutShare] of the plate's radius, beside the road
  // by the leg's drawn half width ([legHalfWidthShare] of it) plus
  // [mastSideM], and [mastHeightM] tall.
  static const double mastOutShare = 0.98;
  static const double legHalfWidthShare = 0.92;
  static const double mastSideM = 1.6;
  static const double mastHeightM = 4.6;

  /// A lamp's edge.
  static const double lampM = 0.3;

  /// Each colour's height above the mast's top, red uppermost; indexed by
  /// [SignalHeadLayer.red] and the rest.
  static const List<double> lampRiseM = [0.7, 0.4, 0.1];

  /// Per head: the mast's top (xyz) and its frame — side, the leg's
  /// direction out of the junction, up — nine per head.
  late final Float64List top;
  late final Float64List frame;

  /// The matrices each colour's draw holds, one per head: the lamp's pose
  /// when it shows that colour, zero scale when it does not.
  late final List<vm.Matrix4> red, amber, green;

  /// Each head's lamps lit, three per head, and each head's state last
  /// written ([SignalState.index] + 1; 0 before the first).
  late final List<vm.Matrix4> _lit;
  late final Uint8List _shown;

  int get headCount => net.headCount;

  void _build() {
    final n = net.headCount;
    final g = geometry;
    top = Float64List(3 * n);
    frame = Float64List(9 * n);
    _lit = List<vm.Matrix4>.generate(3 * n, (_) => vm.Matrix4.zero());
    red = List<vm.Matrix4>.generate(n, (_) => vm.Matrix4.zero());
    amber = List<vm.Matrix4>.generate(n, (_) => vm.Matrix4.zero());
    green = List<vm.Matrix4>.generate(n, (_) => vm.Matrix4.zero());
    _shown = Uint8List(n);
    for (var h = 0; h < n; h++) {
      final node = net.headNode[h];
      if (node >= g.nodeCount) continue;
      final bx = g.nodePts[3 * node], by = g.nodePts[3 * node + 1];
      final bz = g.nodePts[3 * node + 2];
      final bl = math.sqrt(bx * bx + by * by + bz * bz);
      if (bl == 0) continue;
      // Up is radial: the node's own direction from the body's centre.
      final ux = bx / bl, uy = by / bl, uz = bz / bl;
      // The leg's heading on the ground, from the colony's east and north
      // at the node.
      final e = net.headDirE[h], nn = net.headDirN[h];
      var dx = g.nodeEast[3 * node] * e + g.nodeNorth[3 * node] * nn;
      var dy = g.nodeEast[3 * node + 1] * e + g.nodeNorth[3 * node + 1] * nn;
      var dz = g.nodeEast[3 * node + 2] * e + g.nodeNorth[3 * node + 2] * nn;
      final dl = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dl == 0) continue;
      dx /= dl;
      dy /= dl;
      dz /= dl;
      // side = dir × up, as the mesher takes it.
      var sx = dy * uz - dz * uy, sy = dz * ux - dx * uz, sz = dx * uy - dy * ux;
      final sl = math.sqrt(sx * sx + sy * sy + sz * sz);
      sx /= sl;
      sy /= sl;
      sz /= sl;
      // The plate's centre, lifted as the tiles lift it.
      final lift = RoadMesher.plateLiftM + g.nodeLift[node];
      final ax = bx - anchorBF.x + ux * lift;
      final ay = by - anchorBF.y + uy * lift;
      final az = bz - anchorBF.z + uz * lift;
      final out = net.headR[h] * mastOutShare;
      final beside = net.headHalfWidth[h] * legHalfWidthShare + mastSideM;
      final tx = ax + dx * out + sx * beside + ux * mastHeightM;
      final ty = ay + dy * out + sy * beside + uy * mastHeightM;
      final tz = az + dz * out + sz * beside + uz * mastHeightM;
      top[3 * h] = tx;
      top[3 * h + 1] = ty;
      top[3 * h + 2] = tz;
      final f = 9 * h;
      frame
        ..[f] = sx
        ..[f + 1] = sy
        ..[f + 2] = sz
        ..[f + 3] = dx
        ..[f + 4] = dy
        ..[f + 5] = dz
        ..[f + 6] = ux
        ..[f + 7] = uy
        ..[f + 8] = uz;
      // The lamps stack on the mast's top, where the baked head hung before
      // the tiles left it off for agent traffic.
      for (var c = 0; c < 3; c++) {
        final rise = lampRiseM[c];
        TrafficRoad.writePose(
            _lit[3 * h + c],
            tx + ux * rise,
            ty + uy * rise,
            tz + uz * rise,
            sx, sy, sz, dx, dy, dz, ux, uy, uz);
      }
    }
  }

  /// The colour's matrix list, [SignalHeadLayer.red] and the rest.
  List<vm.Matrix4> matricesOf(int colour) => switch (colour) {
        SignalHeadLayer.red => red,
        SignalHeadLayer.amber => amber,
        _ => green,
      };

  /// The colour a head in [state] lights: all-red is red.
  static int colourOf(SignalState state) => switch (state) {
        SignalState.red || SignalState.allRed => SignalHeadLayer.red,
        SignalState.amber => SignalHeadLayer.amber,
        SignalState.green => SignalHeadLayer.green,
      };

  /// Brings every head to agent time [timeUs]: the heads whose light
  /// changed get their three matrices rewritten, and are listed in
  /// [changed] (room for [headCount]); returns how many.
  int update(int timeUs, Int32List changed) {
    var n = 0;
    for (var h = 0; h < headCount; h++) {
      final state = net.stateOf(h, timeUs);
      if (_shown[h] == state.index + 1) continue;
      _shown[h] = state.index + 1;
      final lit = colourOf(state);
      for (var c = 0; c < 3; c++) {
        final m = matricesOf(c)[h]..setFrom(_lit[3 * h + c]);
        // Off: the rotation columns zeroed, the lamp where it hangs.
        if (c != lit) m.storage.fillRange(0, 12, 0);
      }
      changed[n++] = h;
    }
    return n;
  }
}

/// The three lamp draws of one colony, under its body's root.
class SignalHeadLayer {
  /// Colour indices: the draws, and [SignalHeadPlacement.lampRiseM].
  static const int red = 0, amber = 1, green = 2;

  /// Unlit, so a lamp glows at noon and at midnight alike.
  static final List<vm.Vector4> colours = [
    vm.Vector4(1.0, 0.08, 0.05, 1),
    vm.Vector4(1.0, 0.62, 0.05, 1),
    vm.Vector4(0.15, 1.0, 0.35, 1),
  ];

  static fs.MeshGeometry? _geometry;

  fs.Node? _parent;
  fs.Node? _group;
  final List<fs.InstancedMesh> _meshes = [];
  SignalHeadPlacement? _placement;
  Int32List _changed = Int32List(0);

  /// The placement last synced: for the panel and the tests.
  SignalHeadPlacement? get placement => _placement;

  /// One lamp in MODEL space: a box [SignalHeadPlacement.lampM] on a side
  /// centred on the origin, in scene units like the vehicle models, wound
  /// as they are (vehicle_meshes.dart).
  static PropMesh lampModel() {
    final m = MeshBuilder();
    const h = SignalHeadPlacement.lampM / 2;
    Vector3 at(double x, double y, double z) =>
        Vector3(x, y, z) * kRenderScale;
    final c = [
      at(-h, -h, -h), at(-h, h, -h), at(h, h, -h), at(h, -h, -h),
      at(-h, -h, h), at(-h, h, h), at(h, h, h), at(h, -h, h),
    ];
    const n = [
      Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0),
      Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0),
    ];
    const faces = [
      [4, 5, 6, 7], [3, 2, 1, 0], [2, 6, 5, 1],
      [0, 4, 7, 3], [1, 5, 4, 0], [3, 7, 6, 2],
    ];
    for (var f = 0; f < faces.length; f++) {
      final q = [for (final i in faces[f]) m.vertex(c[i], n[f], 0.5, 0.5)];
      m.quad(q[3], q[2], q[1], q[0]);
    }
    return m.build();
  }

  /// Brings [net]'s heads to agent time [timeUs] under [parent] — the body
  /// root, whose anchor is [anchorBF] — on [geometry].
  void sync(fs.Node parent, TrafficNetColumns net, TrafficGeometry geometry,
      Vector3 anchorBF, int timeUs) {
    if (net.headCount == 0 || geometry.nodeCount == 0) {
      drop();
      return;
    }
    var p = _placement;
    var whole = false;
    if (p == null ||
        !identical(p.net, net) ||
        !identical(p.geometry, geometry) ||
        p.anchorBF != anchorBF) {
      p = _placement = SignalHeadPlacement(net, geometry, anchorBF);
      whole = true;
    }
    if (_group == null || !identical(_parent, parent)) {
      _attach(parent);
      whole = true;
    }
    if (_changed.length < p.headCount) _changed = Int32List(p.headCount);
    final changed = p.update(timeUs, _changed);
    for (var c = 0; c < 3; c++) {
      final mesh = _meshes[c];
      final list = p.matricesOf(c);
      if (whole || mesh.instanceCount != list.length) {
        mesh.clearInstances();
        for (final m in list) {
          mesh.addInstance(m);
        }
        continue;
      }
      for (var j = 0; j < changed; j++) {
        mesh.setInstanceTransform(_changed[j], list[_changed[j]]);
      }
    }
  }

  void _attach(fs.Node parent) {
    drop();
    final geometry = _geometry ??= () {
      final mesh = lampModel();
      return fs.MeshGeometry.fromArrays(
        positions: mesh.positions,
        normals: mesh.normals,
        texCoords: mesh.texCoords,
        indices: mesh.indices,
        retainCpuData: false,
      );
    }();
    final group = fs.Node()..castsShadow = false;
    for (var c = 0; c < 3; c++) {
      final material = fs.UnlitMaterial()..baseColorFactor = colours[c];
      final mesh = fs.InstancedMesh(geometry: geometry, material: material);
      // Never culled, like the traffic draws: a lamp changing is a buffer
      // write, not a bounds refit.
      group.add(fs.Node()
        ..addComponent(fs.InstancedMeshComponent(mesh))
        ..frustumCulled = false
        ..castsShadow = false);
      _meshes.add(mesh);
    }
    parent.add(group);
    _parent = parent;
    _group = group;
  }

  /// Takes the lamps out of the scene; the next [sync] puts them back.
  void drop() {
    final group = _group;
    if (group != null) _parent?.remove(group);
    _group = null;
    _parent = null;
    _meshes.clear();
    _placement = null;
  }
}
