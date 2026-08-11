shader_type spatial;
render_mode blend_add, unshaded, cull_back, depth_draw_never, shadows_disabled;

// Glowing explosion orb — the mesh-based replacement for the particle
// fireball that used to mark a ship kill.
//
// WHY A SHADER AND NOT JUST AN EMISSIVE SPHERE. An unshaded sphere with a
// flat colour renders as a hard-edged flat DISC: every fragment of the
// visible hemisphere is the same brightness, so the silhouette is a crisp
// circle and there is no sense of volume at all. It reads as a sticker, not
// a fireball.
//
// The fix is one dot product. NORMAL and VIEW are both in view space and
// VIEW points from the fragment toward the camera, so their dot is 1.0 at
// the centre of the sphere's projected disc and falls to 0.0 exactly at its
// silhouette. Using that as density makes the orb brightest through its
// middle and feather out to nothing at the rim — which is both what a ball
// of burning gas actually looks like and, conveniently, what you would get
// from properly integrating density through a sphere. It is a cheap stand-in
// for a volumetric integral, in the same spirit as everything else in this
// project that reaches for the affordable approximation (see CLAUDE.md on
// volumetric fog being rejected three times).
//
// ADDITIVE, deliberately. A fireball emits light rather than occluding what
// is behind it, so it should brighten whatever it overlaps — and additive
// blending needs no back-to-front sorting, which matters when up to
// `max_concurrent_explosions` (14) of these can overlap each other and the
// rest of the battle's transparent geometry.
//
// `depth_draw_never` so overlapping orbs don't clip against one another, but
// depth TESTING stays on, so terrain and buildings still occlude an
// explosion happening behind them.

uniform vec3 orb_color : source_color = vec3(1.0, 0.72, 0.35);

// Pushed well above 1.0 so Town.tscn's Glow pass (threshold 1.15) blooms the
// core — the bloom is most of what sells this as hot rather than as a
// coloured ball, the same technique used for the HUD text and tracer bolts.
uniform float energy : hint_range(0.0, 40.0) = 8.0;

// Driven from ship_explosion.gd across the life of the flash.
uniform float fade : hint_range(0.0, 1.0) = 1.0;

// Higher = tighter, hotter core with a faster falloff to the rim.
uniform float edge_softness : hint_range(0.1, 8.0) = 2.2;


void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float density = pow(facing, edge_softness);
	ALBEDO = orb_color * energy * density * fade;
	ALPHA = density * fade;
}
