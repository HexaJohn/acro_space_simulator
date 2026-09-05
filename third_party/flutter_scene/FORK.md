# flutter_scene — vendored fork

Upstream: https://github.com/bdero/flutter_scene, `packages/flutter_scene` at
commit `d3ebfb6a589b475e08b3acce43a71ce8c5f0b72f` (2026-06-30, pub 0.18.1+).
Vendored 2026-09-05 as a path dependency so the renderer's per-draw and
per-frame costs can be fixed at the source (the pin was already a git ref,
so nothing changed for pub except the URL). `example/`, `test/` and
`screenshots/` are not carried; `resolution: workspace` was dropped because
the package no longer lives in the upstream pub workspace.

Upstream fixes must be merged by hand. Keep this list current — one line per
patch, newest last — so a future pin bump knows what to re-apply.

## Patches

(none yet)
