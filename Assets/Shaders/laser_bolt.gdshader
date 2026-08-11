shader_type spatial;
render_mode blend_add, unshaded, cull_back, depth_draw_never, shadows_disabled;

// Glowing energy bolt — replaces a flat, opaque, single-colour emissive
// cylinder. Reported live: "the lasers... feel kind of old fashioned."
// The cause was literal, not a matter of taste: a hard-edged 8-sided
// polygon tube with one flat colour reads as a solid physical object (a
// dart or a tracer round), not as a beam of energy.
//
// This applies the SAME two ideas already proven in this project's other
// two "hot glowing thing" effects — the kill fireball
// (explosion_orb.gdshader) and the missile ribbon trail (ribbon_trail.gd) —
// rather than inventing a third visual language:
//
// 1. VIEW-FACING DENSITY FALLOFF, identical to explosion_orb.gdshader.
//    dot(NORMAL, VIEW) is 1.0 at the point of the surface facing the camera
//    dead-on and falls to 0.0 at the silhouette, so using it as density
//    makes the bolt brightest through its centre and feather to nothing at
//    the rim — a soft glowing rod instead of a hard-edged tube. Works
//    correctly at any viewing angle including nearly end-on, where the
//    cylinder's own end caps (their normals pointing straight down the
//    bolt's axis) take over and read as a bright point growing toward the
//    camera — which is the physically correct read for a shot flying
//    straight at you.
//
// 2. HOT-CORE-TO-COOL-TAIL GRADIENT, identical in spirit to
//    ribbon_trail.gd's head/tail colour (white leading edge, cooling
//    toward the tail). The bolt mesh already tapers — narrow "top_radius"
//    at the leading tip (this project's own header calls it "a tapered/
//    arrow-shaped bolt"), wide "bottom_radius" at the trailing end — so the
//    gradient is driven directly off the LOCAL RADIUS at each vertex
//    (`length(VERTEX.xz)` against the `top_radius`/`bottom_radius`
//    uniforms) rather than off which axis sign happens to be "front":
//    correct regardless of the mesh's exact orientation, and it can't drift
//    out of sync with the mesh the way a separately-tracked "which end is
//    the tip" flag could.
//
// TWO CONSUMERS, one shader: LaserBolt.tscn (the player's own bolts, and
// alien fire aimed at the player via the same scene) and
// faction_battle.gd's ambient MultiMesh bolt pool (the mass-battle "lasers
// everywhere" tracers). The ambient pool tints per-instance via
// MultiMesh's own per-instance COLOR (its faction cyan/red) — `tail_color`
// is left neutral WHITE on that material so `tail_color * COLOR` passes
// the faction tint through unmodified, carrying forward the project's
// earlier MULTIPLY-not-ADD fix for "every tracer bloomed the same flat
// white regardless of who fired it" (see CLAUDE.md's tracer-readability
// section) — now expressed directly in this shader's own blend instead of
// a separate `emission_operator` flag. LaserBolt.tscn instead sets
// `tail_color` directly (its own fixed weapon colour) and leaves COLOR at
// its default white, so the multiply is a no-op there.
//
// ADDITIVE, matching the explosion orb's own reasoning: a laser bolt emits
// light rather than occluding what's behind it, and additive needs no
// back-to-front sort order — which matters with up to `max_ambient_bolts`
// (320) potentially overlapping on screen at once. `depth_draw_never` so
// bolts don't clip against each other or against themselves mid-turn;
// depth TESTING stays on so terrain and buildings still occlude a bolt
// passing behind them.
//
// Runs correctly under the existing per-frame INSTANCE SCALING this
// project already applies for muzzle-flash and distance-angular-size
// compensation (faction_battle.gd's `_bolt_transform()`): VERTEX inside
// vertex() is object-local, read before the instance/model transform (and
// any MultiMesh per-instance scale) is applied, so the radius-based
// gradient always reads the bolt's TRUE, unscaled taper regardless of how
// large that frame's instance scale happens to be.

uniform vec3 head_color : source_color = vec3(1.0, 0.97, 0.9);  // hot leading tip, shared across every bolt regardless of faction
uniform vec3 tail_color : source_color = vec3(1.0, 0.15, 0.1);  // trailing-end colour; neutral white on the ambient MultiMesh so per-instance faction COLOR passes through unmodified
uniform float energy : hint_range(0.0, 20.0) = 8.0;
uniform float edge_softness : hint_range(0.1, 8.0) = 2.0;

// Kept in step with the mesh's own CylinderMesh radii by whichever script
// builds the material — see laser_bolt.gd's `_thin_player_mesh()` for the
// one case where those radii change at runtime and the uniforms have to
// follow.
uniform float top_radius = 0.05;
uniform float bottom_radius = 0.28;

varying float length_t;  // 0 at the leading tip, 1 at the trailing end


void vertex() {
	float radius_here = length(VERTEX.xz);
	length_t = clamp((radius_here - top_radius) / max(bottom_radius - top_radius, 0.0001), 0.0, 1.0);
}


void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float density = pow(facing, edge_softness);

	vec3 core = mix(head_color, tail_color * COLOR.rgb, length_t);
	ALBEDO = core * energy * density;
	ALPHA = density;
}
