# Acro Space Simulator

A 1:1-scale space-flight + colony simulator built on a Domain-Driven /
CLEAN-architecture physics engine in Flutter / Dart.

![Orbit overview](release/screenshots/01_orbit_overview.png)

Fly rockets and aircraft under patched-conic orbital mechanics, mine real
elements, build Cities-Skylines-style colonies, and keep crews alive through
reentry heat, radiation, and life support — across the real Solar System.

## Quick start

```bash
flutter pub get
flutter run -d windows      # or -d chrome
```

Press **`M`** for manual flight (W/S/A/D/Q/E + Shift), `[` `]` to zoom.

## Highlights

- **Physics** — 1:1-scale patched conics, on-rails Kepler ↔ RK4 6-DOF, J2,
  eccentric/inclined real ephemeris, SOI transitions.
- **Craft** — real parts catalog (rockets + aircraft), assembled into one rigid
  body; jets, wings, gimbals, RCS, staging.
- **Survival** — reentry heat + ablators, radiation (belts/flares), max-Q,
  life support, splashdown.
- **Resources** — 45-element periodic table, abundance-weighted ore, ISRU.
- **Cities** — RCI growth, road networks, services + happiness, flight-driven demand.
- **Autonomy** — autopilot, Hohmann/plane-change planning, docking, cargo, comms.
- **Multiplayer** — deterministic authoritative loop + client prediction.
- **Universe** — Sun + 8 planets + 5 dwarf planets + ~20 moons, biomes, seasons,
  magnetospheres.

Built across **23 bounded contexts**, pure domain (zero Flutter coupling),
**335 tests passing**.

## Documentation

- [Docs index](docs/README.md) — how everything below is generated
- [Reference: buildings, parts & bodies](docs/REFERENCE.md) — auto-generated from the catalogs
- API wiki (class-level) — `dart doc --output doc/api`, then open `doc/api/index.html`
- [User Guide](release/USER_GUIDE.md)
- [Tutorial](release/TUTORIAL.md)
- [Changelog](CHANGELOG.md)
- [Promo one-pager](release/PROMO.md)

## Development

```bash
dart analyze          # must be clean
flutter test          # 335 tests
flutter build web     # compile check
```

Architecture: `domain/` (pure) ← `application/` (use cases + ports) ←
`adapters/` ← `infrastructure/` (Flutter). Heavy numeric work sits behind a
`ComputePort` ready for a Rust-FFI backend.

# License

This project is licensed under CC BY-NC-SA 4.0
https://creativecommons.org/licenses/by-nc-sa/4.0/

You are free to:

    Share — copy and redistribute the material in any medium or format
    Adapt — remix, transform, and build upon the material
    The licensor cannot revoke these freedoms as long as you follow the license terms.

Under the following terms:

    Attribution — You must give appropriate credit, provide a link to the license, and indicate if changes were made. You may do so in any reasonable manner, but not in any way that suggests the licensor endorses you or your use.
    NonCommercial — You may not use the material for commercial purposes.
    ShareAlike — If you remix, transform, or build upon the material, you must distribute your contributions under the same license as the original.
    No additional restrictions — You may not apply legal terms or technological measures that legally restrict others from doing anything the license permits.

Notices:

You do not have to comply with the license for elements of the material in the public domain or where your use is permitted by an applicable exception or limitation.

No warranties are given. The license may not give you all of the permissions necessary for your intended use. For example, other rights such as publicity, privacy, or moral rights may limit how you use the material.
