# dem_src

Raw elevation/albedo rasters for real-body terrain. Working data, not ship
data: everything here except this README is gitignored (`*.tif`) and must
never be committed or bundled. `assets/` is packaged wholesale by
`pubspec.yaml`, which is why these live outside it — dropped in there they
added ~2 GB to every build, web included.

The intended path mirrors `mesh_src/`: a large licensed/bulk source here, a
small baked artefact in `assets/`, and a tool in `tool/` that does the
conversion. The bake target is a **cubed-sphere tile pyramid** keyed by
`ChunkKey` (`lib/domain/terrain/cubed_sphere.dart`), not equirectangular —
equirectangular carries a pole singularity and a permanent projection
mismatch against the chunk grid.

All sources below are NASA/NOAA public-domain products; they still want
attribution in the in-app credits alongside the existing Solar System Scope
line.

## Formats (verified by parsing the files, not from the filenames)

### `ldem_64.tif` — Moon elevation. **The good one.**

NASA SVS "CGI Moon Kit" displacement map, LOLA-derived.

| | |
|---|---|
| size | 23040 x 11520 (exactly 64 px/degree) |
| format | **float32**, 1 channel, uncompressed, little-endian |
| layout | 1 row per strip, contiguous — pixel `(x,y)` at byte `8 + y*92160 + x*4` |
| ground sample | ~474 m/px at the equator |
| **units** | **kilometres of elevation relative to the 1,737.4 km datum** |

The units were established by sampling known features rather than assumed —
there is no scale/offset to decode, the values are already signed
elevations:

| feature | sampled | published |
|---|---|---|
| lunar high point (5.4N, 201.4E) | +10.72 | ~ +10.79 |
| Apollo 11 site | -1.93 | ~ -1.9 |
| Mare Imbrium | -3.62 | mare basin |
| South Pole-Aitken floor | -6.95 | deepest ~ -9 |

Sampled global range -8.81 .. +10.41 km, against the Moon's real ~19.9 km
spread. So it composes directly: `groundRadius = radius + value * 1000`.

Note this is **6x** the Moon's current `TerrainConfig.amplitude` (3000 m).
That figure, and the shader's `amplitudeScene` altitude blending, need
raising with the bake or high ground will clip the colour ramp.

### `lroc_color_poles.tif` — Moon albedo (NOT height)

LROC WAC colour mosaic. 27360 x 13680, 8-bit RGBA, LZW, ~399 m/px. Feeds the
far-sphere texture and the shader's base colour — it replaces `moon.jpg`,
and has nothing to do with `TerrainField`.

### `gebco_08_rev_{elev,bath}_*.tif` — Earth topography/bathymetry

Blue Marble Next Generation topography/bathymetry. Two sizes: 21600 x 10800
(~1855 m/px) and 5400 x 2700 (~7420 m/px).

**8-bit** (`bps=8`, uncompressed) — GeoTIFF avoids JPEG ringing, but not the
quantization. Roughly 34 m per level on land and ~43 m in the ocean, which
terraces visibly on gentle relief (plains, continental shelves) at a ~1.9 km
sample spacing.

They are a **complementary pair**, not two versions of one raster — 8 bits
cannot span both ranges, so:

- `elev` — land only, ocean masked to 0 (Pacific 0, Marianas 0, Himalaya 225)
- `bath` — ocean only and **inverted**, land masked to 255 (Pacific abyss 123,
  Marianas 44, all land 255)

Combining them needs a land/sea mask, and the exact value->metres ramp has to
come from the dataset documentation before this is usable quantitatively.

For quantitative Earth prefer **ETOPO 2022** or the **GEBCO 2024 grid** —
15 arc-second, 16-bit/float GeoTIFF, bathymetry included. These BMNG rasters
are fine as a continental mask or colour base.
