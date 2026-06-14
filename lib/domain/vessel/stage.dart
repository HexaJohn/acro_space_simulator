import '../dynamics/mass_properties.dart';
import 'part.dart';

/// A staging group: the parts that fire/separate together. Stages are ordered;
/// the active stage's engines produce thrust, and separating it drops its parts
/// (and their mass) from the vessel. Entity within the Vessel aggregate.
class Stage {
  final int index;
  final List<Part> parts;

  const Stage({required this.index, required this.parts});

  Iterable<Part> get engines => parts.where((p) => p.isEngine);

  bool get hasActiveEngine => engines.any((p) {
        // an engine with propellant available somewhere in the stage
        final t = p.engine!.propellant;
        return parts.any((q) => q.containerFor(t) != null);
      });

  MassProperties get massProperties => parts.fold(
        MassProperties.zero,
        (acc, p) => acc + p.massProperties,
      );

  double get mass => parts.fold(0.0, (s, p) => s + p.mass);
}
