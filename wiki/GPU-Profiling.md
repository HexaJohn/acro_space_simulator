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

Numbers on 2026-09-05 for the 127k-building colony at 1320 m: static 9.3 ms
(107 fps), warm orbit 9-11 ms, from 56 ms / 18 fps at the start of the work.
