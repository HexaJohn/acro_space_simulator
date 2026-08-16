// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/foundation.dart' show compute, debugPrint, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_scene/fscene.dart' as fsb;
import 'package:flutter_scene/scene.dart' as fs;

/// The process-wide `.fsceneb` cache: ONE parse + GPU preload per asset, shared
/// by every screen that draws it.
///
/// Two renderers now draw the same seven part bakes — the flight view
/// (`VesselNodes`) and the craft editor — and a cache owned by either one would
/// make the other pay the parse again on first open. That parse is tens of
/// seconds in a debug build, so where the cache lives decides whether opening
/// the VAB after a flight is instant or a stall.
///
/// What is paid once per ASSET: the container parse (~90 MB for a whole-craft
/// bake) and the KTX2 texture transcode (pure Dart, ~30-60 s of CPU per bake in
/// a debug build). What is paid per INSTANCE: [realize], a few milliseconds,
/// because a node cannot be parented twice — every part instance needs its own
/// node graph, and they all share the parsed document and the GPU resources
/// behind it.
///
/// All state is static. The cached documents and their preloaded GPU textures
/// stay resident for the life of the process; see `VesselNodes.prewarm` for
/// what that costs and why it is the trade taken.
class PartBakeCache {
  PartBakeCache._();

  /// One fully-loaded bake per asset: the parsed document plus its preloaded
  /// [fsb.ResourceRealizer], from which per-instance node graphs realize in
  /// milliseconds against shared GPU resources.
  static final Map<String, Future<(fsb.SceneDocument, fsb.ResourceRealizer)>>
      _bakes = {};

  /// Serializes bake loads. Loading two bakes at once doubles the isolate-group
  /// heap churn (parse copies + per-texture transcode isolates), and the
  /// resulting GC pauses land on the UI isolate as multi-second frame stalls.
  ///
  /// It is also what makes a long prewarm queue safe: the queue can only ever
  /// get longer, never wider, so adding assets to it cannot stall the caller.
  static Future<void> _bakeChain = Future<void>.value();

  /// Assets whose load failed. Per-ASSET, so a missing LM export does not
  /// disable the CSM (and one broken part bake does not disable the other six),
  /// and static, so a broken bake costs one attempt per process rather than one
  /// per rebuild.
  ///
  /// A missing bake is routine, not an error: the source models are licensed
  /// for use but not redistribution, so they are absent on a fresh clone and on
  /// web by build policy. Callers draw a procedural stand-in instead.
  static final Set<String> _failedAssets = {};

  /// The shared bake for [asset], loading it on first ask.
  ///
  /// Memoised by asset: repeat callers get the SAME future, so twenty parts
  /// sharing one export queue one load between them.
  static Future<(fsb.SceneDocument, fsb.ResourceRealizer)> bake(String asset) =>
      _bakes.putIfAbsent(asset, () {
        final done = _bakeChain.then((_) => _loadBake(asset));
        // The chain must survive a failed load, or one missing asset stops
        // every bake queued behind it.
        _bakeChain = done.then((_) {}, onError: (Object _) {});
        return done;
      });

  /// A FRESH node graph for [asset], off the shared bake.
  ///
  /// Every instance needs its own graph — a [fs.Node] cannot be parented twice
  /// — but the parse and the GPU resources are the cache's, so this is
  /// milliseconds even for a bake that took a minute to load.
  ///
  /// The caller owns what comes back and must re-check its own state before
  /// parenting it: a craft can stage, be destroyed, or change draw path while
  /// this is in flight. A graph that arrives too late is dropped unparented
  /// (never disposed inline — see the web `Vertices`/`ImageShader` trap).
  static Future<fs.Node> realize(String asset) =>
      bake(asset).then((b) => fsb.realizeSceneAsync(b.$1, resources: b.$2));

  /// Whether [asset] has already failed to load. Callers check this before
  /// asking, so a broken or absent bake is attempted once and then stands in
  /// procedurally forever.
  static bool hasFailed(String asset) => _failedAssets.contains(asset);

  /// Record that [asset] could not be loaded, so nothing hammers it again.
  static void markFailed(String asset) => _failedAssets.add(asset);

  /// Start loading [assets] in the background, IN THE GIVEN ORDER, so a later
  /// screen only realizes node graphs from the cache (~ms) instead of paying
  /// parse + texture transcode at the moment its scene appears.
  ///
  /// The order is the caller's policy and this honours it exactly: [_bakeChain]
  /// runs the loads strictly in sequence, so whatever is first is warm first.
  ///
  /// No-op on WEB: `compute` runs same-isolate there, so prewarming would
  /// freeze the UI for the exact cost it is trying to hide. (Web ships no part
  /// bakes to warm either — see `PartModelLibrary.assetFor`.)
  static void prewarm(Iterable<String> assets) {
    if (kIsWeb) return;
    for (final asset in assets) {
      bake(asset).then((_) {}, onError: (Object e) {
        markFailed(asset);
        // ignore: avoid_print
        print('craft model prewarm failed ($asset): $e');
      });
    }
  }

  /// Loads + parses + GPU-preloads one bake. The container parse runs in a
  /// background isolate (`compute`); the document is pure data, so it crosses
  /// back via `Isolate.exit` without a copy. `preload` transcodes each KTX2
  /// texture in its own isolate and only uploads on this one. After a first
  /// throwaway realize (which memoizes geometry into the realizer), the payload
  /// bytes are dropped — they otherwise pin the whole container's decoded bytes
  /// in the heap for the life of the cache.
  static Future<(fsb.SceneDocument, fsb.ResourceRealizer)> _loadBake(
      String asset) async {
    final sw = Stopwatch()..start();
    final data = await rootBundle.load(asset);
    debugPrint('craftBake $asset: bundle ${sw.elapsedMilliseconds}ms');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final doc = await compute(fsb.readFsceneb, bytes, debugLabel: 'parse $asset');
    debugPrint('craftBake $asset: parsed ${sw.elapsedMilliseconds}ms');
    final realizer = fsb.ResourceRealizer(doc);
    await realizer.preload();
    debugPrint('craftBake $asset: preloaded ${sw.elapsedMilliseconds}ms');
    await fsb.realizeSceneAsync(doc, resources: realizer);
    for (final p in doc.payloads.values) {
      p.bytes = null;
    }
    debugPrint('craftBake $asset ready in ${sw.elapsedMilliseconds}ms');
    return (doc, realizer);
  }
}
