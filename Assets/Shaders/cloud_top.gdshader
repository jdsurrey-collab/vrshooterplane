shader_type spatial;
render_mode depth_draw_opaque;

// Adapted from "Cloud Material" on godotshaders.com (MIT licensed):
// https://godotshaders.com/shader/cloud-material/
// Real-time FBM vertex-displaced cloud surface, used for cloud_top.gd's
// "looking down from above the deck" layer — see that script's header for
// why this is a separate mesh/shader from cloud_deck.gd rather than a
// reskin of it.
//
// TWO REAL CHANGES FROM THE SOURCE, both required, not stylistic:
//
// 1. WORLD-SCALE NOISE INPUT. The original samples fbm(VERTEX.xz * 4.0,
//    TIME) — correct for a small demo plane a few meters across, where
//    VERTEX.xz is already a small number. This project's world is ~100x a
//    normal Godot scene (see CLAUDE.md's History section), so a plane
//    covering the whole map has VERTEX.xz in the tens of thousands of
//    meters; multiplying that directly by a small constant feeds fbm()
//    enormous coordinates, which reads as fine uncorrelated static instead
//    of cloud-sized lobes — the exact same class of bug this project's
//    OTHER cloud texture already hit once (documented in cloud_deck.gd as
//    the "spider web" bug) for the same underlying reason: noise sampled
//    at too high an effective frequency for the world scale it's applied
//    to. Fixed by scaling VERTEX.xz down by `noise_scale` (exposed so
//    cloud_top.gd can derive it from a real "how wide is one puff, in
//    meters" value) before it ever reaches fbm(), instead of a hardcoded
//    literal.
//
// 2. THE HEIGHT-COLOR BLEND NOW READS THE RAW fbm() VALUE, NOT THE SCALED
//    VERTEX.y. The source compares VERTEX.y itself against a small
//    constant (0.3) — which only works because its own height_scale is
//    small enough that the displaced VERTEX.y stays in roughly the same
//    0..1 numeric range as the raw noise. Here height_scale is genuinely
//    large (real world meters, ~180, so the puffs are visible from a
//    realistic flying altitude/distance) — comparing VERTEX.y against 0.3
//    with that height_scale would make EVERY vertex trip the "tall"
//    branch identically (VERTEX.y clears 0.3 the instant height_scale is
//    more than a few units), collapsing all the color/opacity variation
//    the shader is built around. Decoupling the branch from the raw,
//    always-roughly-0..1 `height` value instead of the scaled world-space
//    displacement is what keeps that variation working at any height_scale.
//
// 3. A real typo in the source's upper-color comparison, fixed here:
//    `color2.b == color2.b` (always true, comparing a value to itself)
//    should be `soft_color.b == color2.b`. Harmless in practice — the
//    first two channels already agree by construction — but there's no
//    reason to carry a known-wrong comparison forward.
//
// Everything else (the hash/noise/fbm functions, the two-tier
// transparency) is the original technique unchanged.

uniform float height_scale = 180.0;
uniform float wave_speed = 0.04;
uniform float upper_transparency = 0.6;
uniform float global_transparency = 0.88;

uniform vec2 time_factor = vec2(2.0, 3.0);
uniform sampler2D texture_albedo : source_color;
uniform vec3 uv1_scale = vec3(1.0, 1.0, 1.0);
uniform vec3 uv1_offset = vec3(0.0, 0.0, 0.0);

uniform vec4 color1 : source_color = vec4(0.85, 0.90, 0.94, 1.0);
uniform vec4 color2 : source_color = vec4(0.98, 0.99, 1.0, 1.0);

// How many world meters one fbm "unit" spans — see the header note above.
// A larger value means bigger, gentler puffs; a smaller value means finer,
// busier ones.
uniform float noise_scale = 0.0011;

// Soft fade toward the mesh's own edge, matching cloud_deck.gd's "don't
// terminate in a hard rectangle against the sky" reasoning — computed from
// local VERTEX position (half_size is this mesh's own half-width in
// meters) rather than vertex color, since this is a plain PlaneMesh, not a
// hand-built ArrayMesh with per-vertex color like CloudDeck's.
uniform float half_size = 1.0;
uniform float edge_fade_start = 0.75;

varying flat vec3 out_color;
varying flat vec3 soft_color;
varying float edge_alpha;

vec3 lerpColor(vec4 a, vec4 b, float t) {
	float rr = a.r + (b.r - a.r) * t;
	float gg = a.g + (b.g - a.g) * t;
	float bb = a.b + (b.b - a.b) * t;
	return vec3(rr, gg, bb);
}

float hash(vec2 p) {
	return fract(sin(dot(p * 17.17, vec2(14.91, 67.31))) * 4791.9511);
}

float noise(vec2 x) {
	vec2 p = floor(x);
	vec2 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	vec2 a = vec2(1.0, 0.0);
	return mix(mix(hash(p + a.yy), hash(p + a.xy), f.x),
			mix(hash(p + a.yx), hash(p + a.xx), f.x), f.y);
}

float fbm(vec2 x, float time) {
	float height = 0.0;
	float amplitude = 0.5;
	float frequency = 0.5;
	for (int i = 0; i < 6; i++) {
		height += noise(x * frequency + time * time_factor * wave_speed) * amplitude;
		amplitude *= 0.5;
		frequency *= 2.0;
	}
	return height;
}

void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;

	out_color = vec3(color1.r, color1.g, color1.b);
	soft_color = vec3(color1.r, color1.g, color1.b);

	float height = fbm(VERTEX.xz * noise_scale, TIME);
	VERTEX.y += height * height_scale;
	COLOR.xyz = vec3(height);

	// Branches on the RAW fbm value (~0..1), not the scaled VERTEX.y
	// displacement — see this file's header, change #2.
	if (height > 0.55) {
		out_color = lerpColor(color1, color2, clamp((height - 0.3) / 0.6, 0.5, 1.0));
		soft_color = vec3(color2.r, color2.g, color2.b);
	}

	float edge_dist = max(abs(VERTEX.x), abs(VERTEX.z)) / half_size;
	edge_alpha = 1.0 - smoothstep(edge_fade_start, 1.0, edge_dist);
}

void fragment() {
	ALBEDO = COLOR.xyz;
	vec4 albedo_tex = texture(texture_albedo, UV);
	ALPHA = global_transparency;
	ALBEDO = out_color * albedo_tex.rgb * COLOR.xyz;
	if (soft_color.r == color2.r && soft_color.g == color2.g && soft_color.b == color2.b) {
		ALPHA = upper_transparency;
	}
	ALPHA *= edge_alpha;
}
