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
import 'architecture_style.dart';

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

  /// Height of the GROUND storey, which is usually not the height of the
  /// others: retail wants 4.5 m where the offices above it want 3.5. Carried
  /// beside [storeyM] rather than replacing it because everything above the
  /// ground floor really is a uniform stack, and one extra number is cheaper
  /// than a per-floor table nothing else would read.
  final double groundStoreyM;

  /// The idiom this was massed in. The geometry pass reads the same one, so a
  /// building cannot end up sited as a street wall and detailed as an office
  /// park.
  final ArchitectureStyle style;

  /// This building holds a corner: its lot touches a second street.
  final bool corner;

  /// Which band of the facade atlas this building's walls are cut from.
  ///
  /// Decided HERE, with the rest of the brief, so it is one number that
  /// travels with the massing rather than something the geometry pass rolls
  /// for itself — which would make the same building a different colour every
  /// time it was regenerated.
  final int material;

  const BuildingMassing({
    required this.volumes,
    required this.storeyM,
    required this.floorArea,
    required this.entrance,
    this.parking,
    double? groundStoreyM,
    this.style = ArchitectureStyle.utilitarian,
    this.material = FacadeMaterial.precast,
    this.corner = false,
  }) : groundStoreyM = groundStoreyM ?? storeyM;

  /// Base height of floor [index] within a volume standing on the ground.
  double floorBase(int index) =>
      index <= 0 ? 0 : groundStoreyM + (index - 1) * storeyM;

  /// Height of the bottom [floors] storeys of a ground-standing volume.
  double stackHeight(int floors) =>
      floors <= 0 ? 0 : groundStoreyM + (floors - 1) * storeyM;

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
    this.style = ArchitectureStyle.utilitarian,
    this.storeyM = 3.6,
    this.industrialStoreyM = 7.5,
    this.areaPerResident = 42,
    this.areaPerWorker = 22,
    this.setbackM = 3,
    this.maxFloors = 60,
    this.parkingSpaceM2 = 26,
  });

  /// The urban idiom: where the building stands on its lot, how tall its
  /// ground floor is, when it steps back. See [ArchitectureStyle] — the
  /// siting numbers in there do more for how a street looks than anything in
  /// this class.
  final ArchitectureStyle style;

  BuildingMassingRules withStyle(ArchitectureStyle s) => BuildingMassingRules(
        style: s,
        storeyM: storeyM,
        industrialStoreyM: industrialStoreyM,
        areaPerResident: areaPerResident,
        areaPerWorker: areaPerWorker,
        setbackM: setbackM,
        maxFloors: maxFloors,
        parkingSpaceM2: parkingSpaceM2,
      );

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
    // A megatower parks inside its own podium: eighteen thousand workers on
    // a surface lot would need more block than the building has.
    if (spec.type == 'mega') return 0;
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
    final corner = parcel.isCorner;
    final rnd = math.Random(seed ^ spec.label.hashCode);
    final industrial = _isIndustrial(spec);
    final storey = industrial ? industrialStoreyM : style.upperStoreyM;
    final ground = industrial ? industrialStoreyM : style.groundStoreyM;

    // Land available once the setbacks are taken off, in the parcel's own
    // frontage-aligned axes: width runs ALONG the street, depth away from it,
    // and local y = -depth/2 IS the curb line.
    //
    // The setbacks come from the style, and they are asymmetric on purpose: a
    // street-wall building stands hard on the front line and keeps its yard at
    // the back, where the alley and the parking go. Taking the same margin off
    // both ends is what centred every building in its lot and left a downtown
    // block looking like a business park.
    //
    // Zero side setback does NOT mean building over the property line: the
    // parcel handed in here has already been inset by the density rule in the
    // world snapshot. Zero means "fill what I was given", which is what makes
    // neighbours meet.
    //
    // Capped to the spec's real site size — a solar farm dropped on a
    // ten-kilometre manual lot is still a solar farm, not a ten-kilometre one.
    // The cap applies ONLY to specs that declare a site: ordinary street
    // buildings have no fixed extent and must keep taking their shape from the
    // parcel, or every lot in the city would produce the same building.
    final site = spec.siteMetres();
    final capW = spec.siteWidthM > 0 ? site.width : double.infinity;
    final capD = spec.siteDepthM > 0 ? site.depth : double.infinity;
    final frontEdge = -extent.depth / 2 + style.frontSetbackM;
    final rearEdge = extent.depth / 2 - style.rearSetbackM;
    final availW =
        math.min(math.max(6.0, extent.width - style.sideSetbackM * 2), capW);
    final availD = math.min(math.max(6.0, rearEdge - frontEdge), capD);

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

    // Parking takes a strip off one END of the buildable depth whenever there
    // is room for it; a building that would then have nowhere to stand keeps
    // its plot and loses the lot instead.
    //
    // WHICH end is a style decision and it is not cosmetic. A lot out front
    // pushes the building back off the street and opens a gap in the block —
    // it is the single change that turns a downtown into a strip. Behind the
    // building, off the alley, the same cars are invisible from the pavement.
    var parkDepth = 0.0;
    if (parkArea > 0) {
      parkDepth = (parkArea / availW).clamp(0.0, availD * 0.55);
    }
    final buildD = math.max(6.0, availD - parkDepth);
    final buildW = availW;

    // Footprint: industrial fills its plot, everything else keeps a slimmer
    // block so a dense street does not become one continuous wall.
    // Coverage stays a property of the MASSING, not of density.
    //
    // How much of its plot a building takes by density is decided once, where
    // the lot is measured (`lotCoverageFor` / `lotSetbackFor` in the world
    // snapshot), and the parcel handed to this generator is already inset by
    // it. Applying a density rule here too multiplied the two together and
    // pushed geometry outside its own lot — caught by the architecture tests,
    // which is exactly what they are for.
    // A street wall fills its frontage edge to edge — that IS the street wall.
    // Everything else keeps a slimmer block.
    final coverW = style.sideSetbackM <= 0.01
        ? 1.0
        : (industrial ? 0.92 : 0.7 + rnd.nextDouble() * 0.12);
    final coverD = style.isStreetWall
        ? 0.88 + rnd.nextDouble() * 0.12
        : (industrial ? 0.92 : 0.7 + rnd.nextDouble() * 0.12);
    final footW = buildW * coverW;
    final footD = buildD * coverD;
    final footArea = footW * footD;

    // Floors are bounded by DENSITY, not just by the global cap. Deriving them
    // from required area over footprint alone made a low-density home sixteen
    // storeys tall on a small plot — arithmetically reasonable, and nothing
    // like the detached house the zoning asked for. Intensity is the density
    // signal a spec carries; the ceilings are what each tier looks like.
    final intensity = spec.housing + spec.jobs;
    final tierCap = intensity >= 90
        ? maxFloors
        : (intensity >= 30 ? 8 : 3);

    // What the TENANT needs, which is a minimum and not a design.
    final byDemand =
        (needed / footArea).ceil().clamp(1, math.min(maxFloors, tierCap)).toInt();

    // What the LAND wants. See [ArchitectureStyle.zoneFloors]: a downtown lot
    // is built tall because of where it is, not because of who leases it, and
    // the demand figure alone put a two-storey box on every plot in the middle
    // of the city. The zone target overrides the intensity ceiling as well —
    // that ceiling exists to stop a small tenant becoming a tower by accident,
    // which is the opposite of a deliberate one.
    final byZone = industrial ? 0 : style.targetFloors(spec, seed ^ spec.type.hashCode);
    var floors = industrial
        ? 1
        : math.max(byDemand, byZone).clamp(1, maxFloors).toInt();

    // A corner earns a storey. In every one of the reference streets the tall
    // element of a block is on its corner — it is the part you can see from
    // two directions, so it is the part worth building up — and a block whose
    // corners are the same height as its middle reads as a single extruded
    // shape rather than as a row of buildings.
    if (!industrial && corner && floors < maxFloors) floors += 1;

    // CORNICE DATUM. Real neighbours line their cornices up, because they were
    // built to the same storey heights against the same street. Left free,
    // floor counts come out of a division and every building lands a metre or
    // two off its neighbour, which gives a row of buildings a ragged top edge
    // that nothing in the photographs has.
    //
    // Quantising the COUNT rather than the height is what makes them actually
    // coincide: two buildings with the same storey height and the same number
    // of floors have their cornice at the same height by construction, and
    // the arithmetic cannot drift.
    if (!industrial && style.corniceDatumFloors > 1 && floors > 2) {
      final q = style.corniceDatumFloors;
      // Lower bound guarded against a kit configured with fewer maximum
      // floors than its own cornice datum — `clamp` throws outright when its
      // limits cross, which is a crash rather than a bad-looking building.
      final snapped =
          ((floors / q).round() * q).clamp(math.min(q, maxFloors), maxFloors);
      floors = snapped.toInt();
    }
    // A shed that cannot hold its function on one floor grows a mezzanine
    // rather than a tower.
    if (industrial && needed > footArea * 1.4) floors = 2;

    // MEGATOWER: the one building allowed past the ordinary ceiling. Both
    // regular caps exist to stop ACCIDENTAL towers — [maxFloors] (60) is the
    // hard lid, and the kit's zone targets are why every downtown tower tops
    // out around the same height — but a megatower is nothing but deliberate,
    // so its height is its own seeded rule: 90 to 150 storeys over a full
    // block. The profile mix below shapes it like anything else tall.
    if (spec.type == 'mega') {
      final h = (seed ^ 0x35C0DE) * 2654435761 & 0x7FFFFFFF;
      floors = 90 + h % 61;
    }

    final volumes = <MassBox>[];
    // Where the building sits within its buildable strip, and where the cars
    // go. Front-parking pushes the building back; rear-parking pulls it
    // forward onto the street line.
    final buildCentreY = style.parkingBehind
        ? frontEdge + buildD / 2
        : frontEdge + parkDepth + buildD / 2;
    final parkCentreY = style.parkingBehind
        ? frontEdge + buildD + parkDepth / 2
        : frontEdge + parkDepth / 2;
    // Total height of a stack of [n] floors, with the ground storey taller.
    double stack(int n) => n <= 0 ? 0 : ground + (n - 1) * storey;

    if (floors <= style.stepbackAboveFloors) {
      volumes.add(MassBox(
        x: 0,
        y: buildCentreY,
        z: 0,
        width: footW,
        depth: footD,
        height: stack(floors),
        floors: floors,
      ));
    } else {
      // Three tall profiles, drawn per building. One profile for every tower
      // — the podium-and-setback — made a downtown read as a tray of the
      // same wedding cake at different heights, and the 0.52-0.68 tower
      // fraction on a street-lot footprint made every one of them a pencil.
      // Real skylines mix straight-extruded slabs, podium towers, and the
      // stepped ziggurats the 1916 zoning envelope produced — and their
      // upper shafts hold more of their base than the old fraction allowed.
      final profile = rnd.nextDouble();
      final podiumFloors = math.min(style.podiumFloors, floors - 1);
      final towerFloors = floors - podiumFloors;

      if (profile < 0.34) {
        // Straight extrusion: the whole footprint straight to the parapet.
        // The profile of most real mid-rise and plenty of towers.
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: 0,
          width: footW,
          depth: footD,
          height: stack(floors),
          floors: floors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: stack(floors),
          width: footW * 0.4,
          depth: footD * 0.4,
          height: 3.2,
          glazed: false,
        ));
      } else if (profile < 0.72) {
        // Podium and tower: the base holds the street, the shaft steps back.
        final towerW = footW * (0.62 + rnd.nextDouble() * 0.22);
        final towerD = footD * (0.62 + rnd.nextDouble() * 0.22);
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: 0,
          width: footW,
          depth: footD,
          height: stack(podiumFloors),
          floors: podiumFloors,
        ));
        volumes.add(MassBox(
          // Offset the tower toward the back of the podium, so the street
          // gets a set-back frontage rather than a slab off the pavement.
          x: (rnd.nextDouble() - 0.5) * (footW - towerW) * 0.4,
          y: buildCentreY + (footD - towerD) * 0.18,
          z: stack(podiumFloors),
          width: towerW,
          depth: towerD,
          height: towerFloors * storey,
          floors: towerFloors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY + (footD - towerD) * 0.18,
          z: stack(floors),
          width: towerW * 0.45,
          depth: towerD * 0.45,
          height: 3.2,
          glazed: false,
        ));
      } else {
        // Ziggurat: two setbacks on the way up, each tier holding most of
        // the one below. The wedding-cake profile the zoning envelope built.
        final t1Floors = math.max(1, ((floors - podiumFloors) * 0.55).round());
        final t2Floors = math.max(1, floors - podiumFloors - t1Floors);
        final w1 = footW * (0.78 + rnd.nextDouble() * 0.1);
        final d1 = footD * (0.78 + rnd.nextDouble() * 0.1);
        final w2 = w1 * (0.68 + rnd.nextDouble() * 0.12);
        final d2 = d1 * (0.68 + rnd.nextDouble() * 0.12);
        final back1 = buildCentreY + (footD - d1) * 0.25;
        volumes.add(MassBox(
          x: 0,
          y: buildCentreY,
          z: 0,
          width: footW,
          depth: footD,
          height: stack(podiumFloors),
          floors: podiumFloors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: back1,
          z: stack(podiumFloors),
          width: w1,
          depth: d1,
          height: t1Floors * storey,
          floors: t1Floors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: back1 + (d1 - d2) * 0.25,
          z: stack(podiumFloors) + t1Floors * storey,
          width: w2,
          depth: d2,
          height: t2Floors * storey,
          floors: t2Floors,
        ));
        volumes.add(MassBox(
          x: 0,
          y: back1 + (d1 - d2) * 0.25,
          z: stack(podiumFloors) + (t1Floors + t2Floors) * storey,
          width: w2 * 0.45,
          depth: d2 * 0.45,
          height: 3.0,
          glazed: false,
        ));
      }
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
      groundStoreyM: ground,
      style: style,
      // Industry gets precast or profiled metal whatever the kit says. A
      // fabrication shed faced in cream terracotta is not a stylistic choice,
      // it is a bug you can see from orbit.
      corner: corner,
      material: industrial
          ? (rnd.nextBool()
              ? FacadeMaterial.precast
              : FacadeMaterial.metalPanel)
          : style.materialFor(seed ^ spec.type.hashCode),
      floorArea: area,
      entrance: (0, buildCentreY - footD / 2),
      parking: parkDepth <= 0.5
          ? null
          : ParkingLot(
              x: 0,
              y: parkCentreY,
              width: availW,
              depth: parkDepth,
              spaces: spaces,
              lampPosts: _lampGrid(availW, parkDepth,
                  y0: parkCentreY - parkDepth / 2),
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
      style: style,
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
      style: style,
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
      style: style,
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
