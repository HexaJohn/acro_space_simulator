# Reference — Buildings, Parts & Bodies

> Auto-generated from the live catalogs by `test/tools/gen_reference_test.dart` (`flutter test test/tools/gen_reference_test.dart`). Do not edit by hand — regenerate.

Source of truth:
- Buildings → `lib/infrastructure/flutter/screens/city_model.dart` (`kUtilCatalog`, [`CitySpec`](../doc/api/index.html))
- Parts → `lib/domain/parts/part_catalog.dart` ([`PartCatalog`](../doc/api/index.html), `PartDef`)
- Bodies → `lib/domain/universe/real_solar_system.dart` (`RealSolarSystem`, `CelestialBody`)

## Buildings

54 placeable structures, grouped by tab.

### Power

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Solar Farm** | 1×1 | 40 | 0 | +60 | — | — | 0.0 | 0 |
| **Wind Turbine** | 1×1 | 40 | 0 | +50 | — | — | 0.0 | 0 |
| **Gas Generator** | 1×1 | 50 | 6 | +120 | fuel 0.60/s | — | 2.5 | 0 |
| **Fission Reactor** | 1×1 | 80 | 12 | +240 | — | — | 1.0 | 120 |
| **Fusion Plant** | 1×1 | 200 | 30 | +800 | — | — | 0.0 | 600 |
| **Solar Array** | 2×2 | 140 | 0 | +270 | — | — | 0.0 | 60 |

### Svc

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Aquifer Pump** | 1×1 | 35 | 6 | −8 | — | water 1.50/s | 0.0 | 0 |
| **Water Plant** | 1×1 | 40 | 8 | −12 | — | water 2.00/s | 0.5 | 0 |
| **Farm** | 1×1 | 40 | 10 | −4 | water 0.50/s | food 1.00/s | 0.0 | 0 |
| **Industrial Farm** | 2×2 | 110 | 24 | −14 | water 1.80/s | food 4.20/s | 1.0 | 80 |
| **Hydroponics** | 1×2 | 90 | 14 | −22 | water 1.20/s | food 3.00/s | 0.0 | 120 |
| **Lab-Grown Meat** | 2×2 | 160 | 30 | −30 | water 1.50/s, electronics 0.10/s | food 5.00/s | 1.5 | 300 |
| **Electrolysis Plant** | 1×1 | 50 | 12 | −20 | water 1.00/s | oxygen 0.80/s | 0.0 | 0 |
| **Atmospheric O₂ Harvester** | 1×1 | 60 | 10 | −15 | — | oxygen 2.00/s | 0.0 | 0 |
| **Clinic** | 1×1 | 30 | 6 | −5 | medicine 0.20/s | — | 0.0 | 0 |
| **Hospital** | 1×1 | 40 | 15 | −10 | medicine 0.50/s | — | 0.0 | 60 |
| **Chemist** | 1×1 | 40 | 8 | −6 | water 0.30/s | medicine 0.40/s | 0.0 | 0 |
| **Pharma Plant** | 1×1 | 80 | 30 | −25 | water 0.50/s, electronics 0.10/s | medicine 1.50/s | 1.0 | 200 |
| **School** | 1×1 | 40 | 12 | −8 | — | — | 0.0 | 0 |
| **Police Station** | 1×1 | 40 | 14 | −9 | — | — | 0.0 | 0 |
| **Park** | 1×1 | 40 | 0 | −2 | — | — | 0.0 | 0 |

### Waste

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Landfill** | 1×1 | 30 | 6 | −3 | garbage 2.00/s | — | 1.5 | 0 |
| **Recycling Center** | 1×1 | 60 | 18 | −14 | garbage 3.00/s | ore 0.30/s, steel 0.20/s | 0.0 | 120 |
| **Sewage Treatment** | 1×1 | 50 | 12 | −16 | sewage 3.00/s | water 1.00/s | 0.5 | 0 |

### Death

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Morgue** | 1×1 | 40 | 8 | −6 | — | — | 0.0 | 0 |
| **Crematorium** | 1×1 | 70 | 14 | −14 | — | — | 1.0 | 150 |
| **Cemetery** | 1×1 | 30 | 4 | −2 | — | — | 0.0 | 0 |

### Res-x

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Mine** | 1×1 | 40 | 20 | −15 | — | ore 2.00/s | 2.0 | 0 |
| **Quarry** | 5×5 | 360 | 180 | −130 | — | ore 22.00/s | 14.0 | 400 |
| **Refinery** | 1×1 | 40 | 30 | −25 | ore 1.00/s | fuel 0.40/s, oxidizer 0.30/s | 4.0 | 80 |
| **Steel Mill** | 1×1 | 40 | 35 | −30 | ore 2.00/s | steel 1.50/s, tubes 0.40/s | 5.0 | 120 |
| **Electronics Plant** | 1×1 | 40 | 40 | −35 | steel 0.50/s | electronics 0.60/s | 2.0 | 200 |

### Compute

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Data Center** | 1×1 | 120 | 25 | −60 | electronics 0.20/s | — | 1.0 | 250 |

### Aero

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Rocket Parts Factory** | 1×1 | 40 | 50 | −45 | tubes 0.50/s, electronics 0.30/s | rocketParts 0.40/s | 3.0 | 400 |
| **Vehicle Assembly Building** | 1×1 | 300 | 80 | −80 | rocketParts 0.30/s, tubes 0.20/s, electronics 0.20/s, fuel 0.50/s | — | 2.0 | 700 |

### Mil

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Arms Factory** | 1×1 | 40 | 35 | −25 | steel 0.50/s, electronics 0.10/s | guns 0.30/s, ammo 1.00/s | 3.0 | 300 |
| **Missile Plant** | 1×1 | 40 | 60 | −50 | tubes 0.40/s, rocketParts 0.20/s, electronics 0.20/s | missiles 0.15/s | 4.0 | 800 |
| **Rations Plant** | 1×1 | 40 | 18 | −10 | food 1.00/s | rations 0.80/s | 0.0 | 200 |
| **Barracks** | 1×1 | 80 | 30 | −12 | rations 0.50/s, guns 0.05/s, ammo 0.30/s | — | 0.0 | 300 |
| **Military Base** | 1×1 | 200 | 80 | −40 | rations 1.50/s, fuel 0.50/s, ammo 1.00/s | — | 0.0 | 600 |
| **Gun Emplacement** | 1×1 | 40 | 8 | −6 | ammo 0.50/s | — | 0.0 | 400 |
| **Missile Silo** | 1×1 | 250 | 20 | −20 | missiles 0.05/s | — | 0.0 | 1000 |
| **Airfield** | 1×10 | 200 | 50 | −30 | fuel 1.00/s, ammo 0.50/s | — | 0.0 | 700 |

### Storage

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Warehouse** | 1×1 | 40 | 0 | −3 | — | — | 0.0 | 0 |
| **Silo Cluster** | 1×1 | 80 | 0 | −6 | — | — | 0.0 | 300 |

### Env

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Terraforming Tower** | 1×1 | 150 | 30 | −60 | — | oxygen 0.50/s | -2.0 | 300 |
| **Fallout Shelter** | 1×1 | 60 | 0 | −8 | — | — | 0.0 | 0 |

### Prep

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Early-Warning Station** | 1×1 | 50 | 10 | −8 | — | — | 0.0 | 100 |
| **Bunker** | 1×1 | 70 | 4 | −6 | — | — | 0.0 | 0 |
| **Emergency Services** | 1×1 | 60 | 20 | −12 | medicine 0.30/s | — | 0.0 | 80 |

### Transport

| Building | Size | Cost | Jobs | Power | Inputs | Outputs | Pollution | Unlock pop |
|---|---|---|---|---|---|---|---|---|
| **Transit Stop** | 1×1 | 30 | 4 | −5 | — | — | 0.0 | 0 |
| **Spaceport** | 1×1 | 40 | 40 | −40 | fuel 1.00/s, oxidizer 1.00/s | food 0.30/s, water 0.30/s, ore 0.30/s, oxygen 0.30/s | 0.0 | 0 |
| **Spaceport Complex (2×4)** | 2×4 | 160 | 110 | −110 | fuel 2.60/s, oxidizer 2.60/s | food 0.90/s, water 0.90/s, ore 0.90/s, oxygen 0.90/s | 0.0 | 200 |
| **Starport (3×6)** | 3×6 | 360 | 240 | −240 | fuel 6.00/s, oxidizer 6.00/s | food 2.20/s, water 2.20/s, ore 2.20/s, oxygen 2.20/s | 0.0 | 800 |

## Parts

18 craft parts.

### commandPod

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Mk1 Command Capsule** | 840 kg | — | — | 1 | — | — |
| **Mk1 Aircraft Cockpit** | 1000 kg | — | — | 1 | — | — |

### fuelTank

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **FL-T400 Fuel Tank** | 250 kg | — | — | 0 | 400 | — |
| **Wing Fuel Tank (Jet)** | 150 kg | — | — | 0 | 400 | — |

### rocketEngine

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Merlin 1D (Falcon 9)** | 470 kg | 981 kN | 311 s | 0 | — | — |
| **RL10 (Centaur, vacuum)** | 277 kg | 110 kN | 465 s | 0 | — | — |

### jetEngine

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **J85 Turbojet** | 270 kg | 18 kN jet | — | 0 | — | — |
| **J58 Hybrid Ramjet (SR-71)** | 2700 kg | 145 kN jet | — | 0 | — | — |

### intake

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Ram Air Intake** | 70 kg | — | — | 0 | — | intake |

### wing

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Swept Wing** | 200 kg | — | — | 0 | — | wing 12 m² |

### controlSurface

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Elevon (Control Surface)** | 40 kg | — | — | 0 | — | wing 2 m² |

### decoupler

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **TR-18A Stack Decoupler** | 50 kg | — | — | 0 | — | — |

### landingGear

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Retractable Landing Gear** | 60 kg | — | — | 0 | — | — |

### parachute

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Mk16 Parachute** | 100 kg | — | — | 0 | — | — |

### heatShield

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Heat Shield (1.25m)** | 300 kg | — | — | 0 | — | heat shield |

### science

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Thermometer** | 5 kg | — | — | 0 | — | — |

### rcsThruster

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **RCS Thruster Block** | 50 kg | — | — | 0 | 60 | — |

### structural

| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |
|---|---|---|---|---|---|---|
| **Standard Docking Port** | 50 kg | — | — | 0 | — | — |

## Celestial bodies

35 bodies (Sun + planets + dwarf planets + moons).

| Body | Type | Radius | Surface g | Rotation | Atmosphere | Parent |
|---|---|---|---|---|---|---|
| **Sun** | star | 695700 km | 274.20 m/s² | 609.0 h | none | — |
| **Mercury** | moon | 2440 km | 3.70 m/s² | 1407.5 h | none | sun |
| **Venus** | moon | 6052 km | 8.87 m/s² | 5832.5 h | 250 km | sun |
| **Earth** | moon | 6371 km | 9.82 m/s² | 23.9 h | 140 km | sun |
| **Mars** | moon | 3390 km | 3.73 m/s² | 24.6 h | 125 km | sun |
| **Jupiter** | gas giant | 69911 km | 25.92 m/s² | 9.9 h | none | sun |
| **Saturn** | gas giant | 58232 km | 11.19 m/s² | 10.7 h | none | sun |
| **Uranus** | gas giant | 25362 km | 9.01 m/s² | 17.2 h | none | sun |
| **Neptune** | gas giant | 24622 km | 11.28 m/s² | 16.1 h | none | sun |
| **Moon** | moon | 1737 km | 1.62 m/s² | 655.7 h | none | earth |
| **Phobos** | moon | 11 km | 0.01 m/s² | 7.7 h | none | mars |
| **Io** | moon | 1822 km | 1.80 m/s² | 42.5 h | none | jupiter |
| **Europa** | moon | 1561 km | 1.31 m/s² | 85.2 h | none | jupiter |
| **Ganymede** | moon | 2634 km | 1.43 m/s² | 171.8 h | none | jupiter |
| **Callisto** | moon | 2410 km | 1.24 m/s² | 400.5 h | none | jupiter |
| **Titan** | moon | 2575 km | 1.35 m/s² | 382.8 h | 600 km | saturn |
| **Deimos** | moon | 6 km | 0.00 m/s² | 30.3 h | none | mars |
| **Enceladus** | moon | 252 km | 0.11 m/s² | 27.8 h | none | saturn |
| **Mimas** | moon | 198 km | 0.06 m/s² | 27.8 h | none | saturn |
| **Rhea** | moon | 764 km | 0.26 m/s² | 27.8 h | none | saturn |
| **Iapetus** | moon | 735 km | 0.22 m/s² | 27.8 h | none | saturn |
| **Dione** | moon | 561 km | 0.23 m/s² | 27.8 h | none | saturn |
| **Tethys** | moon | 531 km | 0.15 m/s² | 27.8 h | none | saturn |
| **Titania** | moon | 788 km | 0.38 m/s² | 27.8 h | none | uranus |
| **Oberon** | moon | 761 km | 0.33 m/s² | 27.8 h | none | uranus |
| **Miranda** | moon | 236 km | 0.08 m/s² | 27.8 h | none | uranus |
| **Ariel** | moon | 579 km | 0.25 m/s² | 27.8 h | none | uranus |
| **Umbriel** | moon | 585 km | 0.25 m/s² | 27.8 h | none | uranus |
| **Triton** | moon | 1353 km | 0.78 m/s² | 27.8 h | none | neptune |
| **Ceres** | moon | 476 km | 0.28 m/s² | 9.1 h | none | sun |
| **Pluto** | moon | 1188 km | 0.62 m/s² | 153.3 h | none | sun |
| **Charon** | moon | 606 km | 0.29 m/s² | 27.8 h | none | pluto |
| **Eris** | moon | 1163 km | 0.82 m/s² | 25.9 h | none | sun |
| **Haumea** | moon | 780 km | 0.44 m/s² | 3.9 h | none | sun |
| **Makemake** | moon | 715 km | 0.39 m/s² | 22.5 h | none | sun |

