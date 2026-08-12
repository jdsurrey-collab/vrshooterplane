shader_type spatial;
render_mode blend_mix, cull_disabled, specular_disabled;

// Two-tone cel shading for CloudDeck, replacing StandardMaterial3D's
// DIFFUSE_TOON. Direct request, working from a reference image: bold,
// graphic cumulus clouds with a warm-white lit side and a distinctly COOL
// BLUE-GREY shadow side — not a darker version of the lit color, a
// different hue entirely. That distinction is the whole reason this is a
// custom shader and not a tweak to the old material.
//
// StandardMaterial3D's DIFFUSE_TOON only steps the brightness of the N.L
// term — it still multiplies a single ALBEDO colour, so the shadow side can
// only ever be a dimmer version of the lit side, never a different colour.
// Getting an actual hue shift needs to author the LIT and SHADOW colours
// directly and pick between them, which means writing light() ourselves
// rather than leaning on a diffuse_mode flag.
//
// WHY A CUSTOM light() AND NOT A CHEAPER TRICK (e.g. baking a shadow tint
// into vertex colour against the sun's known fixed direction). This scene
// has no day/night cycle, so the sun direction genuinely is fixed — but a
// static per-vertex bake still can't correctly combine with the thing this
// deck was BUILT for: real buildings casting real shadows across it
// (cloud_deck.gd's whole header is about this). A building's shadow is a
// dynamic shadow-map occlusion event, separate from the cloud's own bump
// shading, and a custom light() is what lets the two compose into ONE
// coherent ramp — ATTENUATION (which already carries shadow-map occlusion)
// and the vertex normal's N.L both fold into the same step, so a vertex is
// only "lit" when it BOTH faces the sun AND isn't shadowed by a tower.
//
// The step is antialiased by a small smoothstep band (shadow_edge_softness),
// not a literal step() — that is purely to stop shader aliasing at the
// transition, not a stylistic softening. The existing density texture
// (cloud_deck.gd's _build_cloud_texture) already commits hard to graphic,
// clearly-separated bands via GRADIENT_INTERPOLATE_CONSTANT; this shader's
// lighting ramp is deliberately just as graphic, on purpose.

uniform sampler2D albedo_texture : source_color, filter_linear, repeat_enable;
uniform vec4 lit_color : source_color = vec4(1.0, 0.98, 0.94, 1.0);
uniform vec4 shadow_color : source_color = vec4(0.55, 0.62, 0.8, 1.0);
uniform float shadow_edge_softness : hint_range(0.001, 0.5, 0.001) = 0.06;
uniform float opacity_scale : hint_range(0.0, 1.0, 0.01) = 0.8;
uniform float emission_energy : hint_range(0.0, 2.0, 0.01) = 0.22;

uniform vec3 uv1_offset = vec3(0.0, 0.0, 0.0);


void fragment() {
	vec4 tex = texture(albedo_texture, UV + uv1_offset.xy);
	ALBEDO = vec3(1.0);
	ALPHA = tex.a * COLOR.a * opacity_scale;
	// Self-glow so sunlit tops read as visibly brighter than the open sky
	// around them at range — same reasoning as the material this replaces:
	// tied to the LIT colour so the glow and the "this side is lit" read
	// reinforce each other instead of being two separately-tuned colours.
	EMISSION = tex.rgb * lit_color.rgb * emission_energy;
}


void light() {
	float ndotl = dot(NORMAL, LIGHT);
	// Real geometric shading (this puff's own bumps, via the mesh's actual
	// per-vertex normals) folded together with real shadow-map occlusion
	// (ATTENUATION) into a single lit/shadow step.
	float lit_amount = smoothstep(-shadow_edge_softness, shadow_edge_softness, ndotl) * ATTENUATION;
	vec3 tone = mix(shadow_color.rgb, lit_color.rgb,
			smoothstep(0.5 - shadow_edge_softness, 0.5 + shadow_edge_softness, lit_amount));
	DIFFUSE_LIGHT += tone * LIGHT_COLOR * ALBEDO;
}
