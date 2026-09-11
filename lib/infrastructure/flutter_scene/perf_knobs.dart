// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The performance trade-offs of the colony and scene streamers as ONE
/// table, by name.
///
/// Each of these is a static somewhere — the tier cache's bytes on
/// [CityNodes], the chunk cap on [CityTileMesher], the collector pacer on
/// the engine's [fs.Scene], the frame budget's target — read every frame
/// by the code that owns it, so flipping one at run time takes effect on
/// the next frame. What was missing was a way to reach them all without
/// knowing where each lives: the studio's PERF panel wants a row per knob,
/// the dev hook wants `knob=<name>&value=<v>` so the perf sweep can A/B a
/// knob without a rebuild, and the status map wants every current value
/// so a run's log says what it ran under. This table is that: a name, an
/// explainer of what the knob trades, a getter and a setter, and nothing
/// else — the defaults and the documentation of each stay with the static.
library;

import 'package:flutter_scene/scene.dart' as fs;

import '../../domain/colony/city/traffic/traffic_tuning.dart';
import '../flutter/screens/city_plat_view.dart' show PlatLayers;
import 'city/agent_traffic_pass.dart';
import 'city/city_nodes.dart';
import 'city/city_tile_mesher.dart';
import 'frame_budget.dart';

/// One knob: its name, what it trades, and the static behind it.
class PerfKnob {
  const PerfKnob(this.name, this.trades, this.get, this.set,
      {this.isFlag = false, this.unit = ''});

  final String name;

  /// One line for the panel: what turning it costs and what it buys.
  final String trades;

  /// A flag reads and writes 0/1.
  final bool isFlag;

  /// For the panel's row: 'MiB', 'KiB', 'ms', or none.
  final String unit;

  final num Function() get;
  final void Function(num v) set;
}

class PerfKnobs {
  PerfKnobs._();

  static const int _mib = 1 << 20;

  /// Every knob, in the order the panel shows them.
  static final List<PerfKnob> all = [
    PerfKnob(
      'tierCacheMiB',
      'Keeps a tile\'s replaced builds for re-attach instead of a rebuild; '
          'costs GPU memory. 0 is off.',
      () => CityNodes.tierCacheBytes / _mib,
      (v) => CityNodes.tierCacheBytes = (v * _mib).round(),
      unit: 'MiB',
    ),
    PerfKnob(
      'tierCacheSetsPerTile',
      'Builds one tile may keep in the tier cache; a slow pass over '
          'downtown would otherwise fill it with one tile\'s history. 0 is '
          'no cap.',
      () => CityNodes.tierCacheSetsPerTile,
      (v) => CityNodes.tierCacheSetsPerTile = v.round(),
    ),
    PerfKnob(
      'bufferPoolMiB',
      'Reuses dropped chunk buffers so the collector finalises fewer native '
          'objects; costs GPU memory. 0 is off.',
      () => CityNodes.bufferPoolBytes / _mib,
      (v) => CityNodes.bufferPoolBytes = (v * _mib).round(),
      unit: 'MiB',
    ),
    PerfKnob(
      'bufferPoolCoolFrames',
      'Frames a dropped buffer rests before reuse, so the GPU is done '
          'with it.',
      () => CityNodes.bufferPoolCoolFrames,
      (v) => CityNodes.bufferPoolCoolFrames = v.round(),
    ),
    PerfKnob(
      'chunkMiB',
      'Bigger chunks are fewer draws and a bigger first-draw hitch.',
      () => CityTileMesher.maxGroupBytes / _mib,
      (v) => CityTileMesher.maxGroupBytes = (v * _mib).round(),
      unit: 'MiB',
    ),
    PerfKnob(
      'uploadKiBPerFrame',
      'Bytes the raster thread is asked to take at first draw each frame; '
          'more lands tiles faster and hitches harder.',
      () => CityNodes.uploadBytesPerFrame / 1024,
      (v) => CityNodes.uploadBytesPerFrame = (v * 1024).round(),
      unit: 'KiB',
    ),
    PerfKnob(
      'pacerMiBPerFrame',
      'Garbage the pacer makes each frame so scavenges come small and '
          'often instead of rare and long. 0 is off.',
      () => fs.Scene.collectorPacerBytesPerFrame / _mib,
      (v) => fs.Scene.collectorPacerBytesPerFrame = (v * _mib).round(),
      unit: 'MiB',
    ),
    PerfKnob(
      'pacerFollowsSlice',
      'The pacer runs at the frame budget\'s slice: full in a frame with '
          'room, none in a loaded one. Off, it runs at its knob every frame.',
      () => FrameBudget.pacerFollowsSlice ? 1 : 0,
      (v) => FrameBudget.pacerFollowsSlice = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'detailLayer',
      'Per-building detail from a job round the eye; off, walking re-keys '
          'the tiles it crosses.',
      () => CityNodes.detailLayer ? 1 : 0,
      (v) => CityNodes.detailLayer = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'detailBudgetMs',
      'The floor of UI-thread upload the detail layer gets a frame; it '
          'also takes what the tile build leaves. More lands detail faster '
          'behind a fast camera and takes it from the frame.',
      () => CityNodes.detailBudgetMs,
      (v) => CityNodes.detailBudgetMs = v.toDouble(),
      unit: 'ms',
    ),
    PerfKnob(
      'buildBudgetMs',
      'UI-thread building a frame spends before the rest of the queue '
          'waits; the fixed budget the frame budget scales.',
      () => CityNodes.buildBudgetMs,
      (v) => CityNodes.buildBudgetMs = v.toDouble(),
      unit: 'ms',
    ),
    PerfKnob(
      'frameBudget',
      'A per-frame limit on the streamers; off, they take their fixed '
          'budgets whatever the frame costs.',
      () => FrameBudget.enabled ? 1 : 0,
      (v) => FrameBudget.enabled = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'frameTargetMs',
      'The UI-thread frame the budget aims for.',
      () => FrameBudget.targetMs,
      (v) => FrameBudget.targetMs = v.toDouble(),
      unit: 'ms',
    ),
    PerfKnob(
      'stallMs',
      'An overrun this far past what the frame\'s parts explain is a '
          'collector pause, not the streamers\', and does not halve the '
          'slice. 0 halves on every overrun.',
      () => FrameBudget.stallMs,
      (v) => FrameBudget.stallMs = v.toDouble(),
      unit: 'ms',
    ),
    PerfKnob(
      'judgeBySpend',
      'An overrun halves the slice only when the streamers spent past it; '
          'off, any frame over the target halves it.',
      () => FrameBudget.judgeBySpend ? 1 : 0,
      (v) => FrameBudget.judgeBySpend = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'scaleUploadBytes',
      'Scale the upload byte cap by the slice; on, a busy frame starves '
          'the reveals and tiles land seconds late.',
      () => CityFrameBudgets.scaleBytes ? 1 : 0,
      (v) => CityFrameBudgets.scaleBytes = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'buildShare',
      'The colony build loop\'s share of the frame budget\'s slice; the '
          'ground streamer gets the rest.',
      () => CityFrameBudgets.buildShare,
      (v) => CityFrameBudgets.buildShare = v.toDouble(),
    ),
    PerfKnob(
      'platFills',
      'The plat\'s lot fills at street scale (retained triangle batches).',
      () => PlatLayers.fills ? 1 : 0,
      (v) => PlatLayers.fills = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'platOutlines',
      'The plat\'s lot outlines at street scale (a stroked path per cell '
          'and use); the dearest thing it does per lot.',
      () => PlatLayers.outlines ? 1 : 0,
      (v) => PlatLayers.outlines = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'platStreets',
      'The plat\'s local streets at street scale (a stroked path per cell '
          'and class).',
      () => PlatLayers.streets ? 1 : 0,
      (v) => PlatLayers.streets = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'platBlockImages',
      'District-scale lot boxes as one image per 2 km block instead of a '
          'triangle batch re-uploaded every frame; costs up to 64 MiB of '
          'textures on a 32 km colony.',
      () => PlatLayers.blockImages ? 1 : 0,
      (v) => PlatLayers.blockImages = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'maxInFlight',
      'Tiles between submission and swap at once; more lands faster and '
          'holds more results in memory.',
      () => CityNodes.maxInFlight,
      (v) => CityNodes.maxInFlight = v.round(),
    ),
    // ---- Agent traffic (docs/plans/agent-traffic.md §15.4). The first
    // eight change what the agents do, so runs compared for determinism
    // must share them; the next two only when their ticks run; the rest
    // only what is drawn.
    PerfKnob(
      'agentsOn',
      'Agent traffic in the colonies that run it; off, their vehicles stand '
          'where they are and the routed model answers the traffic again.',
      () => AgentTuning.agentsOn ? 1 : 0,
      (v) => AgentTuning.agentsOn = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'pathExpansionsPerStep',
      'Route-search steps per agent sub-step; fewer is cheaper a sub-step '
          'and leaves trips waiting longer for a route.',
      () => AgentTuning.pathExpansionsPerStep,
      (v) => AgentTuning.pathExpansionsPerStep = v.round(),
    ),
    PerfKnob(
      'maxVehicles',
      'Vehicles on the road at once; past it, trips wait at their origin. '
          'The table is sized when a colony\'s agents start.',
      () => AgentTuning.maxVehicles,
      (v) => AgentTuning.maxVehicles = v.round(),
    ),
    PerfKnob(
      'maxQueuedPaths',
      'Car trips waiting for a route at once; past it, trips are deferred.',
      () => AgentTuning.maxQueuedPaths,
      (v) => AgentTuning.maxQueuedPaths = v.round(),
    ),
    PerfKnob(
      'maxSpawnsPerStep',
      'Vehicles pulled out per agent sub-step; the rest wait their turn.',
      () => AgentTuning.maxSpawnsPerStep,
      (v) => AgentTuning.maxSpawnsPerStep = v.round(),
    ),
    PerfKnob(
      'stuckDespawnS',
      'Agent seconds a vehicle may make no progress before it is taken off '
          'the road; lower hides a jam sooner.',
      () => AgentTuning.stuckDespawnS,
      (v) => AgentTuning.stuckDespawnS = v.toDouble(),
      unit: 's',
    ),
    PerfKnob(
      'impatientGrantS',
      'Seconds at a line before a vehicle stops waiting for a gap; a clear '
          'crossing is still required.',
      () => AgentTuning.impatientGrantS,
      (v) => AgentTuning.impatientGrantS = v.toDouble(),
      unit: 's',
    ),
    PerfKnob(
      'dontBlockBox',
      'A junction is entered only with room to leave it; off, queues spill '
          'across it and can lock a grid.',
      () => AgentTuning.dontBlockBox ? 1 : 0,
      (v) => AgentTuning.dontBlockBox = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'maxAgentSubStepsPerFrame',
      'Agent sub-steps a held colony runs in one frame; more catches up '
          'faster after a hitch and costs that frame more.',
      () => AgentTuning.maxAgentSubStepsPerFrame,
      (v) => AgentTuning.maxAgentSubStepsPerFrame = v.round(),
    ),
    PerfKnob(
      'maxHeldCityS',
      'Colony seconds the hold may fall behind before one frame drains it '
          'all: a hitch, never a dropped tick.',
      () => AgentTuning.maxHeldCityS,
      (v) => AgentTuning.maxHeldCityS = v.toDouble(),
      unit: 's',
    ),
    PerfKnob(
      'agentsDrawn',
      'Draw the agents\' vehicles; off, they still drive.',
      () => AgentTrafficPass.drawn ? 1 : 0,
      (v) => AgentTrafficPass.drawn = v != 0,
      isFlag: true,
    ),
    PerfKnob(
      'agentRenderCap',
      'Agent vehicles drawn per colony, nearest first.',
      () => AgentTrafficPass.renderCap,
      (v) => AgentTrafficPass.renderCap = v.round(),
    ),
    PerfKnob(
      'agentRangeM',
      'Agent vehicles further than this from the focus are not drawn.',
      () => AgentTrafficPass.rangeM,
      (v) => AgentTrafficPass.rangeM = v.toDouble(),
      unit: 'm',
    ),
    PerfKnob(
      'agentShadowRangeM',
      'Agent vehicles nearer than this cast shadows; each costs the shadow '
          'pass a packing.',
      () => AgentTrafficPass.shadowRangeM,
      (v) => AgentTrafficPass.shadowRangeM = v.toDouble(),
      unit: 'm',
    ),
  ];

  static PerfKnob? byName(String name) {
    for (final k in all) {
      if (k.name == name) return k;
    }
    return null;
  }

  /// Sets [name] from [value] ('1'/'true'/'on' or a number for a flag);
  /// false when the name or the value is not one.
  static bool set(String name, String value) {
    final k = byName(name);
    if (k == null) return false;
    final lower = value.trim().toLowerCase();
    final num? v = k.isFlag && (lower == 'true' || lower == 'on')
        ? 1
        : k.isFlag && (lower == 'false' || lower == 'off')
            ? 0
            : num.tryParse(lower);
    if (v == null) return false;
    k.set(v);
    return true;
  }

  /// Every knob's current value, by name — the status map's 'knobs'.
  static Map<String, num> snapshot() =>
      {for (final k in all) k.name: k.get()};
}
