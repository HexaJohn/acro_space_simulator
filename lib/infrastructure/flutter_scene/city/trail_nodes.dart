// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

part of 'city_nodes.dart';

// A colony's desire paths in 3D (docs/plans/desire-paths.md §5 phase 3): its
// worn trails as ribbons of rutted dirt over the ground, wider the more
// they are worn, and the rovers driving them.
//
// Off [WorldSnapshot.cityTrails], whose points are already on the ground,
// body-fixed: nothing here asks the terrain. Each colony's ribbons are one
// mesh, cut again only when the capture hands a new [TrailRibbons]; its
// rovers are one instanced draw, rewritten each frame (they are a few).
// Everything hangs under the body's root, so a turning planet carries it.

/// The trail state of each [CityNodes].
final Expando<_TrailLayer> _trailLayers = Expando<_TrailLayer>('trailNodes');

class _TrailLayer {
  final Map<String, _TrailDraw> byColony = {};
}

class _TrailDraw {
  fs.Node? parent;
  TrailRibbons? built;
  fs.Node? ribbon;
  List<Float64List>? builtTubes;
  fs.Node? tube;
  fs.InstancedMesh? solid, glazing;
  fs.Node? solidNode, glazingNode;
  final TrafficBuffer poses = TrafficBuffer();

  void drop() {
    final p = parent;
    if (p != null) {
      for (final n in [ribbon, tube, solidNode, glazingNode]) {
        if (n != null) p.remove(n);
      }
    }
    ribbon = tube = solidNode = glazingNode = null;
    solid = glazing = null;
    built = null;
    builtTubes = null;
  }
}

/// Metres a ribbon floats over the ground it was draped on: clear of the
/// terrain's own facets between the samples, under anything built.
const double _ribbonLiftM = 0.15;

extension _TrailNodes on CityNodes {
  _TrailLayer get _trailLayer => _trailLayers[this] ??= _TrailLayer();

  void _syncTrails(WorldSnapshot snap) {
    final layer = _trailLayer;
    final live = <String>{};
    for (final f in snap.cityTrails) {
      final root = _roots[f.bodyId];
      if (root == null) continue;
      live.add(f.colonyId);
      final d = layer.byColony.putIfAbsent(f.colonyId, _TrailDraw.new);
      if (!identical(d.parent, root.node)) {
        d.drop();
        d.parent = root.node;
      }
      if (!identical(d.built, f.ribbons)) {
        final old = d.ribbon;
        if (old != null) root.node.remove(old);
        d.ribbon = null;
        d.built = f.ribbons;
        final geometry = _ribbonGeometry(f.ribbons, root.anchorBF);
        if (geometry != null) {
          final node = fs.Node(
            mesh: fs.Mesh.primitives(primitives: [
              fs.MeshPrimitive(geometry, CityMaterials.dirt),
            ]),
          )..castsShadow = false;
          root.node.add(node);
          d.ribbon = node;
        }
      }
      if (!identical(d.builtTubes, f.tubes)) {
        final old = d.tube;
        if (old != null) root.node.remove(old);
        d.tube = null;
        d.builtTubes = f.tubes;
        final node = _tubeNode(f.tubes, root.anchorBF);
        if (node != null) {
          root.node.add(node);
          d.tube = node;
        }
      }
      _placeRovers(d, f.rovers, root);
    }
    layer.byColony.removeWhere((id, d) {
      if (live.contains(id)) return false;
      d.drop();
      return true;
    });
  }

  /// The ribbons as one mesh, anchor-relative: a quad strip per ribbon,
  /// half a metre to two and a half each side of its line by its wear.
  fs.MeshGeometry? _ribbonGeometry(TrailRibbons r, Vector3 anchorBF) {
    if (r.points.isEmpty) return null;
    final m = MeshBuilder();
    for (var k = 0; k < r.points.length; k++) {
      final pts = r.points[k];
      final n = pts.length ~/ 3;
      if (n < 2) continue;
      final hw = 1.0 + 1.5 * r.wear[k].clamp(0.0, 1.0);
      Vector3 at(int i) => Vector3(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]);
      var prevL = -1, prevR = -1;
      var s = 0.0;
      for (var i = 0; i < n; i++) {
        final p = at(i);
        final up = p.normalized;
        final ahead = at(i + 1 < n ? i + 1 : i) - at(i > 0 ? i - 1 : i);
        var side = ahead.cross(up);
        if (side.length < 1e-9) continue;
        side = side.normalized * hw;
        if (i > 0) s += (p - at(i - 1)).length;
        final c = p - anchorBF + up * _ribbonLiftM;
        final v = s / 8;
        final l = m.vertex(CityNodes._scenePos(c - side), up, 0, v);
        final rr = m.vertex(CityNodes._scenePos(c + side), up, 1, v);
        if (prevL >= 0) m.quad(prevL, prevR, rr, l);
        prevL = l;
        prevR = rr;
      }
    }
    return CityNodes._geometryOf(m.build());
  }

  /// The tubes as one node: a glass barrel round each axis, and a concrete
  /// pier down to the ground every other point (some twenty metres).
  fs.Node? _tubeNode(List<Float64List> tubes, Vector3 anchorBF) {
    if (tubes.isEmpty) return null;
    final glass = MeshBuilder(), piers = MeshBuilder();
    const radius = 1.4, sides = 8, pierHalf = 0.4;
    for (final pts in tubes) {
      final n = pts.length ~/ 3;
      if (n < 2) continue;
      Vector3 at(int i) => Vector3(pts[i * 3], pts[i * 3 + 1], pts[i * 3 + 2]);
      List<int>? prev;
      for (var i = 0; i < n; i++) {
        final p = at(i);
        final up = p.normalized;
        var t = at(i + 1 < n ? i + 1 : i) - at(i > 0 ? i - 1 : i);
        if (t.length < 1e-9) continue;
        t = t.normalized;
        final side = t.cross(up).normalized;
        final lift = side.cross(t).normalized;
        final c = p - anchorBF;
        final ring = <int>[];
        for (var k = 0; k < sides; k++) {
          final a = 2 * math.pi * k / sides;
          final out = side * math.cos(a) + lift * math.sin(a);
          ring.add(glass.vertex(
              CityNodes._scenePos(c + out * radius), out, k / sides, i / 4));
        }
        if (prev != null) {
          for (var k = 0; k < sides; k++) {
            final k1 = (k + 1) % sides;
            glass.quad(prev[k], prev[k1], ring[k1], ring[k]);
          }
        }
        prev = ring;
        // A pier under every other point, from the ground to the barrel.
        if (i.isEven) {
          final top = c - up * radius;
          final foot = c - up * kTubeHeightM;
          final s2 = side * pierHalf, t2 = t * pierHalf;
          final corners = [s2 + t2, s2 - t2, -s2 - t2, -s2 + t2];
          for (var k = 0; k < 4; k++) {
            final a = corners[k], b = corners[(k + 1) % 4];
            final nrm = (a + b).normalized;
            final v0 = piers.vertex(CityNodes._scenePos(foot + a), nrm, 0, 0);
            final v1 = piers.vertex(CityNodes._scenePos(foot + b), nrm, 1, 0);
            final v2 = piers.vertex(CityNodes._scenePos(top + b), nrm, 1, 1);
            final v3 = piers.vertex(CityNodes._scenePos(top + a), nrm, 0, 1);
            piers.quad(v0, v1, v2, v3);
          }
        }
      }
    }
    final g = CityNodes._geometryOf(glass.build());
    final pg = CityNodes._geometryOf(piers.build());
    final prims = <fs.MeshPrimitive>[
      if (pg != null) fs.MeshPrimitive(pg, CityMaterials.facade),
      if (g != null) fs.MeshPrimitive(g, CityMaterials.glazing),
    ];
    if (prims.isEmpty) return null;
    return fs.Node(mesh: fs.Mesh.primitives(primitives: prims))
      ..castsShadow = true;
  }

  /// The rovers on their legs: the six-wheeled rover, standing on the
  /// ground the capture put it on, facing along its trail.
  void _placeRovers(_TrailDraw d, Float64List r, _BodyRoot root) {
    d.poses.reset();
    final a = root.anchorBF;
    for (var k = 0; k + 5 < r.length; k += 6) {
      final px = r[k], py = r[k + 1], pz = r[k + 2];
      final pl = math.sqrt(px * px + py * py + pz * pz);
      if (pl == 0) continue;
      final ux = px / pl, uy = py / pl, uz = pz / pl;
      // Heading flattened onto the ground plane, then the right-handed side.
      var fx = r[k + 3], fy = r[k + 4], fz = r[k + 5];
      final dot = fx * ux + fy * uy + fz * uz;
      fx -= ux * dot;
      fy -= uy * dot;
      fz -= uz * dot;
      final fl = math.sqrt(fx * fx + fy * fy + fz * fz);
      if (fl < 1e-9) continue;
      fx /= fl;
      fy /= fl;
      fz /= fl;
      final sx = fy * uz - fz * uy, sy = fz * ux - fx * uz, sz = fx * uy - fy * ux;
      TrafficRoad.writePose(d.poses.next(), px - a.x, py - a.y, pz - a.z, sx,
          sy, sz, fx, fy, fz, ux, uy, uz);
    }
    if (d.poses.count == 0 && d.solid == null) return;
    final mesh = _vehicleMesh(VehicleKind.rover);
    fs.InstancedMesh? draw(fs.MeshGeometry? g, fs.Material mat,
        void Function(fs.Node) keep) {
      if (g == null) return null;
      final im = fs.InstancedMesh(geometry: g, material: mat);
      final node = fs.Node()
        ..addComponent(fs.InstancedMeshComponent(im))
        ..frustumCulled = false
        ..castsShadow = true;
      root.node.add(node);
      keep(node);
      return im;
    }

    d.solid ??= draw(mesh.solid, CityMaterials.facade, (n) => d.solidNode = n);
    d.glazing ??=
        draw(mesh.glazing, CityMaterials.glazing, (n) => d.glazingNode = n);
    for (final im in [d.solid, d.glazing]) {
      if (im != null) CityNodes._setInstances(im, d.poses);
    }
  }
}
