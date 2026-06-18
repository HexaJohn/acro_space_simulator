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
  static const double _overscan = 1.06;

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
    final cover = coverPx ?? rPx;
    final span = rPx <= 0 ? 1.0 : (cover * _overscan / rPx).clamp(0.02, 1.0);
    final positions = <ui.Offset>[];
    final texCoords = <ui.Offset>[];
    final atmoColors = <ui.Color>[]; // per-vertex atmosphere scatter (pass 3)
    final shadowColors = <ui.Color>[]; // per-vertex night-side darkening (pass 2)

    final iw = image.width.toDouble();
    final ih = image.height.toDouble();

    // Per-body view basis. The visible hemisphere faces the EYE, not the camera
    // forward — for an off-axis body in perspective the eye->body ray differs
    // from the camera's view axis, and using `forward` for every body maps the
    // wrong hemisphere (the texture slides as the camera rotates). So forward is
    // the actual eye->body direction; right/up are the camera's screen axes
    // re-orthogonalized against it, keeping north-up on screen stable.
    final fwd = view.viewDirTo(worldRel);
    var right = _orthoNorm(view.right, fwd);
    // up = right x forward (matches CameraOrbit's _upBase = right.cross(forward)).
    var upv = right.cross(fwd).normalized;
    // Guard the degenerate case (camera right nearly parallel to the ray).
    if (!right.x.isFinite || !upv.x.isFinite) {
      right = view.right;
      upv = view.up;
    }

    // Transform the world sun direction into the CAMERA frame so the lit
    // hemisphere is correct from any camera angle. Camera axes: x=right, y=up,
    // z=toward viewer (= -forward). Vertices are also in this frame, so the
    // Lambert dot below is a true cos(angle) — the night side reads dark even
    // when the camera orbits behind the body.
    final sun = _norm3(
      sunWorld.dot(right),
      sunWorld.dot(upv),
      sunWorld.dot(fwd) * -1,
    );

    // Build a (grid+1)^2 lattice of vertices over the unit disc; cells outside
    // the circle are skipped when emitting triangles.
    final verts = <List<_V?>>[];
    for (var iy = 0; iy <= _grid; iy++) {
      final row = <_V?>[];
      final ny = ((iy / _grid) * 2 - 1) * span; // -span..span (screen up = +)
      for (var ix = 0; ix <= _grid; ix++) {
        final nx = ((ix / _grid) * 2 - 1) * span; // -span..span (screen right=+)
        final r2 = nx * nx + ny * ny;
        if (r2 > 1.0) {
          row.add(null);
          continue;
        }
        // Camera-frame point on the front hemisphere (z toward viewer).
        final cz = math.sqrt(1.0 - r2);
        final cam = [nx, ny, cz];
        // Map camera-frame -> world/body frame via the camera basis. The visible
        // hemisphere faces the camera, so its outward normal is -forward.
        final wx = right.x * nx + upv.x * ny - fwd.x * cz;
        final wy = right.y * nx + upv.y * ny - fwd.y * cz;
        final wz = right.z * nx + upv.z * ny - fwd.z * cz;
        // Body-fixed lon/lat: lon around +Z axis from +X, lat from equator.
        // Subtract the body's spin so the surface texture rotates with epoch.
        final lon = math.atan2(wy, wx) - spin; // -pi..pi (minus rotation)
        final lat = math.asin(wz.clamp(-1.0, 1.0)); // -pi/2..pi/2
        // Keep u continuous (not wrapped) so the ImageShader's repeated tiling
        // hides the longitude seam; wrapping per-vertex would smear a column.
        final u = (lon + math.pi) / (2 * math.pi);
        final v = (math.pi / 2 - lat) / math.pi; // 0..1 (north at top)

        // Lambert brightness vs sun (camera-frame normal == cam point).
        final lit = selfLuminous
            ? 1.0
            : (cam[0] * sun[0] + cam[1] * sun[1] + cam[2] * sun[2])
                .clamp(0.0, 1.0);
        final shade = selfLuminous ? 1.0 : (0.12 + 0.88 * lit);

        // Atmosphere scatter (per-vertex, full 3D so it rotates with the camera
        // and tracks the real day/night terminator):
        //  * day  — only the sunlit hemisphere scatters (soft terminator).
        //  * limb — SPHERICAL falloff: faint at the centre (cz≈1, looking
        //    straight down through a short air column) ramping up toward the
        //    limb (cz→0, long grazing path). (1 - cz)^1.6 gives the curve.
        // Day mask: zero on the NIGHT side (lit<=0), ramping up just inside the
        // terminator. This keeps the scatter a crescent on the lit hemisphere
        // only — never on the dark side.
        final day = _smoothstep(0.0, 0.12, lit);
        final limb = math.pow(1.0 - cz, 1.6).toDouble();
        final atmoA = (0.06 + 0.94 * limb) * day;
        // Warm band: reddens toward the terminator (low but positive lit),
        // fading to the day colour deeper into the lit side.
        final warmF = (1.0 - _smoothstep(0.0, 0.45, lit)) * day;

        // Positions at TRUE rPx (full magnification). When far away (span==1) add
        // the overscan so the mesh's stairstepped edge falls outside the circular
        // clip; when zoomed in (span<1) the mesh already runs past the screen.
        final ps = rPx * (span >= 1.0 ? _overscan : 1.0);
        row.add(_V(
          pos: ui.Offset(centre.dx + nx * ps, centre.dy - ny * ps),
          uv: ui.Offset(u * iw, v * ih),
          shade: shade,
          atmoA: atmoA,
          warmF: warmF,
        ));
      }
      verts.add(row);
    }

    // Emit two triangles per fully-inside cell.
    for (var iy = 0; iy < _grid; iy++) {
      for (var ix = 0; ix < _grid; ix++) {
        final a = verts[iy][ix];
        final b = verts[iy][ix + 1];
        final c = verts[iy + 1][ix];
        final d = verts[iy + 1][ix + 1];
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

    // Clip everything to a true antialiased circle. The triangle mesh only
    // covers cells fully inside the unit disc, so its raw edge is stairstepped;
    // clipping to a smooth circle gives a crisp round limb regardless of mesh
    // resolution.
    // Clip to the true limb circle when far (span==1); when zoomed in, clip to
    // the visible patch (span*rPx ~ screen) so a million-px clip path is never
    // built. The patch covers the screen either way.
    final clipR = span >= 1.0 ? rPx : span * rPx;
    canvas.save();
    canvas.clipPath(
      ui.Path()..addOval(ui.Rect.fromCircle(center: centre, radius: clipR)),
      doAntiAlias: true,
    );

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

  /// Component of [v] perpendicular to unit [axis], normalized (Gram-Schmidt).
  Vector3 _orthoNorm(Vector3 v, Vector3 axis) =>
      (v - axis * v.dot(axis)).normalized;

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
