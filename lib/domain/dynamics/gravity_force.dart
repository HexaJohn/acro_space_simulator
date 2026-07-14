// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../shared/vector3.dart';
import '../universe/celestial_body.dart';
import 'force.dart';
import 'force_model.dart';
import 'mass_properties.dart';
import 'state_vector.dart';

/// Two-body point-mass gravity from the vessel's dominant [body]. The only
/// gravitational contributor under patched conics — exactly one body acts at a
/// time. F = m * a, a = -mu r / |r|^3. Acts through the CoM, so no torque.
class GravityForce implements ForceContributor {
  final CelestialBody body;
  const GravityForce(this.body);

  @override
  GeneralizedForce evaluate(StateVector state, MassProperties mass) {
    final a = body.gravityAt(state.position);
    return GeneralizedForce(a * mass.mass, Vector3.zero);
  }
}
