import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/shared/vector3.dart';
import '../../domain/vessel/vessel.dart';

/// Nav-ball state as 3D directions in the CRAFT's body frame (nose +Z, right +X,
/// up +Y — looking down the nose into the ball). The painter projects these onto
/// the ball and hides anything on the back hemisphere, like a real nav-ball.
class NavState {
  /// Local "up" (radial-out from the body) in the craft frame — defines where
  /// the artificial-horizon sky/ground split sits.
  final Vector3 upInCraft;

  /// Prograde (velocity) direction in the craft frame; null if ~stationary.
  final Vector3? progradeInCraft;

  /// Local NORTH and EAST (tangent-plane compass basis) expressed in the craft
  /// frame, so the painter can place the cardinal compass marks on the ball.
  final Vector3 northInCraft;
  final Vector3 eastInCraft;

  /// Compass heading of the nose, degrees (0 = north, 90 = east), 0..360.
  final double headingDeg;

  const NavState({
    required this.upInCraft,
    this.progradeInCraft,
    this.northInCraft = Vector3.unitZ,
    this.eastInCraft = Vector3.unitX,
    this.headingDeg = 0,
  });

  factory NavState.fromVessel(Vessel v) {
    final pos = v.state.position;
    final worldUp = pos.length < 1 ? Vector3.unitZ : pos.normalized;

    // Local compass basis (ENU) in WORLD space. North = ecliptic +Z projected
    // onto the local tangent plane; east completes the right-handed up/east/north
    // triad (up = east x north). Degenerate at the poles (up ~ +/-Z) -> fall back
    // to world +X for north so the basis stays finite.
    var north = Vector3.unitZ - worldUp * worldUp.dot(Vector3.unitZ);
    if (north.length < 1e-6) {
      north = Vector3.unitX - worldUp * worldUp.dot(Vector3.unitX);
    }
    north = north.normalized;
    final east = north.cross(worldUp).normalized; // up = east x north

    // Craft body axes in world space.
    final nose = v.state.attitude.rotate(Vector3.unitZ);
    final right = v.state.attitude.rotate(Vector3.unitX);
    final up = v.state.attitude.rotate(Vector3.unitY);

    // Express a world direction in the craft frame (x=right, y=up, z=nose).
    Vector3 toCraft(Vector3 d) => Vector3(d.dot(right), d.dot(up), d.dot(nose));

    final vel = v.state.velocity;
    final pg = vel.length > 1 ? toCraft(vel.normalized) : null;

    // Heading: the nose's horizontal bearing, measured from north toward east.
    final hdg = (math.atan2(nose.dot(east), nose.dot(north)) * 180 / math.pi);

    return NavState(
      upInCraft: toCraft(worldUp),
      progradeInCraft: pg,
      northInCraft: toCraft(north),
      eastInCraft: toCraft(east),
      headingDeg: (hdg + 360) % 360,
    );
  }
}

/// A flight nav-ball: the sky-sphere seen looking down the craft's nose, with
/// an artificial horizon (sky/ground from local-up) and prograde/retrograde
/// markers that hide on the back hemisphere.
class NavBall extends StatelessWidget {
  final NavState state;
  final double size;
  const NavBall({super.key, required this.state, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _NavBallPainter(state)),
    );
  }
}

class _NavBallPainter extends CustomPainter {
  final NavState s;
  _NavBallPainter(this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 2;

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));

    // Artificial horizon: the sky hemisphere is the half of the ball whose
    // surface normal points toward local UP. The horizon is the great circle
    // perpendicular to up; its screen projection is a line. In the craft frame
    // up = (ux, uy, uz): screen plane is (x=right, y=up_screen=-y so down is +),
    // toward-viewer = +z (nose). The horizon line on screen has normal (ux, -uy)
    // and is offset by uz (how tilted up is toward/away from the nose).
    final u = s.upInCraft;
    _drawHorizon(canvas, c, r, u);

    // Compass marks: the four cardinal directions on the horizon, projected on
    // the ball and hidden on the back hemisphere (they sweep as the craft yaws,
    // giving a readable heading). N is highlighted.
    _compass(canvas, c, r);

    // Prograde / retrograde markers on the ball surface (back one auto-hidden).
    final pg = s.progradeInCraft;
    if (pg != null) {
      _marker(canvas, c, r, pg.normalized, prograde: true);
      _marker(canvas, c, r, (pg * -1).normalized, prograde: false);
    }

    // Zenith (straight UP) + nadir (straight DOWN) markers: a filled dot inside a
    // ring. When the nose points straight up the zenith ring sits dead-centre on
    // the reticle, so the pilot can see they're pointing exactly up/down.
    _zenithNadir(canvas, c, r);

    canvas.restore(); // drop ball clip

    // Rim + fixed nose reticle (always centred, on top).
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF9FB4CC),
    );
    _nose(canvas, c, r * 0.12);

    // Numeric heading readout, top-centre over the rim.
    _headingLabel(canvas, c, r);
  }

  /// Cardinal compass marks (N/E/S/W) on the horizon, hidden on the back of the
  /// ball. They rotate with the craft's yaw so the nose reticle reads against
  /// them like a compass.
  void _compass(Canvas canvas, Offset c, double r) {
    const marks = [
      ('N', true),
      ('E', false),
      ('S', false),
      ('W', false),
    ];
    final dirs = [
      s.northInCraft,
      s.eastInCraft,
      s.northInCraft * -1, // south
      s.eastInCraft * -1, // west
    ];
    for (var i = 0; i < marks.length; i++) {
      final d = dirs[i];
      if (d.length < 1e-6) continue;
      final dir = d.normalized;
      if (dir.z <= 0.02) continue; // back hemisphere -> hidden
      final p = _project(c, r, dir);
      // Fade toward the limb (z small) so marks near the edge don't pop.
      final a = (dir.z).clamp(0.0, 1.0);
      final isN = marks[i].$2;
      final col = (isN ? const Color(0xFFFF6B6B) : Colors.white)
          .withValues(alpha: 0.35 + 0.65 * a);
      final tp = TextPainter(
        text: TextSpan(
          text: marks[i].$1,
          style: TextStyle(
            color: col,
            fontSize: r * 0.20,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _headingLabel(Canvas canvas, Offset c, double r) {
    final hdg = s.headingDeg.round() % 360;
    final tp = TextPainter(
      text: TextSpan(
        text: '${hdg.toString().padLeft(3, '0')}°',
        style: TextStyle(
          color: const Color(0xFFFFE08A),
          fontSize: r * 0.22,
          fontWeight: FontWeight.bold,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Centred just inside the ball's top rim (stays within the widget bounds),
    // on a dark pill so it reads over the sky/ground.
    final pos = Offset(c.dx - tp.width / 2, c.dy - r + 2);
    final pill = Rect.fromLTWH(pos.dx - 4, pos.dy - 1, tp.width + 8, tp.height + 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, const Radius.circular(4)),
      Paint()..color = const Color(0xCC000000),
    );
    tp.paint(canvas, pos);
  }

  /// Project a unit direction in the craft frame to the ball: screen x = right,
  /// screen y = down (flip the craft-up), front hemisphere when z (nose) > 0.
  Offset _project(Offset c, double r, Vector3 d) =>
      Offset(c.dx + d.x * r, c.dy - d.y * r);

  void _drawHorizon(Canvas canvas, Offset c, double r, Vector3 up) {
    // Fill the whole ball with sky, then draw the GROUND cap (the hemisphere
    // around the anti-up / "down" direction that faces the viewer).
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF2E6FB0)); // sky

    // Down direction in the craft frame.
    final down = up * -1;
    // The ground hemisphere is centred on `down`. Its visible silhouette is a
    // half-plane: points with (p · down) >= 0 in the screen plane, offset by the
    // depth of `down`. Approximate by a clipped half-disc: a line perpendicular
    // to the screen-projected down vector, offset by down.z.
    final dxy = math.sqrt(down.x * down.x + down.y * down.y);
    final ground = Paint()..color = const Color(0xFF7A5630);
    if (dxy < 1e-4) {
      // Up/down along the nose: ground fills the whole ball if down faces us.
      if (down.z > 0) canvas.drawCircle(c, r, ground);
    } else {
      // Screen-space down direction (y flipped).
      final sdx = down.x / dxy, sdy = -down.y / dxy;
      // Offset of the horizon line from centre, along the down direction.
      final off = (-down.z) * r; // when down tilts toward viewer, line shifts
      // Build a big quad covering the half-plane beyond the horizon line.
      final nx = sdx, ny = sdy; // unit normal pointing into the ground side
      final lineCentre = Offset(c.dx + nx * off, c.dy + ny * off);
      // Tangent along the horizon line.
      final tx = -ny, ty = nx;
      const big = 4000.0;
      final p = Path()
        ..moveTo(lineCentre.dx + tx * big, lineCentre.dy + ty * big)
        ..lineTo(lineCentre.dx - tx * big, lineCentre.dy - ty * big)
        ..lineTo(lineCentre.dx - tx * big + nx * big,
            lineCentre.dy - ty * big + ny * big)
        ..lineTo(lineCentre.dx + tx * big + nx * big,
            lineCentre.dy + ty * big + ny * big)
        ..close();
      canvas.drawPath(p, ground);
      // Horizon line.
      canvas.drawLine(
        Offset(lineCentre.dx + tx * big, lineCentre.dy + ty * big),
        Offset(lineCentre.dx - tx * big, lineCentre.dy - ty * big),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 1.5,
      );

      // Pitch-ladder gradations: lines parallel to the horizon at ±30°, ±60°,
      // offset along the down-normal by the pitch fraction, foreshortened by how
      // edge-on the ball is (dxy). nx/ny points toward the GROUND (down) side, so
      // negative offset = sky (up) side.
      final tick = Paint()
        ..color = Colors.white54
        ..strokeWidth = 1;
      for (final deg in const [-60, -30, 30, 60]) {
        final ladOff = off - (deg / 90.0) * r * dxy; // sky (+deg) above horizon
        final lc = Offset(c.dx + nx * ladOff, c.dy + ny * ladOff);
        final half = r * 0.28; // short rungs
        canvas.drawLine(
          Offset(lc.dx + tx * half, lc.dy + ty * half),
          Offset(lc.dx - tx * half, lc.dy - ty * half),
          tick,
        );
      }
    }
  }

  /// Draw a prograde/retrograde marker at [dir] (craft-frame unit). Hidden when
  /// on the back hemisphere (dir.z <= 0 = behind the ball).
  void _marker(Canvas canvas, Offset c, double r, Vector3 dir,
      {required bool prograde}) {
    if (dir.z <= 0.02) return; // back hemisphere -> not visible
    final p = _project(c, r, dir);
    final rad = r * 0.11;
    if (prograde) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFD23F);
      canvas.drawCircle(p, rad, paint);
      canvas.drawLine(p - Offset(rad * 1.6, 0), p - Offset(rad, 0), paint);
      canvas.drawLine(p + Offset(rad, 0), p + Offset(rad * 1.6, 0), paint);
      canvas.drawLine(p - Offset(0, rad * 1.6), p - Offset(0, rad), paint);
      canvas.drawCircle(p, 1.5, Paint()..color = const Color(0xFFFFD23F));
    } else {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFF8C66);
      canvas.drawCircle(p, rad, paint);
      final d = rad * 0.7;
      canvas.drawLine(p + Offset(-d, -d), p + Offset(d, d), paint);
      canvas.drawLine(p + Offset(-d, d), p + Offset(d, -d), paint);
    }
  }

  /// Zenith (local UP) + nadir (local DOWN) markers — a filled dot inside a ring
  /// each, so the pilot can tell when the nose points exactly up or down (the
  /// marker lands on the centre reticle). Back-hemisphere marker is hidden.
  void _zenithNadir(Canvas canvas, Offset c, double r) {
    final up = s.upInCraft;
    if (up.length < 1e-6) return;
    void mark(Vector3 dir, Color col) {
      final d = dir.normalized;
      if (d.z <= 0.02) return; // behind the ball
      final p = _project(c, r, d);
      final a = (d.z).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = col.withValues(alpha: 0.4 + 0.6 * a);
      // Ring.
      canvas.drawCircle(
          p,
          r * 0.10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = paint.color);
      // Centre dot.
      canvas.drawCircle(p, r * 0.03, paint);
    }

    mark(up, const Color(0xFF66E0FF)); // zenith / straight up
    mark(up * -1, const Color(0xFFD98A4A)); // nadir / straight down
  }

  void _nose(Canvas canvas, Offset c, double sz) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFFFE08A);
    canvas.drawLine(c - Offset(sz * 2, 0), c - Offset(sz, 0), paint);
    canvas.drawLine(c + Offset(sz, 0), c + Offset(sz * 2, 0), paint);
    canvas.drawLine(c - Offset(0, sz), c, paint);
    canvas.drawCircle(c, 2, Paint()..color = const Color(0xFFFFE08A));
  }

  @override
  bool shouldRepaint(covariant _NavBallPainter old) =>
      old.s.upInCraft != s.upInCraft ||
      old.s.progradeInCraft != s.progradeInCraft ||
      old.s.northInCraft != s.northInCraft ||
      old.s.headingDeg != s.headingDeg;
}
