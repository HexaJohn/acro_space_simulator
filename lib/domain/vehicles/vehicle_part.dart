/// How a ground vehicle moves — sets which terrain it handles and its speed.
enum LocomotionType {
  wheeled, // fast on flat ground, poor on rough/steep
  tracked, // slower but handles rough terrain + slopes (crawler)
  legged, // walkers — slow, but cross almost anything
  hover, // ignores terrain roughness, costs more power
}

/// Categories of buildable ground-vehicle part.
enum VehiclePartCategory {
  chassis, // structural frame
  cabin, // crew/control + optional pressurization
  wheel, // wheeled locomotion
  track, // tracked locomotion
  leg, // legged locomotion
  motor, // drives the locomotion, draws power
  battery, // stores electric charge
  cargoBay, // hauls resources
  scienceBay, // mobile experiments
}

/// A catalog template for a ground-vehicle part. Locomotion parts carry a
/// [locomotion] type; motors carry [powerDraw]/[drivePower]; etc.
class VehiclePart {
  final String id;
  final String name;
  final VehiclePartCategory category;
  final double dryMass; // kg

  final LocomotionType? locomotion; // for wheel/track/leg/hover parts
  final double drivePower; // W of drive a motor delivers (motors)
  final double powerDraw; // W consumed at full drive (motors)
  final double batteryCapacity; // electric charge units (batteries)
  final int crewCapacity; // cabins
  final double cargoCapacity; // cargo bays
  final double terrainCapability; // 0..1 max roughness this part handles

  const VehiclePart({
    required this.id,
    required this.name,
    required this.category,
    required this.dryMass,
    this.locomotion,
    this.drivePower = 0,
    this.powerDraw = 0,
    this.batteryCapacity = 0,
    this.crewCapacity = 0,
    this.cargoCapacity = 0,
    this.terrainCapability = 0.3,
  });
}
