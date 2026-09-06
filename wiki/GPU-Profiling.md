# GPU Profiling

How to find out where a frame's GPU time actually goes. The city studio's
panel answers this from inside the app as far as the platform allows; past
that point you need an external capture. Both workflows below.

## What the in-app panel can and cannot see

The studio's frame panel (`city_studio_screen.dart`) reports three layers:

| Row | What it measures | Thread |
| --- | --- | --- |
| `terrain` / `city` + sub-rows | Stopwatches around our own update code | UI |
| `ui build` | The engine's whole frame build (`FrameTiming.buildDuration`) | UI |
| `raster` | Encode + submit + driver (`FrameTiming.rasterDuration`) | Raster |
| `scene draws` | Census of the scene graph: one draw per mesh primitive, one per instanced mesh | — |
| `unaccounted` | Frame average minus our stopwatches | — |

The backend on Windows is Impeller on GLES via ANGLE (which itself sits on
D3D11). **There is no GPU timestamp query exposed through flutter_gpu**, so no
in-app number is "milliseconds the GPU spent on pass X". The honest signals
you do get:

- `raster` far above the CPU phase rows → the frame is GPU/driver-bound.
- A/B with the ISOLATE switches (Terrain / City / Shadows / Atmosphere):
  the frame-time delta when a layer is off is that layer's true cost,
  GPU included. This is the fastest attribution tool in the app.
- `scene draws` is what the colour pass submits. Shadow cascades re-draw
  every caster per cascade on top of it (2 cascades in the studio), so the
  real submission count with shadows on is roughly `draws × (1 + cascades)`.

## Flutter DevTools: raster thread timeline

`fvm flutter run -d windows --profile`, then open DevTools → Performance.

- The frame chart splits UI vs Raster per frame — jank shows which side.
- The timeline's raster track carries Impeller's own trace events, so you
  can see the render-pass structure and roughly where raster time pools.
- Run in **profile** mode for believable numbers; debug mode inflates the
  UI thread and shifts the balance.

## RenderDoc: the real per-draw story

ANGLE translates our GLES stream to D3D11, and RenderDoc captures that
D3D11 stream — every draw, every state change, and per-draw GPU durations
on replay.

1. Build: `fvm flutter build windows --profile` (debug also works).
2. RenderDoc → Launch Application →
   `build/windows/x64/runner/Profile/acro_space_simulator.exe`.
   Leave "capture child processes" on.
3. F12 captures a frame. Expect the D3D11 API (that is ANGLE underneath —
   you will see our GLES calls translated, not raw GL).
4. Open the capture → Event Browser → enable duration columns
   (clock icon). Now every draw has a GPU time. The passes read in order:
   shadow cascades first (if on), then the colour pass — terrain chunks,
   city batches, atmosphere shells last (big fullscreen-ish triangles with
   an expensive fragment: that is the Nishita raymarch).
5. Texture Viewer on any draw shows what it wrote — the fastest way to see
   which pass is burning fill (atmosphere and patch/road/walk overdraw are
   the usual suspects).

PIX for Windows works the same way on the same D3D11 layer if you prefer
its occupancy/counter views; RenderDoc is the easier first stop.

## Reading the numbers

- **Draw-bound** (frame scales with `scene draws`, individual draws cheap):
  coarser archetype buckets, fewer variants, shorter Block range, shadows
  off — anything that removes submissions.
- **Fill-bound** (few draws own most of the GPU time in RenderDoc —
  atmosphere shell, terrain chunks near the camera): cheaper fragments or
  less overdraw, not fewer draws.
- **CPU-bound** (`raster` small, our phase rows big): the panel's existing
  sub-rows already name the culprit; RenderDoc will not help.

## Scripted measurement (the regression gate)

Three tools drive a running `main_city_studio_dev` over the VM service
(`fvm flutter run -d windows --profile -t lib/main_city_studio_dev.dart
--enable-impeller --enable-flutter-gpu` prints the URI):

- `dart run tool/city_perf_ab.dart <uri> --sweep --assert=static:12,sweep:16,worst:33`
  generates the colony, waits for the tile queue to drain (sampling straight
  after the generator returns measures the streaming, not the frame), parks
  the camera, samples the panel and the engine's encoded-draw stats, flips
  shadows / atmosphere / the panel one at a time for their deltas, then
  drives the camera: a cold orbit, a warm orbit, an elevation nod and a
  zoom, each reporting average frame, worst frame, deepest build queue and
  governor level. `--assert` exits 1 past a threshold, so the run gates a
  change. Pans and orbits are where regressions have hidden before — a
  static sample never sees a rebuild the camera causes.
- `dart run tool/profile_ui_thread.dart <uri> 6` samples the UI isolate's
  CPU profile and prints the hottest leaves.
- `dart run tool/frame_spikes.dart <uri> 10 14` records the VM timeline and
  names every frame over the threshold with what ran inside it (build,
  paint, collections, engine spans), the scavenge count and cost, the
  window's allocations by class, and the live counts of native-backed
  classes. `--shadows=false`, `--perf=false`, `--distance=` and the other
  dev-hook parameters apply before recording.

Numbers on 2026-09-06 for the 127k-building colony at 1320 m, from 56 ms /
18 fps at the start of the work, UI-thread build (the display was
vsync-paced, so frame time read 16.7 whatever the work cost): static 8.0 ms
(encoded colour 290, shadow 125, 630 draws), warm orbit 11.1, elevation nod
8.8, zoom 10.7, walking at street level 12.0, running 11.8, driving the
buggy 13.6, cold orbit over unbuilt ground 12.7. The worst frames past a
pattern's start are 33-67 ms, an old-generation sweep while tiles land
(its longest span 62-78 ms); on 2026-09-05 they were 108-112 ms, mostly
ProcessWeakHandles finalising the replaced tiles' GPU buffers, since taken
by the buffer pool and the tier cache. One stall remains apart: ~350-480 ms
at the first camera move after generation (see the matrix below).

Two collector facts worth knowing before touching this again. Every frame's
command buffers and render passes are native objects with no dispose API, and
their finalizers run inside the scavenge; a scene that allocates little
scavenged every seventy frames and paid 9-12 ms for all of them at once, so
the fork's `Scene.collectorPacerBytesPerFrame` turns over two megabytes of
small chunks a frame to keep scavenges every dozen frames and ~4 ms. And the
GLES backend uploads a buffer's whole backing store at the geometry's first
draw, not as it is written, which is why tile geometry is chunked
(`CityTileMesher.maxGroupBytes`) and revealed a chunk a frame
(`CityNodes.uploadBytesPerFrame`) instead of staged in slices.

### The knobs, and A/B runs without a rebuild

Every performance trade-off is a static read each frame by the code that
owns it, and `PerfKnobs` (`lib/infrastructure/flutter_scene/perf_knobs.dart`)
lists them by name with a one-line explainer of what each trades: the tier
cache and buffer pool budgets, the chunk cap, the upload bytes per frame,
the collector pacer, the detail layer, the frame budget and its target,
and the budget's two judgement rules. The studio's PERF section is built
from that table, the status map carries every value under `knobs`, and the
dev hook takes `ext.acro.citystudio?knob=<name>&value=<v>`. The sweep takes
`--knob=name=value,name=value` and the gate script `-Knob "name=value"`, so
one build A/Bs any of them:

    powershell -File tool/measure_city_studio.ps1 -Tag pacer0 -Knob "pacerMiBPerFrame=0"
    powershell -File tool/measure_city_studio.ps1 -Tag nobudget -Knob "frameBudget=0"

Each sweep pattern also prints why tiles queued (`phaseCount['queued.*']`:
`first` for a tile never keyed — a cold orbit builds the tiles the hidden
policy never built behind the camera — `tier`, `structure`, `invalidation`,
`stale`, and `answered` for a build the tier cache handed back), the frame
budget's overruns, fixed overruns and stalls over the pattern, its average
slice, and the studio's phase averages, so a slow queue is attributed
rather than guessed at.

The frame budget (`FrameBudget`, `frame_budget.dart`) is the hard limit on
deferrable work: slice = target − (engine encode + learned overhead) −
margin, halved when the streamers spent past their slice and recovered
half a millisecond a frame. Two rules keep it honest, both knobs: a frame
that ran `stallMs` past what its parts explain is a collector pause and is
neither halved for nor learned from (`stalls`), and a long frame the
streamers did not spend lifts the overhead — the room shrinks in
proportion — instead of halving the ceiling (`judgeBySpend`). The first cut
had neither, and an orbit with one scavenge frame in two ran the slice at
its floor while ninety tiles waited.

One measurement trap: the driver's own service calls at the start of a
pattern (opening the timeline stream flushes the recorder's ring, the
allocation profile walks the heap) stall the isolate for up to half a
second, and the panel's worst-of-ninety reported it as the pattern's worst
frame for a whole evening. The windows are reset after those calls have
passed, and the timeline's own worst frame (past its first three seconds)
is printed beside the panel's.

### The overnight A/B matrix (2026-09-06, reference colony at 1320 m)

UI-thread build averages in milliseconds per sweep pattern, one gate run
per arm on the same build (`-Knob` flips the arm before the colony is
generated); the display was vsync-paced, so frame time read 16.7
whatever the work cost and only the UI thread tells. "Worst" is the
panel's worst frame past the pattern's start.

| arm | static | cold orbit | warm orbit | nod | zoom | walk | run | drive | worst (warm/nod/zoom/walk) |
|---|---|---|---|---|---|---|---|---|---|
| defaults (pacer 2 MiB, budget on) | 8.4 | 14.5 (queue 86) | 13.4 (queue 48) | 9.6 | 11.5 | 12.4 | 11.5 | 13.5 | 50 / 33 / 67 / 67 |
| pacer off | 7.7 | 12.5 (84) | 10.5 (2) | 8.4 | 10.2 | 11.9 | 11.6 | 13.6 | 50 / 33 / 50 / 50 |
| budget off | 8.4 | 13.9 (82) | 11.2 (1) | 9.5 | 11.1 | 12.2 | 12.1 | 13.3 | 50 / 33 / 50 / 50 |
| pacer 2 MiB following the slice, submit out of the spend | 8.4 | 13.4 (85) | 11.6 (5) | 9.3 | 11.7 | 12.5 | 12.1 | 13.4 | 50 / 50 / 50 / 67 |
| **shipped**: pacer 1 MiB following the slice | 8.0 | 12.7 (82) | 11.1 (2) | 8.8 | 10.7 | 12.0 | 11.8 | 13.6 | 50 / 33 / 50 / 50 |

What the matrix said. The pacer's two megabytes a frame cost an orbit
three milliseconds and doubled its old-generation spans (3511 vs 1636 in
the warm orbit): 120 MB/s of allocation feeds the collector's
old-generation trigger, and the incremental marking lands on the UI
thread. The budget as first tuned throttled the streamers so hard in the
cold orbit that the warm orbit inherited half its queue, and budget off
beat budget on in every pattern. Both are answered by the same signal:
the pacer now follows the budget's slice (full in a static frame, gone in
a loaded one) and the unsliceable tile submission is subtracted from the
streamers' spend before the budget judges it.

The cold orbit's panel worst (370-480 ms) is one stall at the first
camera move after generation — a raster-thread
`RenderPassGLES::EncodeCommandsInReactor` of ~530 ms and an 87 ms UI
build on that frame — present with the pacer off and the budget off
alike, and absent from every later pattern. It is not the tile-landing
spike; that one is now the 33-67 ms old-generation sweep the other
columns show.

The pacer's static side, from `tool/frame_spikes.dart` over 12 s windows
(~720 frames) with the pacer following the slice (a static slice of ~7
runs it at ~0.8 of the knob):

| pacer knob | frames over 16.7 ms | scavenges | scavenge avg / max | static ui |
|---|---|---|---|---|
| 0 | 4 | 23 | 7.3 / 11.4 ms | 7.8 |
| 0.5 MiB | 2 | 26 | 6.6 / 11.8 ms | 8.0 |
| 1 MiB (default) | 1 | 31 | 5.3 / 8.0 ms | 8.4 |
| 2 MiB | 1 | 43 | 3.8 / 5.5 ms | 8.1 |

So the default is one megabyte following the slice: a static frame keeps
its small scavenges (one dropped frame in twelve seconds against four
without), and a loaded frame — where the slice falls toward the floor —
runs the pacer at nothing, which is where its three milliseconds an
orbit frame went.
