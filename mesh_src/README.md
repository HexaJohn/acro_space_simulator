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

Current sources (keep private backups — the repo does not have them):

- `apollo.glb` — Apollo CSM craft model.
