# mesh_src

Licensed 3D model sources (`.glb`). Commercially licensed but **not
redistributable** — everything here except this README is gitignored and
must never be committed or shipped as source.

## Baking

The app bundles only baked `assets/mesh/*.fsceneb` packages (also
gitignored). To bake after adding or updating a source model:

```
fvm dart run tool/import_mesh.dart          # bake every source
fvm dart run tool/import_mesh.dart eagle    # bake only matching sources
```

Arguments are substring filters against the source path (case insensitive).
A source bakes if it matches any of them, so `... eagle rcs` covers the
whole LEM part set. A full bake costs minutes and hundreds of megabytes of
texture transcoding; the filter exists so a single tweaked model can be
re-baked without paying for the rest. No arguments means bake everything.

Builds without the models fall back to procedural part meshes
(`VesselNodes._failedAssets`).

## Layout and output names

The importer searches `mesh_src/` **recursively**, so sources can be filed
into subdirectories by craft or vendor. Output is **flat**: every bake lands
directly in `assets/mesh/`, because `PartDef.modelAsset` keys off a
single-segment asset name and pubspec bundles `assets/mesh/` as one
directory.

Output basenames are sanitised — lowercased, and any character outside
`[a-z0-9_-]` becomes `_`. That matters here because `LEM Parts/` contains a
space, and asset paths travel through pubspec manifests, the Flutter asset
bundle and the FlatBuffers wire.

Because the tree flattens, two differently-filed sources can claim the same
output name (`RCS Block.glb` and `rcs_block.glb` both sanitise to
`rcs_block`). The importer **detects this and aborts before baking
anything** rather than let one bake silently overwrite another; rename a
source to resolve it.

## Current sources

Top level:

- `apollo.glb` — Apollo CSM, the full stack craft model.
- `lander.glb` — Apollo LM as a single assembled craft model.

`LEM Parts/` — the LM broken into separately mountable parts, for the VAB
part catalog (`PartDef.modelAsset`) rather than whole-craft rendering:

- `eagle_command_pod.glb` — LM ascent stage / crew cabin, the pressurised
  pod the crew rides in.
- `eagle_fuel_tank.glb` — descent stage propellant tank body.
- `eagle_legs.glb` — descent stage landing gear (legs and footpads).
- `eagle_thruster.glb` — descent engine bell and mount.
- `rcs_blast_flute.glb` — RCS plume deflector / blast shield flute.
- `rcs_block.glb` — RCS quad block (the clustered four-thruster assembly).
- `rcs_solo.glb` — a single RCS thruster nozzle.

Baked outputs, all in `assets/mesh/`:

```
apollo.fsceneb            lander.fsceneb
eagle_command_pod.fsceneb eagle_fuel_tank.fsceneb
eagle_legs.fsceneb        eagle_thruster.fsceneb
rcs_blast_flute.fsceneb   rcs_block.fsceneb
rcs_solo.fsceneb
```

## Distribution

Both the `.glb` sources and the `.fsceneb` bakes are gitignored (`*.glb`,
`*.fsceneb` in `/.gitignore`, which covers subdirectories such as
`LEM Parts/` too). Neither form may be redistributed. They exist in exactly
three places:

1. Dev machines, locally.
2. Inside built app bundles, where the baked `.fsceneb` ships as an opaque
   packaged asset.
3. The **private** repo
   [HexaJohn/acro-space-assets](https://github.com/HexaJohn/acro-space-assets),
   which is canonical storage: each release carries the `.glb` sources
   (backup) and the baked `.fsceneb` (what CI ships).

The release workflow's Windows job downloads the latest assets release's
`*.fsceneb` with the `ASSETS_TOKEN` secret (fine-grained PAT, Contents:Read
on that repo) — a glob, so newly published part bakes ship without a
workflow edit. Publishing a new part therefore means uploading its
`.fsceneb` to an `acro-space-assets` release.

The web/Pages build deliberately gets **no** full-res models: Pages serves
its bundle publicly, so only the small, low-res `apollo-web.fsceneb`
variant goes there. Do not point the web job at the `*.fsceneb` glob.
