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

  /// Mesh resolution: cells across the disc. Higher = smoother sphere, more
  /// triangles. The mesh is also clipped to a true circle, so this mainly
  /// controls how round the *interior* texture warp looks.
  static const int _grid = 40;

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

    // Adaptive tessellation: near the surface the visible cap spreads across the
    // whole screen, so the uniform far-grid leaves huge near-camera quads. Boost
    // the lattice resolution as the eye drops toward the surface (altitude -> 0),
    // up to 4x the base grid, so the ground close to the camera subdivides finer.
    final alt = radiusM > 0 ? (eyeDist - radiusM) : double.infinity;
    final grid = (radiusM > 0 && alt < radiusM)
        ? (_grid * (1.0 + 3.0 * (1.0 - (alt / radiusM).clamp(0.0, 1.0)))).round()
        : _grid;

    // LAT/LONG BAND TESSELLATION (body space). The whole sphere is gridded in
    // latitude × longitude; every vertex is projected through the real camera
    // and culled if it's below the eye's local horizon or behind the near plane.
    // Unlike the old eye-facing disc lattice, this makes NO assumption that the
    // camera looks at the body centre — so it's correct for off-axis bodies,
    // orbit tracking (centre off-screen), and a surface eye looking sideways.
    //
    // Resolution: enough bands to read smooth; boosted near the surface where a
    // small patch fills the screen. A back-face cull on whole rows keeps the cost
    // bounded (only the visible hemisphere's verts get projected).
    final latBands = grid; // rows (lat)
    final lonBands = grid * 2; // cols (lon) — twice for a square-ish cell aspect

    // Camera basis for the per-vertex shade (lit/limb): camera frame x=right,
    // y=up, z=toward viewer (= -view.forward).
    final camR = view.right, camU = view.up, camF = view.forward;

    // Eye position relative to the FOCUS = view.eyeOffset; the body centre is at
    // worldRel, so a surface point's vector FROM the eye is (worldRel + r*n) -
    // eyeOffset. Visible iff (eye - centre)·n > radius i.e. (-centreFromEye)·n >
    // radiusM (centreFromEye = worldRel - eyeOffset).
    final verts = <List<_V?>>[];
    for (var iLat = 0; iLat <= latBands; iLat++) {
      final row = <_V?>[];
      // lat: +pi/2 (north) down to -pi/2 (south) so v runs 0..1 top->bottom.
      final lat = math.pi / 2 - (iLat / latBands) * math.pi;
      final cl = math.cos(lat), sl = math.sin(lat);
      final v = iLat / latBands; // texture row
      for (var iLon = 0; iLon <= lonBands; iLon++) {
        // lon 0..2pi from +X; ADD spin so the surface rotates with epoch (the
        // texture column for a body-fixed point shifts opposite the old sign).
        final lon = (iLon / lonBands) * 2 * math.pi + spin;
        // Body-frame surface unit normal n (lon around +Z from +X, lat from eq).
        final nx = cl * math.cos(lon);
        final ny = cl * math.sin(lon);
        final nz = sl;
        // Horizon cull (skip the whole far hemisphere cheaply).
        if (radiusM > 0) {
          final dotEye =
              -(centreFromEye.x * nx + centreFromEye.y * ny + centreFromEye.z * nz);
          if (dotEye <= radiusM) {
            row.add(null);
            continue;
          }
        } else {
          // Ortho / no radius: cull the back hemisphere (facing away from cam).
          final facing = -(nx * camF.x + ny * camF.y + nz * camF.z);
          if (facing <= 0) {
            row.add(null);
            continue;
          }
        }
        // Project the surface point through the camera.
        final relFocus = Vector3(
          worldRel.x + radiusM * nx,
          worldRel.y + radiusM * ny,
          worldRel.z + radiusM * nz,
        );
        final p = view.projectPx(relFocus);
        if (p == null) {
          row.add(null);
          continue;
        }
        final pos = ui.Offset(viewportCentre.dx + p.x, viewportCentre.dy - p.y);
        // u from lon (continuous so TileMode.repeated hides the seam).
        final u = (iLon / lonBands);

        // Camera-frame normal for shade: n in (right, up, toward-viewer).
        final cnx = nx * camR.x + ny * camR.y + nz * camR.z;
        final cny = nx * camU.x + ny * camU.y + nz * camU.z;
        final cnz = -(nx * camF.x + ny * camF.y + nz * camF.z); // toward viewer
        final lit = selfLuminous
            ? 1.0
            : (cnx * sun[0] + cny * sun[1] + cnz * sun[2]).clamp(0.0, 1.0);
        final shade = selfLuminous ? 1.0 : (0.12 + 0.88 * lit);
        // Limb falloff for atmosphere: cnz ~ 1 at the sub-camera point, ~0 at the
        // limb (grazing) — same (1 - facing)^1.6 curve.
        final day = _smoothstep(0.0, 0.12, lit);
        final limb = math.pow((1.0 - cnz.clamp(0.0, 1.0)), 1.6).toDouble();
        final atmoA = (0.06 + 0.94 * limb) * day;
        final warmF = (1.0 - _smoothstep(0.0, 0.45, lit)) * day;

        row.add(_V(
          pos: pos,
          uv: ui.Offset(u * iw, v * ih),
          shade: shade,
          atmoA: atmoA,
          warmF: warmF,
        ));
      }
      verts.add(row);
    }

    // Emit two triangles per cell where all four corners are visible.
    for (var iLat = 0; iLat < latBands; iLat++) {
      for (var iLon = 0; iLon < lonBands; iLon++) {
        final a = verts[iLat][iLon];
        final b = verts[iLat][iLon + 1];
        final c = verts[iLat + 1][iLon];
        final d = verts[iLat + 1][iLon + 1];
        if (a == null || b == null || c == null || d == null) continue;
        _tri(positions, texCoords, shadowColors, atmoColors, atmoTint, atmoWarm,
            a, c, b, iw);
        _tri(positions, texCoords, shadowColors, atmoColors, atmoTint, atmoWarm,
            b, c, d, iw);
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
