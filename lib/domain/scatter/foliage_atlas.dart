// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// One cell of the shared foliage atlas.
///
/// Every alpha-masked card in the whole scatter system — broadleaf clumps,
/// conifer needles, palm fronds, grass blades — samples ONE texture, because
/// every extra texture is another material and another draw call, and a forest
/// that costs four draws instead of one is the difference between shipping this
/// and not. The cells are semantic, not decorative: a generator picks the cell
/// whose SHAPE it needs.
enum FoliageCell {
  /// A clump of rounded leaves, for broadleaf canopies.
  broadleaf,

  /// A fine needle spray, for conifers.
  needle,

  /// A pinnate frond, for palms and ferns. Drawn to fill the cell lengthwise
  /// because it is applied to a ribbon, not a square card.
  frond,

  /// A tuft of grass blades.
  blade,
}

/// UV layout of [FoliageCell] within the atlas texture.
///
/// A 2x2 grid: big enough that each cell keeps real resolution at the texture
/// sizes we bake, and small enough that the half-texel bleed guard below stays
/// a rounding detail rather than eating the artwork.
class FoliageAtlas {
  FoliageAtlas._();

  /// Cells per axis.
  static const int grid = 2;

  /// Inset applied to every cell's UV rect, as a fraction of the cell.
  ///
  /// Without it, a card's edge texel bilinearly blends with its NEIGHBOUR cell
  /// once mips kick in, and a broadleaf clump picks up a fringe of needles at
  /// distance. Half a texel of a 256-px atlas is ~0.2% of a cell; 0.5% is
  /// comfortably clear of it at every mip that matters.
  static const double _inset = 0.005;

  static int columnOf(FoliageCell cell) => cell.index % grid;
  static int rowOf(FoliageCell cell) => cell.index ~/ grid;

  /// The `(u0, v0, u1, v1)` rect for [cell]. Pass [mirror] to flip it
  /// horizontally — free silhouette variety, since a mirrored leaf clump does
  /// not read as the same clump.
  static (double, double, double, double) uv(
    FoliageCell cell, {
    bool mirror = false,
  }) {
    const s = 1.0 / grid;
    final u0 = columnOf(cell) * s + _inset * s;
    final v0 = rowOf(cell) * s + _inset * s;
    final u1 = (columnOf(cell) + 1) * s - _inset * s;
    final v1 = (rowOf(cell) + 1) * s - _inset * s;
    return mirror ? (u1, v0, u0, v1) : (u0, v0, u1, v1);
  }
}
