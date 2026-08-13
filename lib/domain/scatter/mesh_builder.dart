// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import 'prop_mesh.dart';
import 'prop_model.dart';

/// One entry of the builder's transform stack: a uniformly-scaled rigid frame.
///
/// Uniform scale only — a tree branch never needs shear, and it means a normal
/// transforms by the rotation alone (no inverse-transpose), which keeps the
/// hot path a quaternion rotate.
class _Frame {
  _Frame(this.origin, this.rotation, this.scale);

  Vector3 origin;
  Quaternion rotation;
  double scale;

  _Frame get copy => _Frame(origin, rotation, scale);
}

/// Accumulates triangles into a [PropMesh] through a **turtle**: a movable,
/// rotatable local frame with a push/pop stack.
///
/// The turtle is what makes recursive plant geometry readable — `push()`,
/// `turn()` out to a branch angle, recurse, `pop()` back to the parent — and it
/// is the whole reason branch joints line up without any matrix bookkeeping at
/// the call sites. Growth runs along local **+Z** (the domain's up), so a prop
/// built at the identity frame stands on the XY plane with its base at the
/// origin.
///
/// Pure Dart, no Flutter, no GPU: every generator here is unit-testable and
/// isolate-safe.
class MeshBuilder {
  final List<double> _positions = [];
  final List<double> _normals = [];
  final List<double> _texCoords = [];
  final List<int> _indices = [];

  _Frame _frame = _Frame(Vector3.zero, Quaternion.identity, 1.0);
  final List<_Frame> _stack = [];

  int get vertexCount => _positions.length ~/ 3;
  int get triangleCount => _indices.length ~/ 3;

  // ---- Turtle -------------------------------------------------------------

  /// Current frame origin in mesh-local space.
  Vector3 get position => _frame.origin;

  /// Current frame orientation.
  Quaternion get orientation => _frame.rotation;

  /// Current frame's growth direction (+Z) in mesh-local space.
  Vector3 get heading => _frame.rotation.rotate(Vector3.unitZ);

  /// Current accumulated uniform scale.
  double get scale => _frame.scale;

  /// Map a point from the current frame into mesh-local space — how a generator
  /// reports a limb or cluster position to the imposter builder, which works in
  /// mesh coordinates.
  Vector3 toMesh(Vector3 local) =>
      _frame.origin + _frame.rotation.rotate(local * _frame.scale);

  /// World up (+Z) expressed in the CURRENT frame. Tropism — a branch reaching
  /// for the light or drooping under its own weight — is a rotation toward this
  /// vector, and it has to be re-derived per limb because every limb sits in a
  /// differently rotated frame.
  Vector3 get upInFrame => _frame.rotation.conjugate.rotate(Vector3.unitZ);

  void push() => _stack.add(_frame.copy);

  void pop() {
    if (_stack.isEmpty) {
      throw StateError('MeshBuilder.pop() with an empty transform stack');
    }
    _frame = _stack.removeLast();
  }

  /// Advance the turtle by [delta], expressed in the CURRENT frame.
  void move(Vector3 delta) {
    _frame.origin =
        _frame.origin + _frame.rotation.rotate(delta * _frame.scale);
  }

  /// Advance [d] metres along the current heading (+Z).
  void forward(double d) => move(Vector3(0, 0, d));

  /// Rotate the frame by [q], expressed in the CURRENT frame.
  void turn(Quaternion q) => _frame.rotation = (_frame.rotation * q).normalized;

  /// Pitch away from the heading by [angle] about the local X axis.
  void pitch(double angle) =>
      turn(Quaternion.axisAngle(Vector3.unitX, angle));

  /// Roll about the heading by [angle] (the phyllotaxis spin).
  void roll(double angle) => turn(Quaternion.axisAngle(Vector3.unitZ, angle));

  /// Yaw about the local Y axis by [angle].
  void yaw(double angle) => turn(Quaternion.axisAngle(Vector3.unitY, angle));

  /// Multiply the frame's uniform scale.
  void scaleBy(double s) => _frame.scale *= s;

  /// Reset to the identity frame and drop the stack (between sub-props).
  void resetFrame() {
    _frame = _Frame(Vector3.zero, Quaternion.identity, 1.0);
    _stack.clear();
  }

  // ---- Raw emission -------------------------------------------------------

  /// Emit one vertex, transforming [local] and [normal] through the current
  /// frame. Returns its index.
  int vertex(Vector3 local, Vector3 normal, double u, double v) {
    final p = _frame.origin + _frame.rotation.rotate(local * _frame.scale);
    final n = _frame.rotation.rotate(normal);
    _positions.addAll([p.x, p.y, p.z]);
    _normals.addAll([n.x, n.y, n.z]);
    _texCoords.addAll([u, v]);
    return (_positions.length ~/ 3) - 1;
  }

  /// Emit one triangle. Callers order the vertices by the RIGHT-HAND RULE — so
  /// that `(b-a) x (c-a)` points the same way as the surface's shading normal.
  ///
  /// The engine's front face is the OPPOSITE winding, so the flip happens here,
  /// once. That is not a guess: `uvSphereZUp` documents `[a, a+1, b]` as the
  /// outward winding for a sphere, and that triangle's right-hand normal points
  /// INWARD — a consequence of the mirrored camera basis described in
  /// `coord_convert.dart`. Authoring in the engine's order at every call site
  /// instead means every primitive silently encodes the same reversal, and
  /// getting one wrong renders a hollow shell: you see the inside of the far
  /// surface, which reads as a trunk with no front or a rock with no top.
  void triangle(int a, int b, int c) => _indices.addAll([a, c, b]);

  /// Emit a quad as two triangles. [a]..[d] run around the face by the
  /// right-hand rule; see [triangle].
  void quad(int a, int b, int c, int d) {
    triangle(a, b, c);
    triangle(a, c, d);
  }

  /// Emit a standalone flat-shaded triangle: three unshared vertices carrying
  /// the face normal. This is how faceted rock is built — shared vertices would
  /// average the normals and round off the very edges that read as fractured.
  void flatTriangle(
    Vector3 a,
    Vector3 b,
    Vector3 c, {
    double uScale = 1.0,
  }) {
    final n = (b - a).cross(c - a);
    final len = n.length;
    final unit = len < 1e-12 ? Vector3.unitZ : n / len;
    // Planar UVs from the two longest in-plane axes; rock texture is noise, so
    // a per-face projection is indistinguishable from a real unwrap and costs
    // nothing.
    final ia = vertex(a, unit, a.x * uScale, a.y * uScale);
    final ib = vertex(b, unit, b.x * uScale, b.y * uScale);
    final ic = vertex(c, unit, c.x * uScale, c.y * uScale);
    triangle(ia, ib, ic);
  }

  // ---- Primitives ---------------------------------------------------------

  /// A swept tube along [spine] (points in the CURRENT frame), with per-point
  /// [radii]. Used for trunks and branches: one continuous surface, so a curved
  /// limb has no seams or gaps at the joints that per-segment cylinders leave.
  ///
  /// Ring orientation is **parallel-transported** along the spine — each ring's
  /// reference axis is the previous ring's rotated by the minimal rotation
  /// between consecutive tangents. Rebuilding the frame from a fixed world up
  /// instead makes the ring spin wildly wherever the limb passes near vertical,
  /// which twists the bark UVs into a barber pole.
  ///
  /// [vPerMetre] and [uPerMetre] set how many texture repeats a metre of length
  /// and a metre of CIRCUMFERENCE span. Both are in world units on purpose: a
  /// naive tube maps u over `0..1` around the ring regardless of thickness,
  /// which compresses the bark by the ratio of the texture to the circumference
  /// — on a 2 cm twig that is ~50x, so every sample lands in the top mip and
  /// the branch renders as the texture's flat average. Trunks looked like bark
  /// and twigs looked like painted white sticks.
  ///
  /// [capEnd] closes the far end with a fan (needed on branch tips that a leaf
  /// cluster does not cover).
  void tube(
    List<Vector3> spine,
    List<double> radii, {
    int sides = 6,
    double vPerMetre = 0.5,
    double uPerMetre = 1.0,
    bool capEnd = false,
  }) {
    if (spine.length < 2 || radii.length != spine.length || sides < 3) return;

    final tangents = <Vector3>[];
    for (var i = 0; i < spine.length; i++) {
      final Vector3 t;
      if (i == 0) {
        t = spine[1] - spine[0];
      } else if (i == spine.length - 1) {
        t = spine[i] - spine[i - 1];
      } else {
        t = spine[i + 1] - spine[i - 1];
      }
      tangents.add(t.lengthSquared < 1e-18 ? Vector3.unitZ : t.normalized);
    }

    // Seed the transported frame with any axis not parallel to the first
    // tangent, then Gram-Schmidt it into the ring plane.
    var ref = tangents[0].z.abs() > 0.9 ? Vector3.unitX : Vector3.unitZ;
    var normal = (ref - tangents[0] * ref.dot(tangents[0]));
    normal = normal.lengthSquared < 1e-18 ? Vector3.unitY : normal.normalized;

    // U density from the BASE circumference, held constant along the tube: a
    // per-ring circumference would shear the bark diagonally as the limb tapers.
    final uSpan = 2 * math.pi * radii[0] * uPerMetre;

    final rings = <List<int>>[];
    var travelled = 0.0;
    for (var i = 0; i < spine.length; i++) {
      if (i > 0) {
        travelled += (spine[i] - spine[i - 1]).length;
        // Minimal rotation carrying the previous tangent onto this one.
        final prev = tangents[i - 1], cur = tangents[i];
        final axis = prev.cross(cur);
        final sin = axis.length;
        if (sin > 1e-9) {
          final angle = math.atan2(sin, prev.dot(cur));
          normal = Quaternion.axisAngle(axis, angle).rotate(normal);
          // Re-orthogonalise: transported normals drift after many rings.
          normal = (normal - cur * normal.dot(cur)).normalized;
        }
      }
      final binormal = tangents[i].cross(normal);
      final v = travelled * vPerMetre;
      final ring = <int>[];
      // sides+1 vertices so the U seam has a duplicated column at u=1 — a
      // shared wrap vertex would interpolate U backwards across the seam and
      // smear the whole texture into that one triangle strip.
      for (var s = 0; s <= sides; s++) {
        final a = 2 * math.pi * s / sides;
        final ca = math.cos(a), sa = math.sin(a);
        final dir = normal * ca + binormal * sa;
        ring.add(vertex(spine[i] + dir * radii[i], dir, s / sides * uSpan, v));
      }
      rings.add(ring);
    }

    for (var i = 0; i < rings.length - 1; i++) {
      final lo = rings[i], hi = rings[i + 1];
      for (var s = 0; s < sides; s++) {
        quad(lo[s], lo[s + 1], hi[s + 1], hi[s]);
      }
    }

    if (capEnd && radii.last > 1e-6) {
      final tip = tangents.last;
      final centre =
          vertex(spine.last, tip, uSpan * 0.5, travelled * vPerMetre);
      final ring = rings.last;
      for (var s = 0; s < sides; s++) {
        // Anticlockwise about the outward tip tangent, so the cap agrees with
        // the tube's own winding instead of showing its inside.
        triangle(centre, ring[s], ring[s + 1]);
      }
    }
  }

  /// A tapered cylinder standing on the current frame origin along +Z. A thin
  /// convenience over [tube] for straight limbs and grass stems.
  void taperedCylinder({
    required double height,
    required double radiusBottom,
    required double radiusTop,
    int sides = 6,
    double vPerMetre = 0.5,
    bool capEnd = false,
  }) =>
      tube(
        [Vector3.zero, Vector3(0, 0, height)],
        [radiusBottom, radiusTop],
        sides: sides,
        vPerMetre: vPerMetre,
        capEnd: capEnd,
      );

  /// A flat card standing on the current frame origin: [width] across local X,
  /// [height] along local +Z, facing local +Y.
  ///
  /// [twoSided] emits a SECOND coincident quad with reversed winding and
  /// negated normals, so the card reads correctly from either side.
  ///
  /// This is the geometry stand-in for the `gl_FrontFacing` normal flip that a
  /// foliage shader would normally do, and it is not optional. Drawing one quad
  /// through a double-sided material leaves back-facing fragments with a normal
  /// pointing AWAY from the eye; the lighting model then evaluates with a
  /// negative view-dot-normal and its specular term — which is white, and is
  /// not tinted by base colour — blows out. In practice that turned every leaf
  /// clump facing away from the camera into a flat grey mass sitting in an
  /// otherwise green canopy. With two wound copies, back-face culling keeps
  /// exactly the one whose normal faces the eye, so neither copy is ever shaded
  /// inside out and the pair never z-fights (only one is ever rasterised).
  /// [normalOrigin], when set, replaces the card's flat facing normal with one
  /// RADIATING from that local point (biased back toward the card's own facing
  /// by [normalFaceBias] metres).
  ///
  /// This is the difference between foliage that reads as a leafy volume and
  /// foliage that reads as a pile of cardboard. A flat card has one normal, so
  /// it is uniformly lit or uniformly unlit — and in a cluster of cards at
  /// scattered angles that shows up as some clumps blazing and others washing
  /// out to flat grey, with no relation to the shape of the canopy. Radiating
  /// the normals from the cluster's centre makes every card in it shade as part
  /// of one ball: lit on the sun side, dark on the other, exactly as a real
  /// mass of leaves does.
  void card({
    required double width,
    required double height,
    double u0 = 0.0,
    double v0 = 0.0,
    double u1 = 1.0,
    double v1 = 1.0,
    double baseOffset = 0.0,
    Vector3? normalOrigin,
    double normalFaceBias = 0.0,
    bool twoSided = true,
  }) {
    final hw = width * 0.5;
    const face = Vector3(0, 1, 0);

    Vector3 normalAt(Vector3 p) {
      if (normalOrigin == null) return face;
      final out = (p - normalOrigin) + face * normalFaceBias;
      return out.lengthSquared < 1e-12 ? face : out.normalized;
    }

    final pa = Vector3(-hw, 0, baseOffset);
    final pb = Vector3(hw, 0, baseOffset);
    final pc = Vector3(hw, 0, baseOffset + height);
    final pd = Vector3(-hw, 0, baseOffset + height);
    final a = vertex(pa, normalAt(pa), u0, v1);
    final b = vertex(pb, normalAt(pb), u1, v1);
    final c = vertex(pc, normalAt(pc), u1, v0);
    final d = vertex(pd, normalAt(pd), u0, v0);
    // a,d,c,b runs anticlockwise about +Y, matching the +Y facing normal (see
    // [triangle] on why the order is the right-hand one, not the engine's).
    quad(a, d, c, b);
    if (!twoSided) return;
    // Same corners and UVs; reversed order, so the opposite winding pairs with
    // the opposite normals.
    final a2 = vertex(pa, -normalAt(pa), u0, v1);
    final b2 = vertex(pb, -normalAt(pb), u1, v1);
    final c2 = vertex(pc, -normalAt(pc), u1, v0);
    final d2 = vertex(pd, -normalAt(pd), u0, v0);
    quad(b2, c2, d2, a2);
  }

  /// [planes] cards evenly rolled about the heading — the classic cross-quad
  /// foliage cluster, which keeps a leafy silhouette from every viewing angle
  /// at 2-3 quads instead of hundreds of modelled leaves.
  ///
  /// [sphericalNormals] shades the whole cluster as one ball; see [card].
  void crossCards({
    required double width,
    required double height,
    int planes = 3,
    double u0 = 0.0,
    double v0 = 0.0,
    double u1 = 1.0,
    double v1 = 1.0,
    double baseOffset = 0.0,
    bool sphericalNormals = true,
  }) {
    // The cluster's centre, in the (roll-invariant) frame every plane shares.
    final origin = sphericalNormals
        ? Vector3(0, 0, baseOffset + height * 0.5)
        : null;
    // Enough face bias that a vertex level with the centre still tilts out of
    // the card plane; without it those vertices get an in-plane normal and the
    // card goes black edge-on.
    final bias = height * 0.45;
    for (var i = 0; i < planes; i++) {
      push();
      roll(math.pi * i / planes);
      card(
        width: width,
        height: height,
        u0: u0,
        v0: v0,
        u1: u1,
        v1: v1,
        baseOffset: baseOffset,
        normalOrigin: origin,
        normalFaceBias: bias,
      );
      pop();
    }
  }

  /// A tapering strip along [spine] (current-frame points) with per-point
  /// [halfWidths] — grass blades, palm fronds, fern pinnae.
  ///
  /// The strip's width axis is parallel-transported like [tube]'s rings, so a
  /// blade that curls over stays a coherent ribbon instead of twisting edge-on.
  ///
  /// [twoSided] emits the mirrored copy for the same reason [card] does — a
  /// blade seen from behind must not shade with an inverted normal.
  void ribbon(
    List<Vector3> spine,
    List<double> halfWidths, {
    double u0 = 0.0,
    double u1 = 1.0,
    double v0 = 0.0,
    double v1 = 1.0,
    bool twoSided = true,
  }) {
    if (spine.length < 2 || halfWidths.length != spine.length) return;

    final tangents = <Vector3>[];
    for (var i = 0; i < spine.length; i++) {
      final Vector3 t;
      if (i == 0) {
        t = spine[1] - spine[0];
      } else if (i == spine.length - 1) {
        t = spine[i] - spine[i - 1];
      } else {
        t = spine[i + 1] - spine[i - 1];
      }
      tangents.add(t.lengthSquared < 1e-18 ? Vector3.unitZ : t.normalized);
    }

    var ref = tangents[0].z.abs() > 0.9 ? Vector3.unitX : Vector3.unitZ;
    var across = ref - tangents[0] * ref.dot(tangents[0]);
    across = across.lengthSquared < 1e-18 ? Vector3.unitX : across.normalized;

    int? prevL, prevR, prevL2, prevR2;
    for (var i = 0; i < spine.length; i++) {
      if (i > 0) {
        final prev = tangents[i - 1], cur = tangents[i];
        final axis = prev.cross(cur);
        final sin = axis.length;
        if (sin > 1e-9) {
          final angle = math.atan2(sin, prev.dot(cur));
          across = Quaternion.axisAngle(axis, angle).rotate(across);
          across = (across - cur * across.dot(cur)).normalized;
        }
      }
      final face = across.cross(tangents[i]);
      final t = i / (spine.length - 1);
      final v = v0 + (v1 - v0) * t;
      final w = halfWidths[i];
      final pl = spine[i] - across * w, pr = spine[i] + across * w;
      final l = vertex(pl, face, u0, v);
      final r = vertex(pr, face, u1, v);
      if (prevL != null && prevR != null) quad(prevL, prevR, r, l);
      prevL = l;
      prevR = r;
      if (!twoSided) continue;
      final l2 = vertex(pl, -face, u0, v);
      final r2 = vertex(pr, -face, u1, v);
      // Reverse of the front strip's order, pairing reversed winding with the
      // reversed normals.
      if (prevL2 != null && prevR2 != null) quad(l2, r2, prevR2, prevL2);
      prevL2 = l2;
      prevR2 = r2;
    }
  }

  /// A displaced icosphere centred on the current frame origin.
  ///
  /// [radius] is scaled per-axis by [axisScale] (the "potato" squash) and each
  /// vertex is pushed along its own direction by [displace], which the rock
  /// generator wires to 3D noise. [faceted] emits unshared vertices with face
  /// normals for angular, fractured stone; smooth shading rounds it off.
  /// [warp] gets the last word on every placed vertex — the rock generator uses
  /// it to shear the surface off flat where the prop meets the ground, so a
  /// boulder sits half-buried instead of balancing on a sphere's tangent point.
  void icosphere({
    required double radius,
    int subdivisions = 2,
    Vector3 axisScale = const Vector3(1, 1, 1),
    double Function(Vector3 dir)? displace,
    Vector3 Function(Vector3 placed)? warp,
    bool faceted = false,
    double uScale = 1.0,
  }) {
    final (verts, faces) = _icosaGeodesic(subdivisions);

    Vector3 place(Vector3 dir) {
      final r = radius * (displace == null ? 1.0 : displace(dir));
      final p = Vector3(
        dir.x * r * axisScale.x,
        dir.y * r * axisScale.y,
        dir.z * r * axisScale.z,
      );
      return warp == null ? p : warp(p);
    }

    if (faceted) {
      for (final f in faces) {
        flatTriangle(
          place(verts[f[0]]),
          place(verts[f[1]]),
          place(verts[f[2]]),
          uScale: uScale,
        );
      }
      return;
    }

    // Smooth: share vertices and accumulate area-weighted face normals, then
    // normalise. The displaced surface's true normal is NOT the direction from
    // the centre once the noise bites, so using the direction would flatten the
    // lumps the displacement just carved.
    final placed = verts.map(place).toList(growable: false);
    final acc = List<Vector3>.filled(placed.length, Vector3.zero);
    for (final f in faces) {
      final a = placed[f[0]], b = placed[f[1]], c = placed[f[2]];
      final n = (b - a).cross(c - a); // length = 2 * area
      acc[f[0]] = acc[f[0]] + n;
      acc[f[1]] = acc[f[1]] + n;
      acc[f[2]] = acc[f[2]] + n;
    }
    final base = <int>[];
    for (var i = 0; i < placed.length; i++) {
      final n = acc[i].lengthSquared < 1e-18
          ? verts[i]
          : acc[i].normalized;
      final d = verts[i];
      // Spherical UVs; the seam duplication that a textured globe needs is
      // unnecessary here because the rock texture is isotropic noise.
      final u = (math.atan2(d.y, d.x) / (2 * math.pi) + 0.5) * uScale;
      final v = (math.acos(d.z.clamp(-1.0, 1.0)) / math.pi) * uScale;
      base.add(vertex(placed[i], n, u, v));
    }
    for (final f in faces) {
      triangle(base[f[0]], base[f[1]], base[f[2]]);
    }
  }

  // ---- Result -------------------------------------------------------------

  PropMesh build() => PropMesh(
        positions: Float32List.fromList(_positions),
        normals: Float32List.fromList(_normals),
        texCoords: Float32List.fromList(_texCoords),
        indices: Uint32List.fromList(_indices),
      );

  // ---- Icosahedron geodesic ----------------------------------------------

  /// Unit-sphere vertices + triangles from [subdivisions] rounds of 4-way
  /// splitting an icosahedron. Cached: the rock generator asks for the same two
  /// or three levels for every rock in a field.
  static final Map<int, (List<Vector3>, List<List<int>>)> _geodesicCache = {};

  static (List<Vector3>, List<List<int>>) _icosaGeodesic(int subdivisions) {
    final level = subdivisions.clamp(0, 4);
    final hit = _geodesicCache[level];
    if (hit != null) return hit;

    const t = 1.6180339887498949; // golden ratio
    var verts = <Vector3>[
      Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0),
      Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
      Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1),
      Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
    ].map((v) => v.normalized).toList();

    var faces = <List<int>>[
      [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
      [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
      [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
      [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
    ];

    for (var s = 0; s < level; s++) {
      final midpoints = <int, int>{};
      final next = <List<int>>[];
      int mid(int a, int b) {
        final key = a < b ? a * 100000 + b : b * 100000 + a;
        final cached = midpoints[key];
        if (cached != null) return cached;
        final m = ((verts[a] + verts[b]) * 0.5).normalized;
        verts.add(m);
        final idx = verts.length - 1;
        midpoints[key] = idx;
        return idx;
      }

      for (final f in faces) {
        final a = mid(f[0], f[1]), b = mid(f[1], f[2]), c = mid(f[2], f[0]);
        next.addAll([
          [f[0], a, c],
          [f[1], b, a],
          [f[2], c, b],
          [a, b, c],
        ]);
      }
      faces = next;
    }

    final result = (
      List<Vector3>.unmodifiable(verts),
      List<List<int>>.unmodifiable(faces),
    );
    _geodesicCache[level] = result;
    return result;
  }
}

/// Two [MeshBuilder]s — one opaque, one alpha-masked — driven by a SINGLE
/// shared turtle.
///
/// A prop's bark and its leaves need different materials and so different
/// meshes, but they are grown by one traversal: the leaf cluster at a branch tip
/// is placed by exactly the frame that just finished drawing that branch.
/// Keeping two independent turtles in step by hand is precisely the kind of
/// bookkeeping that silently drifts, so every turtle command here is forwarded
/// to both builders and the two frames are identical by construction.
class PropBuilder {
  /// Bark, wood, stone — opaque, back-face culled.
  final MeshBuilder solid = MeshBuilder();

  /// Leaves, needles, blades, fronds — alpha-masked, double-sided.
  final MeshBuilder foliage = MeshBuilder();

  void push() {
    solid.push();
    foliage.push();
  }

  void pop() {
    solid.pop();
    foliage.pop();
  }

  void move(Vector3 delta) {
    solid.move(delta);
    foliage.move(delta);
  }

  void forward(double d) {
    solid.forward(d);
    foliage.forward(d);
  }

  void turn(Quaternion q) {
    solid.turn(q);
    foliage.turn(q);
  }

  void pitch(double a) {
    solid.pitch(a);
    foliage.pitch(a);
  }

  void roll(double a) {
    solid.roll(a);
    foliage.roll(a);
  }

  void yaw(double a) {
    solid.yaw(a);
    foliage.yaw(a);
  }

  void scaleBy(double s) {
    solid.scaleBy(s);
    foliage.scaleBy(s);
  }

  void resetFrame() {
    solid.resetFrame();
    foliage.resetFrame();
  }

  // The two frames are identical, so either builder answers a query.
  Vector3 get position => solid.position;
  Quaternion get orientation => solid.orientation;
  Vector3 get heading => solid.heading;
  Vector3 get upInFrame => solid.upInFrame;
  Vector3 toMesh(Vector3 local) => solid.toMesh(local);

  /// Rotate the frame [amount] of the way from the current heading toward world
  /// up (1.0 = fully upright). Used to stand foliage clusters up on a branch
  /// that is itself near horizontal, and to droop conifer limbs (negative
  /// amounts rotate away from up).
  void alignToUp(double amount) {
    final up = upInFrame;
    final axis = Vector3.unitZ.cross(up);
    final sin = axis.length;
    if (sin < 1e-9) return;
    final angle = math.atan2(sin, up.z);
    turn(Quaternion.axisAngle(axis, angle * amount));
  }

  PropModel build() =>
      PropModel(solid: solid.build(), foliage: foliage.build());
}
