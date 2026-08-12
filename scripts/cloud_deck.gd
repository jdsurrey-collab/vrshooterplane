extends Node3D

## A lit cloud deck covering the ENTIRE MAP at a fixed absolute altitude: a
## single alpha-blended mesh that the tallest towers punch through, so they
## cast real shadows across it.
##
## WHY A MESH AND NOT VOLUMETRIC FOG. This is the cheap way to get the one
## thing volumetric fog was wanted for. Because the deck is an ordinary LIT
## surface, the DirectionalLight3D's shadow map applies to it exactly as it
## does to the ground — no special support needed, no froxel grid. Compared
## to the volumetric attempts it is one draw call instead of a 147k-cell 3D
## grid evaluated per frame per eye, it is visible from any distance instead
## of only within `volumetric_fog_length`, and it cannot jitter because
## nothing is being resampled as the camera moves.
##
## ABSOLUTE ALTITUDE, MATCHING atmosphere.gd's BAND. The deck sits at the
## midpoint of `Atmosphere`'s `cloud_base_y`/`cloud_thickness` (read directly
## from that node in _ready(), not duplicated as separate exports, so the
## visible layer and the "you go blind inside it" fog band can never drift
## out of sync). Earlier versions measured height above LOCAL ground and
## only covered the city footprint — raised on request ("raise that fog up,
## it's way too low") and widened to the whole map ("I'd like that fog to
## cover the entire map"), both of which a fixed world-Y sheet the size of
## the terrain solves at once. This also means the deck no longer needs
## Terrain for height sampling — only for its `world_size`, so the ordering
## hazard that once had this node build itself before Terrain existed no
## longer applies to placement (only to the footprint size, and that read
## happens the same frame regardless).
##
## THE DECK MUST SIT BELOW THE TOWER TOPS. Shadows fall away from the light,
## and the sun is overhead — a building cannot cast onto anything above
## itself. A deck floating above the skyline would just be evenly lit.
## Landmark towers reach ~1800-3800m depending on the terrain under them;
## with the deck at `Atmosphere.cloud_base_y + cloud_thickness/2`, the
## tallest few hundred break through, and it's those protruding towers that
## lay the shadows.
##
## SOFT EDGES MATTER at the map's own boundary — vertex-colour alpha fades
## the deck out before the terrain itself ends, so it doesn't terminate in a
## hard rectangle against the sky.

@export var enabled: bool = true:
	set(value):
		enabled = value
		visible = enabled

## How far past the terrain's own extent the deck is built, so its faded
## edge sits beyond the playable world rather than exactly at the boundary.
@export var coverage_scale: float = 1.1

## Grid resolution across the whole deck. Only needs to be enough for the
## gentle undulation below — the shadows come from the light, not from the
## geometry, and at world-map scale a coarse grid is imperceptible.
@export var subdivisions: int = 96

## Vertical wobble so the deck isn't a dead-flat plane. Also drives the
## per-vertex normals now (see _build_deck_mesh) — raised from an original
## 120 alongside that change, since a flat-normal deck didn't need much
## bump height to still look right, but real per-vertex shading needs
## enough amplitude to actually read as puffy 3D shapes rather than a
## faint ripple.
@export var undulation: float = 200.0

## Warm-white sunlit tops. Two-tone cel shading (see cloud_deck_toon.gdshader)
## replaced the old flat deck_color + StandardMaterial3D DIFFUSE_TOON, per a
## reference image of bold graphic cumulus with a genuinely different-hued
## shadow side rather than just a darker one.
@export var lit_color: Color = Color(1.0, 0.98, 0.94)
## Cool blue-grey shadow side — the actual point of the change. DIFFUSE_TOON
## could only ever dim the lit colour toward black; this is a distinct hue,
## which needs its own uniform rather than a derived darkening.
@export var shadow_color: Color = Color(0.55, 0.62, 0.8)
## Antialiasing width of the lit/shadow step, NOT a stylistic softener — the
## look is deliberately a hard graphic 2-band split, same as the density
## texture's own GRADIENT_INTERPOLATE_CONSTANT bands below. This just keeps
## that step from aliasing/shimmering.
@export var shadow_edge_softness: float = 0.06
## How much of shadow_color fills the shader's own AMBIENT_LIGHT term —
## real bug fix, not a stylistic knob: leaving ambient to Godot's automatic
## ALBEDO-driven default produced a strong, un-toon-stepped wash that
## flattened the whole lit/shadow ramp, reported live as the new shading
## "looking exactly like it did before." See cloud_deck_toon.gdshader's own
## note on AMBIENT_LIGHT.
@export var ambient_floor: float = 0.3
## Peak opacity of the thickest patches; the noise ramp takes it to fully
## transparent elsewhere, which is what makes it read as broken cloud rather
## than a lid.
@export var opacity: float = 0.8
## World size of one tile of the cloud pattern.
@export var pattern_scale: float = 3400.0
## Slow UV drift, so the deck moves without any geometry moving.
@export var drift_speed: Vector2 = Vector2(0.0035, 0.0022)

@export var atmosphere_path: NodePath = ^"../Atmosphere"
@export var terrain_path: NodePath = ^"../Terrain"

const TOON_SHADER := preload("res://Assets/Shaders/cloud_deck_toon.gdshader")

var _material: ShaderMaterial
var _drift: Vector2 = Vector2.ZERO


func _ready() -> void:
	var atmosphere := get_node_or_null(atmosphere_path)
	var terrain := get_node_or_null(terrain_path)
	if not atmosphere or not terrain:
		push_warning("CloudDeck: missing Atmosphere or Terrain, no deck built")
		set_process(false)
		return

	var centre: Vector3 = terrain.global_position
	var half: float = terrain.world_size * 0.5 * coverage_scale
	var deck_y: float = atmosphere.cloud_base_y + atmosphere.cloud_thickness * 0.5

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = _build_deck_mesh(centre, half, deck_y)
	_material = _build_material()
	mesh_instance.material_override = _material
	# Receives the sun's shadows — the entire point — but casts none. A
	# cloud sheet throwing a hard shadow over the whole map would be wrong,
	# and it would also put everything below it into permanent darkness.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)

	visible = enabled


func _build_deck_mesh(centre: Vector3, half: float, deck_y: float) -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.00035
	noise.fractal_octaves = 3

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var step := (half * 2.0) / float(subdivisions)
	# Sample offset for the central-difference normal below. Half a grid
	# step keeps it matched to the mesh's own resolution rather than an
	# arbitrary constant, so the normals stay consistent if subdivisions
	# ever changes.
	var eps := step * 0.5

	for i in subdivisions + 1:
		for j in subdivisions + 1:
			var x := centre.x - half + float(i) * step
			var z := centre.z - half + float(j) * step
			var h := noise.get_noise_2d(x, z) * undulation
			verts.append(Vector3(x, deck_y + h, z))
			uvs.append(Vector2(x / pattern_scale, z / pattern_scale))
			# REAL per-vertex normals from the noise gradient (central
			# difference), not a flat Vector3.UP. This used to be
			# deliberately flat "so the sun's shadow reads cleanly across
			# it rather than shading oddly over every undulation" — but
			# that only affects whether OTHER objects' shadows land
			# cleanly (a shadow-map lookup, independent of the receiver's
			# own normal), not whether the deck's own bumps catch light.
			# Real normals are what make the puffs read as actual 3D
			# shapes with light/dark facets instead of a flat sheet with a
			# picture painted on it — see DIFFUSE_TOON in _build_material.
			var h_x1: float = noise.get_noise_2d(x + eps, z) * undulation
			var h_x0: float = noise.get_noise_2d(x - eps, z) * undulation
			var h_z1: float = noise.get_noise_2d(x, z + eps) * undulation
			var h_z0: float = noise.get_noise_2d(x, z - eps) * undulation
			var normal := Vector3(-(h_x1 - h_x0) / (2.0 * eps), 1.0, -(h_z1 - h_z0) / (2.0 * eps)).normalized()
			normals.append(normal)
			colors.append(Color(1.0, 1.0, 1.0, _edge_alpha(x, z, centre, half)))

	var row := subdivisions + 1
	for i in subdivisions:
		for j in subdivisions:
			var a := i * row + j
			var b := a + 1
			var c := (i + 1) * row + j
			var d := c + 1
			indices.append_array([a, c, b, b, c, d])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Radial fade toward the deck's boundary, carried in vertex alpha. Uses the
## larger of the two axis distances rather than a circular falloff so the
## corners of the rectangle fade too.
func _edge_alpha(x: float, z: float, centre: Vector3, half: float) -> float:
	var edge_distance: float = maxf(absf(x - centre.x), absf(z - centre.z)) / half
	return 1.0 - smoothstep(0.75, 1.0, edge_distance)


## Two-tone TOON shading via a custom light() function
## (Assets/Shaders/cloud_deck_toon.gdshader), replacing StandardMaterial3D's
## DIFFUSE_TOON — see that file's header for exactly why: the built-in toon
## diffuse mode can only dim a single ALBEDO colour toward black, so the
## shadow side could never be a genuinely different hue. This shader picks
## between `lit_color` and `shadow_color` directly, combining the mesh's own
## real per-vertex normals (this puff's bumps) with real shadow-map
## occlusion (buildings crossing the deck) into one graphic step, matching
## the same hard-banded "cel shaded... dynamic contrast" direction the
## density texture below already commits to.
func _build_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = TOON_SHADER
	mat.set_shader_parameter("albedo_texture", _build_cloud_texture())
	mat.set_shader_parameter("lit_color", lit_color)
	mat.set_shader_parameter("shadow_color", shadow_color)
	mat.set_shader_parameter("shadow_edge_softness", shadow_edge_softness)
	mat.set_shader_parameter("ambient_floor", ambient_floor)
	mat.set_shader_parameter("opacity_scale", opacity)
	mat.set_shader_parameter("emission_energy", 0.22)
	mat.set_shader_parameter("uv1_offset", Vector3.ZERO)
	# Transparent surfaces don't write depth by default; that's correct here,
	# so towers punching through sort properly against it — unchanged from
	# the StandardMaterial3D this replaces.
	return mat


## Noise run through a gradient that ends fully transparent, so the deck is
## broken cloud with real gaps rather than a uniform sheet. The gradient is
## what carries the ALPHA — a plain grayscale noise texture is opaque
## everywhere and would just tint the deck.
##
## TUNED SOFT AGAINST THE SPIDER-WEB BUG. An early version (frequency 0.9, 4
## octaves, a gradient snapping from 0.0 to 0.12 alpha within the first 38%
## of the range) read as a "spider web" from above rather than fog —
## high-frequency fractal noise is naturally made of thin connected ridges,
## and a high-contrast alpha cutoff turns those ridges into lace instead of
## soft puffs. Fixed by keeping the BASE frequency low (0.28) — that sets
## the scale of the fundamental blob shapes and is what actually prevents
## the lace, independent of octave count.
##
## Later raised back to 4 octaves (from an intermediate 2) specifically to
## add "bubbly" cauliflower-style surface detail per direct request ("more
## cell shaded... dynamic contrast... I wanna be able to see this bubbly
## smoke") — more octaves layer smaller bumps ON TOP of the low-frequency
## base shape without changing that base shape's scale, which is the
## standard fBm technique for lumpy cumulus-style noise. This is safe
## against the original bug specifically because the base frequency wasn't
## raised back up alongside it.
##
## THE ALPHA RAMP IS NOW STEPPED, NOT SMOOTH — `GRADIENT_INTERPOLATE_CONSTANT`
## instead of the default linear/cubic blend. This is the actual "cell
## shaded" ask: a handful of graphic, clearly-separated density bands
## (clear sky / wispy edge / mid puff / solid core) rather than a
## continuous fog-like translucency gradient. Resolution doubled to 1024 to
## cut the blocky/"pixelated" look the previous 512px texture had once
## viewed up close against this deck's ~3400m tile scale.
func _build_cloud_texture() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.28
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.4

	var ramp := Gradient.new()
	ramp.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	ramp.offsets = PackedFloat32Array([0.0, 0.42, 0.55, 0.7, 0.85])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.28),
		Color(1.0, 1.0, 1.0, 0.55),
		Color(1.0, 1.0, 1.0, 0.82),
		Color(1.0, 1.0, 1.0, 1.0),
	])

	var tex := NoiseTexture2D.new()
	tex.width = 1024
	tex.height = 1024
	tex.seamless = true
	tex.noise = noise
	tex.color_ramp = ramp
	# Mipmaps are what keep the hard step edges from aliasing/shimmering at
	# a distance — they still blend smoothly across mip levels even though
	# the base texture itself is stepped, same as filtered pixel art.
	tex.generate_mipmaps = true
	return tex


## Scrolling the UVs is the entire animation — no geometry moves, so there
## is nothing to jitter and no per-frame mesh work.
func _process(delta: float) -> void:
	if not _material:
		return
	_drift += drift_speed * delta
	_material.set_shader_parameter("uv1_offset", Vector3(_drift.x, _drift.y, 0.0))
