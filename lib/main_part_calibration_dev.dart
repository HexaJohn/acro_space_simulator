// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'domain/parts/lem_parts.dart';
import 'domain/parts/part_catalog.dart';
import 'domain/parts/part_def.dart';
import 'domain/shared/quaternion.dart';
import 'domain/shared/vector3.dart';
import 'domain/vessel/part.dart';
import 'domain/vessel/vessel.dart';
import 'infrastructure/baked_terrain_data.dart';
import 'infrastructure/flutter/sim_view_control.dart';
import 'infrastructure/flutter/simulation_view.dart';
import 'infrastructure/flutter/windows_key_event_workaround.dart';
import 'infrastructure/flutter_scene/atmosphere_nodes.dart';
import 'infrastructure/flutter_scene/cloud_nodes.dart';
import 'infrastructure/flutter_scene/part_model_library.dart';
import 'infrastructure/flutter_scene/render_backend.dart';
import 'infrastructure/flutter_scene/scene_sync.dart';
import 'infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'infrastructure/flutter_scene/vessel_nodes.dart';
import 'infrastructure/sample_world.dart';

/// Dev entrypoint: an OPTICAL BENCH for part art. It flies one craft whose part
/// list is whatever the bench is asked to hold, so a baked export can be looked
/// at against the body-frame metre ruler and its [PartDef.modelScale],
/// [PartDef.modelRotation] and [PartDef.modelOffset] settled by eye.
///
///   .fvm\flutter_sdk\bin\flutter.bat run -d windows --enable-impeller \
///       --enable-flutter-gpu -t lib/main_part_calibration_dev.dart
///
/// Not wired into any release build; the shipping entrypoint stays main.dart.
///
/// ## Why a separate entrypoint
///
/// A part's art can only be judged next to something of known size, and the one
/// ruler this renderer has — `VesselNodes.showAxes`, three 1-metre-ticked shafts
/// — is drawn at the CRAFT ORIGIN. So the part being measured has to BE at the
/// craft origin, which no real craft's layout will do on request.
/// `main_scene_dev.dart` flies a fixed two-craft formation and cannot: its
/// vessels' part lists are fixed at construction.
///
/// This bench keeps the craft and swaps its PARTS instead (`ext.acro.bench`),
/// which the renderer already handles — a part-list change is a staging event,
/// and `VesselNodes` rebuilds the craft from the new list on the next frame.
/// The craft itself never moves, so the camera stays framed across a whole
/// sweep.
///
/// ## The sweep
///
///   ext.acro.bench?show=all                 # the roster in a row along +X
///   ext.acro.bench?show=eagle-legs          # one part, ON the ruler
///   ext.acro.camera?axes=true&rangeM=12&azimuthDeg=0&elevationDeg=0
///   ext.acro.camera?part=eagle-legs&partRotDeg=-90,0,0
///   ext.acro.screenshot?path=test_out/part_calibration/legs.png
///
/// The `part*` knobs are `PartModelLibrary`'s live calibration overrides and
/// behave exactly as they do in `main_scene_dev.dart`; every reply carries
/// `partCalibration`, the settled values as Dart literals to paste into
/// `lem_parts.dart`. The sweep is over when that map is empty again because the
/// catalog says what the overrides said.
///
/// `ext.acro.camera` here is a SUBSET of `main_scene_dev.dart`'s — the camera,
/// the ruler, the part calibration knobs and the few scene switches that change
/// what a part looks like. Knob names match that file exactly, so a command
/// written for one harness reads the same in the other.
final GlobalKey _shotKey = GlobalKey();

/// The bench craft: a lunar orbiter emptied of its stock parts, holding
/// whatever [_setBench] puts on it. Sunlit (daylight side of the Moon) and
/// torque-free, so its attitude never drifts away from the pose a screenshot
/// was framed for.
final Vessel _rig = _buildRig();

/// The bench top: the live part list of the rig's only stage. Mutated in place
/// — the renderer keys its rebuild off the part list's contents, not off the
/// vessel identity, so replacing the contents restages the craft's art without
/// disturbing the orbit, the camera lock or the loaded bakes.
final List<Part> _bench = _rig.stages.first.parts;

/// The catalog the bench draws from, built once: [_setBench] resolves ids
/// through it so a bench part carries the same mass and size the game gives it.
final PartCatalog _catalog = PartCatalog.standard();

/// Metres between parts when the whole roster is shown at once. Wide enough
/// that the descent stage (4.22 m across the flats) and a landing leg (2.54 m
/// of radial reach) cannot touch.
const double _defaultSpacingM = 6.0;

/// What the bench is currently holding, in bench order, for the extension reply.
List<String> _benchIds = const [];

Vessel _buildRig() {
  final v = SampleWorld.buildLunarOrbiter(
    id: 'lem-bench',
    name: 'LEM Optical Bench',
  );
  // IDENTITY attitude, not the prograde pose the sample world hands out: it
  // makes the craft body frame the world frame, so the camera's azimuth and
  // elevation are read directly against part-local X/Y/Z. Nothing torques the
  // craft, so it holds this pose for the whole session.
  v.state = v.state.copyWith(attitude: Quaternion.identity);
  return v;
}

/// One bench part from a catalog definition, at [at] metres in the craft body
/// frame.
///
/// Deliberately carries NO engine and NO resources. An [Engine] anywhere on the
/// active stage fires along +Z at whatever throttle the view is holding, which
/// would push the bench out of frame; the propellant only matters to a thrust
/// model that is not wanted here. Mass, size and the catalog id — the three
/// things the renderer and the mass model actually read — are the real ones.
Part _benchPart(PartDef def, Vector3 at) => Part(
      id: PartId(def.id),
      name: def.name,
      defId: def.id,
      dryMass: def.dryMass,
      positionInVessel: at,
      maxTemperature: def.maxTemperature,
      dragCoefficient: def.dragCoefficient,
      crossSectionArea: def.crossSectionArea,
    );

/// Put [ids] on the bench, in order: the FIRST sits on the craft origin (which
/// is where the axis ruler is drawn), the rest march out along body +X at
/// [spacingM].
///
/// An id may instead carry an EXPLICIT body-frame placement, `id@x:y:z` in
/// metres, which is what turns the bench from a row of separate parts into an
/// assembly: mate two parts by putting each at the position its attach nodes
/// imply, and the joint between them is then a thing a screenshot can judge.
/// Colons rather than commas because commas already separate the ids.
///
/// Unknown ids are dropped rather than faked — a typo must not quietly produce
/// a grey stand-in that reads as "this export has no art". An empty result is
/// ignored for the same reason a craft is never left with no parts at all.
List<String> _setBench(List<String> ids, double spacingM) {
  final placed = <(PartDef, Vector3?)>[];
  for (final raw in ids) {
    final spec = raw.trim().split('@');
    final def = _catalog.byId(spec.first);
    if (def == null) continue;
    placed.add((def, spec.length > 1 ? _triple(spec[1], ':') : null));
  }
  if (placed.isEmpty) return _benchIds;
  _bench
    ..clear()
    ..addAll([
      for (var i = 0; i < placed.length; i++)
        _benchPart(placed[i].$1, placed[i].$2 ?? Vector3(i * spacingM, 0, 0)),
    ]);
  return _benchIds = [
    for (final p in placed)
      p.$2 == null
          ? p.$1.id
          : '${p.$1.id}@${p.$2!.x}:${p.$2!.y}:${p.$2!.z}',
  ];
}

/// A three-component service-extension parameter as a vector, or null when it
/// is absent or malformed. Null means "leave this alone", so a typo can never
/// quietly zero a knob it failed to parse. Same contract as
/// `main_scene_dev.dart`; [sep] is a comma there and a colon inside a `show=`
/// entry, where commas already separate the parts.
Vector3? _triple(String? raw, [String sep = ',']) {
  if (raw == null) return null;
  final p = raw.split(sep).map(double.tryParse).toList();
  if (p.length != 3 || p.contains(null)) return null;
  return Vector3(p[0]!, p[1]!, p[2]!);
}

/// Degrees about a part's own X, Y and Z axes as one orientation, applied X
/// first, then Y, then Z about the FIXED (unrotated) axes — so `90,0,0` and
/// `0,90,0` each name one of the axis-aligned quarter turns a mis-authored
/// export needs, and the pair composes without the reader having to know an
/// intrinsic-rotation convention. Same contract as `main_scene_dev.dart`.
Quaternion _eulerDeg(Vector3 deg) {
  const k = math.pi / 180;
  return Quaternion.axisAngle(Vector3.unitZ, deg.z * k) *
      Quaternion.axisAngle(Vector3.unitY, deg.y * k) *
      Quaternion.axisAngle(Vector3.unitX, deg.x * k);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installWindowsAltKeyAssertFilter();
  await loadBakedTerrainData();

  // The bench exists to look at ONE part's art, so everything that would put
  // pixels between the camera and it is off from the first frame: terrain
  // chunks stream at 100 km altitude and cost frames the bench has no use for,
  // and the Moon carries no air anyway. Both are back on one knob away.
  TerrainNodes.enabled = false;
  for (final s in AtmosphereNodes.styles.values) {
    s.enabled = false;
  }
  for (final s in CloudNodes.styles.values) {
    s.enabled = false;
  }
  // The ruler is the entire point of this harness; a bench that boots without
  // it invites a first screenshot with nothing to measure against.
  VesselNodes.showAxes = true;
  _setBench(LemParts.ids.toList(), _defaultSpacingM);

  // Same contract as main_scene_dev.dart: captures the app's RepaintBoundary
  // rather than the OS window, which stays correct when the window is occluded
  // or the desktop is locked (window-level capture goes white).
  //   callServiceExtension?...&method=ext.acro.screenshot&path=<out.png>
  developer.registerExtension('ext.acro.screenshot', (method, params) async {
    try {
      final path = params['path'] ?? 'part_shot.png';
      final boundary =
          _shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            'no RepaintBoundary yet');
      }
      final ui.Image image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      // A capture that fails because nobody made the folder is a wasted app
      // launch: the bakes behind the frame took minutes to parse.
      await Directory(File(path).parent.path).create(recursive: true);
      await File(path).writeAsBytes(data!.buffer.asUint8List());
      return developer.ServiceExtensionResponse.result(
          jsonEncode({'saved': path}));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
          developer.ServiceExtensionResponse.extensionError, '$e');
    }
  });

  // What the bench holds:
  //   ext.acro.bench?show=all                     the roster, in a row on +X
  //   ext.acro.bench?show=eagle-legs              one part, on the ruler
  //   ext.acro.bench?show=eagle-fuel-tank,eagle-thruster&spacingM=3
  //   ext.acro.bench?show=eagle-fuel-tank@0:0:0,eagle-thruster@0:0:-1.54
  //   ext.acro.bench                              current layout, no change
  // The first id named sits on the craft origin, under the axis gizmo, unless
  // it carries an explicit `@x:y:z` placement in metres — mate two parts at the
  // positions their attach nodes imply and the joint becomes photographable.
  developer.registerExtension('ext.acro.bench', (method, params) async {
    final show = params['show'];
    final spacing =
        double.tryParse(params['spacingM'] ?? '') ?? _defaultSpacingM;
    if (show != null) {
      _setBench(
        show == 'all' ? LemParts.ids.toList() : show.split(','),
        spacing > 0 ? spacing : _defaultSpacingM,
      );
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      'bench': _benchIds,
      'spacingM': spacing,
      'positionsM': {
        for (var i = 0; i < _benchIds.length; i++) _benchIds[i]: i * spacing,
      },
    }));
  });

  // Camera, ruler and the per-part art calibration knobs. A SUBSET of
  // main_scene_dev.dart's extension of the same name, carrying the same knob
  // names — see the file doc.
  developer.registerExtension('ext.acro.camera', (method, params) async {
    final c = SimViewControl.instance;
    double? deg(String k) =>
        params[k] == null ? null : double.tryParse(params[k]!);
    final az = deg('azimuthDeg'), el = deg('elevationDeg'), ro = deg('rollDeg');
    if (az != null || el != null || ro != null) {
      c.orbit?.call(
        azimuth: az == null ? null : az * math.pi / 180,
        elevation: el == null ? null : el * math.pi / 180,
        roll: ro == null ? null : ro * math.pi / 180,
      );
    }
    final range = deg('rangeM');
    if (range != null) c.zoom?.call(rangeM: range);
    if (params['perspective'] != null) {
      c.setPerspective?.call(params['perspective'] == 'true');
    }
    if (params['alignUp'] != null) c.setUpMode?.call(params['alignUp']!);
    // Per-craft origin + 1-metre axis ruler: axes=true|false.
    if (params['axes'] != null) {
      VesselNodes.showAxes = params['axes'] == 'true';
    }
    // Terrain back on for a part shot against real ground: terrain=true.
    if (params['terrain'] != null) {
      TerrainNodes.enabled = params['terrain'] == 'true';
    }
    // Exposure, because a part read against black sky and a part read against
    // a sunlit Moon want different ones: exposure=<x> also switches auto off,
    // autoExposure=true hands it back.
    if (params['autoExposure'] != null) {
      SceneSync.autoExposure = params['autoExposure'] == 'true';
    }
    final exposure = deg('exposure');
    if (exposure != null && exposure > 0) {
      SceneSync.manualExposure = exposure;
      SceneSync.autoExposure = false;
    }
    // Per-PART art calibration — the knobs this harness exists to drive:
    //   ext.acro.camera?part=eagle-legs&partRotDeg=90,0,0
    //   ext.acro.camera?part=eagle-legs&partScale=2.4&partOffsetM=0,0,0.4
    //   ext.acro.camera?partScaleAll=1.1   (every part at once, on top of each
    //                                       part's own scale)
    //   ext.acro.camera?partReset=true     (drop every override)
    // Unnamed values keep whatever is in force, so rotation, scale and offset
    // sweep independently and accumulate.
    final partScaleAll = deg('partScaleAll');
    if (partScaleAll != null && partScaleAll > 0) {
      PartModelLibrary.scaleMultiplier = partScaleAll;
    }
    if (params['partReset'] == 'true') PartModelLibrary.resetCalibration();
    final partKey = params['part'];
    if (partKey != null) {
      final partScale = deg('partScale');
      final rotDeg = _triple(params['partRotDeg']);
      PartModelLibrary.calibrate(
        partKey,
        scale: partScale != null && partScale > 0 ? partScale : null,
        rotation: rotDeg == null ? null : _eulerDeg(rotDeg),
        offset: _triple(params['partOffsetM']),
      );
    }
    return developer.ServiceExtensionResponse.result(jsonEncode({
      ...(c.status?.call() ?? const {'error': 'no live view'}),
      'bench': _benchIds,
      // Always reported, empty or not: a calibration sweep is only over once
      // these literals are in the catalog and this map is empty again.
      'partCalibration': PartModelLibrary.calibrationSource(),
      'partScaleAll': PartModelLibrary.scaleMultiplier,
    }));
  });

  // ExcludeSemantics for the reason main_scene_dev.dart gives: the Windows
  // accessibility bridge faults when the semantics tree mutates on a focus
  // switch, and nothing this harness does needs semantics.
  runApp(
    ExcludeSemantics(
      child: MaterialApp(
        title: 'Acro — part calibration bench',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(
          key: _shotKey,
          child: SimulationView(
            initialBackend: RenderBackend.flutterScene,
            spawnDemoOrbiter: false,
            injectedVessel: _rig,
          ),
        ),
      ),
    ),
  );
}
