import 'dart:math' as math;
import 'dart:ui' as ui show Image, Gradient, Vertices, VertexMode;

import 'package:flutter/material.dart';

import '../../adapters/presenters/atmosphere_halo.dart';
import '../../adapters/presenters/body_shading.dart';
import '../../adapters/presenters/top_down_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'debug_layers.dart';
import 'sphere_texture.dart';
import 'texture_cache.dart';

/// Renders a [TopDownSnapshot] in a top-down XY view with primitive shapes.
/// No 3D rendering this pass — bodies are circles, vessels are triangles, the
/// vessel's orbit-plane heading is the triangle's point.
///
/// Coordinates arrive as metres relative to the camera focus (already small),
/// so projection is just: screen = centre + (worldXY / metresPerPixel), with Y
/// flipped so +Y is up on screen.
class TopDownPainter extends CustomPainter {
  final TopDownSnapshot snapshot;
  final TextureCache? textures;
  final SceneCamera view;
  final DebugLayers layers;
  static const _sphere = SphereTexture();

  /// How far the star's corona glow reaches, in body radii.
  static const double _starGlowScale = 4.5;

  TopDownPainter(this.snapshot,
      {this.textures,
      required this.view,
      this.layers = const DebugLayers()});

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);

    // Backdrop: the Milky Way star map (NASA Deep Star Maps 2020, public
    // domain) drawn cover-fit behind everything; dark fill if not yet decoded.
    final sky = layers.skybox ? textures?.image('starfield') : null;
    if (sky != null) {
      _drawSkybox(canvas, size, sky);
    } else {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFF05070D),
      );
    }

    // The HUD (fixed-screen text) must survive even if a world-space draw throws
    // at an extreme zoom — otherwise the whole frame (panel included) blanks.
    try {
      _paintWorld(canvas, size, centre);
    } catch (e) {
      _label(canvas, 'render error: $e', const Offset(8, 44),
          const Color(0xFFFF6B6B));
    }
    _hud(canvas, size);
  }

  void _paintWorld(Canvas canvas, Size size, Offset centre) {
    const shading = BodyShading();
    // Coordinates arrive as SCREEN px (centre-origin, +y up); place at the
    // viewport centre with Y flipped for Flutter's downward axis.
    Offset project(double xPx, double yPx) =>
        Offset(centre.dx + xPx, centre.dy - yPx);

    // When zoomed in, distant orbits project to millions of pixels — far beyond
    // Skia's safe range, and clamping endpoints distorts the curve into edge-
    // hugging junk. Instead we clip each segment to a margin around the viewport
    // (Cohen–Sutherland), drawing only the on-screen arc and dropping the rest.
    final clip = Rect.fromLTWH(
        -_clipMargin, -_clipMargin, size.width + 2 * _clipMargin, size.height + 2 * _clipMargin);

    // Celestial-body orbit rails: faint ellipses. BACK arc (behind the parent)
    // drawn here, under the discs; FRONT arc after the bodies.
    if (layers.orbitRails) {
      for (final b in snapshot.bodies) {
        _drawBodyRail(canvas, b, project, clip, true);
      }
    }

    // Sphere-of-influence circles (debug overlay): a dashed ring at each body's
    // SOI radius, so gravity-domain boundaries are visible.
    if (layers.showSoi) {
      for (final b in snapshot.bodies) {
        if (b.soiRadiusPx <= 0) continue;
        final c = project(b.x, b.y);
        final rPx = b.soiRadiusPx;
        if (rPx < 6 || rPx > 4000) continue; // skip sub-pixel / absurd
        if (!_discTouchesScreen(c, rPx, size)) continue;
        _dashedCircle(canvas, c, rPx, const Color(0x55B0E0A0));
      }
    }

    // Predicted vessel orbit paths — BACK arc drawn BEFORE the bodies so it's
    // occluded by the planet disc. (Front arc is drawn after the bodies.)
    for (final v in snapshot.vessels) {
      _drawVesselPath(canvas, v, project, clip, true);
    }

    // Bodies: lit disc (ultra-basic shading) + atmosphere halo.
    for (final b in snapshot.bodies) {
      final c = project(b.x, b.y);
      // Optional star-size exaggeration (off by default): floor the star to a
      // minimum on-screen radius so it stays visible from ~1 AU. Looks unnatural,
      // so it's a debug toggle rather than always on.
      final minPx = (b.isStar && layers.exaggerateStar) ? 10.0 : 2.0;
      // Camera already projected the radius to px (ortho or perspective).
      final rPx = math.max(minPx, b.radiusPx);
      // Cull bodies whose disc can't touch the screen — keeps Skia from drawing
      // circles/meshes at million-pixel coordinates (which overflows and kills
      // the whole frame, HUD included). Stars test their wider GLOW radius so the
      // corona still shows even when the disc itself is off-screen / sub-pixel.
      final cullR = b.isStar ? rPx * _starGlowScale : rPx;
      if (!_discTouchesScreen(c, cullR, size)) continue;
      final base = b.isStar ? const Color(0xFFFFD66B) : const Color(0xFF4A90D9);

      // Skia drops or mis-rasterizes geometry once coordinates blow past a few
      // thousand px, so when zoomed in the flat disc (drawn at TRUE rPx) and the
      // sphere (which self-limits its mesh to a screen-sized cap) stop agreeing.
      // The cap only needs to reach the farthest screen CORNER FROM THIS BODY'S
      // centre `c` — not from screen centre — so when `c` is off-screen (zoomed
      // in, or an off-axis body under an orbiter lock) the textured patch still
      // fills the whole viewport instead of a too-small circle stuck mid-screen.
      final coverPx = _farthestCornerDist(c, size);
      // Clamp the DISC's draw radius to EXACTLY the sphere's capped on-screen
      // extent (cover*overscan, see the sphere's clipR) so the textured cap and
      // the base disc share one radius and stay aligned — important for an
      // off-centre body in perspective, where a mismatched radius reads as the
      // texture floating off the disc.
      final discRPx = math.min(rPx, coverPx * SphereTexture.overscan);

      // "Disc covers the viewport" = the sphere mesh has hit its on-screen cap
      // (rPx past coverPx*overscan), at which point the textured patch already
      // spans every corner from `c`. Beyond that the rim/halo/ring work is all
      // off-screen, so skip it. Keyed off the CAP, not raw rPx — rPx is the
      // angular apparent radius and outran the drawn patch, flipping to the
      // fullscreen flat fill while the texture was still smaller than the screen
      // ("flat fill too soon").
      final discCovers = !b.isStar && rPx >= coverPx * SphereTexture.overscan;
      final hasTex = layers.planetTexture &&
          b.textureKey != null &&
          textures?.image(b.textureKey!) != null;
      if (discCovers && !hasTex) {
        // Fullscreen flat fill (the generic "blue fill") when zoomed inside an
        // untextured body — gated on its own baseFill toggle.
        if (layers.baseFill) {
          canvas.drawRect(Offset.zero & size, Paint()..color = _scale(base, 0.6));
        }
        continue;
      }

      // Star corona glow (drawn first, under the disc).
      if (b.isStar) _starGlow(canvas, c, discRPx);

      // Back half of the rings — drawn BEFORE the body so the disc occludes it.
      // (Off-screen when the disc covers the viewport, so skip it then.)
      if (!discCovers) _drawRings(canvas, b, project, true);

      // Surface map: draw the lit sphere when the texture is decoded and the disc
      // is worth texturing (>=5px). No upper cap on rPx — when close the mesh
      // radius is clamped (meshRPx) so vertex coords stay bounded; the sphere
      // clips to the true circle. Below 5px it's not worth it.
      final tex = (layers.planetTexture && b.textureKey != null && rPx >= 5)
          ? textures?.image(b.textureKey!)
          : null;
      // (coverPx — the sphere-cap half-extent — is computed once above, by the
      // disc-radius clamp, and reused for _sphere.paint below.)
      // Atmosphere thickness fraction — gas giants get a fatter haze when the
      // exaggerate-atmosphere debug option is on.
      final atmoThick = (b.isGasGiant && layers.exaggerateAtmosphere) ? 0.5 : 0.22;
      final atmoCol = Color(b.atmoColor);
      if (tex != null) {
        // The limb halo + base disc + rings + label all live at the rim, which
        // is off-screen when the disc covers the viewport — skip them then (the
        // lag fix) and draw only the (capped) textured surface.
        if (!discCovers) {
          if (b.hasAtmosphere && layers.atmoHalo) {
            _atmosphereHalo(canvas, c, discRPx, size,
                view: view,
                sunWorld: Vector3(b.sunWorldX, b.sunWorldY, b.sunWorldZ),
                tint: atmoCol,
                thickness: atmoThick);
          }
          // Base disc underneath: if the textured sphere fails to rasterize on a
          // given backend (web CanvasKit drawVertices quirks), the body still
          // reads as a lit circle instead of vanishing.
          final sun = Vector3(b.sunX, b.sunY, 0);
          if (layers.baseDisc) {
            if (b.isStar) {
              canvas.drawCircle(c, discRPx, Paint()..color = base);
            } else {
              _drawShadedDisc(canvas, c, discRPx, base, sun, shading, b.sunFacing);
            }
          }
        } else if (layers.baseDisc) {
          // Cap reached: the textured sphere is the main surface, but if it
          // fails to rasterize the planet would vanish. Paint a flat fallback
          // UNDER it — but only within the disc circle (radius discRPx at `c`),
          // NOT fullscreen, so the area beyond the limb stays empty and the
          // horizon/space still shows when looking toward the edge of the body.
          final sun = Vector3(b.sunX, b.sunY, 0);
          if (b.isStar) {
            canvas.drawCircle(c, discRPx, Paint()..color = base);
          } else {
            _drawShadedDisc(canvas, c, discRPx, base, sun, shading, b.sunFacing);
          }
        }
        // The sphere is the fragile part; isolate it so a failure leaves the
        // already-drawn disc rather than blanking the world layer.
        try {
          _sphere.paint(
            canvas, tex, c, rPx,
            view: view,
            worldRel: b.worldRel,
            coverPx: coverPx,
            sunWorld: Vector3(b.sunWorldX, b.sunWorldY, b.sunWorldZ),
            spin: b.spin,
            selfLuminous: b.isStar,
            shadow: layers.sphereShadow,
            // Atmosphere scatter is now a per-vertex 3D pass inside the sphere
            // (day-side, spherical limb falloff) so it tracks the terminator and
            // rotates with the camera. Null = no atmosphere / overlay disabled.
            atmoTint: (b.hasAtmosphere && layers.atmoOverlay) ? atmoCol : null,
          );
        } catch (_) {/* keep the disc fallback */}
        if (!discCovers) {
          _drawRings(canvas, b, project, false); // near half, over the disc
          if (b.showLabel) {
            _label(canvas, b.name, c + Offset(rPx + 4, -6),
                const Color(0xFF9FB4CC));
          }
        }
        continue;
      }

      if (b.isStar || rPx < 6) {
        // Tiny or self-luminous: flat fill (shading not worth it). Stars always
        // draw; an untextured PLANET's generic fill obeys baseFill.
        if (b.isStar || layers.baseFill) {
          canvas.drawCircle(c, discRPx, Paint()..color = base);
        }
      } else {
        // Atmosphere halo first (drawn under the disc edge).
        if (b.hasAtmosphere && layers.atmoHalo) {
          _atmosphereHalo(canvas, c, discRPx, size,
              view: view,
              sunWorld: Vector3(b.sunWorldX, b.sunWorldY, b.sunWorldZ),
              tint: atmoCol,
              thickness: atmoThick);
        }
        // Shaded disc for an untextured body — the generic "blue fill". Obeys
        // baseFill (separate from the textured-sphere baseDisc fallback).
        final sun = Vector3(b.sunX, b.sunY, 0);
        if (layers.baseFill) {
          _drawShadedDisc(canvas, c, discRPx, base, sun, shading, b.sunFacing);
        }
      }

      _drawRings(canvas, b, project, false); // near half, over the disc
      if (b.showLabel) {
        _label(canvas, b.name, c + Offset(rPx + 4, -6), const Color(0xFF9FB4CC));
      }
    }

    // Front arcs (over the discs): body rails, then vessel orbit paths.
    if (layers.orbitRails) {
      for (final b in snapshot.bodies) {
        _drawBodyRail(canvas, b, project, clip, false);
      }
    }
    for (final v in snapshot.vessels) {
      _drawVesselPath(canvas, v, project, clip, false);
    }

    // The focused vessel's FLOWN trail (breadcrumb of where it has actually
    // been), drawn over the rails so you can read the real trajectory.
    _drawFlownTrail(canvas, project, clip);

    // Vessels: LOD — a flat heading triangle when small (<= ~10 px apparent),
    // a lit 3D cone when big enough to read (close-up / chase cam).
    const craftLengthM = 30.0; // nominal craft size for the cone projection
    for (final v in snapshot.vessels) {
      final c = project(v.x, v.y);
      if (!_discTouchesScreen(c, 16, size)) continue; // off-screen ship
      final apparentPx = view.radiusPx(v.worldRel, craftLengthM);
      final col = v.onRails ? const Color(0xFF7FE0A0) : const Color(0xFFFF8C66);
      // Surface-proximity cue (drop-line + alt + landed ring) UNDER the marker.
      _drawSurfaceCue(canvas, v, c, project);
      if (apparentPx <= 10) {
        // Heading from the nose projected into the CAMERA screen plane, so the
        // flat triangle points the same way the 3D cone would (they must agree
        // at the LOD switch). h = atan2(forward·up, forward·right).
        final h = math.atan2(v.forwardW.dot(view.up), v.forwardW.dot(view.right));
        _drawShip(canvas, c, h, v.onRails);
      } else {
        _drawCone(canvas, c, v, apparentPx, col);
      }
      _label(canvas, v.name, c + Offset(8 + apparentPx.clamp(0, 30), -4), col);
    }
  }

  /// Surface-approach cue for a vessel: when it's within ~one body radius of the
  /// surface, draw a dashed drop-line from the craft down to the radial foot
  /// (the point on the surface directly below it) plus an altitude label, so it's
  /// obvious the craft is approaching the ground. When landed, a pulsing contact
  /// ring instead. Reads at any zoom because the foot is projected through the
  /// camera like everything else.
  void _drawSurfaceCue(Canvas canvas, VesselView v, Offset c,
      Offset Function(double, double) project) {
    final alt = v.altSurfaceM;
    if (!alt.isFinite || v.bodyRadiusM <= 0) return;
    // Only cue once we're close-ish: within one body radius of the surface.
    if (alt > v.bodyRadiusM && !v.landed) return;

    final footPx = view.projectPx(v.surfaceFootRel);
    if (footPx == null) return;
    final foot = project(footPx.x, footPx.y);

    if (v.landed) {
      // Contact ring — landed.
      canvas.drawCircle(
          c,
          10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFF7FE0A0));
      _label(canvas, 'LANDED', c + const Offset(12, 6),
          const Color(0xFF7FE0A0));
      return;
    }

    // Approach: closer = redder + brighter (warns of impending ground contact).
    final frac = (alt / v.bodyRadiusM).clamp(0.0, 1.0);
    final warn = frac < 0.05; // < 5% of a radius up — very low
    final lineCol =
        (warn ? const Color(0xFFFF3B30) : const Color(0xFF8FE3FF))
            .withValues(alpha: (1.0 - frac).clamp(0.25, 0.9));

    // Dashed drop-line craft -> surface foot.
    _dashLine(canvas, c, foot, lineCol);
    // A little tick on the surface where it touches down.
    canvas.drawCircle(foot, 3, Paint()..color = lineCol);
    // Altitude label at the midpoint.
    final mid = Offset.lerp(c, foot, 0.5)!;
    _label(canvas, _altLabel(alt), mid + const Offset(6, -2), lineCol);
  }

  /// Dashed straight line between two screen points.
  void _dashLine(Canvas canvas, Offset a, Offset b, Color color) {
    const dash = 6.0, gap = 4.0;
    final total = (b - a).distance;
    if (total < 1) return;
    final dir = (b - a) / total;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    var t = 0.0;
    while (t < total) {
      final s = a + dir * t;
      final e = a + dir * math.min(t + dash, total);
      canvas.drawLine(s, e, paint);
      t += dash + gap;
    }
  }

  String _altLabel(double m) => m.abs() < 10000
      ? '${m.toStringAsFixed(0)} m'
      : '${(m / 1000).toStringAsFixed(1)} km';

  /// The craft marker: a 4-sided SQUARE-base pyramid (the lander shape),
  /// oriented by the craft's real 3D attitude and projected through the camera.
  /// Each of the four faces is split at its base-edge midpoint into two
  /// triangles -> 8 facets, painted in an alternating light/dark checker (the
  /// lander look) modulated by Lambert vs the sun. Drawn back-to-front so it
  /// reads as solid.
  void _drawCone(
      Canvas canvas, Offset c, VesselView v, double sizePx, Color tint) {
    // Project a craft-space direction onto the camera screen plane (px).
    Offset axis(Vector3 worldDir) =>
        Offset(worldDir.dot(view.right), -worldDir.dot(view.up));
    final noseDir = axis(v.forwardW);
    // Craft right/up axes spanning the base plane (perpendicular to the nose).
    final craftRight = v.upW.cross(v.forwardW).normalized;
    final rightDir = axis(craftRight);
    final upDir = axis(v.upW);

    final len = sizePx * 1.4;
    final rad = sizePx * 0.6;
    final apex = c + noseDir * len;
    // Engine exhaust opposite the nose, scaled by throttle — drawn first so the
    // pyramid overdraws its root (matches the lander flame on the other models).
    if (v.throttle > 0.02) {
      final flameLen = sizePx * (1.0 + 2.0 * v.throttle);
      final tail = c - noseDir * flameLen;
      canvas.drawLine(
          c,
          tail,
          Paint()
            ..color = const Color(0xCCFF8C42)
            ..strokeWidth = (sizePx * 0.5).clamp(1.5, 8.0)
            ..strokeCap = StrokeCap.round);
      // Hot inner core.
      canvas.drawLine(
          c,
          Offset.lerp(c, tail, 0.55)!,
          Paint()
            ..color = const Color(0xEEFFE08A)
            ..strokeWidth = (sizePx * 0.25).clamp(1.0, 4.0)
            ..strokeCap = StrokeCap.round);
    }
    // 4 square-base corners (on the diagonals so the base reads as a square).
    final corner = <Offset>[];
    final corner3 = <Vector3>[]; // world-dir of each corner (for lighting/depth)
    for (var i = 0; i < 4; i++) {
      final a = (i + 0.5) / 4 * 2 * math.pi;
      corner3.add((craftRight * math.cos(a) + v.upW * math.sin(a)).normalized);
      corner.add(c + (rightDir * math.cos(a) + upDir * math.sin(a)) * rad);
    }
    final dark = _scale(tint, 0.55); // the darker checker tone

    // Two facets per face (split at the edge midpoint) -> 8, checkered by the
    // GLOBAL facet index so it goes light/dark/light/dark all the way round.
    final faces = <({Path path, double bright, double depth, bool dark})>[];
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      final mid = Offset.lerp(corner[i], corner[j], 0.5)!;
      final mid3 = (corner3[i] + corner3[j]).normalized;
      // Face outward normal: base dirs tilted toward the nose. Lambert vs sun.
      final normal = (corner3[i] + corner3[j]).normalized * 0.7 +
          v.forwardW * 0.3;
      final bright = 0.25 + 0.75 * (normal.normalized.dot(v.sunW)).clamp(0.0, 1.0);
      final depth = -mid3.dot(view.forward);
      // Sub-triangle A: apex, corner i, mid.
      faces.add((
        path: Path()
          ..moveTo(apex.dx, apex.dy)
          ..lineTo(corner[i].dx, corner[i].dy)
          ..lineTo(mid.dx, mid.dy)
          ..close(),
        bright: bright,
        depth: depth,
        dark: (2 * i).isOdd, // = false -> light
      ));
      // Sub-triangle B: apex, mid, corner j.
      faces.add((
        path: Path()
          ..moveTo(apex.dx, apex.dy)
          ..lineTo(mid.dx, mid.dy)
          ..lineTo(corner[j].dx, corner[j].dy)
          ..close(),
        bright: bright,
        depth: depth,
        dark: (2 * i + 1).isOdd, // = true -> dark
      ));
    }
    // Square BASE cap so the pyramid isn't open underneath. Its outward normal
    // is -nose; it sits opposite the apex, so its depth tracks the nose
    // direction (base toward the viewer when the nose points away).
    final baseNormal = (-v.forwardW).normalized;
    final baseBright = 0.25 + 0.75 * (baseNormal.dot(v.sunW)).clamp(0.0, 1.0);
    faces.add((
      path: Path()
        ..moveTo(corner[0].dx, corner[0].dy)
        ..lineTo(corner[1].dx, corner[1].dy)
        ..lineTo(corner[2].dx, corner[2].dy)
        ..lineTo(corner[3].dx, corner[3].dy)
        ..close(),
      bright: baseBright,
      depth: v.forwardW.dot(view.forward),
      dark: true, // a flat dark underside
    ));
    faces.sort((a, b) => a.depth.compareTo(b.depth)); // far first
    for (final f in faces) {
      final c = _scale(f.dark ? dark : tint, f.bright);
      canvas.drawPath(f.path, Paint()..color = c);
    }
    // Nose tip for definition.
    canvas.drawCircle(c, 1.5, Paint()..color = tint);
  }

  void _drawShip(Canvas canvas, Offset c, double heading, bool onRails) {
    const len = 9.0;
    const wid = 5.0;
    // Heading: +X is right, but screen Y is flipped, so negate the angle.
    final a = -heading;
    final cosA = math.cos(a), sinA = math.sin(a);
    Offset rot(double x, double y) =>
        c + Offset(x * cosA - y * sinA, x * sinA + y * cosA);

    final path = Path()
      ..moveTo(rot(len, 0).dx, rot(len, 0).dy)
      ..lineTo(rot(-len * 0.6, wid).dx, rot(-len * 0.6, wid).dy)
      ..lineTo(rot(-len * 0.6, -wid).dx, rot(-len * 0.6, -wid).dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()..color = onRails ? const Color(0xFF7FE0A0) : const Color(0xFFFF8C66),
    );
  }

  /// Draws a vessel orbit path, emitting a segment only when BOTH endpoints
  /// belong to [behindPass] (behind / in front of the dominant body). This
  /// avoids a spurious closing chord where the path crosses the depth boundary.
  void _drawVesselPath(Canvas canvas, VesselView v,
      Offset Function(double, double) project, Rect clip, bool behindPass) {
    final pts = v.path, beh = v.pathBehind;
    if (pts.length < 2 || beh.length != pts.length) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = (v.onRails ? const Color(0xFF7FE0A0) : const Color(0xFFFF8C66))
          .withValues(alpha: 0.5);
    for (var i = 0; i < pts.length - 1; i++) {
      final ai = beh[i] == behindPass;
      final bi = beh[i + 1] == behindPass;
      if (!ai && !bi) continue;
      // Break the line at NaN points (underground / culled) — no streak.
      if (pts[i].x.isNaN ||
          pts[i].y.isNaN ||
          pts[i + 1].x.isNaN ||
          pts[i + 1].y.isNaN) {
        continue;
      }
      var pa = project(pts[i].x, pts[i].y);
      var pb = project(pts[i + 1].x, pts[i + 1].y);
      // At a behind<->front transition draw only HALF the straddling segment (to
      // the midpoint) so the two passes meet exactly — no gap, no double-draw.
      if (ai && !bi) pb = Offset.lerp(pa, pb, 0.5)!;
      if (bi && !ai) pa = Offset.lerp(pa, pb, 0.5)!;
      final seg = _clipSegment(pa, pb, clip);
      if (seg != null) canvas.drawLine(seg.$1, seg.$2, paint);
    }
  }

  /// The focused vessel's FLOWN breadcrumb trail (screen px from the snapshot).
  /// Solid cyan, fading toward the oldest point so the newest path reads
  /// strongest. NaN points (camera-culled) break the line rather than streaking
  /// across the screen.
  void _drawFlownTrail(
      Canvas canvas, Offset Function(double, double) project, Rect clip) {
    final pts = snapshot.trailPx;
    if (pts.length < 2) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i], b = pts[i + 1];
      if (a.x.isNaN || a.y.isNaN || b.x.isNaN || b.y.isNaN) continue;
      // Older points fade out: alpha ramps from ~0.1 (oldest) to 0.9 (newest).
      final t = i / (pts.length - 1);
      paint.color = const Color(0xFF4FC3F7).withValues(alpha: 0.1 + 0.8 * t);
      final seg = _clipSegment(project(a.x, a.y), project(b.x, b.y), clip);
      if (seg != null) canvas.drawLine(seg.$1, seg.$2, paint);
    }
  }

  /// Draws a celestial body's orbit rail with the same depth handling as vessel
  /// paths: a segment only in [behindPass], halving the straddling segment at a
  /// behind<->front transition so the two halves meet without gap or overlap.
  void _drawBodyRail(Canvas canvas, BodyView b,
      Offset Function(double, double) project, Rect clip, bool behindPass) {
    final pts = b.orbitPath, beh = b.orbitBehind;
    if (pts.length < 2 || beh.length != pts.length) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF5A7CA8).withValues(alpha: 0.28);
    for (var i = 0; i < pts.length - 1; i++) {
      final ai = beh[i] == behindPass;
      final bi = beh[i + 1] == behindPass;
      if (!ai && !bi) continue;
      var pa = project(pts[i].x, pts[i].y);
      var pb = project(pts[i + 1].x, pts[i + 1].y);
      if (ai && !bi) pb = Offset.lerp(pa, pb, 0.5)!;
      if (bi && !ai) pa = Offset.lerp(pa, pb, 0.5)!;
      final seg = _clipSegment(pa, pb, clip);
      if (seg != null) canvas.drawLine(seg.$1, seg.$2, paint);
    }
  }

  // ---- Rayleigh-scattering atmosphere ----
  // Rayleigh scatter ∝ 1/λ⁴, so short (blue) wavelengths scatter most. On a
  // planet limb we approximate the physics with screen-space colour, not a
  // raymarch:
  //  * The DAY side glows blue (forward + side scattering of sunlight).
  //  * Toward the TERMINATOR the sightline grazes a long air path, blue is
  //    scattered out and the remaining light reddens — the sunset arc.
  //  * The NIGHT limb is dark (no incoming sunlight to scatter).
  // Direction to the sun arrives in screen space (sunX right, sunY up — but
  // screen Y is flipped vs world, so we negate sunY).

  // Default day-sky tint (used when a body has no specific atmosphere colour).
  static const Color _rayleighBlue = Color(0xFF6FB4FF);

  /// Draws the equirectangular star map as a sky window: instead of stretching
  /// the whole panorama flat, we crop a sub-rectangle of it centred on the
  /// camera's look direction (azimuth -> longitude, elevation -> latitude) and
  /// blit that to the screen. Panning the camera scrolls the window across the
  /// sky, so the distortion of a 360° photo no longer reads as a flat picture.
  void _drawSkybox(Canvas canvas, Size size, ui.Image sky) {
    final iw = sky.width.toDouble();
    final ih = sky.height.toDouble();

    // Look direction -> equirect UV centre. azimuth maps around longitude,
    // elevation maps to latitude (top-down look = straight up = image top).
    final u = ((view.azimuth / (2 * math.pi)) % 1.0 + 1.0) % 1.0;
    // Pitch: +elevation looks DOWN; the sky window must move with the camera
    // (not against it), so add the elevation term.
    final v = (0.5 + view.elevation / math.pi).clamp(0.0, 1.0);

    // Field of view: how much of the panorama the window covers. ~70° horizontal.
    const fovU = 70 / 360; // fraction of longitude
    final fovV = fovU * (size.height / size.width); // keep screen aspect

    final srcW = iw * fovU;
    final srcH = ih * fovV;
    var sx = u * iw - srcW / 2;
    var sy = (v * ih - srcH / 2).clamp(0.0, ih - srcH);
    // Wrap longitude: if the window crosses the seam, just clamp into range —
    // the star map is dense enough that a hard edge isn't noticeable when dim.
    sx = sx.clamp(0.0, iw - srcW);

    canvas.drawImageRect(
      sky,
      Rect.fromLTWH(sx, sy, srcW, srcH),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..colorFilter =
            const ColorFilter.mode(Color(0x73000000), BlendMode.srcOver),
    );
  }

  /// Planetary rings, drawn as concentric stroked ellipses (genuinely hollow,
  /// with procedural banding). [behindPass] selects which half to draw: the part
  /// of the rings on the far side of the body (true, drawn before the disc) or
  /// the near side (false, drawn over it), so the planet occludes the back of
  /// the rings instead of the rings covering the whole planet.
  /// Width (texels) of the synthetic radial band gradient. The shader samples a
  /// linear gradient from (0,0)->(W,0) in texcoord space; each ring vertex gets a
  /// texcoord whose x = radial-fraction * W, so the inner->outer banding (ripple
  /// + division gaps) is reproduced per-pixel crisp at any zoom — no row limit.
  static const double _ringBandW = 256;

  /// Radial band shaders keyed by ringColor (so each body's tint is baked once,
  /// not rebuilt every frame). The gap/ripple profile matches the old per-band
  /// alpha curve; alpha lives in the gradient so the shader carries colour AND
  /// banding, and the per-vertex colours carry only shadow/occlusion darkening.
  final Map<int, Shader> _ringBandShaders = {};

  Shader _ringBandShader(int ringColor) => _ringBandShaders.putIfAbsent(
        ringColor,
        () {
          const stops = 48;
          final colors = <Color>[];
          final pos = <double>[];
          final ringBase = Color(ringColor);
          for (var k = 0; k < stops; k++) {
            final f = k / (stops - 1); // 0 = inner, 1 = outer
            final gap = (f > 0.42 && f < 0.5) || (f > 0.74 && f < 0.78);
            final ripple = 0.5 + 0.5 * math.cos(f * math.pi * 11);
            final alpha = gap ? 0.06 : (0.18 + 0.32 * ripple);
            final tint =
                Color.lerp(_scale(ringBase, 0.82), ringBase, f) ?? ringBase;
            colors.add(tint.withValues(alpha: alpha));
            pos.add(f);
          }
          return ui.Gradient.linear(
            const Offset(0, 0),
            const Offset(_ringBandW, 0),
            colors,
            pos,
          );
        },
      );

  void _drawRings(Canvas canvas, BodyView b,
      Offset Function(double, double) project, bool behindPass) {
    final inN = b.ringInnerPath, outN = b.ringOuterPath, beh = b.ringBehind;
    final shI = b.ringShadowInner, shO = b.ringShadowOuter;
    if (inN.length < 3 ||
        outN.length != inN.length ||
        beh.length != inN.length) {
      return;
    }
    final hasShadow = shI.length == inN.length && shO.length == inN.length;

    // One triangle-strip-style mesh between the inner and outer ring polylines,
    // submitted as a single drawVertices call (was up to 48*160*2 drawLine).
    //  - texcoord.x = 0 at inner, _ringBandW at outer -> the band shader supplies
    //    tint + ripple/gap, modulated by drawVertices against the vertex colour.
    //  - vertex colour = white (lit) or near-black (planet shadow), times the
    //    body ring intensity in alpha. The shader's own alpha holds the banding.
    //  - only segments whose samples belong to THIS pass (front/back of the disc)
    //    are emitted, so the planet still occludes the far half.
    final intensity = b.ringIntensity.clamp(0.0, 1.0);
    final litColor = Color.fromRGBO(255, 255, 255, intensity);
    final shadowColor = Color.fromRGBO(20, 20, 20, intensity);

    // Shadow is per-EDGE (inner vs outer) so the gradient interpolates the chord
    // across the band: a vertex is dark when its perpendicular distance to the
    // planet's sun-line is inside the body radius.
    Color edgeColor(bool inner, int i) =>
        (hasShadow && (inner ? shI[i] : shO[i]) < b.radius)
            ? shadowColor
            : litColor;

    final positions = <Offset>[];
    final texCoords = <Offset>[];
    final colors = <Color>[];

    void addQuad(int i, int j) {
      final inI = project(inN[i].x, inN[i].y);
      final outI = project(outN[i].x, outN[i].y);
      final inJ = project(inN[j].x, inN[j].y);
      final outJ = project(outN[j].x, outN[j].y);
      final cInI = edgeColor(true, i), cOutI = edgeColor(false, i);
      final cInJ = edgeColor(true, j), cOutJ = edgeColor(false, j);
      const tIn = Offset(0, 0), tOut = Offset(_ringBandW, 0);
      // Triangle 1: inI, outI, inJ
      positions.add(inI);
      texCoords.add(tIn);
      colors.add(cInI);
      positions.add(outI);
      texCoords.add(tOut);
      colors.add(cOutI);
      positions.add(inJ);
      texCoords.add(tIn);
      colors.add(cInJ);
      // Triangle 2: outI, outJ, inJ
      positions.add(outI);
      texCoords.add(tOut);
      colors.add(cOutI);
      positions.add(outJ);
      texCoords.add(tOut);
      colors.add(cOutJ);
      positions.add(inJ);
      texCoords.add(tIn);
      colors.add(cInJ);
    }

    for (var i = 0; i < inN.length - 1; i++) {
      // Emit the segment only when BOTH endpoints sit on this pass's side; the
      // straddling (front<->back transition) segment is dropped — the gap is one
      // sample wide out of 160 and the disc covers it anyway.
      if (beh[i] != behindPass || beh[i + 1] != behindPass) continue;
      // Skip culled (NaN) samples so no degenerate triangles reach the GPU.
      if (_nan(inN[i]) || _nan(outN[i]) || _nan(inN[i + 1]) || _nan(outN[i + 1])) {
        continue;
      }
      addQuad(i, i + 1);
    }

    if (positions.length < 3) return;
    final verts = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: texCoords,
      colors: colors,
    );
    // BlendMode.modulate: fragment = shader(texcoord) * vertexColor — banding &
    // tint from the gradient, shadow/occlusion darkening from the vertex colour.
    canvas.drawVertices(
      verts,
      BlendMode.modulate,
      Paint()..shader = _ringBandShader(b.ringColor),
    );
  }

  bool _nan(({double x, double y}) p) => p.x.isNaN || p.y.isNaN;

  /// Faint blue atmosphere halo ringing the body's limb.
  /// Outer atmospheric glow ringing the body's limb (drawn UNDER the disc), with
  /// Rayleigh colouring: blue on the sunlit side fading to a warm tint near the
  /// terminator. [sunX]/[sunY] are screen-space; pass 0 for an even glow.
  /// Bright corona/glow around a star: a hot white-yellow core blooming out to
  /// a soft orange falloff. Additive so it brightens whatever's behind it.
  void _starGlow(Canvas canvas, Offset c, double rPx) {
    final outer = rPx * _starGlowScale;
    final glow = RadialGradient(
      colors: const [
        Color(0xFFFFF7E0), // hot core
        Color(0xCCFFE08A), // bright yellow
        Color(0x66FFB347), // orange falloff
        Color(0x1AFF8C1A), // faint outer
        Color(0x00FF8C1A), // transparent
      ],
      stops: const [0.0, 0.18, 0.4, 0.7, 1.0],
    );
    final rect = Rect.fromCircle(center: c, radius: outer);
    canvas.drawCircle(
      c,
      outer,
      Paint()
        ..blendMode = BlendMode.plus // additive bloom
        ..shader = glow.createShader(rect),
    );
  }

  /// Outer atmosphere halo, lit by the SAME 3D Lambert model as the sphere (not
  /// a 2D sweep — that snapped between modes). Each point around the limb has a
  /// camera-frame normal (cosθ, sinθ, 0); we rotate it to world and dot with the
  /// sun. This makes the lit crescent rotate smoothly and the night side go dark,
  /// while a separate forward-scatter term lights the whole ring when the sun is
  /// directly behind the body — all one continuous formula, no mode switch.
  void _atmosphereHalo(Canvas canvas, Offset c, double rPx, Size size,
      {required SceneCamera view,
      required Vector3 sunWorld,
      Color tint = _rayleighBlue,
      double thickness = 0.22}) {
    final halo = AtmosphereHalo(bodyRadiusPx: rPx, thicknessFraction: thickness);
    final right = view.right, upv = view.up, fwd = view.forward;
    // Sun in camera frame: x=right, y=up, z=toward viewer (= -forward).
    final sc = [
      sunWorld.dot(right),
      sunWorld.dot(upv),
      -sunWorld.dot(fwd),
    ];
    // How much the sun is behind the body (forward-scatter / backlit rim glow).
    final back = (-sc[2]).clamp(0.0, 1.0);

    final day = tint;
    final bright = Color.lerp(tint, const Color(0xFFFFFFFF), 0.35) ?? tint;
    const warm = Color(0xFFFF9D5C);

    // Per-angle scatter colour, baked into a SweepGradient — ONE shader, a few
    // draw calls, instead of thousands of arcs (the perspective-zoom lag). The
    // Lambert + warm-band logic is the same, just sampled at N stops.
    const stops = 48;
    final colors = <Color>[];
    final positions = <double>[];
    for (var i = 0; i <= stops; i++) {
      final t = i / stops;
      final ang = t * 2 * math.pi;
      final nx = math.cos(ang), ny = -math.sin(ang);
      final lit = (nx * sc[0] + ny * sc[1]).clamp(-1.0, 1.0);
      final dayF = _smoothstep01(lit, -0.45, 0.4);
      final warmF = (1 - _smoothstep01(lit, -0.45, 0.6)) * dayF;
      final scatter = (dayF + back * 0.8).clamp(0.0, 1.0);
      var col = Color.lerp(day, warm, warmF) ?? day;
      if (lit > 0.7) col = Color.lerp(col, bright, 0.4) ?? col;
      if (back > 0.4) col = Color.lerp(col, warm, back * 0.5) ?? col;
      colors.add(col.withValues(alpha: scatter));
      positions.add(t);
    }
    final rect = Rect.fromCircle(center: c, radius: halo.outerRadius);
    final sweep = SweepGradient(colors: colors, stops: positions);

    // Radial mask: transparent inside the body, the glow building from the
    // surface (rPx) out to the halo edge then fading. Multiplied with the sweep.
    final innerFrac = halo.innerRadius / halo.outerRadius;
    final mask = RadialGradient(
      colors: const [
        Color(0x00000000), // inside the body: clear
        Color(0x00000000),
        Color(0xFFFFFFFF), // at the surface: full
        Color(0x00000000), // fade to the halo edge
      ],
      stops: [0.0, innerFrac * 0.98, innerFrac, 1.0],
    );

    // Bound the offscreen layer to the viewport so a giant halo rect doesn't
    // allocate a huge buffer.
    final layerBounds = rect.intersect(Offset.zero & size);
    if (layerBounds.isEmpty) return;
    canvas.saveLayer(layerBounds, Paint());
    canvas.drawCircle(c, halo.outerRadius,
        Paint()..shader = sweep.createShader(rect));
    canvas.drawCircle(
      c,
      halo.outerRadius,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = mask.createShader(rect),
    );
    canvas.restore();
  }

  double _smoothstep01(double x, double e0, double e1) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// Ultra-basic shaded disc: clip to the body circle, fill dark, then paint a
  /// coarse grid of cells tinted by Lambert brightness. The sun arrives as a full
  /// 3D direction (screen x,y + [sunZ] = how much it faces the camera), so the
  /// shading is correct even when the sun is along the view axis (front-on lights
  /// the whole disc, back-on leaves it dark) — the old 2D-only sun couldn't tell.
  void _drawShadedDisc(Canvas canvas, Offset c, double rPx, Color base,
      Vector3 sun, BodyShading shading, double sunZ) {
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: rPx)));
    // Night side.
    canvas.drawCircle(c, rPx, Paint()..color = _scale(base, 0.12));

    // Full 3D sun direction. sun.x/.y are the screen-plane components; sunZ is
    // toward the camera. Normalize so the Lambert dot is a true cosine.
    var sx = sun.x, sy = sun.y, sz = sunZ;
    final sl = math.sqrt(sx * sx + sy * sy + sz * sz);
    if (sl < 1e-6) {
      sx = 0;
      sy = 0;
      sz = 1;
    } else {
      sx /= sl;
      sy /= sl;
      sz /= sl;
    }

    final step = math.max(2.0, rPx / 10); // ~10 cells across
    for (var py = -rPx; py <= rPx; py += step) {
      for (var px = -rPx; px <= rPx; px += step) {
        final dx = px / rPx;
        final dy = py / rPx;
        final r2 = dx * dx + dy * dy;
        if (r2 > 1) continue;
        // Surface normal of the visible hemisphere at this cell (z toward
        // camera). Screen Y is flipped vs world, so the normal's y is -dy.
        final nz = math.sqrt(1 - r2);
        final bright = (dx * sx + (-dy) * sy + nz * sz).clamp(0.0, 1.0);
        if (bright <= 0.02) continue;
        canvas.drawRect(
          Rect.fromLTWH(c.dx + px, c.dy + py, step + 0.6, step + 0.6),
          Paint()..color = _scale(base, 0.15 + 0.85 * bright),
        );
      }
    }
    canvas.restore();
  }

  Color _scale(Color base, double f) => Color.fromARGB(
        255,
        (base.r * 255 * f).clamp(0, 255).round(),
        (base.g * 255 * f).clamp(0, 255).round(),
        (base.b * 255 * f).clamp(0, 255).round(),
      );

  /// Pixels beyond the viewport edge we still draw into (so a line leaves the
  /// screen cleanly). Segments are clipped to this band before rasterizing.
  static const double _clipMargin = 64.0;


  // Cohen–Sutherland region outcode.
  int _outcode(Offset p, Rect r) {
    var code = 0;
    if (p.dx < r.left) {
      code |= 1;
    } else if (p.dx > r.right) {
      code |= 2;
    }
    if (p.dy < r.top) {
      code |= 4;
    } else if (p.dy > r.bottom) {
      code |= 8;
    }
    return code;
  }

  /// Clip a single segment to [clip]; returns the visible sub-segment, or null
  /// if it lies entirely outside (or is non-finite).
  (Offset, Offset)? _clipSegment(Offset a, Offset b, Rect clip) {
    if (!a.dx.isFinite || !a.dy.isFinite || !b.dx.isFinite || !b.dy.isFinite) {
      return null;
    }
    var x0 = a.dx, y0 = a.dy, x1 = b.dx, y1 = b.dy;
    var c0 = _outcode(Offset(x0, y0), clip);
    var c1 = _outcode(Offset(x1, y1), clip);
    for (var guard = 0; guard < 16; guard++) {
      if ((c0 | c1) == 0) return (Offset(x0, y0), Offset(x1, y1)); // both in
      if ((c0 & c1) != 0) return null; // both share an outside region -> reject
      final out = c0 != 0 ? c0 : c1;
      double x, y;
      if ((out & 8) != 0) {
        x = x0 + (x1 - x0) * (clip.bottom - y0) / (y1 - y0);
        y = clip.bottom;
      } else if ((out & 4) != 0) {
        x = x0 + (x1 - x0) * (clip.top - y0) / (y1 - y0);
        y = clip.top;
      } else if ((out & 2) != 0) {
        y = y0 + (y1 - y0) * (clip.right - x0) / (x1 - x0);
        x = clip.right;
      } else {
        y = y0 + (y1 - y0) * (clip.left - x0) / (x1 - x0);
        x = clip.left;
      }
      if (out == c0) {
        x0 = x;
        y0 = y;
        c0 = _outcode(Offset(x0, y0), clip);
      } else {
        x1 = x;
        y1 = y;
        c1 = _outcode(Offset(x1, y1), clip);
      }
    }
    return null;
  }

  /// Whether a disc of radius [rPx] centred at [c] overlaps the screen (plus a
  /// margin). Guards against drawing at extreme coordinates when zoomed in.
  bool _discTouchesScreen(Offset c, double rPx, Size size) {
    if (!c.dx.isFinite || !c.dy.isFinite || !rPx.isFinite) return false;
    return c.dx + rPx > -16 &&
        c.dx - rPx < size.width + 16 &&
        c.dy + rPx > -16 &&
        c.dy - rPx < size.height + 16;
  }

  /// Distance from [c] to the FARTHEST screen corner. A circle of this radius
  /// centred on [c] just covers the whole viewport, wherever [c] sits (including
  /// off-screen). The sphere/disc sizes its cap to this so the surface fills the
  /// frame regardless of where the body centre projects.
  double _farthestCornerDist(Offset c, Size size) {
    if (!c.dx.isFinite || !c.dy.isFinite) return size.bottomRight(Offset.zero).distance;
    double d2(double x, double y) {
      final dx = c.dx - x, dy = c.dy - y;
      return dx * dx + dy * dy;
    }
    return math.sqrt([
      d2(0, 0),
      d2(size.width, 0),
      d2(0, size.height),
      d2(size.width, size.height),
    ].reduce(math.max));
  }

  /// A dashed circle (segments around the circumference) for SOI boundaries.
  void _dashedCircle(Canvas canvas, Offset c, double r, Color color) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    const dashes = 64;
    for (var i = 0; i < dashes; i += 2) {
      final a0 = (i / dashes) * 2 * math.pi;
      final a1 = ((i + 1) / dashes) * 2 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        a0,
        a1 - a0,
        false,
        paint,
      );
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _hud(Canvas canvas, Size size) {
    final az = (view.azimuth * 180 / math.pi).toStringAsFixed(0);
    final el = (view.elevation * 180 / math.pi).toStringAsFixed(0);
    _label(canvas, 'cam az$az el$el',
        const Offset(8, 8), const Color(0xFF6E8299));

    // Readout lines from the presenter's HUD view.
    var y = 26.0;
    for (final line in snapshot.hud.lines) {
      _label(canvas, line, Offset(8, y), const Color(0xFFB9C9DC));
      y += 14;
    }

    // Texture attribution (CC-BY 4.0 license requirement).
    _label(
      canvas,
      'Body maps: solarsystemscope.com (CC-BY 4.0)',
      Offset(size.width - 250, size.height - 16),
      const Color(0xFF4A5A6A),
    );
  }

  @override
  bool shouldRepaint(covariant TopDownPainter old) =>
      old.snapshot != snapshot || old.view != view || old.layers != layers;
}
