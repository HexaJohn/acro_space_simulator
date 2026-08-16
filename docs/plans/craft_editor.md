# The Craft Editor (VAB)

**Status:** shipping. Reached from the main menu; `CraftAssemblyScreen` is the
shell, and LAUNCH hands the design to the existing `VesselAssembler`.

This is an orientation document, not a specification. It covers the decisions
you cannot recover by reading the code, and points at the code for the rest.

---

## 1. What it is

A 3D craft editor. You pick a part out of the catalog, aim at a marker on the
craft already on the pad, and click; the part is seated on that marker with its
own mating node, at the pose the attach solver computes. Ring symmetry places
several copies at once. Parts carry stage assignments, everything is undoable,
designs save and reload, and LAUNCH bakes the design into a `Vessel` and flies
it.

The viewport is `flutter_scene`; the camera is a turntable about the craft. Q/E
roll the held part, W/S cycle which of its nodes seats, 1/2/4 set the symmetry
count, M toggles mirror, Tab cycles between overlapping aim candidates. The 2D
overlay (`craft_editor_painter.dart`) draws the markers, the commitment ring and
the HUD on top.

**Units.** METRES everywhere in the domain and the editor. Craft body frame is
right-handed, Z-up, **+Z = nose**. The scene is KILOMETRES — `lengthToScene`
is the only conversion, applied at the renderer boundary and nowhere else.

---

## 2. The three decisions that shaped it

### Placement is onto authored attach nodes, and only onto them

There is no free placement, no snapping-to-surface, no drag-in-space. A part
mates node-to-node or it does not mate. `AttachTargets.pairingsFor` enumerates
the legal (parent node, child node) pairs, `AttachSolver.solveMate` produces the
pose, and the editor never invents a position of its own.

*Why:* the pose has to be reproducible from the saved design — the codec stores
the mate (`parentInstanceId`, `parentNode`, `childNode`, `roll`), not the
resulting transform — and it has to be the same pose the assembler bakes and the
renderer draws. Free placement would make the saved craft a list of float
triples that no later change to a part's geometry could ever correct, and would
put the editor in the business of deciding what "resting on" means. Authored
nodes make legality a property of the catalog: a part is buildable because
someone wrote a seat for it, and `attach_node_data_test.dart` can then assert
mechanically that every part in the roster reaches a mate.

*The cost:* a part with no seat is unusable and a part whose only seat is its own
root can host nothing. Both are catalog bugs, and both are now caught by test
rather than by a player.

### Symmetry is ring-based, not mirror-based

`setSymmetryCount(n)` places `n` copies, one per seat of the **authored ring**
the aimed node belongs to — `quad-1..quad-4`, `leg-1..leg-4`. It does not
reflect, and it does not synthesise node names.

*Why:* a reflected copy needs a node to land on, and inventing one (`quad-1` →
`quad-1-mirror`) produces a design that validates on the way out of the codec
and throws on the way back in — the craft is unloadable the first time anyone
saves it. Rings are already in the data: `AttachTargets.ringsOf` detects them
from the authored positions, so a symmetry set is always a set of real seats,
and `craftGhostPlan` can preview exactly what the commit will do because both
read the same `seatsFor` list.

*The consequence worth knowing:* every seat a ring expands to is legal by
construction, so there is no per-seat legality re-check on the commit path.
Mirror mode (`AttachSolver.mirrorMate`, M) is a separate thing and is a
*rotation* — a rotation cannot reflect, so a mirrored part comes out spun, not
handed. True handedness needs a mirrored mesh; see §5.

### The root sits at the origin and the pad tracks the craft's lowest point

`placeRoot` seats the root part's origin at craft z = 0, and every part authors
its box and its nodes symmetrically about its own origin — so a stack grows
*downward* from zero. The pad plane is then drawn at
`CraftEditorNodes.padPlaneZ` = the minimum z of the committed craft's bounds.

*Why:* the alternative — re-seating the craft so it rests on z = 0 — moves the
DOMAIN frame. `PlacedPart.position`, every solved mate, the codec's snapshots,
`CraftBalance`'s readouts and the assembler's bake all live in that frame, so
adding a landing leg at the bottom of a stack would have to rewrite every part
in the design *and every undo step* to hold the invariant. Moving the pad is one
bounds read per frame, is exact for any craft, and nothing has to move: add a
leg and the pad drops to meet it, delete it and the pad rises.

The pad tracks COMMITTED parts only, so a ghost dipping below it is the honest
picture of a part about to become the new lowest point.

---

## 3. The seams

Each of these is a place where two layers agree by convention rather than by
type, which is why each has a test that asserts a number about it.

| Seam | Held by |
|---|---|
| catalog `PartDef.id` → `Part.defId` → `PartSnapshot.type` → art | `part_model_binding_test.dart` |
| the whole chain, end to end | `craft_integration_test.dart` |
| the VAB's stand-in vs the flight view's stand-in | `PartPrimitivesByCategory.standInScaleM` — ONE definition, both renderers call it |
| authored ring data vs the ring detector | `craft_integration_test.dart` |
| design → JSON → design | `craft_design_codec_test.dart` |
| plume anchor vs the hull actually drawn | `kitbash_render_test.dart` |
| layering (`lib/domain` and `lib/adapters` import inward only) | `source_hygiene_test.dart` |

**The render branch is the sharpest of them.** `VesselNodes.isKitbash` decides
per frame whether a vessel is drawn from its PART LIST (one node per part) or as
ONE whole-craft model. The predicate is **provenance, not art**: true as soon as
one part came from the catalog, so a craft the player assembled is drawn as the
stack they assembled whether or not any of its parts has a bake yet. Everything
hand-built — the sample fleet, a spawned test mass — reports a display name the
catalog has never heard of and stays on the whole-craft model it was authored
and calibrated for. `part_model_binding_test.dart` asserts that the assembler
and the save codec are the *only* things in `lib/` that stamp a `defId`, which
is what makes that argument a property of the source rather than a coincidence.

---

## 4. What the stock roster actually looks like on screen

No stock part ships a baked model, and no part bake ships on web at all. What
you see is `PartPrimitivesByCategory`: a silhouette per part, resolved from the
id first and the `PartCategory` second, scaled so the DRAWN box equals
`PartDef.size` exactly. That last part matters — the primitives are not all unit
cubes (`PartPrimitives.slab` is 1.0 × 0.4 × 0.06 m), so the scale divides by the
mesh's own authored extent. It is also what makes the drawn silhouette equal the
oriented box `CraftEditorPick` hit-tests, so every pixel of a part is clickable
and nothing outside it is.

A stand-in is the FIRST FRAME of every part, not an error path.

---

## 5. Deliberately not done

- **Mirrored (handed) parts.** `mirrorMate` reflects the *seat*, then solves a
  rotation onto it. A wing seated on a hull's opposite ring therefore arrives
  spun half a turn about Z, carrying its underwing hardpoint to the other side
  of the craft. Rolling it back brings the pod under and takes the trailing edge
  forward. Both cannot be right from a rotation — this needs a mirrored MESH.
- **Per-part orientation over the wire.** `PartFrame` in `wire/sim.fbs` has no
  quaternion field, so a bridged renderer receives every part unrotated (four LM
  legs all facing the same way). In-process rendering never serialises and is
  correct. `part_frame_contract_test.dart` is a tripwire, not an endorsement:
  when `rot:Quat` lands, invert that test and delete both GAP notes.
- **Part rotation in the inertia tensor.** The assembler bakes rigid and its
  self-inertia box is axis-aligned, so `rotationInVessel` is carried for render
  and structure only and deliberately not fed into the tensor.
- **Three parts still ship the default 1 m cube:** `elevon` (which claims
  1.5 m² of control surface), `ramjet-sr71` (a J58 — 2,700 kg, ~5.7 m real) and
  `rl10`. They mate correctly; their silhouettes and inertia boxes are
  placeholders. Note before fixing `elevon`: its local +X becomes the *chord*
  when seated on a trailing edge and the *span* when seated on a hull ring, so
  which axis carries the length has to be decided first.
- **`jet-fuel-tank` ("Wing Fuel Tank") has no wing-root seat** — it reaches a
  wing only through `swept-wing.pod`, which hangs it under the panel rather than
  inline in it.
- **`docking-port-std.mount` carries the 1.25 m class on a surface seat** while
  every other radial fitting uses 0.30. Surface mates ignore class, so legality
  is unaffected; its berth marker just draws four times the size of a gear
  marker.

---

## 6. The part-calibration bench

Art is calibrated by eye against a ruler, not by arithmetic. `PartDef` carries
`modelScale`, `modelRotation` and `modelOffset`; the bench
(`lib/main_part_calibration_dev.dart`) is a dev entrypoint that flies one craft
whose part list is whatever you ask for, so the part being measured sits ON the
craft origin where `VesselNodes.showAxes` draws its 1-metre-ticked shafts.

```
.fvm\flutter_sdk\bin\flutter.bat run -d windows --enable-impeller \
    --enable-flutter-gpu -t lib/main_part_calibration_dev.dart
```

Then, over the VM service:

```
ext.acro.bench?show=all                 # the roster in a row along +X
ext.acro.bench?show=eagle-legs          # one part, ON the ruler
ext.acro.camera?axes=true&rangeM=12&azimuthDeg=0&elevationDeg=0
ext.acro.camera?part=eagle-legs&partRotDeg=-90,0,0
ext.acro.screenshot?path=test_out/part_calibration/legs.png
```

The `part*` knobs are `PartModelLibrary`'s live calibration overrides, and every
reply carries `partCalibration` — the settled values as Dart literals to paste
back into the catalog. **The sweep is over when that map is empty again**,
because the catalog now says what the overrides said. Knob names match
`main_scene_dev.dart` exactly.

See `docs/plans/lem_part_calibration.md` for the settled LM numbers and how they
were arrived at.

---

## 7. Where to start reading

| | |
|---|---|
| `lib/domain/craft/` | `CraftDesign` (the model), `AttachSolver` (the pose), `AttachTargets` (what is legal), `CraftBalance` (bounds, CoM), `CraftDesignCodec` |
| `lib/infrastructure/flutter/screens/craft/` | `CraftEditorController` (every mutation, undo, save), the viewport, the panes |
| `lib/infrastructure/flutter_scene/craft/craft_editor_nodes.dart` | the editor's scene graph: ghosts, markers, the pad |
| `lib/adapters/presenters/` | `CraftEditorCamera` (turntable), `CraftEditorPick` (OBB ray test) — pure math, no Flutter |
| `lib/infrastructure/flutter_scene/vessel_nodes.dart` | how the launched craft is drawn |

The controller is the only thing that mutates a design. Every mutation goes
through `edit(label, mutate)`, which is what makes undo a property of the class
rather than something each command remembers to do.
