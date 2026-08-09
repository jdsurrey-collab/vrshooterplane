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

## Vertical wobble so the deck isn't a dead-flat plane.
@export var undulation: float = 120.0

@export var deck_color: Color = Color(0.80, 0.82, 0.82)
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

var _material: StandardMaterial3D
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

	for i in subdivisions + 1:
		for j in subdivisions + 1:
			var x := centre.x - half + float(i) * step
			var z := centre.z - half + float(j) * step
			verts.append(Vector3(x, deck_y + noise.get_noise_2d(x, z) * undulation, z))
			uvs.append(Vector2(x / pattern_scale, z / pattern_scale))
			# Flat up-facing normals: the deck is lit as a horizontal
			# surface, so the sun's shadow reads cleanly across it rather
			# than shading oddly over every undulation.
			normals.append(Vector3.UP)
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


func _build_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(deck_color.r, deck_color.g, deck_color.b, opacity)
	mat.albedo_texture = _build_cloud_texture()
	# The radial edge fade lives in vertex alpha, so it has to be multiplied in.
	mat.vertex_color_use_as_albedo = true
	# Visible from underneath as well — the player spends most of the fight
	# below this.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# LIT, not unshaded. This is the line that makes building shadows appear
	# on the deck; an unshaded material ignores lights and shadows entirely.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.roughness = 1.0
	mat.metallic = 0.0
	# Cloud shouldn't have a specular hotspot.
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	# Transparent surfaces don't write depth by default; that's correct here,
	# so towers punching through sort properly against it.
	return mat


## Noise run through a gradient that ends fully transparent, so the deck is
## broken cloud with real gaps rather than a uniform sheet. The gradient is
## what carries the ALPHA — a plain grayscale noise texture is opaque
## everywhere and would just tint the deck.
##
## TUNED SOFT ON PURPOSE. The first version (frequency 0.9, 4 octaves, a
## gradient snapping from 0.0 to 0.12 alpha within the first 38% of the
## range) read as a "spider web" from above rather than fog — high-frequency
## fractal noise is naturally made of thin connected ridges, and a
## high-contrast alpha cutoff turns those ridges into lace instead of soft
## puffs. Fixed on both ends: the noise itself is lower frequency and fewer
## octaves (fewer, bigger blobs instead of many fine filaments), and the
## gradient's floor is raised and the whole ramp widened so there is no
## sharp edge for a ridge to snap into — density fades in and out gradually
## instead of tracing the noise's contour lines.
func _build_cloud_texture() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.28
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.35

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.30, 0.55, 0.80, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 0.0),
		Color(1.0, 1.0, 1.0, 0.32),
		Color(1.0, 1.0, 1.0, 0.55),
		Color(1.0, 1.0, 1.0, 0.8),
		Color(1.0, 1.0, 1.0, 1.0),
	])

	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.noise = noise
	tex.color_ramp = ramp
	# Softens the sampled result further, which is what actually kills the
	# fine web tendrils that survive even at a lower base frequency.
	tex.generate_mipmaps = true
	return tex


## Scrolling the UVs is the entire animation — no geometry moves, so there
## is nothing to jitter and no per-frame mesh work.
func _process(delta: float) -> void:
	if not _material:
		return
	_drift += drift_speed * delta
	_material.uv1_offset = Vector3(_drift.x, _drift.y, 0.0)
