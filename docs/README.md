# Acro Space Simulator — Documentation

Three layers of docs, all grounded on the actual Dart code:

| Doc | What | How it's made |
|---|---|---|
| [**REFERENCE.md**](REFERENCE.md) | Every **building, part, and celestial body** with their real numbers (cost, thrust, radius, gravity, …) | Auto-generated from the live catalogs by `test/tools/gen_reference_test.dart` |
| **API docs** (`doc/api/`) | The full **class-level wiki**: every aggregate, value object, service, and catalog type, from the inline doc comments | `dart doc --output doc/api` (config in `dartdoc_options.yaml`) |
| [**CHANGELOG.md**](../CHANGELOG.md) | Release history | Hand-written |

## Regenerate

```sh
# Reference tables (buildings / parts / bodies)
flutter test test/tools/gen_reference_test.dart

# Class-level API wiki -> doc/api/index.html
dart doc --output doc/api
```

The API site is browsable by bounded context (Flight & Physics, Vessels & Parts,
Universe & Bodies, Colony & Cities, Planetary Science) — see
[`doc/categories/`](../doc/categories/).

## Live web app

Tagged releases (`vX.Y.Z`) auto-deploy the static web build to GitHub Pages and
publish web + Windows builds on the GitHub Release (see
[`.github/workflows/release.yml`](../.github/workflows/release.yml)).
