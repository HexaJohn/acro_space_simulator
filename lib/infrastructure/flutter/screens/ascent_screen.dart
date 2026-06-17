import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../adapters/flight/flight_traffic.dart';
import '../../../domain/flight/flight_world.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../nav_ball.dart';
import 'app_theme.dart';

/// Powered-ascent trainer with full 6-DOF attitude — the inverse of the landing
/// scenario, sharing the flight sim's quaternion attitude + nav-ball. A rocket
/// lifts off the surface and must fly a gravity turn to orbit: point the nose
/// where you want thrust, climb out of the air, then pitch toward the horizon to
/// build the HORIZONTAL speed that keeps you up.
///
/// Self-contained 3D integration (position + velocity + attitude) in the body's
/// equatorial plane, using its real μ, radius + atmosphere — the same physics
/// the flight sim runs. Ap/Pe come from the orbital energy + angular momentum.
/// A flyable craft profile handed to [AscentScreen] from the VAB — the physical
/// numbers a design bakes down to. Defaults reproduce the old hard-coded trainer
/// rocket, so opening Ascent with no profile is unchanged.
class LaunchProfile {
  final String name;
  final double dryMass; // kg
  final double maxThrust; // N
  final double exhaustVelocity; // m/s (Isp * g0)
  final double fuel; // kg propellant
  final double dragArea; // m^2
  final double dragCoefficient;
  final bool isPlane; // wings/jet -> launched from an airfield runway

  const LaunchProfile({
    this.name = 'Trainer',
    this.dryMass = 3000,
    this.maxThrust = 220000,
    this.exhaustVelocity = 320 * 9.80665,
    this.fuel = 5200,
    this.dragArea = 8.0,
    this.dragCoefficient = 0.3,
    this.isPlane = false,
  });
}

class AscentScreen extends StatefulWidget {
  /// Body to launch from (defaults to Earth) — lets the city's lander launch
  /// from whatever world the colony is on.
  final String? bodyId;

  /// The craft to fly (from the VAB). Null = the built-in trainer rocket.
  final LaunchProfile? profile;

  /// Shared airspace this flight joins — other players + supply craft come from
  /// here and we publish our own state into it. Null = a fresh local world (the
  /// standalone trainer; demo traffic is seeded so the feature is visible).
  final FlightTraffic? traffic;

  /// The local player id (owner of this flight) for the shared world.
  final String localPlayerId;

  /// Launch towers / pads at the origin spaceport — drawn across the bottom of
  /// the ascent profile. At least 1.
  final int pads;

  /// DESCENT mode: start high + falling and aim for a safe touchdown on a pad,
  /// instead of climbing to orbit. Same in-atmo flight model + shared traffic.
  final bool descent;

  /// Called on a successful DESCENT touchdown with WHERE it came down: a pad
  /// index (0..pads-1) if on a launch pad, or null for an off-site landing on
  /// open ground. Lets the colony park the craft on that pad.
  final void Function(int? padIndex)? onLand;

  /// Called when the craft comes down ON the city (not a pad) — the colony
  /// should destroy a random building (the craft is also destroyed).
  final void Function()? onCrashIntoCity;

  const AscentScreen({
    super.key,
    this.bodyId,
    this.profile,
    this.traffic,
    this.localPlayerId = 'player',
    this.pads = 1,
    this.descent = false,
    this.onLand,
    this.onCrashIntoCity,
  });

  @override
  State<AscentScreen> createState() => _AscentScreenState();
}

enum _Outcome { flying, orbit, landed, destroyed }

class _AscentScreenState extends State<AscentScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  late final List<CelestialBody> _bodies;
  late CelestialBody _body;

  // Craft parameters come from the launch profile (the VAB design) or fall back
  // to the built-in trainer rocket.
  LaunchProfile get _profile => widget.profile ?? const LaunchProfile();
  double get _dryMass => _profile.dryMass; // kg
  double get _maxThrust => _profile.maxThrust; // N
  double get _ispG0 => _profile.exhaustVelocity; // exhaust velocity (m/s)
  double get _dragArea => _profile.dragArea; // m^2
  double get _cd => _profile.dragCoefficient;
  static const double _turnRate = 1.2; // rad/s max attitude rate

  // 3D state, body-centred inertial. Motion is in the X-Y plane (Z = spin axis).
  late Vector3 _pos; // m
  late Vector3 _vel; // m/s
  late Quaternion _att; // nose = +Z body axis
  double _fuel = 5200; // kg (reset to the profile's fuel on _resetState)
  double _throttle = 1.0;
  // Attitude command (-1..1) from the sliders/keys: pitch, yaw, roll.
  double _pitchCmd = 0, _yawCmd = 0, _rollCmd = 0;
  bool _liftedOff = false; // true once clear of the pad (gates crash detection)
  final List<Vector3> _trail = []; // flown 3D body-relative path (breadcrumb)
  double _warp = 1; // time-warp multiplier
  static const _warps = [1.0, 2.0, 4.0, 8.0];
  _Outcome _outcome = _Outcome.flying;

  // Shared airspace this flight participates in. Other players' craft + supply
  // ships are read from here; our own state is published into it each frame.
  late final FlightTraffic _traffic;
  bool _ownsTraffic = false; // dispose only a traffic we created
  String get _localId => 'flight-${widget.localPlayerId}';

  @override
  void initState() {
    super.initState();
    final system = RealSolarSystem.build();
    _bodies = system.all.where((b) => !b.isStar).toList()
      ..sort((a, b) => _surfaceG(a).compareTo(_surfaceG(b)));
    final want = widget.bodyId ?? 'earth';
    _body = _bodies.firstWhere((b) => b.id.value == want,
        orElse: () => _bodies.firstWhere((b) => b.id.value == 'earth',
            orElse: () => _bodies.first));
    // Join (or create) the shared flight world.
    if (widget.traffic != null) {
      _traffic = widget.traffic!;
    } else {
      final local = LocalFlightTraffic(
        gravityMu: (_) => _body.mu,
        bodyRadius: (_) => _body.radius,
      );
      _seedDemoTraffic(local);
      _traffic = local;
      _ownsTraffic = true;
    }
    _resetState();
    _ticker = createTicker(_onTick)..start();
  }

  /// Standalone demo: a couple of other craft sharing the airspace so the
  /// traffic + collision features are visible without a live session.
  void _seedDemoTraffic(LocalFlightTraffic t) {
    final R = _body.radius;
    // A supply ship descending toward the pad from above.
    t.addSupply(FlightCraft(
      id: 'supply-1',
      kind: FlightCraftKind.supply,
      bodyId: _body.id.value,
      position: Vector3(R + 60000, 8000, 0),
      velocity: Vector3(-180, 20, 0),
      label: 'cargo',
    ));
    // Another player coasting downrange.
    t.world.upsert(FlightCraft(
      id: 'remote-bo',
      kind: FlightCraftKind.remotePlayer,
      ownerId: 'Bo',
      bodyId: _body.id.value,
      position: Vector3(R + 30000, 40000, 0),
      velocity: Vector3(40, 120, 0),
      label: 'Bo',
    ));
  }

  @override
  void dispose() {
    _ticker.dispose();
    if (_ownsTraffic) _traffic.dispose();
    super.dispose();
  }

  void _resetState() {
    // Nose radially OUT (+X = straight up). Body nose is +Z; the composed
    // rotation maps nose +Z -> +X and the craft's up +Y -> world north +Z, so it
    // sits nose-up with the nav-ball upright. (Verified numerically: +90° about Y
    // then +90° about the new nose axis X.)
    _att = Quaternion.axisAngle(Vector3.unitX, math.pi / 2) *
        Quaternion.axisAngle(Vector3.unitY, math.pi / 2);
    if (widget.descent) {
      // DESCENT: start high, coming in fast with some downrange speed. Aim the
      // retro-burn down to arrest the fall before touchdown.
      final startAlt = _targetAlt * 0.9;
      _pos = Vector3(_body.radius + startAlt, 0, 0);
      _vel = Vector3(-_orbitalSpeed(startAlt) * 0.2, 80, 0); // falling + downrange
      _liftedOff = true; // already airborne -> ground contact judged by speed
    } else {
      // ASCENT: on the pad at rest, throttle idle until the pilot lifts off.
      _pos = Vector3(_body.radius, 0, 0);
      _vel = Vector3.zero;
      _liftedOff = false;
    }
    _fuel = _profile.fuel;
    _throttle = 0;
    _pitchCmd = 0;
    _yawCmd = 0;
    _rollCmd = 0;
    _trail.clear();
    _warp = 1;
    _outcome = _Outcome.flying;
  }

  void _reset() => setState(_resetState);

  double _surfaceG(CelestialBody b) => b.mu / (b.radius * b.radius);
  double get _mass => _dryMass + _fuel;
  double get _altitude => _pos.length - _body.radius;
  double get _speed => _vel.length;
  Vector3 get _nose => _att.rotate(Vector3.unitZ);

  /// Vertical (radial) + horizontal speed components, for the gravity-turn cues.
  double get _vVert => _vel.dot(_pos.normalized);
  double get _vHoriz => math.sqrt(math.max(0, _speed * _speed - _vVert * _vVert));

  /// Liftoff-guaranteed max thrust: a launch vehicle ALWAYS has enough to clear
  /// the pad, so a weak/underbuilt design (or a tiny lander profile) can still
  /// fly the trainer. Floored to a TWR of ~1.4 on the launch body at full
  /// fuelled mass — you still have to fly the gravity turn to actually orbit.
  double get _effectiveMaxThrust {
    final wetMass = _dryMass + _profile.fuel;
    final minForLiftoff = 1.4 * wetMass * _surfaceG(_body);
    return math.max(_maxThrust, minForLiftoff);
  }

  double get _twr =>
      _effectiveMaxThrust * _throttle / (_mass * _surfaceG(_body));

  /// Target parking-orbit altitude (above the air).
  double get _targetAlt {
    final atmo = _body.atmosphere?.atmosphereHeight ?? 0;
    return math.max(atmo + 20000, _body.radius * 0.02);
  }

  double _orbitalSpeed(double alt) => math.sqrt(_body.mu / (_body.radius + alt));

  // --- Orbit shape from the current state (vis-viva + angular momentum). ---
  ({double ap, double pe, double ecc}) get _orbit {
    final r = _pos.length;
    final v2 = _vel.lengthSquared;
    final energy = 0.5 * v2 - _body.mu / r;
    final h = _pos.cross(_vel).length; // specific angular momentum
    if (energy >= 0 || energy.isNaN) {
      return (ap: double.infinity, pe: -_body.radius, ecc: 1.0);
    }
    final a = -_body.mu / (2 * energy); // semi-major axis
    final ecc = math.sqrt(math.max(0, 1 + 2 * energy * h * h / (_body.mu * _body.mu)));
    final apR = a * (1 + ecc), peR = a * (1 - ecc);
    return (ap: apR - _body.radius, pe: peR - _body.radius, ecc: ecc);
  }

  void _onTick(Duration elapsed) {
    var frame = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (_outcome != _Outcome.flying) return;
    frame = frame.clamp(0.0, 0.05);
    // Time warp: run the physics in fixed ≤0.05s sub-steps so warping stays
    // stable (no giant integration jumps). Stop early if the run ends.
    var remaining = frame * _warp;
    while (remaining > 1e-6 && _outcome == _Outcome.flying) {
      final dt = math.min(0.05, remaining);
      remaining -= dt;
      if (_step(dt)) break; // run ended (orbit / destroyed)
    }
    setState(() {});
  }

  /// One physics sub-step. Returns true if the run ENDED this step.
  bool _step(double dt) {
    // 1) Attitude: integrate the commanded body-rates (pitch=X, yaw=Y, roll=Z).
    final omega = Vector3(_pitchCmd, _yawCmd, _rollCmd) * _turnRate;
    if (omega.lengthSquared > 1e-9) {
      final dq = _att.derivative(omega).scaled(dt);
      _att = (_att + dq).normalized;
    }

    // 2) Forces.
    final r = _pos.length;
    final g = _body.mu / (r * r);
    final gravity = _pos.normalized * (-g); // toward the body

    var thr = _throttle;
    if (_fuel <= 0) thr = 0;
    final thrustN = _effectiveMaxThrust * thr;
    final thrust = _nose * (thrustN / _mass); // along the nose

    Vector3 drag = Vector3.zero;
    final atmo = _body.atmosphere;
    if (atmo != null && atmo.hasAtmosphere(_altitude) && _speed > 0.1) {
      final rho = atmo.sampleAt(_altitude).density;
      final dragMag = 0.5 * rho * _speed * _speed * _cd * _dragArea;
      drag = _vel.normalized * (-dragMag / _mass);
    }

    if (thrustN > 0) {
      _fuel = math.max(0, _fuel - thrustN / _ispG0 * dt);
    }

    // 3) Integrate (semi-implicit Euler).
    final accel = gravity + thrust + drag;
    _vel = _vel + accel * dt;
    _pos = _pos + _vel * dt;

    // Track whether we've actually lifted off (clear of the pad), so resting on
    // the surface at launch never counts as a crash.
    if (_altitude > 50) _liftedOff = true;

    // 4) Ground contact. Only two ends exist: ORBIT, or DESTROYED on impact.
    //    Sitting/idling on the pad is NOT a crash — only a real downward impact
    //    after lift-off (or any hard descent into the ground) destroys the craft.
    //    Otherwise the craft just rests on the surface and keeps "flying" so you
    //    can keep throttling up to climb out.
    if (_pos.length <= _body.radius) {
      _pos = _pos.normalized * _body.radius;
      final out = _pos.normalized;
      final vr = _vel.dot(out); // <0 = moving into the ground
      final touchdownSpeed = _speed; // total speed at contact
      if (widget.descent) {
        _vel = Vector3.zero;
        // DESCENT: too fast = smashed regardless of where.
        const safe = 8.0; // m/s
        if (touchdownSpeed > safe) {
          _outcome = _Outcome.destroyed;
          return true;
        }
        // Gentle touchdown — resolve WHERE it came down across the landing strip.
        // Downrange angle maps to the same 0..1 the pads/city are laid out on.
        final ang = math.atan2(_pos.y, _pos.x).abs();
        final f = (ang / 0.6).clamp(0.0, 1.0); // 0 = origin pad .. 1 = far edge
        final padCount = widget.pads.clamp(1, 12);
        // Pads sit at the centres of [padCount] even slots across the strip.
        var nearestPad = 0;
        var nearestD = double.infinity;
        for (var i = 0; i < padCount; i++) {
          final padF = (i + 0.5) / padCount;
          final d = (f - padF).abs();
          if (d < nearestD) {
            nearestD = d;
            nearestPad = i;
          }
        }
        // Snap onto a pad if close enough.
        if (nearestD <= 0.5 / padCount) {
          _outcome = _Outcome.landed;
          widget.onLand?.call(nearestPad);
          return true;
        }
        // Missed every pad but still over the CITY footprint (the strip span) ->
        // crash into a building; otherwise an off-site landing on open ground.
        final overCity = f <= 1.0 && widget.onCrashIntoCity != null;
        if (overCity) {
          _outcome = _Outcome.destroyed;
          widget.onCrashIntoCity!.call();
        } else {
          _outcome = _Outcome.landed; // open ground, off-site
          widget.onLand?.call(null);
        }
        return true;
      }
      if (_liftedOff && vr < -2.0) {
        // Ascent flight that fell back and hit the ground -> destroyed.
        _outcome = _Outcome.destroyed;
        return true;
      }
      // Rest on the surface (kill the inward velocity), stay flying.
      if (vr < 0) _vel = _vel - out * vr;
    }

    // 6) Shared airspace: publish our own state, advance the other traffic
    //    (remote players + supply ships) ballistically, then check collisions.
    //    Hitting another craft is fatal — same as a ground impact.
    _traffic.publishLocal(_localCraft());
    _traffic.step(dt, localId: _localId);
    if (_liftedOff && _traffic.collisions(_localCraft()).isNotEmpty) {
      _outcome = _Outcome.destroyed;
      return true;
    }

    // 5) Orbit check (ASCENT only): periapsis clears the atmosphere AND we're up.
    if (!widget.descent) {
      final o = _orbit;
      if (o.pe >= _targetAlt * 0.5 &&
          o.ap >= _targetAlt &&
          _altitude > _targetAlt * 0.5) {
        _outcome = _Outcome.orbit;
        return true;
      }
    }
    return false;
  }

  /// Our craft as a shared-world entity (body-centred state).
  FlightCraft _localCraft() => FlightCraft(
        id: _localId,
        kind: FlightCraftKind.localPlayer,
        ownerId: widget.localPlayerId,
        bodyId: _body.id.value,
        position: _pos,
        velocity: _vel,
        radius: 20,
        label: 'YOU',
      );

  /// Build the nav-ball state from the current attitude + velocity (the same
  /// craft-frame projection the flight sim's NavState uses).
  NavState _navState() {
    final worldUp = _pos.length < 1 ? Vector3.unitZ : _pos.normalized;
    var north = Vector3.unitZ - worldUp * worldUp.dot(Vector3.unitZ);
    if (north.length < 1e-6) {
      north = Vector3.unitX - worldUp * worldUp.dot(Vector3.unitX);
    }
    north = north.normalized;
    final east = north.cross(worldUp).normalized;

    final nose = _att.rotate(Vector3.unitZ);
    final right = _att.rotate(Vector3.unitX);
    final up = _att.rotate(Vector3.unitY);
    Vector3 toCraft(Vector3 d) => Vector3(d.dot(right), d.dot(up), d.dot(nose));

    final pg = _speed > 1 ? toCraft(_vel.normalized) : null;
    final hdg = math.atan2(nose.dot(east), nose.dot(north)) * 180 / math.pi;
    return NavState(
      upInCraft: toCraft(worldUp),
      progradeInCraft: pg,
      northInCraft: toCraft(north),
      eastInCraft: toCraft(east),
      headingDeg: (hdg + 360) % 360,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: widget.descent
          ? (widget.profile == null
              ? 'DESCENT TO SURFACE'
              : 'LANDING · ${widget.profile!.name}')
          : (widget.profile == null
              ? 'ASCENT TO ORBIT'
              : '${widget.profile!.isPlane ? "TAKEOFF" : "ASCENT"} · ${widget.profile!.name}'),
      accentColor: AppTheme.accent2,
      actions: [
        // Time warp: cycle 1x -> 2x -> 4x -> 8x -> 1x.
        TextButton.icon(
          icon: const Icon(Icons.fast_forward, color: AppTheme.accent2, size: 18),
          label: Text('${_warp.toStringAsFixed(0)}x',
              style: AppTheme.mono.copyWith(color: AppTheme.accent2)),
          onPressed: () => setState(() {
            final i = _warps.indexOf(_warp);
            _warp = _warps[(i + 1) % _warps.length];
          }),
        ),
        IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.text),
            tooltip: 'Reset',
            onPressed: _reset),
      ],
      body: Column(
        children: [
          _bodyBar(),
          // The 3D scene fills all remaining space; the control panel is DOCKED
          // to the bottom at its natural height (capped + internally scrollable
          // on short viewports so it never pushes the scene off-screen).
          Expanded(child: _ascentView()),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42),
            child: _instruments(),
          ),
        ],
      ),
    );
  }

  Widget _bodyBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: AppTheme.panel,
        child: Row(children: [
          const Text('Body', style: AppTheme.body),
          const SizedBox(width: 12),
          DropdownButton<CelestialBody>(
            value: _body,
            dropdownColor: AppTheme.panelLight,
            underline: Container(height: 1, color: AppTheme.accent2),
            items: [
              for (final b in _bodies)
                DropdownMenuItem(
                    value: b,
                    child: Text('${b.name}  (g=${_surfaceG(b).toStringAsFixed(1)})',
                        style: AppTheme.body)),
            ],
            onChanged: (b) => setState(() {
              _body = b!;
              _resetState();
            }),
          ),
          const Spacer(),
          Text('TWR ${_twr.toStringAsFixed(1)}',
              style: AppTheme.mono.copyWith(
                  color: _twr >= 1 ? AppTheme.accent2 : AppTheme.danger)),
        ]),
      );

  // --- 3D scene basis at the launch site. Local frame: U = up (radial out at
  //     the pad, world +X), E = east (world +Y), N = north (world +Z = the
  //     out-of-plane / spin axis). Yaw steers the craft toward N/S so the path
  //     genuinely leaves the plane and reads against the compass. ---
  static final Vector3 _localUp = Vector3.unitX; // up / zenith
  static final Vector3 _localEast = Vector3.unitY; // east
  static final Vector3 _localNorth = Vector3.unitZ; // out of the launch plane

  /// A world (body-centred) point in the launch LOCAL frame: (east, north, up)
  /// metres relative to the pad. Up is altitude; east/north are the ground track.
  ({double e, double n, double u}) _local(Vector3 pos) {
    final rel = pos - _localUp * _body.radius; // relative to the pad
    return (e: rel.dot(_localEast), n: rel.dot(_localNorth), u: rel.dot(_localUp));
  }

  /// Project a launch-local (e,n,u) point to the screen with a fixed oblique 3D
  /// camera looking down-range from the south-west and slightly above, so the
  /// ground plane + the climbing trajectory both read with depth. Returns the
  /// screen point + a depth (for ordering) given the view size.
  ({Offset at, double depth}) _project3D(
      double e, double n, double u, double w, double h) {
    // Normalise metres into a unit-ish scene (target orbit alt = ~1 up unit;
    // a comparable downrange span across east/north).
    final span = _targetAlt;
    final ex = e / span, nx = n / span, ux = u / span;
    // Oblique axonometric: camera yaw ~35° + pitch. Screen right mixes east+north
    // (yaw), screen up is altitude minus a little of the ground-depth (pitch).
    const cy = 0.82, sy = 0.57; // cos/sin of yaw
    const cp = 0.62, sp = 0.78; // cos/sin of pitch
    final sx = ex * cy - nx * sy; // screen-x from the ground yaw
    final depth = ex * sy + nx * cy; // into the screen
    final screenY = ux * sp - depth * cp; // altitude up, depth recedes
    // Fit into the viewport (origin lower-centre, scale to height).
    final scale = h * 0.42;
    final px = w * 0.5 + sx * scale;
    final py = h - 46 - screenY * scale;
    return (at: Offset(px, py), depth: depth - ux);
  }

  ({Offset at, double depth}) _project3DPos(Vector3 pos, double w, double h) {
    final l = _local(pos);
    return _project3D(l.e, l.n, l.u, w, h);
  }

  /// PREDICTED forward path (3D ballistic coast — the orbit rail).
  List<Offset> _predictPath(double w, double h) {
    final pts = <Offset>[];
    var p = _pos, v = _vel;
    const steps = 220;
    const dt = 1.5;
    for (var i = 0; i < steps; i++) {
      final r = p.length;
      final g = _body.mu / (r * r);
      v = v + p.normalized * (-g) * dt;
      p = p + v * dt;
      pts.add(_project3DPos(p, w, h).at);
      if (p.length <= _body.radius) break;
      if (p.length - _body.radius > _targetAlt * 1.4) break;
    }
    return pts;
  }

  Widget _ascentView() => LayoutBuilder(builder: (context, c) {
        final h = c.maxHeight, w = c.maxWidth;
        final frac = (_altitude / (_targetAlt * 1.15)).clamp(0.0, 1.0);
        // Record the flown path as 3D body-relative points (breadcrumb).
        if (_outcome == _Outcome.flying &&
            (_trail.isEmpty || (_pos - _trail.last).length > 200)) {
          _trail.add(_pos);
          if (_trail.length > 500) _trail.removeAt(0);
        }
        final predicted = _outcome == _Outcome.flying && _speed > 1
            ? _predictPath(w, h)
            : const <Offset>[];
        // Other craft sharing the airspace -> projected 3D blips.
        final blips = <({Offset at, Color color, String label})>[
          for (final cr in _traffic.trafficNear(_body.id.value,
              exceptId: _localId))
            (
              at: _project3DPos(cr.position, w, h).at,
              color: cr.kind == FlightCraftKind.supply
                  ? const Color(0xFFE0A040)
                  : const Color(0xFF7FD0FF),
              label: cr.label,
            ),
        ];
        return Stack(children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Color.lerp(const Color(0xFF1B2A3A), const Color(0xFF05070C),
                        frac)!,
                    const Color(0xFF02030A),
                  ],
                ),
              ),
            ),
          ),
          // The whole 3D scene: ground grid + N/E/S/W axes, predicted rail, flown
          // trail, traffic blips, and the craft at its 3D attitude.
          Positioned.fill(
            child: CustomPaint(
              painter: _Scene3DPainter(
                project: (p) => _project3DPos(p, w, h).at,
                projectLocal: (e, n, u) => _project3D(e, n, u, w, h).at,
                span: _targetAlt,
                bodyRadius: _body.radius,
                trail: List.of(_trail),
                predicted: predicted,
                blips: blips,
                craftPos: _pos,
                craftNose: _nose,
                throttle: _throttle,
                firing: _throttle > 0 && _fuel > 0 &&
                    _outcome == _Outcome.flying,
                craftColor: _outcome == _Outcome.orbit
                    ? AppTheme.accent2
                    : AppTheme.text,
              ),
            ),
          ),
          // City danger band (descent only).
          if (widget.descent && widget.onCrashIntoCity != null)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 18,
              child: ColoredBox(
                color: Color(0x33B00020),
                child: Center(
                    child: Text('CITY — avoid',
                        style: TextStyle(
                            color: Color(0xAAFF6E6E), fontSize: 10))),
              ),
            ),
          // Launch pads across the bottom (one per launch tower).
          Positioned(
            left: 0,
            right: 0,
            bottom: 22,
            height: 22,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < widget.pads.clamp(1, 12); i++)
                  Icon(Icons.cell_tower,
                      size: 15,
                      color: i == 0 ? AppTheme.accent2 : AppTheme.textDim),
              ],
            ),
          ),
          // Nav-ball, top-right — shared with FLIGHT mode.
          Positioned(
              top: 10,
              right: 10,
              child: NavBall(state: _navState(), size: 116)),
          if (_outcome != _Outcome.flying) Center(child: _outcomeBanner()),
        ]);
      });

  Widget _outcomeBanner() {
    final ok = _outcome == _Outcome.orbit || _outcome == _Outcome.landed;
    final o = _orbit;
    final title = switch (_outcome) {
      _Outcome.orbit => 'ORBIT ACHIEVED',
      _Outcome.landed => 'TOUCHDOWN',
      _Outcome.destroyed => 'CRAFT DESTROYED',
      _ => '',
    };
    final detail = switch (_outcome) {
      _Outcome.orbit =>
        'Ap ${(o.ap / 1000).toStringAsFixed(0)} km · Pe ${(o.pe / 1000).toStringAsFixed(0)} km · '
            '${_speed.toStringAsFixed(0)} m/s. You\'re in orbit.',
      _Outcome.landed =>
        'Safe landing — gentle touchdown on the pad.',
      _Outcome.destroyed => widget.descent
          ? 'Came in too hot — the craft was destroyed on impact. Burn harder to '
              'slow the descent before touchdown.'
          : 'The craft came back down and slammed into the surface. Pitch over to '
              'build horizontal speed before gravity wins.',
      _ => '',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: ok ? AppTheme.accent2 : AppTheme.danger, width: 2),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(ok ? Icons.check_circle : Icons.warning,
            color: ok ? AppTheme.accent2 : AppTheme.danger, size: 40),
        const SizedBox(height: 8),
        Text(title,
            style: AppTheme.title
                .copyWith(color: ok ? AppTheme.accent2 : AppTheme.danger)),
        const SizedBox(height: 4),
        Text(detail, style: AppTheme.dim, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (ok)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accent2,
                  foregroundColor: AppTheme.bg),
              icon: const Icon(Icons.public),
              label: const Text('TO ORBIT'),
              onPressed: () => Navigator.of(context).maybePop(true),
            ),
          if (ok) const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, color: AppTheme.text),
            label: const Text('RETRY', style: TextStyle(color: AppTheme.text)),
            onPressed: _reset,
          ),
        ]),
      ]),
    );
  }

  Widget _instruments() {
    final o = _orbit;
    final apStr = o.ap.isInfinite ? 'escape' : '${(o.ap / 1000).toStringAsFixed(0)} km';
    final peStr = '${(o.pe / 1000).toStringAsFixed(0)} km';
    final orbV = _orbitalSpeed(_altitude);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: AppTheme.panel,
        border: Border(top: BorderSide(color: Color(0xFF223247))),
      ),
      // Scrollable so the gauges + attitude controls never overflow on short
      // viewports (phones / split layouts).
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _gauge('ALT', '${(_altitude / 1000).toStringAsFixed(1)} km', AppTheme.text),
          _gauge('AP', apStr, o.ap >= _targetAlt ? AppTheme.accent2 : AppTheme.warn),
          _gauge('PE', peStr, o.pe >= _targetAlt * 0.5 ? AppTheme.accent2 : AppTheme.warn),
          _gauge('VEL', '${_speed.toStringAsFixed(0)} m/s',
              _speed >= orbV ? AppTheme.accent2 : AppTheme.text),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          _gauge('V/S', '${_vVert >= 0 ? "↑" : "↓"}${_vVert.abs().toStringAsFixed(0)}',
              AppTheme.textDim),
          _gauge('H-SPD', '${_vHoriz.toStringAsFixed(0)} m/s', AppTheme.textDim),
          _gauge('FUEL', '${_fuel.toStringAsFixed(0)} kg',
              _fuel > 200 ? AppTheme.accent : AppTheme.danger),
          _gauge('THR', '${(_throttle * 100).toStringAsFixed(0)}%', AppTheme.warn),
        ]),
        const SizedBox(height: 8),
        // Attitude controls — pitch / yaw / roll body rates + throttle.
        _axisSlider('Pitch', _pitchCmd, (v) => setState(() => _pitchCmd = v)),
        _axisSlider('Yaw', _yawCmd, (v) => setState(() => _yawCmd = v)),
        _axisSlider('Roll', _rollCmd, (v) => setState(() => _rollCmd = v)),
        Row(children: [
          const SizedBox(width: 44, child: Text('Thr', style: AppTheme.body)),
          Text('${(_throttle * 100).toStringAsFixed(0)}%',
              style: AppTheme.mono.copyWith(color: AppTheme.warn)),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                  activeTrackColor: AppTheme.warn, thumbColor: AppTheme.warn),
              child: Slider(
                value: _throttle,
                onChanged: _outcome == _Outcome.flying
                    ? (v) => setState(() => _throttle = v)
                    : null,
              ),
            ),
          ),
        ]),
        Text('Point the nose with pitch/yaw/roll (nav-ball). Lift off straight up, '
            'then pitch toward the horizon to build orbital speed.',
            style: AppTheme.dim),
      ]),
      ),
    );
  }

  /// A centre-detented attitude-rate slider (-1..1): release snaps back to 0 so
  /// it behaves like a self-centring stick.
  Widget _axisSlider(String label, double value, ValueChanged<double> onCh) =>
      Row(children: [
        SizedBox(width: 44, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
                activeTrackColor: AppTheme.accent2,
                thumbColor: AppTheme.accent2,
                trackHeight: 2),
            child: Slider(
              value: value,
              min: -1,
              max: 1,
              onChanged: _outcome == _Outcome.flying ? onCh : null,
              onChangeEnd: (_) => setState(() => onCh(0)), // self-centre
            ),
          ),
        ),
      ]);

  Widget _gauge(String label, String value, Color color) => Expanded(
        child: Column(children: [
          Text(label, style: AppTheme.dim),
          const SizedBox(height: 2),
          Text(value,
              style: AppTheme.mono.copyWith(color: color, fontSize: 14)),
        ]),
      );
}

/// The 3D ascent/descent scene: a ground plane grid with N/E/S/W cardinal axes,
/// the predicted ballistic rail, the flown trail, traffic blips, and the craft
/// drawn as a cone at its real 3D attitude — all projected through the oblique
/// camera the screen supplies. Because yaw steers the craft out of the launch
/// plane, the path genuinely curves across the compass.
class _Scene3DPainter extends CustomPainter {
  final Offset Function(Vector3 worldPos) project;
  final Offset Function(double e, double n, double u) projectLocal;
  final double span; // scene unit (target orbit alt, m)
  final double bodyRadius;
  final List<Vector3> trail;
  final List<Offset> predicted;
  final List<({Offset at, Color color, String label})> blips;
  final Vector3 craftPos;
  final Vector3 craftNose;
  final double throttle;
  final bool firing;
  final Color craftColor;

  const _Scene3DPainter({
    required this.project,
    required this.projectLocal,
    required this.span,
    required this.bodyRadius,
    required this.trail,
    required this.predicted,
    required this.blips,
    required this.craftPos,
    required this.craftNose,
    required this.throttle,
    required this.firing,
    required this.craftColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _drawGround(canvas);
    // Predicted rail (dashed amber).
    if (predicted.length >= 2) {
      final p = Paint()
        ..color = AppTheme.warn.withValues(alpha: 0.6)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      for (var i = 1; i < predicted.length; i++) {
        if (i.isOdd) canvas.drawLine(predicted[i - 1], predicted[i], p);
      }
    }
    // Flown trail (solid, fading).
    if (trail.length >= 2) {
      for (var i = 1; i < trail.length; i++) {
        final t = i / trail.length;
        canvas.drawLine(project(trail[i - 1]), project(trail[i]),
            Paint()
              ..color = AppTheme.accent2.withValues(alpha: 0.15 + 0.5 * t)
              ..strokeWidth = 2
              ..strokeCap = StrokeCap.round);
      }
    }
    // Traffic blips.
    for (final b in blips) {
      if (b.at.dx.isNaN) continue;
      canvas.drawCircle(
          b.at, 9, Paint()..color = b.color.withValues(alpha: 0.25));
      canvas.drawPath(
          Path()
            ..moveTo(b.at.dx, b.at.dy - 6)
            ..lineTo(b.at.dx + 5, b.at.dy)
            ..lineTo(b.at.dx, b.at.dy + 6)
            ..lineTo(b.at.dx - 5, b.at.dy)
            ..close(),
          Paint()..color = b.color);
    }
    _drawCraft(canvas);
  }

  /// Ground plane: a square grid centred on the pad with the four cardinal axes
  /// (N up-range, S, E, W) labelled, so the trajectory reads against compass.
  void _drawAxis(Canvas canvas, double e, double n, String label, Color col) {
    final a = projectLocal(0, 0, 0);
    final b = projectLocal(e, n, 0);
    canvas.drawLine(a, b, Paint()..color = col..strokeWidth = 1.5);
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: TextStyle(
              color: col, fontSize: 13, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, b - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawGround(Canvas canvas) {
    final grid = Paint()
      ..color = const Color(0x223C6E8F)
      ..strokeWidth = 1;
    const n = 4;
    final step = span; // one grid cell = the scene span
    // Grid lines across east/north.
    for (var i = -n; i <= n; i++) {
      canvas.drawLine(projectLocal(i * step, -n * step, 0),
          projectLocal(i * step, n * step, 0), grid);
      canvas.drawLine(projectLocal(-n * step, i * step, 0),
          projectLocal(n * step, i * step, 0), grid);
    }
    // Cardinal axes (north is up-range from the pad, +north).
    _drawAxis(canvas, 0, n * step, 'N', const Color(0xFFFF8080));
    _drawAxis(canvas, 0, -n * step, 'S', const Color(0xFF80B0FF));
    _drawAxis(canvas, n * step, 0, 'E', const Color(0xFF80E0B0));
    _drawAxis(canvas, -n * step, 0, 'W', const Color(0xFFE0C880));
  }

  void _drawCraft(Canvas canvas) {
    // Build a small cone in WORLD space along the craft's nose, projected.
    final apexWorld = craftPos + craftNose.normalized * (span * 0.05);
    final apex = project(apexWorld);
    final base = project(craftPos);
    // Base ring perpendicular to the nose.
    final nose = craftNose.normalized;
    var ref = nose.cross(Vector3.unitZ);
    if (ref.length < 1e-3) ref = nose.cross(Vector3.unitX);
    ref = ref.normalized;
    final ref2 = nose.cross(ref).normalized;
    final r = span * 0.025;
    final rim = <Offset>[
      for (var i = 0; i < 8; i++)
        project(craftPos +
            ref * (r * math.cos(i / 8 * 2 * math.pi)) +
            ref2 * (r * math.sin(i / 8 * 2 * math.pi)))
    ];
    final dark = Color.lerp(craftColor, const Color(0xFF000000), 0.4)!;
    for (var i = 0; i < rim.length; i++) {
      final j = (i + 1) % rim.length;
      canvas.drawPath(
          Path()
            ..moveTo(apex.dx, apex.dy)
            ..lineTo(rim[i].dx, rim[i].dy)
            ..lineTo(rim[j].dx, rim[j].dy)
            ..close(),
          Paint()..color = i.isEven ? craftColor : dark);
    }
    // Engine flame opposite the nose when firing.
    if (firing) {
      final flame = project(craftPos - nose * (span * 0.04 * (0.5 + throttle)));
      canvas.drawLine(
          base,
          flame,
          Paint()
            ..color = const Color(0xCCFF8C42)
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_Scene3DPainter old) => true;
}
