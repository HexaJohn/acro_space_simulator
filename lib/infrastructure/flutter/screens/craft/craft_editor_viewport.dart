// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;

import '../../../../adapters/presenters/craft_editor_camera.dart';
import '../../../../adapters/presenters/craft_editor_pick.dart';
import '../../../../domain/craft/attach_solver.dart';
import '../../../../domain/craft/attach_targets.dart';
import '../../../../domain/craft/craft_balance.dart';
import '../../../../domain/parts/part_def.dart';
import '../../../../domain/shared/quaternion.dart';
import '../../../../domain/shared/vector3.dart';
import '../../../flutter_scene/craft/craft_editor_nodes.dart';
import '../../../flutter_scene/part_bake_cache.dart';
import '../../../flutter_scene/scene_camera_adapter.dart';
import '../app_theme.dart';
import 'craft_editor_controller.dart';
import 'craft_editor_painter.dart';
import 'craft_editor_state.dart';

/// The craft editor's 3D view: a turntable over the craft, the whole input map,
/// and the 2D overlay that names what a click is about to do.
///
/// ## The widget nesting is load-bearing, not a style choice
///
/// ```
/// LayoutBuilder                       <- the camera's viewport size
/// +- DragTarget<PartDef>              <- catalog row dropped on the view
///    +- Focus                         <- keys; NOT KeyboardListener (see below)
///       +- Listener                   <- raw buttons, wheel, finger count
///          +- MouseRegion             <- hover and cursor
///             +- RawGestureDetector   <- button-filtered tap/scale/long-press
///                +- Stack
///                   |- Transform.flip(flipX) -> fs.SceneView
///                   +- IgnorePointer -> CustomPaint(CraftEditorPainter)
/// ```
///
/// Three properties of that tree are correctness rules:
///
///  1. **`Transform.flip` wraps the `SceneView` and nothing else.** The domain
///     camera's basis and flutter_scene's `lookAt` differ by exactly one negated
///     horizontal axis, so the raw render is a mirror image and the flip
///     cancels it. That makes the flipped image literally
///     `PerspectiveCamera.projectPx`, which is why
///     [CraftEditorCamera.project] carries no mirror term at all.
///  2. **Every gesture widget is an ANCESTOR of the flip.** A recogniser nested
///     inside it reports a mirrored `localPosition`, and because a rocket is
///     symmetric about its axis the result LOOKS almost right: a bare stack and
///     a four-way RCS ring are both invisible under a mirrored x. It shows up
///     the day someone places one asymmetric part.
///  3. **The overlay is a SIBLING of the flip**, inside `IgnorePointer`. Nested
///     under it, every label would be drawn backwards.
///
/// [Focus] rather than `KeyboardListener`: the latter reports every key as
/// ignored, which on macOS walks the AppKit responder chain and rings the alert
/// sound once per key repeat. `Listener.onPointerDown` reclaims focus so a click
/// on the view takes the keyboard back from the catalog's chips.
///
/// ## What lives here and what lives on the controller
///
/// Camera pose, hover and the pick cycle are LOCAL state. They change on every
/// pointer move, and a `ChangeNotifier` notification rebuilds every listening
/// pane — an orbit would rebuild the catalog list. The rule the editor follows
/// is that state which survives an undo lives on the controller and state that
/// dies with the frame does not.
class CraftEditorViewport extends StatefulWidget {
  const CraftEditorViewport({
    super.key,
    required this.controller,
    this.onLongPressPart,
    this.onSave,
    this.onOpen,
    this.background = AppTheme.bg,
    this.prewarmModels = true,
  });

  final CraftEditorController controller;

  /// A long press landed on a placed part — the touch context sheet (Roll,
  /// Stage, Symmetry, Detach, Delete). Owned by the screen, because a modal
  /// sheet is a route and the viewport must not push routes.
  final void Function(String instanceId, Offset globalPosition)? onLongPressPart;

  /// `Ctrl/Cmd+S` and `Ctrl/Cmd+O`. The keys are claimed ONLY when a handler is
  /// supplied: save and open need a slot picker, which is the screen's, and a
  /// viewport that swallowed the chord without one would make the system
  /// shortcut disappear for nothing.
  final VoidCallback? onSave;
  final VoidCallback? onOpen;

  /// What shows through before the renderer is ready, and on any platform where
  /// it never will be. The overlay stays fully live over it — the editor is
  /// usable with no 3D at all.
  final Color background;

  /// Start loading the catalog's part bakes as soon as the view exists.
  ///
  /// The editor draws seven part assets rather than the flight view's two
  /// whole-craft ones, and paying that parse at the moment the first ghost
  /// appears is a multi-second stall. Loading is serialised and per-asset
  /// failure-tolerant, so this can only ever make the first placement faster.
  ///
  /// Switchable because a headless widget test has no asset bundle worth
  /// warming and no reason to spawn parse isolates it will then have to wait on.
  final bool prewarmModels;

  @override
  CraftEditorViewportState createState() => CraftEditorViewportState();
}

/// The viewport's state, public so the screen and the dev harness can drive the
/// camera and read what the pointer resolved to. Same arrangement `ScaffoldState`
/// uses: reach it with a `GlobalKey<CraftEditorViewportState>`.
class CraftEditorViewportState extends State<CraftEditorViewport> {
  /// The base shader bundle. Static and shared with every other scene view in
  /// the app: geometry and material CONSTRUCTION throws before it completes, not
  /// just rendering, so everything is gated on it.
  ///
  /// Wrapped in an `async` function so a synchronous throw from the plugin
  /// surfaces as a rejected future rather than as an exception out of
  /// [initState].
  static final Future<void> _staticInit = _initialiseScene();

  static Future<void> _initialiseScene() => fs.Scene.initializeStaticResources();

  /// Radians of orbit per logical pixel of drag. Matches `simulation_view`'s
  /// rate so the two 3D views feel the same in the hand.
  static const double orbitRadPerPx = 0.005;

  /// Wheel zoom rate per scroll unit — `scatter_lab_screen`'s constant.
  static const double zoomPerScrollUnit = 0.0016;

  /// `[` and `]`, and the touch pinch floor/ceiling.
  static const double keyZoomStep = 1.15;

  /// Roll per `Q`/`E` press, radians. Fifteen degrees divides a quarter turn
  /// evenly, so six presses put a part back where it started.
  static const double rollStep = 15 * math.pi / 180;
  static const double rollStepFine = 5 * math.pi / 180;

  /// A right-button press that travelled less than this is a click, not a pan.
  /// Six pixels is more than the jitter a physical click carries and less than
  /// any deliberate drag.
  static const double rmbClickSlopPx = 6.0;

  /// Repeat-tap window for touch candidate cycling. There is no hover on a
  /// touch screen, so tapping the same spot again is the only way to say "not
  /// that one, the next one".
  static const Duration retapWindow = Duration(milliseconds: 400);
  static const double retapSlopPx = 3.0;

  /// Two candidates closer than this on screen are, for picking purposes, the
  /// same point: the axial view of a node ring, where no ranking can help and
  /// the honest answer is to tell the player to orbit.
  static const double edgeOnPx = 2.0;

  final FocusNode _keyFocus = FocusNode(debugLabel: 'craftEditorViewport');

  fs.Scene? _scene;
  CraftEditorNodes? _nodes;

  /// The last frame [CraftEditorNodes.sync] ran in. Pointer events cause several
  /// builds per vsync and each sync touches GPU resources, so only the first
  /// build in a frame does that work.
  Duration? _lastSyncFrame;

  // ---- camera pose (craft frame, metres/radians) ----
  double _azimuth = 0.9;
  double _elevation = 0.28;
  double _distanceM = 10.0;
  Vector3 _pivot = Vector3.zero;
  Size _viewport = const Size(800, 600);
  CraftEditorCamera? _camera;

  /// The craft has been framed once. Flow 1 frames when the root lands and never
  /// again: a camera that re-frames on every placement is nauseating.
  bool _framed = false;
  int _seenRevision = -1;

  // ---- pointer state ----
  bool _mmbDragging = false;
  Offset _mmbAnchor = Offset.zero;
  bool _rmbDragging = false;
  Offset _rmbAnchor = Offset.zero;
  double _rmbTravelPx = 0;

  int _activePointers = 0;

  /// This gesture had two fingers down at some point, so its taps are pinch
  /// residue and must not place a part.
  ///
  /// Cleared on the FIRST pointer down of a fresh gesture, never on pointer up.
  /// `Listener` handlers run before the gesture arena is swept, so clearing the
  /// taint when the last finger lifts would clear it immediately before the very
  /// tap it exists to veto — and fingers never release simultaneously, so that
  /// is the common case rather than a corner one.
  bool _multiTouch = false;

  double _pinchBaseDistanceM = 10.0;
  Offset _pinchBaseFocal = Offset.zero;
  Vector3 _pinchBasePivot = Vector3.zero;

  // ---- hover / picking ----
  Offset? _cursor;
  TargetPairing? _hoverPairing;
  String? _hoverPartId;
  int _alternatives = 0;
  int _cycle = 0;
  bool _edgeOn = false;
  AttachTarget? _refusedTarget;

  /// What the last pick was resolved against: the held part's def and the node
  /// `W`/`S` chose, which together decide which markers are candidates at all.
  ///
  /// Holding a part and cycling its node are VIEW state and bump no revision,
  /// so a cursor parked on a marker would otherwise keep answering for the part
  /// that was held a moment ago — and preview the new one at its seat.
  (String, String?)? _pickedFor;

  Offset? _lastTapAt;
  DateTime _lastTapTime = DateTime.fromMillisecondsSinceEpoch(0);

  CraftEditorController get controller => widget.controller;

  // ---------------- lifecycle ----------------

  @override
  void initState() {
    super.initState();
    controller.addListener(_onControllerChanged);
    // Warm the PART bakes, not the whole-vessel ones: prewarming through
    // VesselNodes would pull in two complete craft bakes the editor never draws
    // and stall the first open behind about 130 MB it does not need.
    if (widget.prewarmModels) {
      PartBakeCache.prewarm({
        for (final def in controller.catalog.all)
          if (def.modelAsset != null) def.modelAsset!,
      });
    }
    _staticInit.then((_) {
      if (!mounted) return;
      final scene = fs.Scene();
      setState(() {
        _scene = scene;
        _nodes = CraftEditorNodes(scene);
      });
    }).catchError((Object e) {
      // A missing shader bundle is not a broken editor: markers, picking,
      // placement, undo and the whole overlay run without it. Report it once
      // and keep going.
      debugPrint('craft editor scene unavailable: $e');
    });
  }

  @override
  void didUpdateWidget(CraftEditorViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      controller.addListener(_onControllerChanged);
      _framed = false;
    }
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    _nodes?.dispose();
    _nodes = null;
    _scene = null;
    _keyFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (controller.revision != _seenRevision) {
      _seenRevision = controller.revision;
      // A structural change invalidates which candidate index means what: the
      // node the cycle was pointing at may not exist any more.
      _cycle = 0;
      if (!_framed && !controller.design.isEmpty) {
        _framed = true;
        _applyPose(CraftEditorCamera.framing(controller.design, _viewport));
      }
      _refreshHover();
    } else if (_heldSignature != _pickedFor) {
      // The craft has not moved but the question has: a different part is on
      // the cursor, or `W`/`S` chose a different node of it, and the marker
      // under the pointer may have gone from legal to refused or back.
      _refreshHover();
    }
    setState(() {});
  }

  /// The part-and-node pair [_pickedFor] records. Null when nothing is held.
  (String, String?)? get _heldSignature {
    final held = controller.held;
    return held == null ? null : (held.def.id, held.childNodeName);
  }

  // ---------------- public surface ----------------

  /// The camera this frame's overlay and render both use.
  CraftEditorCamera get camera => _camera ??= CraftEditorCamera(
        azimuth: _azimuth,
        elevation: _elevation,
        distanceM: _distanceM,
        pivot: _pivot,
        viewport: _viewport,
      );

  /// The target a click would commit to, or null.
  AttachTarget? get hoveredTarget => _hoverPairing?.target;

  /// The pairing a click would commit, or null. Includes which of the held
  /// part's own nodes seats.
  TargetPairing? get hoveredPairing => _hoverPairing;

  /// The part a click would select when nothing is held, or null.
  String? get hoveredPartId => _hoverPartId;

  /// The open node under the cursor that the held part CANNOT mate to, or null.
  ///
  /// A click here commits nothing, and that is exactly why it is resolved: an
  /// aim at an incompatible marker that drew nothing at all would read as a
  /// broken preview rather than as the refusal it is. See [craftGhostPlan].
  AttachTarget? get refusedTarget => _refusedTarget;

  /// The translucent previews the scene is showing this frame.
  ///
  /// Readable without an Impeller context on purpose. The ghosts otherwise
  /// exist only inside the flutter_scene graph — the one part of this view a
  /// headless test cannot see, and therefore the one part where a preview that
  /// silently draws nothing goes unnoticed.
  List<CraftGhost> get ghosts => _ghostPlan().ghosts;

  /// How many candidates were in range at the last pick.
  int get alternatives => _alternatives;

  /// Which of them is chosen. Advanced by `Tab`, `Alt` and a touch repeat-tap.
  int get pickCycle => _cycle;

  /// The top candidates are within [edgeOnPx] of one another on the same ring.
  bool get edgeOn => _edgeOn;

  /// Whether the flutter_scene view is live. False headless, and false on any
  /// platform where the shader bundle failed to load.
  bool get sceneReady => _nodes != null;

  /// `F`: fit the whole craft in frame.
  void frameCraft() {
    setState(() {
      _framed = true;
      _applyPose(CraftEditorCamera.framing(controller.design, _viewport));
    });
  }

  /// Set the turntable directly — the dev harness and the flow tests, which
  /// need a camera they can compute pixel positions against.
  void setPose({
    double? azimuth,
    double? elevation,
    double? distanceM,
    Vector3? pivot,
  }) {
    setState(() {
      _azimuth = azimuth ?? _azimuth;
      _elevation = elevation ?? _elevation;
      _distanceM = (distanceM ?? _distanceM).clamp(
          CraftEditorCamera.minDistanceM, CraftEditorCamera.maxDistanceM);
      _pivot = pivot ?? _pivot;
      _framed = true;
      _camera = null;
    });
  }

  void _applyPose(CraftEditorCamera pose) {
    _azimuth = pose.azimuth;
    _elevation = pose.elevation;
    _distanceM = pose.distanceM;
    _pivot = pose.pivot;
    _camera = null;
  }

  // ---------------- camera input ----------------

  /// Moving the camera re-resolves what is under the cursor in the SAME
  /// [setState], because the pointer has not moved but the world under it has:
  /// leaving the old hover in place would name a node the click no longer
  /// commits, which is precisely the promise the commitment display makes.
  void _orbitBy(Offset delta) {
    setState(() {
      _azimuth += delta.dx * orbitRadPerPx;
      _elevation = (_elevation + delta.dy * orbitRadPerPx).clamp(
          -CraftEditorCamera.maxElevationRad, CraftEditorCamera.maxElevationRad);
      _camera = null;
      _refreshHover();
    });
  }

  void _panBy(Offset delta) {
    setState(() {
      _applyPose(camera.panned(delta));
      _refreshHover();
    });
  }

  void _zoomBy(double factor) {
    setState(() {
      _distanceM = (_distanceM * factor).clamp(
          CraftEditorCamera.minDistanceM, CraftEditorCamera.maxDistanceM);
      _camera = null;
      _refreshHover();
    });
  }

  // ---------------- picking ----------------

  /// Pairings the held part can actually use, narrowed to the node `W`/`S`
  /// chose when one has been chosen.
  List<TargetPairing> _heldPairings(HeldPart held) {
    final all = controller.pairings;
    final node = held.childNodeName;
    if (node == null) return all;
    final narrowed = [for (final p in all) if (p.childNodeName == node) p];
    // A held part whose chosen node fits nothing here would otherwise light up
    // no markers at all and read as a broken editor; fall back to every node.
    return narrowed.isEmpty ? all : narrowed;
  }

  /// Resolve what is under [local] and remember it.
  ///
  /// THE SINGLE PICK PATH. Hover and tap both come through here, so the target
  /// the overlay names before the click is by construction the target the click
  /// commits: the function is pure in `(camera, targets, cursor, cycle)`, and a
  /// mouse that has not moved between the hover and the tap yields the same
  /// answer twice — including the same refusal.
  void _pickAt(Offset local, {required bool touch}) {
    _cursor = local;
    _pickedFor = _heldSignature;
    final held = controller.held;
    if (held == null) {
      _hoverPairing = null;
      _alternatives = 0;
      _edgeOn = false;
      _refusedTarget = null;
      _hoverPartId =
          CraftEditorPick.pickPart(camera, controller.design, local);
      return;
    }
    _hoverPartId = null;
    final pairings = _heldPairings(held);
    final picked = CraftEditorPick.pickTarget<TargetPairing>(
      camera,
      pairings,
      local,
      markerOf: (tp) => (
        position: tp.target.positionInCraft,
        direction: tp.target.directionInCraft,
        size: tp.target.size,
      ),
      // One MARKER is one candidate. A pairing carries the held part's own
      // node as well as the target, and a surface ring mated against a surface
      // ring offers one pairing per child node on the SAME chevron — four
      // pairings the player sees as one place to click. Counting those
      // separately would inflate the cycle hint and spend most Tab presses
      // changing the child node, which is what W/S is for.
      identityOf: (tp) => (tp.target.ownerInstanceId, tp.target.nodeName),
      touch: touch,
      cycle: _cycle,
    );
    _hoverPairing = picked?.pairing;
    _alternatives = picked?.alternatives ?? 0;
    _edgeOn = _isEdgeOn(picked?.pairing.target, pairings);
    // Only when nothing legal answered: a legal aim is never also a refusal,
    // and asking twice per pointer move for an answer that cannot be used
    // would double the cost of the common case.
    _refusedTarget =
        _hoverPairing == null ? _refusedAim(local, touch: touch) : null;
  }

  /// The open node under [local] that NO node of the held part can mate to, or
  /// null when the aim is simply nowhere.
  ///
  /// Ranked by the same [CraftEditorPick.pickTarget] the legal aim uses, so a
  /// refusal is offered under exactly the pixels a mate would have been. The
  /// candidate set is every open node that appears in no pairing at all —
  /// widened from `controller.pairings` rather than from the `W`/`S`-narrowed
  /// list, because a node that fits a DIFFERENT one of the held part's nodes is
  /// a node the player can still reach by cycling, and calling it refused would
  /// be wrong.
  AttachTarget? _refusedAim(Offset local, {required bool touch}) {
    final legal = <(String, String)>{
      for (final p in controller.pairings)
        (p.target.ownerInstanceId, p.target.nodeName),
    };
    final refused = [
      for (final t in controller.openTargets)
        if (!legal.contains((t.ownerInstanceId, t.nodeName))) t,
    ];
    if (refused.isEmpty) return null;
    return CraftEditorPick.pickTarget<AttachTarget>(
      camera,
      refused,
      local,
      markerOf: (t) => (
        position: t.positionInCraft,
        direction: t.directionInCraft,
        size: t.size,
      ),
      identityOf: (t) => (t.ownerInstanceId, t.nodeName),
      touch: touch,
    )?.pairing;
  }

  /// Does the chosen target have a RING SIBLING projecting on top of it?
  ///
  /// This is the residual projection picking cannot solve: seen down the stack
  /// axis, `quad-1` and `quad-3` land on the same pixel and every tie-break in
  /// `CraftEditorPick` is a coin toss. Restricted to ring peers on the same
  /// owner on purpose — two unrelated nodes overlapping is ordinary occlusion,
  /// which the facing test and the cycle already handle.
  bool _isEdgeOn(AttachTarget? chosen, List<TargetPairing> pairings) {
    if (chosen == null || _alternatives < 2) return false;
    final ring = controller.ringAt(chosen);
    if (ring == null) return false;
    final at = camera.project(chosen.positionInCraft);
    if (at == null) return false;
    for (final p in pairings) {
      final t = p.target;
      if (t.ownerInstanceId != chosen.ownerInstanceId) continue;
      if (t.nodeName == chosen.nodeName) continue;
      if (!ring.nodeNames.contains(t.nodeName)) continue;
      final other = camera.project(t.positionInCraft);
      if (other != null && (other - at).distance <= edgeOnPx) return true;
    }
    return false;
  }

  void _refreshHover() {
    final at = _cursor;
    if (at == null) return;
    _pickAt(at, touch: false);
  }

  void _clearHover() {
    setState(() {
      _cursor = null;
      _hoverPairing = null;
      _hoverPartId = null;
      _alternatives = 0;
      _edgeOn = false;
      _refusedTarget = null;
    });
  }

  /// Advance to the next candidate under the cursor: `Tab`, `Alt`, repeat-tap.
  ///
  /// False when there was nothing to advance through, which is what lets `Tab`
  /// stay a traversal key everywhere it is not a cycle key.
  bool _cycleCandidates() {
    if (_alternatives < 2) return false;
    setState(() {
      _cycle = (_cycle + 1) % _alternatives;
      _refreshHover();
    });
    return true;
  }

  // ---------------- committing ----------------

  void _onTap(Offset local, PointerDeviceKind kind) {
    // A tap that was part of a pinch must never place: the second finger of a
    // zoom lifts first and the first finger's release is a perfectly ordinary
    // tap as far as the arena is concerned.
    if (_multiTouch) return;
    final touch = kind != PointerDeviceKind.mouse;

    if (touch) {
      final last = _lastTapAt;
      final now = DateTime.now();
      final repeat = last != null &&
          (last - local).distance <= retapSlopPx &&
          now.difference(_lastTapTime) <= retapWindow;
      _lastTapAt = local;
      _lastTapTime = now;
      if (repeat && _alternatives > 1) {
        _cycle = (_cycle + 1) % _alternatives;
      }
    }

    setState(() => _pickAt(local, touch: touch));

    final held = controller.held;
    if (held == null) {
      controller.select(_hoverPartId);
      return;
    }
    if (controller.design.isEmpty) {
      // Flow 1: the first part goes on the pad at the craft origin, so there is
      // nothing to aim at and any click in the view places it.
      controller.placeRoot();
      return;
    }
    final pairing = _hoverPairing;
    // No target under the cursor keeps the held part. Dropping it here would
    // punish a near miss by making the player pick the row again.
    if (pairing != null) controller.attachAt(pairing);
  }

  // ---------------- keyboard ----------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final shift = keys.isShiftPressed;
    final command = keys.isControlPressed || keys.isMetaPressed;

    if (event is KeyUpEvent) {
      // Close the coalescing run a held Q/E opened, so two separate presses are
      // two undo steps while one held press stays one.
      if (event.logicalKey == LogicalKeyboardKey.keyQ ||
          event.logicalKey == LogicalKeyboardKey.keyE) {
        controller.endGesture();
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (command) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (shift) {
          controller.redo();
        } else {
          controller.undo();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyY) {
        controller.redo();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyS && widget.onSave != null) {
        widget.onSave!();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyO && widget.onOpen != null) {
        widget.onOpen!();
        return KeyEventResult.handled;
      }
      // Every other chord belongs to the platform. Claiming them would break
      // copy, quit and the window manager for no gain.
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.keyQ || key == LogicalKeyboardKey.keyE) {
      final step = shift ? rollStepFine : rollStep;
      controller.roll(key == LogicalKeyboardKey.keyQ ? -step : step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyW) {
      controller.cycleHeldNode(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      controller.cycleHeldNode(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit1) {
      controller.setSymmetryCount(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit2) {
      controller.setSymmetryCount(2);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit4) {
      controller.setSymmetryCount(4);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      controller.setMirror(!controller.symmetry.mirror);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      // Claimed ONLY when there is a stack to walk. This [Focus] autofocuses and
      // sits below the app's [Shortcuts], so reporting `handled` for a Tab that
      // did nothing stops the traversal walk dead and puts the toolbar, the
      // catalog rows and the NODES list — the keyboard route through the whole
      // editor — out of reach.
      return _cycleCandidates()
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      controller.deleteSelection(wholeGroup: !shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      frameCraft();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyG) {
      controller.setShowNodes(!controller.showNodes);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      controller.setShowBalance(!controller.showBalance);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      // Held part first, then the selection: Esc always undoes the most recent
      // commitment the player made, one press at a time.
      if (controller.held != null) {
        controller.clearHeld();
      } else {
        controller.select(null);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketLeft) {
      _zoomBy(keyZoomStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketRight) {
      _zoomBy(1 / keyZoomStep);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------- ghosts ----------------

  ({List<CraftGhost> ghosts, List<AttachTarget> seats}) _ghostPlan() =>
      craftGhostPlan(controller, _hoverPairing, refusedTarget: _refusedTarget);


  // ---------------- overlay assembly ----------------

  CraftEditorOverlay _overlay(CraftEditorCamera cam, List<AttachTarget> seats) {
    final design = controller.design;
    final held = controller.held;
    final targets = controller.showNodes ? controller.openTargets : const <AttachTarget>[];

    final compatible = <(String, String)>{};
    if (held != null) {
      for (final p in _heldPairings(held)) {
        compatible.add((p.target.ownerInstanceId, p.target.nodeName));
      }
    }

    Vector3? com;
    Vector3? thrustOrigin;
    Vector3? thrustAxis;
    double? offAxisDeg;
    if (controller.showBalance && !design.isEmpty) {
      com = CraftBalance.centreOfMass(design);
      final t = CraftBalance.thrust(design);
      if (t != null) {
        thrustOrigin = t.origin;
        thrustAxis = t.direction;
        // The exhaust should point directly away from the centre of mass; the
        // angle between the two is exactly the lever arm that torques the craft
        // when the engine lights.
        final toCom = com - t.origin;
        if (toCom.length > 1e-6) {
          final cos = (-t.direction).dot(toCom.normalized).clamp(-1.0, 1.0);
          offAxisDeg = math.acos(cos) * 180 / math.pi;
        }
      }
    }

    final hud = <String>[];
    if (held != null) {
      final node = held.childNodeName;
      hud.add('Placing: ${held.def.name}'
          '${node == null ? '' : ' > $node'} - Esc to stop');
    }
    // The refusal in words as well as in red. The ghost lives in the scene
    // graph, and the editor is expected to stay usable with no renderer at all
    // — on a machine where the shader bundle never loads, this line is the
    // whole affordance.
    final refused = _refusedTarget;
    if (held != null && refused != null) {
      final owner = design.partById(refused.ownerInstanceId);
      hud.add('${owner?.def.name ?? refused.ownerInstanceId} > '
          '${refused.nodeName} is a ${refused.kind.name} seat of '
          '${refused.size.toStringAsFixed(2)} m - it will not take '
          '${held.def.name}');
    }
    if (!controller.symmetry.isSingle) {
      hud.add(controller.symmetry.mirror
          ? 'Symmetry: mirror'
          : 'Symmetry: x${controller.symmetry.count}');
    }
    if (controller.hasLooseParts) {
      hud.add('Craft is in ${controller.looseParts.length + 1} pieces');
    }

    final selectedId = controller.selectedId;
    final selected = selectedId == null ? null : design.partById(selectedId);
    final group = controller.selection;

    return CraftEditorOverlay(
      camera: cam,
      design: design,
      targets: targets,
      compatible: compatible,
      hovered: _hoverPairing?.target,
      hoveredPartId: _hoverPartId,
      seats: seats,
      cursor: _cursor,
      selection: group,
      selectionLabel: selected == null
          ? null
          : '${selected.def.name} - S${selected.stage}'
              '${group.length > 1 ? ' - x${group.length}' : ''}',
      looseIds: {for (final p in controller.looseParts) p.instanceId},
      centreOfMass: com,
      thrustOrigin: thrustOrigin,
      thrustAxis: thrustAxis,
      thrustOffAxisDeg: offAxisDeg,
      showNodes: controller.showNodes,
      showBalance: controller.showBalance,
      showStages: controller.tool == EditorTool.stage,
      rootGhost: held != null && design.isEmpty,
      alternatives: _alternatives,
      cycle: _cycle,
      edgeOn: _edgeOn,
      hud: hud,
      blocked: controller.blocked,
    );
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size != _viewport && size.width > 0 && size.height > 0) {
        _viewport = size;
        _camera = null;
      }
      final cam = camera;
      final plan = _ghostPlan();
      _syncScene(cam, plan.ghosts);

      return DragTarget<PartDef>(
        // Dragging a catalog row onto the view is a desktop convenience only.
        // The drop runs the SAME pick and the SAME commit a tap does, so it can
        // never place somewhere a tap would not.
        //
        // `details.offset` is `globalPosition - dragStartPoint`, so this is the
        // cursor's own position ONLY because the source anchors its drag to the
        // pointer (`CraftCatalogPane`, `pointerDragAnchorStrategy`). A source
        // that anchors to its child instead hands over a point up to a pane's
        // width away, and the drop then aims at whatever is there — usually
        // nothing, silently.
        onAcceptWithDetails: (details) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          controller.hold(details.data);
          _onTap(box.globalToLocal(details.offset), PointerDeviceKind.mouse);
        },
        builder: (context, _, _) => Focus(
          focusNode: _keyFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            onPointerSignal: _onPointerSignal,
            onPointerHover: _onPointerHover,
            child: MouseRegion(
              onExit: (_) => _clearHover(),
              cursor: controller.held != null
                  ? SystemMouseCursors.precise
                  : SystemMouseCursors.basic,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: _gestures(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: widget.background),
                    // CHIRALITY: this flip, and NOTHING else, is what makes the
                    // rendered image agree with `CraftEditorCamera.project`.
                    // Nothing that reads a pointer position may live inside it.
                    if (_scene != null)
                      Transform.flip(
                        flipX: true,
                        // The adapter is named HERE, not in the presenter: the
                        // camera stays loadable with no renderer linked, and
                        // `toSceneCamera` is still the only thing that builds
                        // the eye/target/up the chirality contract is pinned on.
                        child: fs.SceneView(_scene!,
                            camera: cam.sceneCameraVia(toSceneCamera)),
                      ),
                    IgnorePointer(
                      child: CustomPaint(
                        painter:
                            CraftEditorPainter(_overlay(cam, plan.seats)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  void _syncScene(CraftEditorCamera cam, List<CraftGhost> ghosts) {
    final nodes = _nodes;
    if (nodes == null) return;
    final frame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (_lastSyncFrame == frame) return;
    _lastSyncFrame = frame;
    nodes.sync(
      controller.design,
      pivot: cam.pivot,
      azimuth: cam.azimuth,
      ghosts: ghosts,
      selection: controller.selection,
    );
  }

  // ---------------- gesture wiring ----------------

  /// `RawGestureDetector`, NOT `GestureDetector`.
  ///
  /// The stock tap and scale recognisers accept EVERY mouse button, so a middle
  /// drag orbits twice — once here and once in the [Listener] — and a right
  /// press orbits on the few pixels of jitter every physical click carries.
  /// This codebase has already shipped that bug once and it is guarded by
  /// `camera_mouse_button_test.dart`. Routing the buttons inside each handler
  /// would work too, but it requires every handler to remember; filtering at
  /// construction makes it structural, and in this editor the primary button
  /// does destructive work.
  ///
  /// So: the primary button and touch own tap, scale and long press. The middle
  /// and right buttons are the [Listener]'s alone.
  Map<Type, GestureRecognizerFactory> _gestures() => {
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
          () => TapGestureRecognizer(
              allowedButtonsFilter: (buttons) => buttons == kPrimaryButton),
          (r) => r..onTapUp = (d) => _onTap(d.localPosition, d.kind),
        ),
        ScaleGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
          () => ScaleGestureRecognizer(
              allowedButtonsFilter: (buttons) => buttons == kPrimaryButton),
          (r) => r
            ..onStart = (d) {
              _pinchBaseDistanceM = _distanceM;
              _pinchBaseFocal = d.localFocalPoint;
              _pinchBasePivot = _pivot;
            }
            ..onUpdate = (d) {
              if (d.pointerCount >= 2) {
                // Two fingers pinch AND pan together, the `city_map_view`
                // behaviour: the craft slides under the fingers instead of
                // fighting them. Both are re-derived from the values captured
                // at the gesture start, because `scale` and the focal point are
                // cumulative from there — integrating per-frame deltas would
                // drift over a long pinch.
                setState(() {
                  _distanceM = (_pinchBaseDistanceM / d.scale.clamp(0.2, 5.0))
                      .clamp(CraftEditorCamera.minDistanceM,
                          CraftEditorCamera.maxDistanceM);
                  _pivot = _pinchBasePivot;
                  _camera = null;
                  _applyPose(camera.panned(d.localFocalPoint - _pinchBaseFocal));
                });
                return;
              }
              _orbitBy(d.focalPointDelta);
            },
        ),
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(
              allowedButtonsFilter: (buttons) => buttons == kPrimaryButton),
          (r) => r..onLongPressStart = _onLongPress,
        ),
      };

  void _onLongPress(LongPressStartDetails d) {
    final handler = widget.onLongPressPart;
    if (handler == null || _multiTouch) return;
    final id = CraftEditorPick.pickPart(camera, controller.design, d.localPosition);
    if (id != null) handler(id, d.globalPosition);
  }

  // ---------------- raw pointer wiring ----------------

  void _onPointerDown(PointerDownEvent e) {
    // Any click on the view reclaims the keyboard from the catalog's chips.
    _keyFocus.requestFocus();
    _activePointers++;
    if (_activePointers == 1) {
      // A fresh gesture starts clean. See [_multiTouch] for why the taint is
      // cleared here and not on pointer up.
      _multiTouch = false;
    } else {
      _multiTouch = true;
    }
    if (e.buttons & kMiddleMouseButton != 0) {
      _mmbDragging = true;
      _mmbAnchor = e.localPosition;
    }
    if (e.buttons & kSecondaryMouseButton != 0) {
      _rmbDragging = true;
      _rmbAnchor = e.localPosition;
      _rmbTravelPx = 0;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_mmbDragging) {
      // A pointer-up missed off-window leaves the drag armed, and the next
      // unrelated drag then applies its delta from a stale anchor and the
      // camera leaps. Re-check the button on EVERY move rather than trusting
      // that the up event arrived.
      if (e.buttons & kMiddleMouseButton == 0) {
        _mmbDragging = false;
      } else {
        final d = e.localPosition - _mmbAnchor;
        _mmbAnchor = e.localPosition;
        _orbitBy(d);
        return;
      }
    }
    if (_rmbDragging) {
      if (e.buttons & kSecondaryMouseButton == 0) {
        _rmbDragging = false;
        return;
      }
      final d = e.localPosition - _rmbAnchor;
      _rmbAnchor = e.localPosition;
      _rmbTravelPx += d.distance;
      _panBy(d);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _activePointers = math.max(0, _activePointers - 1);
    if (e.buttons & kMiddleMouseButton == 0) _mmbDragging = false;
    if (_rmbDragging && e.buttons & kSecondaryMouseButton == 0) {
      _rmbDragging = false;
      if (_rmbTravelPx < rmbClickSlopPx) {
        // A right CLICK, not a pan: drop the held part, or clear the selection
        // when nothing is held. One button, one "never mind".
        if (controller.held != null) {
          controller.clearHeld();
        } else {
          controller.select(null);
        }
      }
    }
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _activePointers = math.max(0, _activePointers - 1);
    _mmbDragging = false;
    _rmbDragging = false;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    _zoomBy(1 + e.scrollDelta.dy * zoomPerScrollUnit);
  }

  void _onPointerHover(PointerHoverEvent e) {
    // Only a real mouse hovers. A stylus or a stray touch-hover has no cursor
    // when the finger is up, and treating one as a hover leaves a phantom
    // commitment on screen.
    if (e.kind != PointerDeviceKind.mouse) return;
    setState(() => _pickAt(e.localPosition, touch: false));
  }
}

/// The preview for the current aim: one ghost per seat the click would fill,
/// and the seat markers the overlay draws the snap ring on.
///
/// [hoverPairing] is what the pick resolved the cursor to, or null when the
/// cursor is over nothing the held part can use. With an EMPTY design there is
/// no seat to aim at and the single ghost stands at the craft origin, which is
/// where [CraftEditorController.placeRoot] puts the root.
///
/// Every pose comes from [AttachSolver.solveMate], the same solve
/// `CraftDesign.attachPart` runs on commit, and the seat list comes from
/// [CraftEditorController.seatsFor], the same list the commit iterates. The
/// ghost therefore cannot lie about where the parts land, and there is no pop
/// on drop.
///
/// ## Why the seats of a legal aim are all legal
///
/// The aimed seat came from [CraftEditorController.pairings], which filters, so
/// it is a mate the domain has agreed to. Its siblings come from `seatsFor`,
/// which expands through `AttachTargets.ringsOf` — and a ring is detected over
/// SURFACE nodes only. So every sibling is a surface node mated against the
/// same surface child node: kinds agree, `sizesCompatible` is unconditionally
/// true off the stack, and surface nodes are never occupied. There is nothing
/// left for a per-seat re-check to catch, and one written here would be a
/// branch that can never run.
///
/// ## Where a refused ghost comes from instead
///
/// [refusedTarget] is an open node the pick resolved to that appears in NO
/// pairing — an aim the commit will ignore. It is previewed as a single ghost
/// with `valid: false` at the pose the mate would have produced, because an aim
/// that draws nothing at all reads as a broken preview, where a red part
/// standing in the seat reads as the refusal it is.
///
/// Free of the widget so it can be exercised without an Impeller context: the
/// ghosts otherwise exist only inside the flutter_scene graph.
({List<CraftGhost> ghosts, List<AttachTarget> seats}) craftGhostPlan(
  CraftEditorController controller,
  TargetPairing? hoverPairing, {
  AttachTarget? refusedTarget,
}) {
  final held = controller.held;
  if (held == null) return (ghosts: const [], seats: const []);
  final design = controller.design;

  if (design.isEmpty) {
    return (
      ghosts: [
        CraftGhost(
          def: held.def,
          position: Vector3.zero,
          rotation: Quaternion.identity,
        ),
      ],
      seats: const [],
    );
  }

  if (hoverPairing == null) {
    return (
      ghosts: refusedTarget == null
          ? const <CraftGhost>[]
          : _refusedGhost(controller, held, refusedTarget),
      seats: const [],
    );
  }
  final owner = design.partById(hoverPairing.target.ownerInstanceId);
  if (owner == null) return (ghosts: const [], seats: const []);
  final childNode = held.def.node(hoverPairing.childNodeName);
  if (childNode == null) return (ghosts: const [], seats: const []);

  final ghosts = <CraftGhost>[];
  final seats = <AttachTarget>[];
  for (final nodeName in controller.seatsFor(hoverPairing.target)) {
    final inBody = owner.nodeInBody(nodeName);
    if (inBody == null) continue;
    seats.add(AttachTarget(
      ownerInstanceId: owner.instanceId,
      nodeName: inBody.name,
      positionInCraft: inBody.position,
      directionInCraft: inBody.direction.normalized,
      size: inBody.size,
      kind: inBody.kind,
    ));
    // solveMate throws on a degenerate normal: a modelling fault with no pose
    // to draw at all, as opposed to a refusal, which has one.
    if (inBody.direction.lengthSquared == 0 ||
        childNode.direction.lengthSquared == 0) {
      continue;
    }
    final mate = AttachSolver.standard.solveMate(
      parentNodeInBody: inBody,
      childNodeLocal: childNode,
      roll: held.roll,
    );
    ghosts.add(CraftGhost(
      def: held.def,
      position: mate.position,
      rotation: mate.rotation,
    ));
  }
  return (ghosts: ghosts, seats: seats);
}

/// The one red preview for an aim at [target], a seat nothing on the held part
/// can mate to.
///
/// Seated on the held part's chosen node (`W`/`S`) or, with no choice made, on
/// its first authored one — the same node the legal preview would have used —
/// and posed by the same [AttachSolver.solveMate], so the ghost stands exactly
/// where the part would have landed had the mate been allowed. Empty for a def
/// with no attach nodes and for a degenerate normal, where there is no pose to
/// draw rather than a refusal to show.
List<CraftGhost> _refusedGhost(
  CraftEditorController controller,
  HeldPart held,
  AttachTarget target,
) {
  final owner = controller.design.partById(target.ownerInstanceId);
  final inBody = owner?.nodeInBody(target.nodeName);
  if (inBody == null) return const [];

  final chosen = held.childNodeName;
  final childNode = chosen != null
      ? held.def.node(chosen)
      : (held.def.attachNodes.isEmpty ? null : held.def.attachNodes.first);
  if (childNode == null) return const [];
  if (inBody.direction.lengthSquared == 0 ||
      childNode.direction.lengthSquared == 0) {
    return const [];
  }

  final mate = AttachSolver.standard.solveMate(
    parentNodeInBody: inBody,
    childNodeLocal: childNode,
    roll: held.roll,
  );
  return [
    CraftGhost(
      def: held.def,
      position: mate.position,
      rotation: mate.rotation,
      valid: false,
    ),
  ];
}
