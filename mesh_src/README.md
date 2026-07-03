# mesh_src

Licensed 3D model sources (`.glb`). Commercially licensed but **not
redistributable** — everything here except this README is gitignored and
must never be committed or shipped.

The app bundles only baked `assets/mesh/*.fsceneb` packages (also
gitignored). To bake after adding or updating a source model:

```
fvm dart run tool/import_mesh.dart
```

Builds without the models fall back to procedural part meshes
(`VesselNodes._glbFailed`).

Canonical storage is the **private** repo
[HexaJohn/acro-space-assets](https://github.com/HexaJohn/acro-space-assets):
each release carries the `.glb` sources (backup) and baked `.fsceneb`
(what CI ships). The release workflow's Windows job downloads the latest
release's `*.fsceneb` using the `ASSETS_TOKEN` secret (fine-grained PAT,
Contents:Read on that repo). The web/Pages build deliberately gets no
models — Pages would serve the raw file publicly.

Current sources:

- `apollo.glb` — Apollo CSM craft model.
