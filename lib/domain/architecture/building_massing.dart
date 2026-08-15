// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How a building is SHAPED, before any triangles exist.
///
/// Massing is derived from what the building has to do — how many people it
/// houses or employs, how much plant it contains — and from how much land it
/// was given. That is the whole point of generating buildings rather than
/// placing models: a hospital on a narrow street lot becomes a tower, the same
/// hospital on an open plot becomes a low block with wings, and neither needs
/// an artist. Keeping the sizing separate from the mesh also means it can be
/// tested as arithmetic, and the renderer can bucket similar massings into one
/// shared mesh for instancing.
library;

import 'dart:math' as math;

import '../colony/city/city_building_spec.dart';
import '../colony/city/parcel.dart';

/// A rectangular volume in building-local metres, Z-up, origin at the centre of
/// the building's footprint on the ground.
class MassBox {
  /// Centre of the box in plan; z is the box's BASE height above ground.
  final double x, y, z;
  final double width, depth, height;

  /// Floors this volume contains (0 for plant, canopies, plinths).
  final int floors;

  /// Whether this volume gets glazing. Plant rooms and plinths do not.
  final bool glazed;

  const MassBox({
    required this.x,
    required this.y,
    required this.z,
    required this.width,
    required this.depth,
    required this.height,
    this.floors = 0,
    this.glazed = true,
  });

  double get top => z + height;
  double get floorArea => width * depth * math.max(1, floors);
}

/// A surface car park attached to a building.
class ParkingLot {
  /// Centre in building-local plan metres.
  final double x, y;
  final double width, depth;
  final int spaces;

  /// Light column positions in building-local metres, on the lot.
  final List<(double x, double y)> lampPosts;

  const ParkingLot({
    required this.x,
    required this.y,
    required this.width,
    required this.depth,
    required this.spaces,
    this.lampPosts = const [],
  });

  double get area => width * depth;
}

/// The complete shape brief for one building.
class BuildingMassing {
  final List<MassBox> volumes;
  final ParkingLot? parking;

  /// Storey height used throughout, metres.
  final double storeyM;

  /// Total enclosed floor area, m².
  final double floorArea;

  /// Where the entrance sits, in local plan metres — on the frontage side.
  final (double x, double y) entrance;

  const BuildingMassing({
    required this.volumes,
    required this.storeyM,
    required this.floorArea,
    required this.entrance,
    this.parking,
  });

  double get height =>
      volumes.fold(0.0, (h, v) => math.max(h, v.top));

  int get floors =>
      volumes.fold(0, (f, v) => math.max(f, ((v.top) / storeyM).floor()));

  ({double width, double depth}) get footprint {
    var w = 0.0, d = 0.0;
    for (final v in volumes) {
      w = math.max(w, v.x.abs() * 2 + v.width);
      d = math.max(d, v.y.abs() * 2 + v.depth);
    }
    return (width: w, depth: d);
  }
}

/// Derives massing from function and available land.
class BuildingMassingRules {
  const BuildingMassingRules({
    this.storeyM = 3.6,
    this.industrialStoreyM = 7.5,
    this.areaPerResident = 42,
    this.areaPerWorker = 22,
    this.setbackM = 3,
    this.maxFloors = 60,
    this.parkingSpaceM2 = 26,
  });

  /// Habitable storey height. Industrial sheds get a taller one — a factory
  /// floor with a 3.6 m ceiling reads as an office block with the wrong texture.
  final double storeyM;
  final double industrialStoreyM;

  final double areaPerResident;
  final double areaPerWorker;

  /// Gap between the property line and the building face.
  final double setbackM;

  final int maxFloors;

  /// Bay plus its share of aisle and circulation.
  final double parkingSpaceM2;

  /// Floor area this building's function demands, m².
  double requiredArea(CityBuildingSpec spec) {
    var a = spec.housing * areaPerResident + spec.jobs * areaPerWorker;
    // Plant with no staff still needs a building around it. Size those from
    // their power rating, which is the only scale signal such a spec carries.
    if (a < 40) {
      a = 60 + spec.powerOutput * 0.9 + spec.powerDraw * 0.4;
    }
    // Storage is all volume, no occupancy.
    a += spec.storageBonus * 0.35;
    return math.max(a, 45);
  }

  bool _isIndustrial(CityBuildingSpec spec) => const {
        'ind',
        'res-x',
        'power',
        'waste',
        'storage',
        'aero',
      }.contains(spec.group);

  /// Cars this building attracts. Workers dominate; shops and civic buildings
  /// add visitor demand, which is what makes a mall's lot dwarf its shell.
  int parkingSpaces(CityBuildingSpec spec) {
    final staff = spec.jobs * 0.55;
    final visitors = (spec.services['leisure'] ?? 0) * 0.04 +
        (spec.services['health'] ?? 0) * 0.03 +
        (spec.services['education'] ?? 0) * 0.02;
    final residents = spec.housing * 0.35;
    return (staff + visitors + residents).round();
  }

  /// Shape [spec] to fit [parcel].
  BuildingMassing massFor(CityBuildingSpec spec, Parcel parcel, {int seed = 0}) {
    final extent = parcel.buildableExtent;
    final rnd = math.Random(seed ^ spec.label.hashCode);
    final industrial = _isIndustrial(spec);
    final storey = industrial ? industrialStoreyM : storeyM;

    // Land available once the setbacks are taken off, in the parcel's own
    // frontage-aligned axes: width runs ALONG the street, depth away from it.
    // Capped to the spec's real site size — a solar farm dropped on a
    // ten-kilometre manual lot is still a solar farm, not a ten-kilometre one.
    // The cap applies ONLY to specs that declare a site: ordinary street
    // buildings have no fixed extent and must keep taking their shape from the
    // parcel, or every lot in the city would produce the same building.
    final site = spec.siteMetres();
    final capW = spec.siteWidthM > 0 ? site.width : double.infinity;
    final capD = spec.siteDepthM > 0 ? site.depth : double.infinity;
    final availW = math.min(math.max(6.0, extent.width - setbackM * 2), capW);
    final availD = math.min(math.max(6.0, extent.depth - setbackM * 2), capD);

    switch (spec.siteKind) {
      case SiteKind.field:
        return _field(spec, availW, availD);
      case SiteKind.pit:
        return _pit(spec, availW, availD, storey);
      case SiteKind.pad:
        return _apron(spec, availW, availD, storey);
      case SiteKind.building:
        break;
    }

    final needed = requiredArea(spec);
    final spaces = parkingSpaces(spec);
    final parkArea = spaces * parkingSpaceM2;

    // Parking takes a strip off the FRONT of the lot (between the building and
    // the street) whenever there is room for it; a building that would then
    // have nowhere to stand keeps its plot and loses the lot instead.
    var parkDepth = 0.0;
    if (parkArea > 0) {
      parkDepth = (parkArea / availW).clamp(0.0, availD * 0.55);
    }
    final buildD = math.max(6.0, availD - parkDepth);
    final buildW = availW;

    // Footprint: industrial fills its plot, everything else keeps a slimmer
    // block so a dense street does not become one continuous wall.
    final coverage = industrial ? 0.92 : 0.7 + rnd.nextDouble() * 0.12;
    final footW = buildW * coverage;
    final footD = buildD * coverage;
    final footArea = footW * footD;

    var floors = industrial ? 1 : (needed / footArea).ceil().clamp(1, maxFloors);
    // A shed that cannot hold its function on one floor grows a mezzanine
    // rather than a tower.
    if (industrial && needed > footArea * 1.4) floors = 2;

    final volumes = <MassBox>[];
    // Building sits at the BACK of the buildable strip, parking in front of it.
    final buildCentreY = parkDepth / 2;

    if (floors <= 4) {
      volumes.add(MassBox(
        x: 0,
        y: buildCentreY,
        z: 0,
        width: footW,
        depth: footD,
        height: floors * storey,
        floors: floors,
      ));
    } else {
      // Podium and tower. Real tall buildings step back above their base, and
      // the step is what stops a generated skyline reading as a bar chart.
      const podiumFloors = 2;
      final towerFloors = floors - podiumFloors;
      final towerW = footW * (0.52 + rnd.nextDouble() * 0.16);
      final towerD = footD * (0.52 + rnd.nextDouble() * 0.16);
      volumes.add(MassBox(
        x: 0,
        y: buildCentreY,
        z: 0,
        width: footW,
        depth: footD,
        height: podiumFloors * storey,
        floors: podiumFloors,
      ));
      volumes.add(MassBox(
        // Offset the tower toward the back of the podium, so the street gets a
        // set-back frontage rather than a slab straight off the pavement.
        x: (rnd.nextDouble() - 0.5) * (footW - towerW) * 0.4,
        y: buildCentreY + (footD - towerD) * 0.18,
        z: podiumFloors * storey,
        width: towerW,
        depth: towerD,
        height: towerFloors * storey,
        floors: towerFloors,
      ));
      // Rooftop plant.
      volumes.add(MassBox(
        x: 0,
        y: buildCentreY + (footD - towerD) * 0.18,
        z: floors * storey,
        width: towerW * 0.45,
        depth: towerD * 0.45,
        height: 3.2,
        glazed: false,
      ));
    }

    // Industrial sites get their plant on the roof too, plus a loading canopy.
    if (industrial && spec.powerOutput > 0) {
      final v = volumes.first;
      volumes.add(MassBox(
        x: v.x,
        y: v.y,
        z: v.top,
        width: v.width * 0.35,
        depth: v.depth * 0.35,
        height: 4 + spec.powerOutput * 0.01,
        glazed: false,
      ));
    }

    final area = volumes.fold(0.0, (s, v) => s + (v.floors > 0 ? v.floorArea : 0));

    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: area,
      entrance: (0, buildCentreY - footD / 2),
      parking: parkDepth <= 0.5
          ? null
          : ParkingLot(
              x: 0,
              y: buildCentreY - footD / 2 - parkDepth / 2,
              width: availW,
              depth: parkDepth,
              spaces: spaces,
              lampPosts: _lampGrid(availW, parkDepth,
                  y0: buildCentreY - footD / 2 - parkDepth),
            ),
    );
  }

  /// An open installation: rows of low racks across the site, plus a small
  /// control/maintenance building at one corner.
  ///
  /// Rows rather than one slab because that is what makes the scale legible
  /// from the air — a kilometre of undifferentiated grey reads as a car park,
  /// while a kilometre of repeating rows reads as a solar farm.
  BuildingMassing _field(CityBuildingSpec spec, double w, double d) {
    const rowPitch = 9.0; // row spacing, set by inter-row shading
    const rowDepth = 3.6; // panel run depth
    const rackHeight = 2.6;
    final rows = math.max(1, (d / rowPitch).floor());
    final volumes = <MassBox>[
      for (var i = 0; i < rows; i++)
        MassBox(
          x: 0,
          y: -d / 2 + rowPitch * (i + 0.5),
          z: 0.8,
          width: w * 0.96,
          depth: rowDepth,
          height: rackHeight,
          glazed: false,
        ),
      // Substation / control room on the access side.
      MassBox(
        x: -w / 2 + 12,
        y: -d / 2 + 8,
        z: 0,
        width: 18,
        depth: 12,
        height: 5,
        floors: 1,
      ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storeyM,
      floorArea: 18 * 12,
      entrance: (-w / 2 + 12, -d / 2),
      parking: _lotFor(spec, w, y0: -d / 2 - 20),
    );
  }

  /// An excavation. The hole itself is terrain, cut by a stepped-pit brush; all
  /// that stands here is the plant around its rim.
  BuildingMassing _pit(CityBuildingSpec spec, double w, double d, double storey) {
    final volumes = <MassBox>[
      // Processing shed and ore bins, set back from the crest.
      MassBox(
        x: -w / 2 + math.min(60, w * 0.12),
        y: -d / 2 + math.min(50, d * 0.1),
        z: 0,
        width: math.min(90, w * 0.16),
        depth: math.min(60, d * 0.12),
        height: storey * 2,
        floors: 2,
      ),
      MassBox(
        x: -w / 2 + math.min(140, w * 0.22),
        y: -d / 2 + math.min(46, d * 0.09),
        z: 0,
        width: math.min(28, w * 0.05),
        depth: math.min(28, d * 0.05),
        height: 26,
        glazed: false,
      ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: volumes.first.floorArea,
      entrance: (-w / 2, -d / 2),
      parking: _lotFor(spec, math.min(w, 160), y0: -d / 2 - 30),
    );
  }

  /// A paved apron: hardstanding with a control tower beside it.
  BuildingMassing _apron(CityBuildingSpec spec, double w, double d, double storey) {
    final volumes = <MassBox>[
      // The apron itself — flat, but real geometry so it takes the pad's
      // material rather than showing bare regolith between the pads.
      MassBox(
        x: 0,
        y: 0,
        z: 0,
        width: w,
        depth: d,
        height: 0.25,
        glazed: false,
      ),
      MassBox(
        x: -w / 2 + 30,
        y: -d / 2 + 30,
        z: 0,
        width: 22,
        depth: 22,
        height: math.max(24.0, storey * 8),
        floors: 8,
      ),
    ];
    return BuildingMassing(
      volumes: volumes,
      storeyM: storey,
      floorArea: 22 * 22 * 8,
      entrance: (-w / 2 + 30, -d / 2),
      parking: _lotFor(spec, math.min(w, 240), y0: -d / 2 - 40),
    );
  }

  /// A car park for a site whose building does not front a street.
  ParkingLot? _lotFor(CityBuildingSpec spec, double w, {required double y0}) {
    final spaces = parkingSpaces(spec);
    if (spaces <= 0) return null;
    final depth = (spaces * parkingSpaceM2 / math.max(20.0, w)).clamp(8.0, 140.0);
    return ParkingLot(
      x: 0,
      y: y0 - depth / 2,
      width: w,
      depth: depth,
      spaces: spaces,
      lampPosts: _lampGrid(w, depth, y0: y0 - depth),
    );
  }

  /// Lamp columns on a ~22 m grid — close enough that the pools of light on the
  /// tarmac overlap, which is what makes a car park read as lit rather than as
  /// a dark rectangle with dots on it.
  List<(double, double)> _lampGrid(double w, double d, {required double y0}) {
    final out = <(double, double)>[];
    final cols = math.max(1, (w / 22).round());
    final rows = math.max(1, (d / 22).round());
    for (var i = 0; i < cols; i++) {
      for (var j = 0; j < rows; j++) {
        out.add((
          -w / 2 + w * (i + 0.5) / cols,
          y0 + d * (j + 0.5) / rows,
        ));
      }
    }
    return out;
  }
}
