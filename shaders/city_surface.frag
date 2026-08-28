// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The engine's standard PBR surface, plus the city's night skyglow — a
// PER-FRAGMENT ambient term that falls off with the surface's own height
// above the colony's ground.
//
// The glow is the city's street and window light thrown back by the air, and
// it pools in the street canyons: pavements and shopfronts bathe in it, the
// fortieth floor rises out of it into the dark. A camera-height fade cannot
// say that (every surface brightened together however tall it was), and one
// directional light cannot either — so the falloff is evaluated here, per
// fragment, from the fragment's radial height above the colony ground shell.
//
// Everything else is the stock pipeline, verbatim: this file is the engine's
// flutter_scene_standard.frag with one uniform block and one emissive term
// added, compiled against the engine GLSL vendored in engine/ (which matches
// the FVM-pinned flutter_scene checkout — re-vendor if the pin ever moves).
// Keeping every stock uniform name and layout is what lets the unmodified
// PhysicallyBasedMaterial.bind feed this shader without knowing it changed.

#include "engine/material_varyings.glsl"
#include "engine/normals.glsl"
#include "engine/pbr.glsl"
#include "engine/texture.glsl"
#include "engine/material_engine_lighting.glsl"
#include "engine/material_inputs.glsl"
#include "engine/material_lighting.glsl"
#include "engine/lod_fade.glsl"

uniform sampler2D base_color_texture;
uniform sampler2D emissive_texture;
uniform sampler2D metallic_roughness_texture;
uniform sampler2D normal_texture;
uniform sampler2D occlusion_texture;

uniform CityGlow {
  // xyz: the body's centre in scene units (origin-relative, same space as
  // v_position). w: the COLONY's ground radius in scene units — height is
  // measured off the ground the city stands on, not the datum sphere, which
  // can sit hundreds of metres away from it.
  vec4 centre_radius;
  // rgb: glow colour * intensity * night factor, linear. Zero by day, so the
  // whole term vanishes without a branch. w: falloff length, scene units.
  vec4 glow;
}
city_glow;

// Fills the surface description for the standard glTF metallic-roughness
// material from the FragInfo parameters and the material textures. The shared
// lighting framework (material_lighting.glsl) consumes it.
void Surface(inout MaterialInputs material) {
  vec4 vertex_color = mix(vec4(1), v_color, frag_info.vertex_color_weight);
  vec4 base_color_srgb = texture(base_color_texture, v_texture_coords);
  vec3 albedo = SRGBToLinear(base_color_srgb.rgb) * vertex_color.rgb *
                frag_info.color.rgb;
  float alpha = base_color_srgb.a * vertex_color.a * frag_info.color.a;
  // MASK alpha mode: discard fragments below the cutoff, render the
  // rest fully opaque (glTF treats MASK output as binary). Done here, before
  // the normal-map derivatives, so the discard's effect on screen-space
  // derivatives matches the original monolithic shader.
  if (frag_info.alpha_mode == 1.0) {
    if (alpha < frag_info.alpha_cutoff) {
      discard;
    }
    alpha = 1.0;
  }
  material.base_color = vec4(albedo, alpha);

  // Note: PerturbNormal needs the non-normalized view vector
  //       (camera_position - vertex_position).
  vec3 normal = normalize(v_normal);
  if (frag_info.has_normal_map > 0.5) {
    normal =
        PerturbNormal(normal_texture, normal, v_viewvector, v_texture_coords);
  }
  material.normal = normal;

  vec4 metallic_roughness =
      texture(metallic_roughness_texture, v_texture_coords);
  material.metallic = clamp(metallic_roughness.b * frag_info.metallic_factor,
                            0.0, 1.0);
  material.roughness =
      clamp(metallic_roughness.g * frag_info.roughness_factor, kMinRoughness,
            1.0);

  float occlusion = texture(occlusion_texture, v_texture_coords).r;
  material.occlusion = 1.0 - (1.0 - occlusion) * frag_info.occlusion_strength;

  material.emissive =
      SRGBToLinear(texture(emissive_texture, v_texture_coords).rgb) *
      frag_info.emissive_factor.rgb;

  // The skyglow, as albedo-tinted emissive: riding the emissive slot keeps it
  // inside the stock lighting, tonemap and alpha path rather than pasted over
  // the finished colour. exp() falloff off the fragment's own height, so the
  // term is strongest on the carriageway and gone at the parapet.
  float height =
      length(v_position - city_glow.centre_radius.xyz) -
      city_glow.centre_radius.w;
  float pooled = exp(-max(height, 0.0) / max(city_glow.glow.w, 1e-6));
  material.emissive += material.base_color.rgb * city_glow.glow.rgb * pooled;

  PrepareMaterial(material);
}

void main() {
  ApplyLodFade(frag_info.fade);
  MaterialInputs material = InitMaterialInputs();
  Surface(material);
  frag_color = EvaluateLighting(material);
}
