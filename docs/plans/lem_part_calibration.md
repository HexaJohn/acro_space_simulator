# LEM part art calibration

What the seven Apollo Lunar Module exports actually look like once baked, how
each one's `modelRotation`, `modelScale` and `modelOffset` in
`lib/domain/parts/lem_parts.dart` were settled, and which one is still open.

Every number below was read off a **render**, not off a file. A part's art can
only be judged against something of known size, so each export was put alone on
the craft origin with the body-frame metre ruler switched on and photographed.

The images are named in each per-part section and live in
`test_out/part_calibration/`, which `.gitignore` excludes — as it must, since
they are frames of licensed art that is itself not redistributable (the `.glb`
sources and their `.fsceneb` bakes are excluded for the same reason). They are
therefore LOCAL artifacts: a fresh clone will not have them, and the way to get
them back is to re-run the captures, which is what "Re-running this" at the
bottom is for. Every filename cited below is exactly what that procedure writes.

## The bench

`lib/main_part_calibration_dev.dart` is a dev entrypoint that flies one craft
whose part list is whatever you ask for. It exists because the ruler
(`VesselNodes.showAxes`: three 1-metre-ticked shafts, X red, Y green, Z blue)
is drawn at the **craft origin**, so the part being measured has to *be* at the
craft origin — which no real craft's layout will do on request, and which
`main_scene_dev.dart` cannot arrange because its vessels' part lists are fixed
at construction. The bench swaps the craft's parts instead; the renderer treats
that as a staging event and rebuilds the art on the next frame, so the camera
stays framed across a whole sweep.

```
.fvm\flutter_sdk\bin\flutter.bat run -d windows --enable-impeller \
    --enable-flutter-gpu -t lib/main_part_calibration_dev.dart
```

Drive it over the VM service. `flutter run` prints the URI; registered
extensions are called by their own name, with the main isolate's id:

```
GET http://127.0.0.1:<port>/<auth>/getVM                    -> isolates[0].id
GET http://127.0.0.1:<port>/<auth>/ext.acro.bench?isolateId=<id>&show=eagle-legs
GET http://127.0.0.1:<port>/<auth>/ext.acro.camera?isolateId=<id>&axes=true&rangeM=9
GET http://127.0.0.1:<port>/<auth>/ext.acro.screenshot?isolateId=<id>&path=out.png
```

`ext.acro.bench?show=` takes `all`, a single id, a comma-separated list (laid
out in a row along body +X at `spacingM`), or ids carrying an explicit
`id@x:y:z` placement in metres — which is how the assembly shots below were
staged. `ext.acro.camera` carries the same part-calibration knobs as
`main_scene_dev.dart` (`part=`, `partScale=`, `partRotDeg=`, `partOffsetM=`,
`partScaleAll=`, `partReset=`) and every reply reports `partCalibration`, the
overrides in force as pasteable Dart. **The sweep is over when those literals
are in the catalog and that map is empty again**, which is the state the final
shots below were taken in.

## How a measurement was taken

Two facts make the images metric:

- **The screen centre is the part origin.** The camera locks onto the bench
  craft's position, which is the craft body origin, and the first part named
  sits there. In a 1264 x 681 capture that is pixel (632, 340).
- **Scale follows from the range.** The camera is 75 degrees vertical FOV, so
  `px/m = 681 / (2 * rangeM * tan(37.5deg))` at the focus plane — 55.4 px/m at
  `rangeM=8`, 37.0 at 12, 277 at 1.6. The ruler's 1-metre ticks confirm it in
  the frame, which is what makes the number trustworthy rather than assumed.

One systematic error to keep in mind when reading these numbers back: features
displaced **toward the camera** are magnified by `range / (range - depth)`. It
is why the descent stage's silhouette measures 2.94 m tall at `rangeM=8` and
2.57 m at 12 — the near corner of the octagon, 2.4 m closer than the axis, in
both cases. Lateral extents at the focus depth (a bell's width, a leg's span)
carry no such error, so the scale checks below are all lateral ones.

## Result

| part | modelRotation | modelScale | modelOffset (m) |
|------|---------------|-----------|-----------------|
| `eagle-command-pod`     | identity | 2.40 | `(0, 0, -1.4)` |
| `eagle-fuel-tank`       | identity | 2.40 | `(0, 0, -1.12)` |
| `eagle-thruster`        | identity | 2.40 | `(0, 0, 0.37)` |
| `eagle-legs`            | `Quaternion(0.5, 0.5, 0.5, 0.5)` | 2.40 | `(-1.26, 0, 0.59)` |
| `eagle-rcs-block`       | `axisAngle(unitX, pi/2)` | 2.40 | zero |
| `eagle-rcs-solo`        | identity | 2.40 | `(0, 0, -0.11)` |
| `eagle-rcs-blast-flute` | **UNSETTLED** — left identity | 2.40 | zero |

**Scale 2.40 is confirmed, not assumed.** Two independent lateral measurements:
the descent engine's bell measures **1.49 m** across against the published
1.50 m DPS exit diameter, and a corrected landing leg's drawn box is
**2.68 x 2.34 x 3.29 m** against the 2.54 x 2.37 x 3.22 m the catalog declares
from the same export. Nothing in any render argued for 1.7 or for a per-part
literal.

### The assembled check

*Images: `assembly_az0.png`, `assembly_34.png`, `roster_settled.png`.*

Single parts can each be right and still not fit together, so the settled values
were re-shot on a **mated stack** — descent stage, ascent stage, descent engine
and one landing gear leg, each at the position its own attach nodes put it (the
arithmetic is at the bottom of this file). The app was restarted first so the
catalog itself supplies every number: `ext.acro.camera` reports
`partCalibration: {}` in these frames, i.e. **no override is in force**.

It reads as a Lunar Module. The ascent stage nests down into the descent stage's
deck with no gap and no interpenetration; the engine bell protrudes below the
base plane and nothing else does; the leg's outrigger meets the stage's side and
its footpad lands **0.18 m** below the bell mouth, against the 0.39 m clearance
`lem_parts.dart` cites for the flown vehicle. A wrong `modelScale` would have
shown here as meshes floating out of their mates by the ratio of the error, and
a wrong `modelOffset` as a stage sunk into or hovering over its neighbour.
Neither is present.

**The bounding-box inference in the brief was wrong about the descent stage.**
It read `eagle_fuel_tank`'s accessor bounds (X 2.0217, Y 2.0002, Z 0.9581) as
symmetric about Z, concluded the export was already Z-up, and predicted the
renderer's +90-degree X fix would tip the stage onto its side needing a -90 to
cancel. It does not. `tank_r12_top_identity.png` is a nadir view of the part at
**identity** rotation and shows a clean, face-on regular octagon — the deck,
seen from directly above, which is only possible if the stage's axis is already
on body +Z. Applying the predicted -90 would have laid the descent stage on its
side. This is the case for looking.

---

## eagle-command-pod — ascent stage

*Images: `pod_az0_el0.png`, `pod_az90_el0.png`, `pod_top.png`,
`pod_r12_az90.png`, `pod_off-1.8.png`, `pod_final.png`.*

**Rotation: identity, confirmed.** At `az=90` the export shows the overhead
docking tunnel and its drogue on **+Z**, the cabin's two triangular windows and
the flagged hatch facing the camera, the S-band steerable antenna above and
outboard, and the porch and ladder hanging below. That is the vehicle the right
way up under the renderer's standard glTF Y-up fix alone. No correction.

**Offset: `(0, 0, -1.4)`.** At identity the ascent structure photographs
entirely above the origin. Note the export also carries the **ladder and
porch**, which hang well below the ascent stage proper and make the raw
bounding box much taller than the part — the seat was measured against the
*structure* (base skirt to cabin roof, which is what `size.z = 3.46` describes),
not the box. With `-1.4` applied (`pod_final.png`, `rangeM=8`, 55.4 px/m) the
base lands at **Z = -1.75 m** against the `stage-bottom` node at -1.73, and the
cabin roof at **+1.90** against `dock-top` at +1.73. The 0.17 m at the top is
the export being 3.65 m base-to-roof where the catalog declares 3.46.

## eagle-fuel-tank — descent stage

*Images: `tank_r12_az90_identity.png`, `tank_r12_top_identity.png`,
`tank_az90_offset.png`, `tank_final.png`.*

**Rotation: identity, confirmed — see the correction above.** The nadir view at
identity frames the octagonal deck face-on. The side view shows a squat
octagonal box 4.84 m across, matching the export's own 2.0217 model units at
2.40 m/unit (4.85 m).

**Offset: `(0, 0, -1.12)`.** Measured twice: the mesh centred +1.46 m above the
origin at `rangeM=12` before correction, and after applying `-1.46` it centred
0.34 m *below* — the difference being the near-face magnification described
above. The value that lands it centred is `-1.12`, verified in `tank_final.png`
(top +1.53, bottom -1.41 at `rangeM=8`, i.e. centred to within 0.06 m).

## eagle-thruster — descent engine (DPS)

*Images: `eagle-thruster_r8_az90_identity.png`, `thruster_az90_offset.png`.*

**Rotation: identity, confirmed.** The bell mouth flares **downward (-Z)**,
which is where an engine's exhaust has to go, with the narrow throat up toward
the mount. Nothing to correct.

**Offset: `(0, 0, 0.37)` — the only part of the seven that hangs LOW.** At
identity the bell occupies Z 0.00 to -0.74; the catalog anchors it centred, with
its `mount` node at +0.39 on the top of the bell. With `+0.37` applied
(`thruster_az90_offset.png`, `rangeM=4`) the bell spans **+0.43 to -0.41**,
centred on the origin, top within 0.04 m of the mount node.

**This is also the family's scale witness.** The bell photographs **1.49 m**
wide at the focus depth against the published 1.50 m DPS exit diameter.

## eagle-legs — landing gear leg

*Images: `eagle-legs_r8_az90_identity.png`, `legs_az0_identity.png`,
`legs_34_identity.png`, `legs_34_rot180_0_-90.png`, `legs_az0_rot180_0_-90.png`,
`legs_az0_rot90_0_90.png`, `legs_az90_rot90_0_90.png`,
`legs_az0_rot90_0_90_off.png`.*

**Rotation: `Quaternion(0.5, 0.5, 0.5, 0.5)` — an axis CYCLE, not a quarter
turn.** At identity the footpad photographs roughly 2 m **above** the origin
and off along -Y: the leg reaches up and sideways instead of down and outward.
The correction is the 120-degree rotation about (1,1,1) that sends
X -> Y -> Z -> X, i.e. `partRotDeg=90,0,90`. No single quarter turn does this,
which is why the first candidate tried (`partRotDeg=180,0,-90`,
`legs_az0_rot180_0_-90.png`) put the footpad in the right *direction* while
leaving the leg rolled 90 degrees about its own reach — its drawn box came out
3.39 m radially by 2.31 m vertically where the catalog declares 2.54 by 3.22,
the two swapped. With the cycle applied the box measures
**2.68 x 2.34 x 3.29 m** against the declared **2.54 x 2.37 x 3.22 m**, the
best agreement any of the seven reaches.

The pose is right for the reasons a leg should look right, not only by the
numbers: at `az=0` (radial in the screen plane) the primary strut runs from the
inboard top corner down and out to the footpad with the secondary struts edge-on
beneath it; at `az=90` (looking down the radial axis) the leg is symmetric about
the vertical with the footpad centred below and the secondaries splayed
laterally.

**Offset: `(-1.26, 0, 0.59)`.** Centres that box on the part origin. Verified in
`legs_az0_rot90_0_90_off.png`: the outrigger pickup lands at
**(-1.16, ~0, +1.66)** against the `outrigger` attach node at
(-1.27, 0, +1.61) — within 0.11 m without ever being fitted to it.

## eagle-rcs-block — RCS quad

*Images: `eagle-rcs-block_az90_identity.png`, `block_az0_identity_noaxes.png`,
`block_az90_identity_noaxes.png`, `block_34_identity_noaxes.png`,
`block_az90_rot90_0_0.png`, `block_az0_rot90_0_0.png`,
`block_top_rot90_0_0.png`.*

**Rotation: a quarter turn about X (`partRotDeg=90,0,0`).** At identity the
up-and-down-firing thruster pair lies along the part's **Y**, photographing
**1.01 m** tip to tip at `rangeM=1.6` — which is exactly the 1.00 m the catalog
declares as `size.z` and describes as "+Z along the up/down thruster pair". With
the quarter turn that pair stands on **±0.51 m of Z** (`block_az90_rot90_0_0.png`)
and the cluster is already centred on the origin, so **no offset**.

**What is NOT settled here: the remaining spin about Z.** The quad's two
horizontal bells are opposed along a diagonal of the part's X-Y plane, so which
way they face relative to the hull is a further 45-degree-family choice. Nothing
in `lem_parts.dart` states it, and one part in isolation cannot show it — the
hull it stands off from is not in the frame. Check it on an **assembled ascent
stage**, where a bell firing into the skin is unmistakable, and correct by
adding a `partRotDeg=90,0,<yaw>` sweep. Recorded as a comment on the part.

## eagle-rcs-solo — R-4D thruster

*Images: `eagle-rcs-solo_az90_zoom.png`, `solo_az0_identity.png`,
`solo_final.png`.*

**Rotation: identity, confirmed.** The exit bell flares **up (+Z)** with the
mount neck at -Z, matching this part's declared local frame exactly. Measured
0.16 m across the bell (catalog 0.15) and 0.225 m long (catalog 0.22) — a third
independent confirmation of 2.40.

**Offset: `(0, 0, -0.11)`.** At identity the whole thruster stands above the
origin, spanning Z 0.00 to +0.23. Half its own length brings it back onto the
mount face; `solo_final.png` shows it spanning **+0.117 to -0.113**.

Note this part is smaller than the ruler's own 0.4 m origin cube, which hides it
completely at close range. Shoot it with `axes=false` and rely on the screen
centre being the origin.

## eagle-rcs-blast-flute — plume deflector: UNSETTLED

*Images: `eagle-rcs-blast-flute_az90_identity.png`, `flute_az0_identity.png`,
`flute_az90_identity.png`.*

Left at identity rotation and zero offset **deliberately**, because there is
nothing to settle it against yet.

What the render shows: a curved shell carried on a two-leg truss. The truss feet
do land on **-X** with the shell standing off at **+X** and up, which is what
this part's local frame asks for (its `mount` node is at (-0.30, 0, 0) facing
-X), so identity is at least not obviously wrong. But the drawn box measures
**1.75 x 1.55 x 0.78 m** and the catalog declares **0.60 x 1.65 x 1.35** — no
permutation of the axes reconciles those, so there is no frame to rotate the
mesh *into*.

`lem_parts.dart` already flags this part as the lowest-confidence entry in the
file and its identification as provisional. **Settle what the part IS first**;
the orientation and the offset follow from that, not the other way round. If it
stays a deflector, the numbers to reconcile are its `size` against the box above.

---

## Re-running this

To re-check any row, or to settle the two open questions:

```
# 1. boot the bench
.fvm\flutter_sdk\bin\flutter.bat run -d windows --enable-impeller \
    --enable-flutter-gpu -t lib/main_part_calibration_dev.dart
#    wait for "craftBake <asset> ready in" for each bake you need
#    (~32 s each in a debug build, loaded strictly in sequence)

# 2. one part, on the ruler
ext.acro.bench?show=eagle-rcs-blast-flute
ext.acro.camera?axes=true&rangeM=3&azimuthDeg=0&elevationDeg=0&rollDeg=0
ext.acro.screenshot?path=test_out/part_calibration/flute_az0.png

# 3. sweep. az=0 is +X right / +Y into screen / +Z up; az=90 is +X into
#    screen / +Y left. Use both — a displacement along +X and one along -Y
#    look identical at az=45.
ext.acro.camera?part=eagle-rcs-blast-flute&partRotDeg=0,0,90
ext.acro.camera?part=eagle-rcs-blast-flute&partOffsetM=0,0.35,-0.34

# 4. paste the reply's partCalibration literals into lem_parts.dart, restart,
#    and confirm the map comes back empty with the render unchanged.
ext.acro.camera
```

For the quad's yaw, stage an assembly instead of a single part — the bench
places parts at explicit body-frame positions, so the mated stack is one call:

```
ext.acro.bench?show=eagle-fuel-tank@0:0:0,eagle-command-pod@0:0:2.54,\
eagle-thruster@0:0:-1.54,eagle-legs@3.38:0:-0.71
```

Those four positions are the attach nodes' own arithmetic: the descent stage's
`deck-top` (+0.81) against the pod's `stage-bottom` (-1.73) puts the pod origin
at +2.54; `engine-mount` (-1.15) against the engine's `mount` (+0.39) puts it at
-1.54; `leg-1` (2.11, 0, 0.90) against the leg's `outrigger` (-1.27, 0, 1.61)
puts that leg at (3.38, 0, -0.71).

## Guard

`test/parts/lem_part_orientation_test.dart` pins the results above as
**geometry**, not as literals: it rotates basis vectors through each
`modelRotation` and asserts where they land, so an edit that changes a
quaternion without changing the pose passes and one that changes the pose fails.
It also holds the family to one `modelScale`, keeps every correction on the unit
sphere, bounds a seat by the part it seats, and asserts that the seat never
reaches the docking port or the attach nodes — the art-only invariant.
