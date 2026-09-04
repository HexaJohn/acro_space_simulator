// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A block face, built on demand: one road, a row of lots, a building on each.
///
/// The city studio answers "can we afford a colony"; this answers a different
/// question that it is bad at — "is this building RIGHT". A whole generated
/// city is the worst possible place to judge a facade, because everything you
/// want to look at is 400 m away behind a hundred other buildings, and every
/// change costs a twelve-second regeneration before you can see it.
///
/// So: no terrain, no simulation, no streaming. A flat ground plane, a
/// straight street, and as many lots as you ask for, rebuilt in a few
/// milliseconds. What it keeps from the real path is the part being judged —
/// the same [BuildingGenerator], the same styles, the same materials, and the
/// same parcel geometry the colony hands its buildings — so what you tune here
/// is what the colony gets.
///
/// The ROW is the point. A single hero building tells you nothing about the
/// thing that actually makes a street look like a street: whether its
/// neighbours line up, whether the frontages meet, whether the parking has
/// punched a hole in the block.
library;

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_materials.dart';
import 'city_nodes.dart';
import 'scale_rig.dart';

/// What the studio wants drawn.
/// The outline a preview lot is cut to.
///
/// The massing reads a lot as its frontage-aligned bounding box and a corner
/// flag, so what a shape changes is exactly that box — and the outline drawn
/// beside the building is what shows where the two disagree. That is the
/// point of offering shapes: a tapered lot is what a bent street plats, and
/// the generator's answer to it is worth seeing before a colony makes
/// a thousand of them.
enum LotShape {
  rectangle('Rectangle', 'The plat\'s default: a straight street, even cuts.'),
  tapered('Tapered', 'Narrower at the back: the lot a street bending AWAY leaves.'),
  flared('Flared', 'Wider at the back: the lot a street bending TOWARD leaves.'),
  notched('L-shaped', 'A notch taken out of the back corner, as a neighbour\'s '
      'assemblage would.'),
  cornerCut('Corner cut', 'A diagonal across the street corner, as a junction '
      'splay takes it.');

  const LotShape(this.label, this.note);
  final String label;
  final String note;
}

class BuildingPreviewRequest {
  const BuildingPreviewRequest({
    required this.style,
    required this.spec,
    required this.lotWidthM,
    required this.lotDepthM,
    required this.lots,
    required this.seed,
    required this.detail,
    this.varySeeds = true,
    this.showRig = true,
    this.showLots = true,
    this.corners = true,
    this.shape = LotShape.rectangle,
    this.manualPlot = false,
  });

  /// The outline each lot is cut to.
  final LotShape shape;

  /// Hand the generator what an INSTALLATION gets in the colony: a claimed
  /// plot with no frontage and no side street, so its axes are the world's
  /// and its depth is the whole box — not the street lot the row otherwise
  /// stands on.
  final bool manualPlot;

  final ArchitectureStyle style;
  final CityBuildingSpec spec;

  /// Frontage width of one lot, curb to curb of its neighbours.
  final double lotWidthM;

  /// How deep the lots run back from the street.
  final double lotDepthM;

  /// Lots along the block face. One is a hero shot; five is a street.
  final int lots;

  final int seed;
  final BuildingDetail detail;

  /// Give each lot its own seed. Off shows one building repeated, which is how
  /// you inspect a single design; on shows what a real row would look like.
  final bool varySeeds;

  final bool showRig;

  /// Draw the property lines. The whole question here is how a building sits
  /// on its lot, and you cannot see that without seeing the lot.
  final bool showLots;

  /// Make the two END lots corner lots, the way a real block face is.
  ///
  /// A corner building is the one worth looking at: two public faces, no blank
  /// flank, and the extra storey that makes a block's silhouette. Previewing a
  /// row of mid-block lots hides all of it.
  final bool corners;

  double get blockWidthM => lotWidthM * lots;

  @override
  bool operator ==(Object other) =>
      other is BuildingPreviewRequest &&
      other.style.id == style.id &&
      other.spec.type == spec.type &&
      other.spec.label == spec.label &&
      other.lotWidthM == lotWidthM &&
      other.lotDepthM == lotDepthM &&
      other.lots == lots &&
      other.seed == seed &&
      other.detail == detail &&
      other.varySeeds == varySeeds &&
      other.showRig == showRig &&
      other.showLots == showLots &&
      other.corners == corners &&
      other.shape == shape &&
      other.manualPlot == manualPlot;

  @override
  int get hashCode => Object.hash(style.id, spec.type, spec.label, lotWidthM,
      lotDepthM, lots, seed, detail, varySeeds, showRig, showLots, corners,
      shape, manualPlot);
}

/// What the last rebuild produced, for the HUD.
class BuildingPreviewStats {
  const BuildingPreviewStats({
    this.triangles = 0,
    this.drawCalls = 0,
    this.floors = 0,
    this.heightM = 0,
    this.footprintW = 0,
    this.footprintD = 0,
    this.floorAreaM2 = 0,
    this.parkingSpaces = 0,
    this.frontGapM = 0,
    this.sideGapM = 0,
    this.buildMs = 0,
    this.lotAreaM2 = 0,
    this.coverage = 0,
    this.overhangs = false,
  });

  final int triangles;
  final int drawCalls;
  final int floors;
  final double heightM;
  final double footprintW;
  final double footprintD;
  final double floorAreaM2;
  final int parkingSpaces;

  /// The lot's own area, and how much of it the footprint covers.
  final double lotAreaM2;
  final double coverage;

  /// Whether any volume's corner falls OUTSIDE the lot polygon — what a
  /// bounding-box massing does on a tapered or notched lot.
  final bool overhangs;

  /// Distance from the curb line to the building face. The number the whole
  /// street-wall question comes down to.
  final double frontGapM;

  /// Gap left between one building and its neighbour. Zero is a party wall.
  final double sideGapM;

  final double buildMs;
}

/// Builds and owns the studio's scene nodes.
class BuildingPreviewNodes {
  BuildingPreviewNodes(this._scene);

  final fs.Scene _scene;
  final List<fs.Node> _nodes = [];

  BuildingPreviewRequest? _built;
  BuildingPreviewStats stats = const BuildingPreviewStats();

  /// Half-extent of everything drawn, so the screen can frame it.
  double layoutRadiusM = 40;

  /// Road half-width. A two-lane street with parking on both sides.
  static const double roadHalfWidthM = 8.5;

  /// Pavement between the curb and the property line.
  static const double pavementM = 3.0;

  void update(BuildingPreviewRequest request) {
    if (_built == request) return;
    _built = request;
    _rebuild(request);
  }

  void invalidate() => _built = null;

  void _rebuild(BuildingPreviewRequest r) {
    final sw = Stopwatch()..start();
    _clear();

    // Lot-local axes match the massing's: x along the street, y away from it,
    // z up. The street runs along x at y = -(pavement + lotDepth/2) once the
    // lots are centred on the origin, so put the curb where the parcels' own
    // frontage edge says it is and let everything else follow.
    final generator = const BuildingGenerator().withStyle(r.style);
    final solid = MeshBuilder();
    final glass = MeshBuilder();
    final ground = MeshBuilder();
    final road = MeshBuilder();

    final blockW = r.blockWidthM;
    final halfBlock = blockW / 2;
    // y = 0 is the FRONT property line; lots run back to +lotDepth.
    final curbY = -pavementM;

    _groundPlane(ground, blockW, r.lotDepthM);
    _road(road, blockW, curbY);
    _pavement(ground, blockW, curbY);

    var floors = 0, spaces = 0;
    var height = 0.0, fw = 0.0, fd = 0.0, area = 0.0;
    var frontGap = double.infinity;
    var lotArea = 0.0, footArea = 0.0;
    var overhangs = false;
    final faces = <(double lo, double hi)>[];

    for (var i = 0; i < r.lots; i++) {
      final x0 = -halfBlock + r.lotWidthM * i;
      final centreX = x0 + r.lotWidthM / 2;
      final parcel = _lot(i, x0, r.lotWidthM, r.lotDepthM,
          corner: r.corners && (i == 0 || i == r.lots - 1),
          shape: r.shape,
          manual: r.manualPlot);
      if (r.showLots) _lotOutline(ground, centreX, parcel.polygon);

      final built = generator.generate(
        r.spec,
        parcel,
        seed: r.varySeeds ? r.seed + i : r.seed,
        detail: r.detail,
      );

      // The generator works in lot-local metres with the lot centred on its
      // own origin; move it onto this lot's slice of the block.
      final offsetY = r.lotDepthM / 2;
      appendMesh(solid, built.model.solid, centreX, offsetY);
      appendMesh(glass, built.model.foliage, centreX, offsetY);

      final m = built.massing;
      floors = math.max(floors, m.floors);
      height = math.max(height, m.height);
      fw = math.max(fw, m.footprint.width);
      fd = math.max(fd, m.footprint.depth);
      area = math.max(area, m.floorArea);
      spaces = math.max(spaces, m.parking?.spaces ?? 0);

      for (final v in m.volumes.where((v) => v.floors > 0)) {
        frontGap = math.min(frontGap, (v.y - v.depth / 2 + offsetY) - curbY);
        faces.add((centreX + v.x - v.width / 2, centreX + v.x + v.width / 2));
      }
      // How the massing sits in the lot it was handed: the generator works
      // about the lot's centroid, so a volume corner is tested there.
      lotArea = math.max(lotArea, parcel.area);
      footArea = math.max(footArea, m.footprint.width * m.footprint.depth);
      final c = parcel.centroid;
      for (final v in m.volumes) {
        for (final sx in const [-0.5, 0.5]) {
          for (final sy in const [-0.5, 0.5]) {
            final corner =
                Vec2(c.e + v.x + v.width * sx, c.n + v.y + v.depth * sy);
            if (!parcel.contains(corner)) overhangs = true;
          }
        }
      }
    }

    // Gap between one building's right edge and the next one's left edge.
    faces.sort((a, b) => a.$1.compareTo(b.$1));
    var sideGap = 0.0;
    for (var i = 1; i < faces.length; i++) {
      sideGap = math.max(sideGap, faces[i].$1 - faces[i - 1].$2);
    }

    if (r.showRig) {
      // Beside the block, on the far pavement, where it does not hide the
      // frontage it exists to measure.
      ScaleRig.emit(solid, glass,
          Vector3(-halfBlock - 10, curbY - roadHalfWidthM * 2, 0),
          const Vector3(0, 1, 0), const Vector3(0, 0, 1));
    }

    var tris = 0, draws = 0;
    for (final (builder, material) in [
      (ground, CityMaterials.ground),
      (road, CityMaterials.road),
      (solid, CityMaterials.facade),
      (glass, CityMaterials.glazing),
    ]) {
      final mesh = builder.build();
      if (mesh.isEmpty) continue;
      final geometry = CityNodes.geometryOf(mesh);
      if (geometry == null) continue;
      final node = fs.Node(
        mesh: fs.Mesh.primitives(
            primitives: [fs.MeshPrimitive(geometry, material)]),
      );
      // Meshes are authored in METRES; the scene renders in kilometres, so the
      // conversion rides the node transform and the geometry stays honest.
      final s = lengthToScene(1.0);
      node.localTransform = vm.Matrix4.diagonal3Values(s, s, s);
      _scene.add(node);
      _nodes.add(node);
      tris += mesh.triangleCount;
      draws++;
    }

    layoutRadiusM = math.max(blockW, r.lotDepthM + roadHalfWidthM * 2) / 2 + 12;
    stats = BuildingPreviewStats(
      triangles: tris,
      drawCalls: draws,
      floors: floors,
      heightM: height,
      footprintW: fw,
      footprintD: fd,
      floorAreaM2: area,
      parkingSpaces: spaces,
      frontGapM: frontGap.isFinite ? frontGap - pavementM : 0,
      sideGapM: sideGap,
      buildMs: sw.elapsedMicroseconds / 1000,
      lotAreaM2: lotArea,
      coverage: lotArea > 0 ? (footArea / lotArea).clamp(0.0, 9.0) : 0,
      overhangs: overhangs,
    );
  }

  /// One rectangular lot fronting the street, in the axes the massing expects:
  /// the frontage edge at y = 0, the lot running back to +depth, centred on
  /// x = 0. The block offset is applied to the finished geometry instead, so
  /// every lot generates identical archetypes and only the placement differs —
  /// which is exactly what the colony does.
  Parcel _lot(int index, double x0, double w, double d,
      {bool corner = false,
      LotShape shape = LotShape.rectangle,
      bool manual = false}) {
    final polygon = polygonFor(shape, w, d);
    if (manual) {
      // A claimed plot: no frontage, no side street, world-aligned — the
      // parcel an installation is really handed.
      return Parcel(id: 'studio-$index', polygon: polygon, manual: true);
    }
    return Parcel(
      id: 'studio-$index',
      polygon: polygon,
      frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      sideStreet: corner ? (Vec2(w / 2, 0), Vec2(w / 2, d)) : null,
    );
  }

  /// A lot outline of [shape], [w] across the frontage (at y = 0) and [d]
  /// deep, wound counter-clockwise like the plat's own.
  static List<Vec2> polygonFor(LotShape shape, double w, double d) {
    final h = w / 2;
    return switch (shape) {
      LotShape.rectangle => [
          Vec2(-h, 0),
          Vec2(h, 0),
          Vec2(h, d),
          Vec2(-h, d),
        ],
      LotShape.tapered => [
          Vec2(-h, 0),
          Vec2(h, 0),
          Vec2(w * 0.32, d),
          Vec2(-w * 0.32, d),
        ],
      LotShape.flared => [
          Vec2(-h, 0),
          Vec2(h, 0),
          Vec2(w * 0.72, d),
          Vec2(-w * 0.72, d),
        ],
      LotShape.notched => [
          Vec2(-h, 0),
          Vec2(h, 0),
          Vec2(h, d * 0.55),
          Vec2(w * 0.1, d * 0.55),
          Vec2(w * 0.1, d),
          Vec2(-h, d),
        ],
      LotShape.cornerCut => [
          Vec2(-h, 0),
          Vec2(w * 0.2, 0),
          Vec2(h, d * 0.35),
          Vec2(h, d),
          Vec2(-h, d),
        ],
    };
  }

  /// Copy a generated mesh into the shared builder, shifted onto its lot.
  ///
  /// Static so it can be measured without a scene: whether this preserves
  /// winding is the difference between a street and an empty road, and it is
  /// not a thing to find out by looking.
  static void appendMesh(
      MeshBuilder into, PropMesh mesh, double dx, double dy) {
    final p = mesh.positions, n = mesh.normals, t = mesh.texCoords;
    if (p.isEmpty) return;
    final base = <int>[];
    for (var i = 0; i + 2 < p.length; i += 3) {
      final uv = i ~/ 3 * 2;
      base.add(into.vertex(
        Vector3(p[i] + dx, p[i + 1] + dy, p[i + 2]),
        Vector3(n[i], n[i + 1], n[i + 2]),
        uv + 1 < t.length ? t[uv] : 0,
        uv + 1 < t.length ? t[uv + 1] : 0,
      ));
    }
    // The winding must arrive VERBATIM. `MeshBuilder.triangle(a, b, c)` emits
    // (a, c, b) — it reverses what it is handed — so the triple is swapped
    // going in to cancel that out. Feeding it straight through flips every
    // face and turns the whole block inside out, which looks like the
    // buildings having vanished.
    final idx = mesh.indices;
    for (var i = 0; i + 2 < idx.length; i += 3) {
      into.triangle(base[idx[i]], base[idx[i + 2]], base[idx[i + 1]]);
    }
  }

  void _groundPlane(MeshBuilder m, double blockW, double lotD) {
    final w = blockW / 2 + 40;
    _quad(
      m,
      Vector3(-w, -roadHalfWidthM * 2 - pavementM - 30, -0.05),
      Vector3(w, -roadHalfWidthM * 2 - pavementM - 30, -0.05),
      Vector3(w, lotD + 30, -0.05),
      Vector3(-w, lotD + 30, -0.05),
      const Vector3(0, 0, 1),
      // The ground palette is a strip of bands, sampled at a band's MIDDLE so
      // filtering cannot bleed a neighbouring colour in. Residential is the
      // green one — the studio's surround is meant to read as land, and the
      // palette has no separate grass band to spend.
      u: (CityPatchSnapshot.kindResidential + 0.5) / kGroundSwatches,
    );
  }

  void _road(MeshBuilder m, double blockW, double curbY) {
    final w = blockW / 2 + 40;
    final y1 = curbY, y0 = curbY - roadHalfWidthM * 2;
    // U runs ACROSS the carriageway (curb, centre line, curb); V along it.
    final v = math.max(1.0, (w * 2 / 18).roundToDouble());
    final i0 = m.vertex(Vector3(-w, y0, 0), const Vector3(0, 0, 1), 0, 0);
    final i1 = m.vertex(Vector3(w, y0, 0), const Vector3(0, 0, 1), 0, v);
    final i2 = m.vertex(Vector3(w, y1, 0), const Vector3(0, 0, 1), 1, v);
    final i3 = m.vertex(Vector3(-w, y1, 0), const Vector3(0, 0, 1), 1, 0);
    m.quad(i0, i1, i2, i3);
  }

  void _pavement(MeshBuilder m, double blockW, double curbY) {
    final w = blockW / 2 + 40;
    _quad(
      m,
      Vector3(-w, curbY, 0.12),
      Vector3(w, curbY, 0.12),
      Vector3(w, 0, 0.12),
      Vector3(-w, 0, 0.12),
      const Vector3(0, 0, 1),
      u: (CityPatchSnapshot.kindSupport + 0.5) / kGroundSwatches,
    );
  }

  /// The property line: a thin strip along every edge of the lot polygon,
  /// which is centred on [centreX]. Strips rather than a filled quad so a
  /// building standing on its line does not z-fight the lot it stands on.
  void _lotOutline(MeshBuilder m, double centreX, List<Vec2> polygon) {
    const t = 0.35;
    // The placement-heatmap 'site ok' swatch: a bright green, which is
    // exactly what a property line wants to be against grass and tarmac.
    const u = (7 + 0.5) / kGroundSwatches;
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % polygon.length];
      final d = b - a;
      if (d.length < 1e-6) continue;
      final n = d.perp.normalized * (t / 2);
      _quad(
        m,
        Vector3(centreX + a.e - n.e, a.n - n.n, 0.06),
        Vector3(centreX + b.e - n.e, b.n - n.n, 0.06),
        Vector3(centreX + b.e + n.e, b.n + n.n, 0.06),
        Vector3(centreX + a.e + n.e, a.n + n.n, 0.06),
        const Vector3(0, 0, 1),
        u: u,
      );
    }
  }

  void _quad(MeshBuilder m, Vector3 a, Vector3 b, Vector3 c, Vector3 d,
      Vector3 n, {required double u}) {
    final i0 = m.vertex(a, n, u, 0);
    final i1 = m.vertex(b, n, u, 1);
    final i2 = m.vertex(c, n, u, 1);
    final i3 = m.vertex(d, n, u, 0);
    // Corners anticlockwise seen from above, emitted in that order — copied
    // off the city's own ground-patch pass, which is known to render face up.
    // Reversed, the whole studio would open onto bare space with the buildings
    // floating over nothing.
    m.quad(i0, i1, i2, i3);
  }

  void _clear() {
    for (final n in _nodes) {
      _scene.remove(n);
    }
    _nodes.clear();
  }

  void dispose() => _clear();
}
