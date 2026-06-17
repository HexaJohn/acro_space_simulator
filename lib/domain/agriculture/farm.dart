/// A crop type with its agronomy: how long it takes to mature, how much water
/// it drinks, and how much food a unit area yields at harvest.
enum CropType {
  grain(growthDays: 120, waterPerAreaPerDay: 2.0, yieldPerArea: 0.5),
  potato(growthDays: 90, waterPerAreaPerDay: 1.5, yieldPerArea: 0.8),
  soy(growthDays: 100, waterPerAreaPerDay: 1.8, yieldPerArea: 0.4),
  rice(growthDays: 150, waterPerAreaPerDay: 4.0, yieldPerArea: 0.9),
  hydroponicGreens(growthDays: 40, waterPerAreaPerDay: 0.5, yieldPerArea: 0.3);

  final double growthDays;
  final double waterPerAreaPerDay; // water units per m^2 per day
  final double yieldPerArea; // food units per m^2 per harvest

  const CropType({
    required this.growthDays,
    required this.waterPerAreaPerDay,
    required this.yieldPerArea,
  });
}

/// A field of crops in a colony. Entity within the Colony aggregate. [growth]
/// runs 0..1; at 1 it harvests into the colony food stockpile and resets.
class Farm {
  final String id;
  final CropType crop;
  final double area; // m^2

  double growth; // 0..1 toward maturity

  Farm({
    required this.id,
    required this.crop,
    required this.area,
    this.growth = 0,
  });

  bool get isMature => growth >= 1.0;

  /// Food produced by a harvest of this field.
  double get harvestYield => area * crop.yieldPerArea;
}
