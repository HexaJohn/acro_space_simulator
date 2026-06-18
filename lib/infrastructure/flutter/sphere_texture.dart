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

    // ADAPTIVE ICOSPHERE (body space). The sphere is a subdivided icosahedron:
    // 20 triangular faces of (near) uniform size, recursively split into 4 when
    // their projected on-screen size exceeds a target. UNLIKE a lat/long grid it
    // has NO pole singularity, so a straight-down / nadir view doesn't collapse.
    // Each vertex is a unit body-direction projected through the real camera;
    // verts are welded via a cache so the mesh is ground-anchored (no swim).
    final camR = view.right, camU = view.up, camF = view.forward;

    // Reference longitude = the body-fixed longitude of the sub-camera point (the
    // surface point straight under the eye). We map each vertex's longitude as an
    // UNWRAPPED offset from this reference, so the visible cap NEVER straddles the
    // equirect antimeridian seam (lon=±pi). Without this, a triangle bridging the
    // seam needs u on one side and u+width on the other; the welded vertex can
    // only hold one, so neighbours disagree and the texture tears down the seam
    // (the vertical split + radial shred seen during ascent). The cap is always
    // < pi wide, so all offsets land in (-pi,pi): one continuous, tear-free patch.
    final sdx = eyeDist > 1e-6 ? -centreFromEye.x / eyeDist : 0.0;
    final sdy = eyeDist > 1e-6 ? -centreFromEye.y / eyeDist : 0.0;
    // Undo the geometry spin to get the body-FIXED reference longitude.
    final sbx = sdx * math.cos(spin) + sdy * math.sin(spin);
    final sby = -sdx * math.sin(spin) + sdy * math.cos(spin);
    final lon0 = math.atan2(sby, sbx);

    // Whether a body-frame surface direction n is visible (above the eye's local
    // horizon in perspective, front-facing in ortho).
    bool dirVisible(double nx, double ny, double nz) {
      if (radiusM > 0) {
        return -(centreFromEye.x * nx +
                centreFromEye.y * ny +
                centreFromEye.z * nz) >
            radiusM;
      }
      return -(nx * camF.x + ny * camF.y + nz * camF.z) > 0;
    }

    // Depth bound, scaled to how close the eye is (computed up here because the
    // weld-key resolution below depends on it). Far / mid: a modest cap (the
    // projected-size test stops early anyway). VERY low altitude (a few ico faces
    // fill the screen) needs more depth to reach screen-sized leaves — scale by
    // log2(radius/alt). The horizon/screen prune + vertex weld bound the cost.
    final alt = radiusM > 0 ? (eyeDist - radiusM) : double.infinity;
    var maxDepth = 7;
    if (radiusM > 0 && alt > 0 && alt < radiusM * 0.2) {
      final extra = (math.log(radiusM / alt) / math.ln2).round();
      maxDepth = (7 + extra).clamp(7, 14);
    }

    // Weld-key resolution. A shared edge midpoint is the EXACT same float from
    // both faces, so any grid welds it; the danger is the OPPOSITE — when zoomed
    // in, adjacent-but-distinct deep-subdivision vertices (spacing ~ ico_edge /
    // 2^maxDepth) must NOT collapse into the same cell, or one vertex inherits a
    // wrong cached UV from elsewhere on the sphere and the texture shreds into a
    // pinwheel. So the grid must be FINER than the leaf spacing. 15 bits
    // (grid 3e-5) is far too coarse at low altitude (leaf spacing ~7e-5). Scale
    // the bit count with maxDepth, capped at 17 bits/axis (3*17=51 < 53 safe).
    final qBits = (12 + maxDepth).clamp(15, 17).toInt();
    final qScale = (1 << (qBits - 1)).toDouble(); // half-range
    final qMask = (1 << qBits) - 1;
    final qShift = 1 << qBits;
    final cache = <int, _V?>{};
    _V? evalDir(double nx, double ny, double nz) {
      // NON-colliding weld key: quantise each component (in [-1,1]) to qBits and
      // bit-pack — within the web 53-bit-safe-int range, so no XOR collisions
      // (which streaked the disc) and no per-vertex string alloc (which tanked
      // the frame rate when zoomed in).
      final qx = ((nx * qScale).round() + (qShift >> 1)) & qMask;
      final qy = ((ny * qScale).round() + (qShift >> 1)) & qMask;
      final qz = ((nz * qScale).round() + (qShift >> 1)) & qMask;
      final key = (qx * qShift + qy) * qShift + qz;
      final hit = cache[key];
      if (hit != null || cache.containsKey(key)) return hit;
      final relFocus = Vector3(
        worldRel.x + radiusM * nx,
        worldRel.y + radiusM * ny,
        worldRel.z + radiusM * nz,
      );
      final p = view.projectPx(relFocus);
      if (p == null) {
        cache[key] = null;
        return null;
      }
      final pos = ui.Offset(viewportCentre.dx + p.x, viewportCentre.dy - p.y);
      // UV from the BODY-FIXED lat/lon (undo the epoch spin we added to geometry).
      final bx = nx * math.cos(spin) + ny * math.sin(spin);
      final by = -nx * math.sin(spin) + ny * math.cos(spin);
      final lon = math.atan2(by, bx);
      final lat = math.asin(nz.clamp(-1.0, 1.0));
      // Unwrap longitude relative to the sub-camera reference so the whole
      // visible cap is one continuous strip (no seam straddle). dLon in (-pi,pi].
      var dLon = lon - lon0;
      while (dLon > math.pi) {
        dLon -= 2 * math.pi;
      }
      while (dLon < -math.pi) {
        dLon += 2 * math.pi;
      }
      final u = (lon0 + dLon + math.pi) / (2 * math.pi);
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
        nearPole: nz.abs() > 0.985, // within ~10 deg of a pole
      );
      cache[key] = vtx;
      return vtx;
    }

    // Leaf target on screen (px). Bigger leaves = fewer triangles. A small/far
    // disc needs fine leaves for a round limb (rPx/24); a big near disc that
    // fills the screen uses a coarse 64 px leaf — at that zoom the texture is
    // already sub-texel/blurry, so finer leaves cost a lot for no visible gain.
    final targetPx = (rPx / 24.0).clamp(6.0, 64.0);
    final screenW = viewportCentre.dx * 2, screenH = viewportCentre.dy * 2;
    // Tighter off-screen prune margin (was 0.5) so off-screen subtrees stop
    // recursing sooner — a perf win when zoomed in and most of the cap is off
    // screen. Still leaves a margin so an edge-straddling node tessellates.
    final marginX = screenW * 0.25, marginY = screenH * 0.25;

    // Visible cap geometry: the cap is the spherical disc of directions within
    // angle [capAngle] of [toEye] (the sub-camera direction); perspective only.
    // A face is pruned only when it lies WHOLLY outside the cap by more than its
    // own angular radius — never on corner-visibility alone, since at low
    // altitude the visible cap is far smaller than a coarse ico face and would
    // otherwise be pruned before the face subdivides down to it.
    final toEyeX = eyeDist < 1e-6 ? 0.0 : -centreFromEye.x / eyeDist;
    final toEyeY = eyeDist < 1e-6 ? 0.0 : -centreFromEye.y / eyeDist;
    final toEyeZ = eyeDist < 1e-6 ? 1.0 : -centreFromEye.z / eyeDist;
    final capAngle =
        radiusM > 0 ? math.acos((radiusM / eyeDist).clamp(0.0, 1.0)) : math.pi;

    // A spherical triangle of three unit body-directions. Recursively split into
    // four (edge midpoints, re-normalised onto the sphere) until small on screen.
    void faceRecurse(List<double> A, List<double> B, List<double> C, int depth) {
      final mx = (A[0] + B[0] + C[0]), my = (A[1] + B[1] + C[1]), mz = (A[2] + B[2] + C[2]);
      final ml = math.sqrt(mx * mx + my * my + mz * mz);
      final cx = mx / ml, cy = my / ml, cz = mz / ml;
      if (radiusM > 0) {
        // Angle from the face centroid to the cap centre, and the face's angular
        // radius (centroid->corner). Prune only if the face can't reach the cap.
        final dotCap = (cx * toEyeX + cy * toEyeY + cz * toEyeZ).clamp(-1.0, 1.0);
        final centAngle = math.acos(dotCap);
        final dotCorner = (cx * A[0] + cy * A[1] + cz * A[2]).clamp(-1.0, 1.0);
        final faceRad = math.acos(dotCorner);
        if (centAngle - faceRad > capAngle) return; // wholly past the horizon
      } else {
        // Ortho: prune a face that's entirely back-facing.
        if (!dirVisible(A[0], A[1], A[2]) &&
            !dirVisible(B[0], B[1], B[2]) &&
            !dirVisible(C[0], C[1], C[2]) &&
            !dirVisible(cx, cy, cz)) {
          return;
        }
      }
      final va = evalDir(A[0], A[1], A[2]);
      final vb = evalDir(B[0], B[1], B[2]);
      final vc = evalDir(C[0], C[1], C[2]);

      // Off-screen prune (only when all corners projected — a near-plane crosser
      // keeps splitting to resolve its boundary).
      if (va != null && vb != null && vc != null) {
        final minX = math.min(va.pos.dx, math.min(vb.pos.dx, vc.pos.dx));
        final maxX = math.max(va.pos.dx, math.max(vb.pos.dx, vc.pos.dx));
        final minY = math.min(va.pos.dy, math.min(vb.pos.dy, vc.pos.dy));
        final maxY = math.max(va.pos.dy, math.max(vb.pos.dy, vc.pos.dy));
        if (maxX < -marginX ||
            minX > screenW + marginX ||
            maxY < -marginY ||
            minY > screenH + marginY) {
          return;
        }
      }

      var split = depth < maxDepth;
      if (split && va != null && vb != null && vc != null) {
        double seg(ui.Offset p, ui.Offset q) {
          final dx = p.dx - q.dx, dy = p.dy - q.dy;
          return math.sqrt(dx * dx + dy * dy);
        }
        final sz = math.max(
            seg(va.pos, vb.pos), math.max(seg(vb.pos, vc.pos), seg(vc.pos, va.pos)));
        if (sz <= targetPx) split = false;
      }

      if (split) {
        List<double> mid(List<double> p, List<double> q) {
          final x = p[0] + q[0], y = p[1] + q[1], z = p[2] + q[2];
          final l = math.sqrt(x * x + y * y + z * z);
          return [x / l, y / l, z / l];
        }
        final ab = mid(A, B), bc = mid(B, C), ca = mid(C, A);
        faceRecurse(A, ab, ca, depth + 1);
        faceRecurse(ab, B, bc, depth + 1);
        faceRecurse(ca, bc, C, depth + 1);
        faceRecurse(ab, bc, ca, depth + 1);
        return;
      }
      // Leaf: emit if all three corners projected (in front of the near plane).
      if (va != null && vb != null && vc != null) {
        _tri(positions, texCoords, shadowColors, atmoColors, atmoTint, atmoWarm,
            va, vb, vc, iw);
      }
    }

    // Icosahedron vertices (unit), then rotate each by +spin about +Z so the
    // GEOMETRY turns with epoch (evalDir undoes the spin for the body-fixed UV).
    const t = 1.618033988749895; // golden ratio
    final ico = <List<double>>[
      [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0],
      [0, -1, t], [0, 1, t], [0, -1, -t], [0, 1, -t],
      [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
    ].map((p) {
      final l = math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
      final x = p[0] / l, y = p[1] / l, z = p[2] / l;
      final cs = math.cos(spin), sn = math.sin(spin);
      return [x * cs - y * sn, x * sn + y * cs, z]; // +spin about +Z
    }).toList();
    const faces = <List<int>>[
      [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
      [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
      [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
      [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
    ];
    for (final f in faces) {
      faceRecurse(ico[f[0]], ico[f[1]], ico[f[2]], 0);
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

    var ua = a.uv.dx, ub = b.uv.dx, ud = d.uv.dx;

    // The cap-relative longitude unwrap (evalDir) already keeps the whole visible
    // patch on one continuous side of the seam, so no per-triangle seam-lift is
    // needed (it was the cause of the tears along the antimeridian). Only the
    // genuine geographic pole still needs handling: there all longitudes converge,
    // so the three u's fan out and linear interpolation smears the texture; the
    // polar pixels are near-uniform, so collapse all three to the MEDIAN column.
    if (a.nearPole || b.nearPole || d.nearPole) {
      final maxU = math.max(ua, math.max(ub, ud));
      final minU = math.min(ua, math.min(ub, ud));
      final med = ua + ub + ud - maxU - minU; // the middle value
      ua = med;
      ub = med;
      ud = med;
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
  final bool nearPole; // |lat| near 90 -> equirect U is ill-defined here
  const _V(
      {required this.pos,
      required this.uv,
      required this.shade,
      this.atmoA = 0,
      this.warmF = 0,
      this.nearPole = false});
}
