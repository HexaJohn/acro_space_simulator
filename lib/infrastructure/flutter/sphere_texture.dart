import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../adapters/presenters/camera_view.dart';
import '../../domain/shared/vector3.dart';

/// Draws an equirectangular surface map onto a body disc as a lit, orthographic
/// sphere — the visible hemisphere facing the camera, UV-sampled from the map
/// and shaded by the sun direction.
///
/// It works by tessellating the disc into a triangle mesh (a grid over the
/// projected unit circle). Each vertex is a point on the front hemisphere of the
/// unit sphere in *camera frame* (z toward viewer); we rotate it into the
/// world/body frame for the current [CameraView] to get its longitude/latitude,
/// which becomes the texture UV. Per-vertex Lambert shading vs. the sun is baked
/// into the vertex colours and multiplied with the image. GPU-accelerated via
/// [Canvas.drawVertices].
class SphereTexture {
  const SphereTexture();

  /// Mesh is drawn this much larger than the clip circle so its faceted edge
  /// hides behind the antialiased circular clip (no grid stairsteps at the rim).
  /// Public so the painter can size the base disc to the SAME capped extent and
  /// keep the two aligned.
  static const double overscan = 1.06;

  void paint(
    ui.Canvas canvas,
    ui.Image image,
    ui.Offset centre,
    double rPx, {
    required SceneCamera view,
    required Vector3 sunWorld, // body -> star, WORLD frame (unit)
    Vector3 worldRel = Vector3.zero, // body position relative to the eye/focus
    double spin = 0, // body rotation about +Z (rad) — offsets texture longitude
    bool selfLuminous = false,
    bool shadow = true, // draw the night-side darkening pass
    ui.Color? atmoTint, // atmosphere day colour; null = no atmosphere pass
    ui.Color atmoWarm = const ui.Color(0xFFFF9D5C), // terminator warm band
    double? coverPx, // on-screen half-extent the mesh must cover (see below)
    required double radiusM, // body radius (m), for the surface projection
    required ui.Offset viewportCentre, // canvas px of the screen centre
  }) {
    // Bail on non-finite inputs (degenerate camera geometry can produce NaN/Inf
    // in the centre / worldRel); a single bad vertex makes Skia drop the whole
    // mesh, blanking the body. Better to skip this body's sphere this frame.
    if (!centre.dx.isFinite ||
        !centre.dy.isFinite ||
        !rPx.isFinite ||
        !worldRel.x.isFinite ||
        !worldRel.y.isFinite ||
        !worldRel.z.isFinite) {
      return;
    }

    // When zoomed in so close the disc dwarfs the screen, [rPx] can be millions
    // of px. Spanning the WHOLE hemisphere at that scale overflows Skia (blank
    // frame) — and capping the mesh radius froze the zoom (the surface stopped
    // magnifying). Instead we keep TRUE [rPx] scale but only tessellate the
    // VISIBLE cap: vertices range over nx,ny in [-span, span] (a fraction of the
    // unit sphere) where span covers [coverPx] on screen. So detail keeps
    // growing as you zoom, and coordinates stay ~screen-sized. span=1 = the full
    // hemisphere (normal, far-away case).
    final positions = <ui.Offset>[];
    final texCoords = <ui.Offset>[];
    final atmoColors = <ui.Color>[]; // per-vertex atmosphere scatter (pass 3)
    final shadowColors = <ui.Color>[]; // per-vertex night-side darkening (pass 2)

    final iw = image.width.toDouble();
    final ih = image.height.toDouble();

    // World sun direction in the CAMERA frame (x=right, y=up, z=toward viewer =
    // -forward), matching the per-vertex camera-frame normals below, so the
    // Lambert dot is a true cos(angle) from any camera angle.
    final sun = _norm3(
      sunWorld.dot(view.right),
      sunWorld.dot(view.up),
      sunWorld.dot(view.forward) * -1,
    );

    // Every surface vertex is projected through the REAL camera (no flat
    // billboard) so the sphere is correct from any distance — including an eye
    // at the surface, where the horizon (the tangent circle from the eye) falls
    // out of the projection naturally.
    //
    // worldRel is the body centre relative to the camera FOCUS; the eye is pulled
    // back from the focus by view.eyeOffset, so the centre relative to the EYE is
    // worldRel - eyeOffset (eyeOffset is zero for ortho's parallel rays). Used
    // for the per-vertex horizon cull below.
    final centreFromEye = worldRel - view.eyeOffset;
    final eyeDist = centreFromEye.length;
    // Clip the mesh to a crisp limb CIRCLE when the silhouette really is a circle
    // (far away / ortho); skip the clip when the eye is within ~1 radius of the
    // surface, where the limb is the projected horizon arc, not a circle.
    final clipCircle =
        radiusM <= 0 || view.eyeOffset == Vector3.zero || (eyeDist - radiusM) >= radiusM;

    // GROUND-ANCHORED ADAPTIVE QUADTREE (body space). Recursively subdivide the
    // sphere in lat/lon; a node splits when its projected on-screen size exceeds
    // a target, so detail concentrates wherever the camera actually looks
    // (nadir, the horizon when tilted, an off-axis body) — not assumed at the
    // centre. Vertices sit at FIXED lat/lon corners (welded via a cache), so the
    // mesh is anchored to the ground and doesn't swim as the eye/planet moves.
    final camR = view.right, camU = view.up, camF = view.forward;

    // Evaluate a body-fixed (lat, lon) surface corner -> a projected _V, cached
    // so shared corners weld (no cracks, no swim). Returns null if behind the
    // near plane. [visible] also reports whether it's above the local horizon /
    // front-facing, used to prune whole nodes.
    final cache = <int, _V?>{};
    final visCache = <int, bool>{};
    const lonKeyScale = 100000.0;
    int keyOf(double lat, double lon) =>
        (lat * lonKeyScale).round() * 1000000007 + (lon * lonKeyScale).round();

    bool cornerVisible(double lat, double lon) {
      final k = keyOf(lat, lon);
      final hit = visCache[k];
      if (hit != null) return hit;
      final cl = math.cos(lat), sl = math.sin(lat);
      final nx = cl * math.cos(lon + spin),
          ny = cl * math.sin(lon + spin),
          nz = sl;
      bool vis;
      if (radiusM > 0) {
        vis = -(centreFromEye.x * nx + centreFromEye.y * ny + centreFromEye.z * nz) >
            radiusM;
      } else {
        vis = -(nx * camF.x + ny * camF.y + nz * camF.z) > 0;
      }
      visCache[k] = vis;
      return vis;
    }

    _V? evalCorner(double lat, double lon) {
      final k = keyOf(lat, lon);
      if (cache.containsKey(k)) return cache[k];
      final cl = math.cos(lat), sl = math.sin(lat);
      // +spin rotates the geometry with epoch; the texture uses body-fixed lon.
      final gLon = lon + spin;
      final nx = cl * math.cos(gLon), ny = cl * math.sin(gLon), nz = sl;
      final relFocus = Vector3(
        worldRel.x + radiusM * nx,
        worldRel.y + radiusM * ny,
        worldRel.z + radiusM * nz,
      );
      final p = view.projectPx(relFocus);
      if (p == null) {
        cache[k] = null;
        return null;
      }
      final pos = ui.Offset(viewportCentre.dx + p.x, viewportCentre.dy - p.y);
      final u = (lon + math.pi) / (2 * math.pi); // body-fixed longitude -> u
      final v = (math.pi / 2 - lat) / math.pi;
      final cnx = nx * camR.x + ny * camR.y + nz * camR.z;
      final cny = nx * camU.x + ny * camU.y + nz * camU.z;
      final cnz = -(nx * camF.x + ny * camF.y + nz * camF.z);
      final lit = selfLuminous
          ? 1.0
          : (cnx * sun[0] + cny * sun[1] + cnz * sun[2]).clamp(0.0, 1.0);
      final shade = selfLuminous ? 1.0 : (0.12 + 0.88 * lit);
      final day = _smoothstep(0.0, 0.12, lit);
      final limb = math.pow((1.0 - cnz.clamp(0.0, 1.0)), 1.6).toDouble();
      final atmoA = (0.06 + 0.94 * limb) * day;
      final warmF = (1.0 - _smoothstep(0.0, 0.45, lit)) * day;
      final vtx = _V(
        pos: pos,
        uv: ui.Offset(u * iw, v * ih),
        shade: shade,
        atmoA: atmoA,
        warmF: warmF,
      );
      cache[k] = vtx;
      return vtx;
    }

    // Target leaf size on screen (px), ADAPTIVE: a small/far disc needs fine
    // leaves so its LIMB reads round (a 40 px leaf would facet a 200 px planet);
    // a big near disc that fills the screen uses coarse leaves for perf. Scale
    // the target so the disc always has roughly >= 24 leaves across its radius,
    // clamped to [6, 40] px. Depth is capped so a grazing view can't explode;
    // with the screen-bounds prune off-screen subtrees never recurse.
    final targetPx = (rPx / 24.0).clamp(6.0, 40.0);
    final alt = radiusM > 0 ? (eyeDist - radiusM) : double.infinity;
    final maxDepth = (radiusM > 0 && alt < radiusM) ? 7 : 6;


    // Screen bounds (canvas px) with a generous margin so a node straddling the
    // edge still tessellates; nodes entirely off ONE edge are pruned.
    final screenW = viewportCentre.dx * 2, screenH = viewportCentre.dy * 2;
    final marginX = screenW * 0.5, marginY = screenH * 0.5;

    // Recursively tessellate the lat/lon rectangle [la0,la1]x[lo0,lo1].
    void recurse(double la0, double la1, double lo0, double lo1, int depth) {
      // Prune: skip a node with NO visible corner (its whole span is below the
      // horizon / back-facing). Test the four corners + the centre.
      final laM = (la0 + la1) / 2, loM = (lo0 + lo1) / 2;
      final anyVis = cornerVisible(la0, lo0) ||
          cornerVisible(la0, lo1) ||
          cornerVisible(la1, lo0) ||
          cornerVisible(la1, lo1) ||
          cornerVisible(laM, loM);
      if (!anyVis) return;

      final a = evalCorner(la0, lo0);
      final b = evalCorner(la0, lo1);
      final c = evalCorner(la1, lo0);
      final d = evalCorner(la1, lo1);

      // SCREEN-BOUNDS PRUNE: if every projected corner is in front (non-null) and
      // they all lie off the SAME screen edge, the node can't be on screen — skip
      // it (and its subtree). This is the big perf win at low altitude where the
      // visible cap is large but most of it is off-screen. A node with any null
      // corner (crosses the near plane) is kept so the boundary still resolves.
      if (a != null && b != null && c != null && d != null) {
        final minX = math.min(a.pos.dx, math.min(b.pos.dx, math.min(c.pos.dx, d.pos.dx)));
        final maxX = math.max(a.pos.dx, math.max(b.pos.dx, math.max(c.pos.dx, d.pos.dx)));
        final minY = math.min(a.pos.dy, math.min(b.pos.dy, math.min(c.pos.dy, d.pos.dy)));
        final maxY = math.max(a.pos.dy, math.max(b.pos.dy, math.max(c.pos.dy, d.pos.dy)));
        if (maxX < -marginX ||
            minX > screenW + marginX ||
            maxY < -marginY ||
            minY > screenH + marginY) {
          return; // wholly off one edge
        }
      }

      // Decide whether to split: too big on screen (use the projected diagonal of
      // whatever corners we have) and depth remains. If a corner is behind the
      // near plane (null) we must split to resolve the boundary.
      var split = depth < maxDepth;
      if (split && a != null && b != null && c != null && d != null) {
        double seg(ui.Offset p, ui.Offset q) {
          final dx = p.dx - q.dx, dy = p.dy - q.dy;
          return math.sqrt(dx * dx + dy * dy);
        }
        final size = math.max(seg(a.pos, b.pos),
            math.max(seg(a.pos, c.pos), math.max(seg(b.pos, d.pos), seg(c.pos, d.pos))));
        if (size <= targetPx) split = false;
      }

      if (split) {
        recurse(la0, laM, lo0, loM, depth + 1);
        recurse(la0, laM, loM, lo1, depth + 1);
        recurse(laM, la1, lo0, loM, depth + 1);
        recurse(laM, la1, loM, lo1, depth + 1);
        return;
      }
      // Leaf: emit each of the quad's two triangles independently, so a node
      // STRADDLING the near plane (one corner behind it -> null) still draws the
      // triangle(s) whose three corners are all in front, instead of dropping the
      // whole quad. That's what was culling the ground right in front of the
      // camera at the surface.
      if (a != null && c != null && b != null) {
        _tri(positions, texCoords, shadowColors, atmoColors, atmoTint, atmoWarm,
            a, c, b, iw);
      }
      if (b != null && c != null && d != null) {
        _tri(positions, texCoords, shadowColors, atmoColors, atmoTint, atmoWarm,
            b, c, d, iw);
      }
    }

    // Seed the recursion: split the sphere into coarse lat/lon root tiles
    // (4 lat x 8 lon) so each root is small enough that the projected-size test
    // is meaningful, and so a tile straddling the seam stays narrow.
    const rootLat = 4, rootLon = 8;
    for (var i = 0; i < rootLat; i++) {
      final la0 = math.pi / 2 - (i / rootLat) * math.pi;
      final la1 = math.pi / 2 - ((i + 1) / rootLat) * math.pi;
      for (var j = 0; j < rootLon; j++) {
        final lo0 = -math.pi + (j / rootLon) * 2 * math.pi;
        final lo1 = -math.pi + ((j + 1) / rootLon) * 2 * math.pi;
        recurse(la0, la1, lo0, lo1, 0);
      }
    }

    if (positions.isEmpty) return;

    final shader = ui.ImageShader(
      image,
      ui.TileMode.repeated, // wrap longitude seam
      ui.TileMode.clamp,
      Float64List.fromList(
          <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
    );

    // FAR / ortho: the silhouette is a clean circle (radius = the projected limb
    // rPx), so clip to it for a crisp antialiased limb (the band mesh edge is
    // otherwise stairstepped). NEAR the surface: the limb is the projected
    // horizon arc, not a circle at `centre`, so don't crop — the horizon-culled
    // mesh defines the shape.
    canvas.save();
    if (clipCircle) {
      canvas.clipPath(
        ui.Path()..addOval(ui.Rect.fromCircle(center: centre, radius: rPx)),
        doAntiAlias: true,
      );
    }

    // PASS 1 — the texture itself. We deliberately DON'T pass vertex colours
    // here: combining `colors` + an image shader in one ui.Vertices trips a
    // null-check inside the web canvas backend. Image-only is rock solid.
    //
    // NOTE: do NOT dispose the Vertices/ImageShader synchronously after the
    // draw. On the web canvas backend the draw is consumed lazily, so an
    // immediate dispose blanks every frame after the first (the cause of the
    // "textured for one frame, then gone" bug). We let them be GC'd instead.
    final texVerts = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: texCoords,
    );
    canvas.drawVertices(
      texVerts,
      ui.BlendMode.srcOver,
      ui.Paint()..shader = shader,
    );

    // PASS 2 — lighting. Overlay a second mesh whose per-vertex colour is a
    // translucent black (alpha = how dark this point is), darkening the night
    // side. No shader here, so no colours+shader interaction.
    if (!selfLuminous && shadow) {
      final shadowVerts = ui.Vertices(
        ui.VertexMode.triangles,
        positions,
        colors: shadowColors,
      );
      canvas.drawVertices(
        shadowVerts,
        ui.BlendMode.srcOver,
        ui.Paint(),
      );
    }

    // PASS 3 — atmosphere. A tinted mesh whose per-vertex alpha is the scatter
    // (day-side, spherical limb falloff). Drawn over the lit surface; rotates
    // with the camera because it's computed per-vertex in 3D.
    if (atmoTint != null && atmoColors.length == positions.length) {
      final atmoVerts = ui.Vertices(
        ui.VertexMode.triangles,
        positions,
        colors: atmoColors,
      );
      canvas.drawVertices(atmoVerts, ui.BlendMode.srcOver, ui.Paint());
    }

    canvas.restore(); // drop the circular clip
  }

  void _tri(List<ui.Offset> p, List<ui.Offset> t, List<ui.Color> s,
      List<ui.Color> atmo, ui.Color? atmoTint, ui.Color atmoWarm, _V a, _V b,
      _V d, double iw) {
    p..add(a.pos)..add(b.pos)..add(d.pos);

    // Per-vertex atmosphere colour: blend the day tint toward the warm
    // terminator band by warmF, modulated by the scatter alpha.
    if (atmoTint != null) {
      ui.Color at(_V vtx) {
        final col = ui.Color.lerp(atmoTint, atmoWarm, vtx.warmF) ?? atmoTint;
        return col.withValues(alpha: vtx.atmoA.clamp(0.0, 1.0));
      }
      atmo..add(at(a))..add(at(b))..add(at(d));
    }

    // Seam fix: a triangle straddling the longitude wrap has u values spanning
    // nearly the whole texture (e.g. one vertex near 0, another near iw). Linear
    // interpolation then runs the LONG way across the map — a smeared band. If
    // the spread exceeds half the width, lift the low-u vertices by +iw so all
    // three sit on the same side; TileMode.repeated samples the wrapped copy.
    var ua = a.uv.dx, ub = b.uv.dx, ud = d.uv.dx;
    final maxU = math.max(ua, math.max(ub, ud));
    if (maxU - math.min(ua, math.min(ub, ud)) > iw / 2) {
      if (maxU - ua > iw / 2) ua += iw;
      if (maxU - ub > iw / 2) ub += iw;
      if (maxU - ud > iw / 2) ud += iw;
    }
    t
      ..add(ui.Offset(ua, a.uv.dy))
      ..add(ui.Offset(ub, b.uv.dy))
      ..add(ui.Offset(ud, d.uv.dy));

    // Shadow alpha: darker where less lit. shade in [0.12..1] -> alpha in
    // [~0.88..0].
    s..add(_shadow(a.shade))..add(_shadow(b.shade))..add(_shadow(d.shade));
  }

  ui.Color _shadow(double shade) =>
      ui.Color.fromARGB(((1.0 - shade) * 235).clamp(0, 255).round(), 0, 0, 0);

  List<double> _norm3(double x, double y, double z) {
    final len = math.sqrt(x * x + y * y + z * z);
    if (len < 1e-9) return [0, 0, 1];
    return [x / len, y / len, z / len];
  }

  double _smoothstep(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}

class _V {
  final ui.Offset pos;
  final ui.Offset uv;
  final double shade;
  final double atmoA; // atmosphere scatter alpha at this vertex
  final double warmF; // 0=day colour, 1=warm terminator band
  const _V(
      {required this.pos,
      required this.uv,
      required this.shade,
      this.atmoA = 0,
      this.warmF = 0});
}
