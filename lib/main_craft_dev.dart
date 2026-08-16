// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'domain/craft/craft_balance.dart';
import 'domain/parts/part_catalog.dart';
import 'domain/parts/part_def.dart';
import 'domain/shared/vector3.dart';
import 'infrastructure/flutter/craft_editor_control.dart';
import 'infrastructure/flutter/screens/app_theme.dart';
import 'infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';

/// Dev entrypoint: boots STRAIGHT into a bare craft editor — no menu, no
/// clicking through the VAB's panes. Same reason `main_scatter_dev.dart` exists:
/// the three things this feature cannot verify headlessly (part model scale,
/// ghost-versus-marker agreement, and the chirality flip on a real frame) are
/// all checked by changing a number and LOOKING at the result, over and over,
/// and reaching the editor through the main menu on every hot restart makes that
/// loop several times slower.
///
///   .fvm/flutter_sdk/bin/flutter run -d windows --enable-impeller \
///       --enable-flutter-gpu -t lib/main_craft_dev.dart
///
/// Not wired into any release build; the shipping entrypoint stays `main.dart`,
/// which reaches the real editor through its CRAFT ASSEMBLY menu item. This
/// harness deliberately hosts the [CraftEditorViewport] DIRECTLY rather than
/// pushing `CraftAssemblyScreen`: the point of a harness is to put the view into
/// a scripted state, and the screen keeps its controller private.
///
/// Two service extensions, both the same contract the other dev entrypoints use:
///
///   `ext.acro.screenshot?path=<out.png>`        photograph the whole window
///   `ext.acro.craft?build=lem&az=0.9&dist=14`   pose and drive the editor
///
/// Every `ext.acro.craft` reply is the editor's full status, so a capture script
/// can assert what it just photographed rather than trusting the request landed.
/// Examples:
///
/// ```
/// ext.acro.craft?build=lem&frame=true            the flown LM, framed
/// ext.acro.craft?nodes=false&balance=false       the ART alone, for a scale check
/// ext.acro.craft?az=0&el=0&dist=9                broadside, for measuring
/// ext.acro.craft?hold=rcs-block&sym=4            four ghosts on the quad ring
/// ext.acro.craft                                 current state, no change
/// ```
final GlobalKey _shotKey = GlobalKey();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsAltKeyAssertFilter();

  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'craft_shot.png';
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError,
          'no RepaintBoundary yet',
        );
      }
      final ui.Image image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'saved': path}));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        '$e',
      );
    }
  });

  developer.registerExtension('ext.acro.craft', (method, params) async {
    final control = CraftEditorControl.instance;
    final apply = control.apply;
    if (apply == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'no live craft editor',
      );
    }
    double? number(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    int? integer(String k) =>
        params[k] == null ? null : int.tryParse(params[k]!);
    bool? flag(String k) => params[k] == null ? null : params[k] == 'true';

    await apply(
      azimuth: number('az'),
      elevation: number('el'),
      distanceM: number('dist'),
      frame: flag('frame'),
      holdPartId: params['hold'],
      drop: flag('drop'),
      symmetryCount: integer('sym'),
      mirror: flag('mirror'),
      showNodes: flag('nodes'),
      showBalance: flag('balance'),
      build: params['build'],
      clear: flag('clear'),
      undo: flag('undo'),
      redo: flag('redo'),
      loadSlot: params['open'],
      saveSlot: params['save'],
    );
    // apply() only schedules a rebuild, so reading the status straight back
    // would describe the frame BEFORE the one a capture is about to photograph
    // — the bug `main_scatter_dev.dart` already fixed once. Wait for the frame
    // to actually paint first.
    await SchedulerBinding.instance.endOfFrame;
    return developer.ServiceExtensionResponse.result(
        jsonEncode(control.status?.call() ?? const {}));
  });

  runApp(
    // ExcludeSemantics for the same reason the other dev entrypoints do it: the
    // Windows accessibility bridge faults when the semantics tree mutates on a
    // focus switch. Harmless elsewhere, kept so every harness behaves the same
    // wherever it is run.
    ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro — craft editor lab',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(key: _shotKey, child: const CraftDevScreen()),
      ),
    ),
  );
}

/// The harness: a full-bleed [CraftEditorViewport] with a thin rail of catalog
/// buttons down the side.
///
/// Public so this file has one named thing rather than a private widget nobody
/// can reach; nothing in the app imports it.
class CraftDevScreen extends StatefulWidget {
  const CraftDevScreen({super.key});

  @override
  State<CraftDevScreen> createState() => _CraftDevScreenState();
}

class _CraftDevScreenState extends State<CraftDevScreen> {
  late final CraftEditorController _controller;
  final GlobalKey<CraftEditorViewportState> _viewportKey =
      GlobalKey<CraftEditorViewportState>();

  @override
  void initState() {
    super.initState();
    _controller = CraftEditorController(catalog: PartCatalog.standard());
    _controller.addListener(_onChanged);
    CraftEditorControl.instance
      ..apply = _apply
      ..status = _status;
  }

  @override
  void dispose() {
    // Leave the singleton empty rather than pointing at a dead State: the
    // service extension checks for null and reports "no live craft editor",
    // which is a better answer than a callback into a disposed controller.
    final control = CraftEditorControl.instance;
    if (control.apply == _apply) {
      control
        ..apply = null
        ..status = null;
    }
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  // ---------------- the control surface ----------------

  Future<void> _apply({
    double? azimuth,
    double? elevation,
    double? distanceM,
    bool? frame,
    String? holdPartId,
    bool? drop,
    int? symmetryCount,
    bool? mirror,
    bool? showNodes,
    bool? showBalance,
    String? build,
    bool? clear,
    bool? undo,
    bool? redo,
    String? loadSlot,
    String? saveSlot,
  }) async {
    // Structure first, then pose: `frame=true` sent with `build=lem` has to
    // frame the craft that was just built, not the empty pad it replaced.
    if (clear == true) _controller.clear();
    if (build != null) _buildReference(build);
    if (loadSlot != null) await _controller.load(loadSlot);
    if (undo == true) _controller.undo();
    if (redo == true) _controller.redo();

    if (holdPartId != null) {
      final def = _resolve(holdPartId);
      if (def != null) _controller.hold(def);
    }
    if (drop == true) _controller.clearHeld();
    if (symmetryCount != null) _controller.setSymmetryCount(symmetryCount);
    if (mirror != null) _controller.setMirror(mirror);
    if (showNodes != null) _controller.setShowNodes(showNodes);
    if (showBalance != null) _controller.setShowBalance(showBalance);

    final viewport = _viewportKey.currentState;
    if (viewport != null) {
      if (azimuth != null || elevation != null || distanceM != null) {
        viewport.setPose(
            azimuth: azimuth, elevation: elevation, distanceM: distanceM);
      }
      if (frame == true) viewport.frameCraft();
    }
    if (saveSlot != null) await _controller.save(saveSlot);
  }

  /// The editor as plain JSON-able values.
  ///
  /// Carries every part's instance id, def id and craft-frame position because
  /// that is what makes a screenshot checkable: a leg drawn a metre out of its
  /// outrigger is a MODEL error, and the only way to say so is to compare what
  /// the picture shows against where the domain put the part.
  Map<String, Object?> _status() {
    final design = _controller.design;
    final viewport = _viewportKey.currentState;
    final cam = viewport?.camera;
    final com = design.isEmpty ? null : CraftBalance.centreOfMass(design);
    final thrust = design.isEmpty ? null : CraftBalance.thrust(design);
    return {
      'craft': design.name,
      'parts': design.partCount,
      'stages': design.stages.length,
      'loose': _controller.looseParts.length,
      'held': _controller.held?.def.id,
      'symmetry': _controller.symmetry.mirror
          ? 'mirror'
          : 'x${_controller.symmetry.count}',
      'selected': _controller.selectedId,
      'showNodes': _controller.showNodes,
      'showBalance': _controller.showBalance,
      'undo': _controller.undoCount,
      'redo': _controller.redoCount,
      'blocked': _controller.blocked,
      'sceneReady': viewport?.sceneReady ?? false,
      'hovered': viewport?.hoveredTarget?.nodeName,
      if (cam != null)
        'camera': {
          'azimuth': _round(cam.azimuth),
          'elevation': _round(cam.elevation),
          'distanceM': _round(cam.distanceM),
          'pivot': _vector(cam.pivot),
          'viewport': [cam.viewport.width, cam.viewport.height],
        },
      if (com != null) 'centreOfMass': _vector(com),
      if (thrust != null)
        'thrust': {
          'origin': _vector(thrust.origin),
          'direction': _vector(thrust.direction),
          'newtons': _round(thrust.thrustN),
        },
      'placed': [
        for (final p in design.parts)
          {
            'id': p.instanceId,
            'def': p.def.id,
            'stage': p.stage,
            'position': _vector(p.position),
            'parentNode': p.attachment?.parentNode,
          }
      ],
    };
  }

  static double _round(double v) => (v * 1000).roundToDouble() / 1000;

  static List<double> _vector(Vector3 v) =>
      [_round(v.x), _round(v.y), _round(v.z)];

  /// Catalog lookup by id, spelled loosely.
  ///
  /// These ids are typed by hand into a URL, so `rcs-block`, `rcs_block` and
  /// `eagle-rcs-block` all have to reach the same part or the harness is slower
  /// to drive than the mouse it replaces.
  PartDef? _resolve(String query) {
    String key(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    final wanted = key(query);
    PartDef? loose;
    for (final def in _controller.catalog.all) {
      final id = key(def.id);
      if (id == wanted) return def;
      if (loose == null && id.contains(wanted)) loose = def;
    }
    return loose;
  }

  /// Assemble a named reference craft, replacing whatever is on the pad.
  ///
  /// One [CraftEditorController.edit] for the whole vehicle, so a sweep can put
  /// the LM up, look at it, and take it back with a single undo. `lem` is the
  /// flown Apollo Lunar Module: ascent stage, descent stage, DPS bell, four legs
  /// and four RCS quads — the craft every model-scale question is asked about,
  /// because it is the one where a wrong `modelScale` shows as a joint that does
  /// not close.
  void _buildReference(String name) {
    if (name.toLowerCase() != 'lem' && name.toLowerCase() != 'lm') return;
    final catalog = _controller.catalog;
    final pod = catalog.byId('eagle-command-pod');
    final descent = catalog.byId('eagle-fuel-tank');
    final engine = catalog.byId('eagle-thruster');
    final leg = catalog.byId('eagle-legs');
    final quad = catalog.byId('eagle-rcs-block');
    if (pod == null ||
        descent == null ||
        engine == null ||
        leg == null ||
        quad == null) {
      return;
    }
    _controller.edit('build Eagle', () {
      final design = _controller.design;
      // Materialise the id list first: `roots` is a lazy view over the list
      // being emptied.
      for (final id in [for (final p in design.roots) p.instanceId]) {
        design.remove(id);
      }
      design.addPart(
          def: pod, instanceId: 'ascent', position: Vector3.zero);
      design.attachPart(
        def: descent,
        instanceId: 'descent',
        toInstanceId: 'ascent',
        parentNode: 'stage-bottom',
        childNode: 'deck-top',
      );
      design.attachPart(
        def: engine,
        instanceId: 'dps',
        toInstanceId: 'descent',
        parentNode: 'engine-mount',
        childNode: 'mount',
      );
      for (var i = 1; i <= 4; i++) {
        design.attachPart(
          def: leg,
          instanceId: 'leg-$i',
          toInstanceId: 'descent',
          parentNode: 'leg-$i',
          childNode: 'outrigger',
        );
        design.attachPart(
          def: quad,
          instanceId: 'quad-$i',
          toInstanceId: 'ascent',
          parentNode: 'quad-$i',
          childNode: 'mount',
        );
      }
      CraftBalance.autoStage(design);
    });
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.bg,
      child: Row(
        children: [
          SizedBox(width: 210, child: _rail()),
          const VerticalDivider(width: 1, color: Color(0xFF223247)),
          Expanded(
            child: CraftEditorViewport(
              key: _viewportKey,
              controller: _controller,
            ),
          ),
        ],
      ),
    );
  }

  /// A plain list of hold buttons plus the verbs a sweep needs by hand. No
  /// catalog pane: this harness is deliberately not the VAB, and a shell that
  /// tracked the shipping screen's layout would be one more thing to keep in
  /// step for no diagnostic gain.
  Widget _rail() {
    final held = _controller.held?.def.id;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Text('CRAFT LAB', style: AppTheme.heading),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _verb('LEM', () => _buildReference('lem')),
            _verb('CLEAR', _controller.clear),
            _verb('UNDO', _controller.undo),
            _verb('REDO', _controller.redo),
            _verb('FRAME', () => _viewportKey.currentState?.frameCraft()),
            for (final n in const [1, 2, 4])
              _verb('x$n', () => _controller.setSymmetryCount(n),
                  on: !_controller.symmetry.mirror &&
                      _controller.symmetry.count == n),
            _verb('G', () => _controller.setShowNodes(!_controller.showNodes),
                on: _controller.showNodes),
            _verb('C',
                () => _controller.setShowBalance(!_controller.showBalance),
                on: _controller.showBalance),
          ],
        ),
        const Divider(color: Color(0xFF223247)),
        for (final def in _controller.catalog.all)
          InkWell(
            onTap: () => _controller.hold(def),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                def.name,
                style: AppTheme.body.copyWith(
                    color: def.id == held ? AppTheme.accent2 : AppTheme.text),
              ),
            ),
          ),
      ],
    );
  }

  Widget _verb(String label, VoidCallback onTap, {bool on = false}) => InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(color: on ? AppTheme.accent2 : AppTheme.textDim),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(label,
              style: AppTheme.dim.copyWith(
                  color: on ? AppTheme.accent2 : AppTheme.textDim)),
        ),
      );
}
