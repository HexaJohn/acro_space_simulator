// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The frame's hard budget for DEFERRABLE work, and the pure derivations
/// that turn it into the streamers' per-frame knobs.
///
/// The colony's tiles and the ground's chunks are built, uploaded and
/// revealed a step at a time under fixed per-frame caps — nine
/// milliseconds of tile building, four chunk uploads — that were tuned
/// against a static frame. They do not know what the REST of the frame
/// costs: the engine's own encode of the scene (the shadow cascades, the
/// colour pass, both on the UI thread inside the painter), the widget
/// tree, the walker's ground samples. Walking at street level, with fifty
/// tiles queued and the engine at three milliseconds, the same nine
/// milliseconds of building made a 32-36 ms frame: the caps were right for
/// a frame with nothing else in it and wrong for every other frame.
///
/// [FrameBudget] closes the loop. It is fed what the frame actually cost
/// (the engine's measured build duration) and what its fixed parts will
/// cost this frame, and yields the slice the deferrable work may spend:
/// the target less the fixed cost less a margin. Then it adapts: a frame
/// that overran the target halves the next slice, and the slice recovers
/// half a millisecond a frame while the frames stay under — asymmetric on
/// purpose, so a spike is answered at once and the answer is withdrawn
/// slowly, and the slice does not oscillate about the line.
///
/// Pure: no clock, no engine, nothing but numbers in and a number out, so
/// the whole policy is tested without a frame. The screens own an
/// instance, feed it from their `FrameTiming` callback and the engine's
/// frame stats, and write the slice to the streamers' statics before their
/// updates run (see [CityFrameBudgets], [TerrainFrameBudgets]).
class FrameBudget {
  /// The A/B switch. Off, the slice reads [referenceSliceMs] whatever the
  /// inputs and [sliceForConsumers] is null, so the streamers keep their
  /// old fixed knobs exactly as they were.
  static bool enabled = true;

  /// The frame the budget aims for, milliseconds of UI build. Fifteen
  /// leaves ~1.7 ms under 60 Hz for what the timing callback does not see
  /// (the raster thread's own handoff, the vsync jitter).
  static double targetMs = 15.0;

  /// An overrun is the streamers' to answer only when the frame's parts
  /// explain it: the engine, what they reported spending, the learned
  /// overhead. A frame that ran this many milliseconds past all of them
  /// stalled on something else — the collector's old-generation pause
  /// under a landing, a safepoint waited on a worker — and halving the
  /// slice for it would answer a spike the streamers did not make and
  /// could not have avoided. Measured before this rule: an orbit with one
  /// collector frame in five kept the slice near its floor (avg 1.8 ms,
  /// min 0.5) and the queue never drained. Such a frame counts in
  /// [stalls], not [overruns]. Zero halves on every overrun.
  static double stallMs = 6.0;

  /// Whether an overrun is judged by what the streamers SPENT — theirs
  /// only when they spent past their slice by more than
  /// [spendToleranceMs] — or by the measured frame alone. The first cut
  /// judged by the frame, and halved the slice on every frame the engine,
  /// the widgets and a scavenge pushed past the target while the
  /// streamers sat at the floor: an orbit's slice averaged 1.8 ms with
  /// forty overruns a pattern and the streamers explaining none of them.
  /// Under the spend rule such a frame still tells — its overhead sample
  /// lifts the fixed cost and the room shrinks with it, in proportion,
  /// not by halves — and the halving is kept for the case it fits: a
  /// step that ran past the slice its cost memory said it would fit.
  /// Off is the A/B's other arm.
  static bool judgeBySpend = true;
  static double spendToleranceMs = 1.0;

  /// Whether the engine's collector pacer follows the slice (see
  /// [pacerScale]). The pacer turns over megabytes a frame so scavenges
  /// come small and often; that turnover is a tax — the allocation, the
  /// scavenges it hastens, the old-generation cycles it triggers — and a
  /// loaded frame cannot afford it. Measured on the reference colony with
  /// the pacer at its full two megabytes against none: warm orbit 13.4 vs
  /// 10.5 ms of UI build, cold orbit 14.5 vs 12.5, and twice the
  /// old-generation spans; static 8.4 vs 7.7. But a static frame without
  /// it pays 9-12 ms every seventy frames (the passes' finalizers at
  /// once), so the pacer stays on where there is room: scaled by the
  /// slice's ratio to the reference, full at a slice of nine and gone at
  /// the floor. Off, the pacer runs at its knob whatever the frame.
  static bool pacerFollowsSlice = true;

  /// The factor the engine's pacer should run at this frame, 0..1: the
  /// slice against the reference when [pacerFollowsSlice] and the budget
  /// is on, else one.
  double get pacerScale {
    if (!enabled || !pacerFollowsSlice) return 1.0;
    final s = sliceMs / referenceSliceMs;
    return s < 0 ? 0.0 : (s > 1 ? 1.0 : s);
  }

  /// The slice the streamers' knobs were tuned at: the old fixed
  /// `CityNodes.buildBudgetMs`. The derived knobs scale against it, so at
  /// this slice the budgeted streamers behave exactly as they did before.
  static const double referenceSliceMs = 9.0;

  /// Held back from every slice, so a step that runs a little long under
  /// its own last-cost estimate still lands under the target.
  final double marginMs;

  /// The slice's floor and ceiling. The floor keeps the streamers moving —
  /// one step a frame, however busy the frame — and the ceiling is what a
  /// frame with nothing else in it may spend, a little over the reference
  /// so an empty frame builds faster than it used to.
  final double minSliceMs;
  final double maxSliceMs;

  /// The slice regained per frame under the target after an overrun.
  final double recoverMsPerFrame;

  /// The weight of a new overhead sample in the EMA. Small: the overhead
  /// is the frame's steady part, and one odd frame should not move it.
  final double overheadAlpha;

  FrameBudget({
    this.marginMs = 0.5,
    this.minSliceMs = 0.5,
    this.maxSliceMs = 12.0,
    this.recoverMsPerFrame = 0.5,
    this.overheadAlpha = 0.1,
  }) : _ceilingMs = maxSliceMs;

  /// The adaptive ceiling: halved by an overrun, recovered slowly. The
  /// slice is the lesser of this and what the fixed cost leaves.
  double _ceilingMs;

  /// The last measured build fed, not yet consumed by [beginFrame]. Each
  /// measured frame is judged ONCE: the timing callback runs a frame or
  /// two behind the ticker and sometimes delivers two frames at once, and
  /// a slice halved twice for one long frame would have been the
  /// oscillation this exists to avoid.
  double? _pendingBuildMs;

  /// The steady part of the frame the budget does not hand out: the
  /// widget tree, the walker, the screen's own bookkeeping. An EMA of the
  /// measured build less the engine's part and less what the deferrable
  /// work reported spending, so it settles on what is left over.
  double overheadMs = 0;

  /// The last inputs and output, for the panel and the status map.
  double lastBuildMs = 0;
  double engineMs = 0;
  double fixedMs = 0;
  double sliceMs = referenceSliceMs;

  /// Frames that measured over [targetMs] since construction and were
  /// the streamers' to answer (see [stallMs], [judgeBySpend]).
  int overruns = 0;

  /// Frames over the target that were neither a stall nor the streamers'
  /// spend: the fixed part grew, and the overhead answered it.
  int fixedOverruns = 0;

  /// Frames over the target that the frame's parts did not explain: not
  /// halved for (see [stallMs]).
  int stalls = 0;

  /// Frames budgeted since construction.
  int frames = 0;

  /// A measured UI build duration, milliseconds — `FrameTiming.buildDuration`
  /// as the engine reports it, a frame or two after the fact. The latest
  /// one fed before [beginFrame] is the one judged.
  void feed(double buildMs) {
    lastBuildMs = buildMs;
    _pendingBuildMs = buildMs;
  }

  /// The slice for the frame about to run, given [engineMs] — the engine's
  /// fixed cost of encoding this frame (its pre-pass, shadow and colour
  /// encode, all on this thread) — and [spentMs], what the deferrable work
  /// reported spending LAST frame; null assumes it spent the whole of last
  /// frame's slice, the conservative reading when the consumers do not
  /// report.
  double beginFrame({required double engineMs, double? spentMs}) {
    this.engineMs = engineMs;
    frames++;
    if (!enabled) {
      // Passthrough: the knobs' reference, and no adaptation — the ceiling
      // and the overhead are left where they were so switching back on
      // resumes, not restarts; but a frame measured while off is not
      // evidence about the budget, so it is dropped, not kept for the
      // first frame back on to halve against.
      _pendingBuildMs = null;
      sliceMs = referenceSliceMs;
      fixedMs = engineMs + overheadMs;
      return sliceMs;
    }
    final measured = _pendingBuildMs;
    _pendingBuildMs = null;
    if (measured != null) {
      // The overhead is what the last frame cost beyond its budgeted parts.
      // Clamped at zero: a frame that finished under its own slice is not
      // evidence of negative overhead.
      final budgeted = engineMs + (spentMs ?? sliceMs);
      final sample = measured - budgeted;
      // A stall (see [stallMs]) is judged against the overhead as it
      // stands, before this frame could teach it: the frame is neither
      // the streamers' overrun nor evidence about the steady overhead —
      // folded into the EMA, one collector pause would have cut the room
      // for the next ten frames as surely as a halving.
      final stalled = measured > targetMs &&
          stallMs > 0 &&
          measured - (budgeted + overheadMs) > stallMs;
      if (stalled) {
        stalls++;
      } else {
        overheadMs +=
            overheadAlpha * ((sample < 0 ? 0 : sample) - overheadMs);
        if (measured > targetMs) {
          // Last frame's spend against last frame's slice: [sliceMs] is
          // not recomputed until below.
          final theirs = !judgeBySpend ||
              spentMs == null ||
              spentMs > sliceMs + spendToleranceMs;
          if (theirs) {
            overruns++;
            _ceilingMs = _clamp(_ceilingMs / 2);
          } else {
            fixedOverruns++;
          }
        } else {
          _ceilingMs = _clamp(_ceilingMs + recoverMsPerFrame);
        }
      }
    }
    fixedMs = engineMs + overheadMs;
    final room = targetMs - fixedMs - marginMs;
    sliceMs = _clamp(room < _ceilingMs ? room : _ceilingMs);
    return sliceMs;
  }

  /// The slice as the streamers read it: null while the budget is off, so
  /// every consumer falls back to its old fixed knobs (see
  /// [CityFrameBudgets.forSlice], [TerrainFrameBudgets.forSlice]).
  double? get sliceForConsumers => enabled ? sliceMs : null;

  /// The adaptive ceiling now in force, for the panel.
  double get ceilingMs => _ceilingMs;

  double _clamp(double v) =>
      v < minSliceMs ? minSliceMs : (v > maxSliceMs ? maxSliceMs : v);

  /// The slice's ratio to the reference, clamped to what the knobs may
  /// scale by: a quarter at the least (the streamers keep moving on a busy
  /// frame) and never above what they were tuned at (a byte cap raised
  /// past the raster thread's tolerance would spike THERE, out of this
  /// thread's sight).
  static double scaleOf(double sliceMs,
      {double minScale = 0.25, double maxScale = 1.0}) {
    final s = sliceMs / referenceSliceMs;
    return s < minScale ? minScale : (s > maxScale ? maxScale : s);
  }
}

/// The colony streamer's three per-frame knobs, derived from a slice.
///
/// The build loop takes [buildShare] of the slice; its uploads get
/// [uploadShare] of the slice within that, never over [uploadCapMs] (the
/// old fixed cap, which the raster-side byte cap was tuned against); and
/// the bytes it may put in front of the GPU scale with the slice's ratio
/// to the reference (see [FrameBudget.scaleOf]).
class CityFrameBudgets {
  /// The build loop's share of the slice. The ground streamer gets the
  /// rest (see [TerrainFrameBudgets]); the traffic pass costs under a
  /// millisecond and is not budgeted.
  static double buildShare = 0.6;

  /// The uploads' share of the slice, and the most they may have.
  static double uploadShare = 0.3;
  static double uploadCapMs = 2.0;

  /// Whether the byte cap scales with the slice. Off by default: the cap
  /// is the RASTER thread's tolerance for first-draw uploads, not this
  /// thread's time, and the UI cost of moving the bytes is already under
  /// [uploadShare]. Scaled, a busy frame (a slice near the floor for a
  /// run of frames) cut the cap to a quarter and the reveals, which take
  /// the frame's bytes first, to an eighth: fifty-five tiles stood
  /// "revealing" seconds after a zoom settled, their old sets drawn
  /// beside their new chunks. The A/B's other arm keeps the scaling.
  static bool scaleBytes = false;

  final double buildMs;
  final double uploadMs;
  final int uploadBytes;

  const CityFrameBudgets({
    required this.buildMs,
    required this.uploadMs,
    required this.uploadBytes,
  });

  /// The knobs for [sliceMs], scaling [baseUploadBytes] (the byte cap as
  /// tuned at the reference slice). A null slice — the budget switched off
  /// — hands back the fixed knobs [buildMs]/[uploadMs]/[baseUploadBytes]
  /// untouched: the A/B's other arm.
  static CityFrameBudgets forSlice(
    double? sliceMs, {
    required double buildMs,
    required double uploadMs,
    required int baseUploadBytes,
  }) {
    if (sliceMs == null) {
      return CityFrameBudgets(
          buildMs: buildMs, uploadMs: uploadMs, uploadBytes: baseUploadBytes);
    }
    final upload = sliceMs * uploadShare;
    return CityFrameBudgets(
      buildMs: sliceMs * buildShare,
      uploadMs: upload < uploadCapMs ? upload : uploadCapMs,
      uploadBytes: scaleBytes
          ? (baseUploadBytes * FrameBudget.scaleOf(sliceMs)).round()
          : baseUploadBytes,
    );
  }

  @override
  String toString() => 'CityFrameBudgets(build ${buildMs.toStringAsFixed(2)} '
      'ms, upload ${uploadMs.toStringAsFixed(2)} ms, '
      '${uploadBytes ~/ 1024} KiB)';
}

/// The ground streamer's per-frame COUNTS, derived from a slice.
///
/// Terrain's knobs are counts — chunk uploads a frame, mesh jobs in
/// flight, batch rebuilds — not milliseconds, so they scale by the slice's
/// ratio to the reference (see [FrameBudget.scaleOf]), never below one:
/// a frame that uploads no chunk at all makes no progress, and the ground
/// under a moving craft must keep arriving. The selection cadence is left
/// alone; it is gated on the eye's motion already and a slower cadence
/// would leave the wrong chunks resident, not fewer.
class TerrainFrameBudgets {
  final int uploadsPerFrame;
  final int meshJobsInFlight;
  final int batchRebuildsPerFrame;

  const TerrainFrameBudgets({
    required this.uploadsPerFrame,
    required this.meshJobsInFlight,
    required this.batchRebuildsPerFrame,
  });

  /// The counts for [sliceMs], scaling the fixed knobs; a null slice hands
  /// them back untouched.
  static TerrainFrameBudgets forSlice(
    double? sliceMs, {
    required int uploadsPerFrame,
    required int meshJobsInFlight,
    required int batchRebuildsPerFrame,
  }) {
    if (sliceMs == null) {
      return TerrainFrameBudgets(
        uploadsPerFrame: uploadsPerFrame,
        meshJobsInFlight: meshJobsInFlight,
        batchRebuildsPerFrame: batchRebuildsPerFrame,
      );
    }
    final scale = FrameBudget.scaleOf(sliceMs);
    int scaled(int base) {
      final n = (base * scale).round();
      return n < 1 ? 1 : n;
    }

    return TerrainFrameBudgets(
      uploadsPerFrame: scaled(uploadsPerFrame),
      meshJobsInFlight: scaled(meshJobsInFlight),
      batchRebuildsPerFrame: scaled(batchRebuildsPerFrame),
    );
  }

  @override
  String toString() => 'TerrainFrameBudgets(uploads $uploadsPerFrame, '
      'jobs $meshJobsInFlight, rebuilds $batchRebuildsPerFrame)';
}
