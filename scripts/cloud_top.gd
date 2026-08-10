extends Node3D

## The TOP of the cloud layer — a real-time animated "sea of clouds" surface
## meant to be seen from ABOVE, looking down through the canopy once the
## player climbs over the existing CloudDeck (cloud_deck.gd, the
## UNDERSIDE/fog-band visual). Direct request, with a specific reference
## shader supplied: https://godotshaders.com/shader/cloud-material/
## ("Cloud Material," MIT licensed) — vertex-displaced FBM noise that both
## bumps the mesh AND recolors/re-opacifies it by height, so the tallest
## bumps read as brighter cloud tops. Adapted into
## Assets/Shaders/cloud_top.gdshader rather than used verbatim — see that
## file's header for the real changes this world's scale required.
##
## WHY A SEPARATE MESH/SHADER FROM CloudDeck, NOT A REPLACEMENT. CloudDeck
## is tuned specifically for the underside view: shadows crossing it (a
## real lit surface, receives the sun's shadow map), soft toon-shaded
## puffs, a texture baked once at load (cheap, matches this project's
## "generate what's needed, bake it, don't recompute per frame"
## philosophy elsewhere). This shader is the opposite trade: genuinely
## animated per-frame vertex displacement, which is what makes a
## convincing "sea of clouds" you fly over — CloudDeck's flat baked puffs
## would look static and 2D from directly above, staring straight down at
## a texture.
##
## COST, STATED PLAINLY. Unlike almost everything else visual in this
## project, this mesh's shape and color are recomputed on the GPU EVERY
## FRAME (a 6-octave FBM per vertex, not baked once at load like
## CloudDeck's texture or geometry). Vertex shaders are cheap per-
## invocation on a modern GPU, but this project already has an unresolved
## GPU-side FPS collapse (see CLAUDE.md's Known gaps) — `subdivisions`
## below is deliberately kept no higher than CloudDeck's own vertex count,
## and this is the first thing to cut if that issue is ever pinned
## specifically on this node.
##
## CULLED FROM BELOW ON PURPOSE, unlike CloudDeck (which is deliberately
## double-sided). A PlaneMesh's default front face points +Y, so from
## underneath — inside or below the cloud band, where CloudDeck already
## provides the visual — this mesh is simply invisible. That's correct:
## it exists only for the "climbed above the deck, looking down" view
## CloudDeck was never meant to cover.

const SHADER := preload("res://Assets/Shaders/cloud_top.gdshader")

@export var enabled: bool = true:
	set(value):
		enabled = value
		visible = enabled

## How far past the terrain's own extent this layer is built, matching
## CloudDeck's own coverage_scale for the same reason (a faded edge beyond
## the playable world rather than exactly at its boundary).
@export var coverage_scale: float = 1.1

## Vertex grid resolution. Kept comparable to CloudDeck's own 96 rather
## than higher — see this file's COST note above.
@export var subdivisions: int = 96

@export_group("Look")
@export var color1: Color = Color(0.85, 0.90, 0.94)
@export var color2: Color = Color(0.98, 0.99, 1.0)
## Real-world meters of vertical bump — large relative to the source
## shader's own small demo value, because this mesh spans a map tens of
## kilometers across and needs bumps visible from a real flying altitude.
@export var height_scale: float = 180.0
@export var wave_speed: float = 0.04
@export var global_transparency: float = 0.88
@export var upper_transparency: float = 0.6
## How wide one "puff" reads, in meters. This world runs ~100x a typical
## Godot demo's scale, so the shader's noise-sample coordinates have to be
## scaled down by roughly this project's world size or the noise reads as
## fine static instead of cloud-sized lobes — see cloud_top.gdshader's
## header. This is the practical dial for that: a bigger wavelength means
## bigger, gentler puffs.
@export var puff_wavelength: float = 900.0

@export var atmosphere_path: NodePath = ^"../Atmosphere"
@export var terrain_path: NodePath = ^"../Terrain"

var _material: ShaderMaterial


func _ready() -> void:
	var atmosphere := get_node_or_null(atmosphere_path)
	var terrain := get_node_or_null(terrain_path)
	if not atmosphere or not terrain:
		push_warning("CloudTop: missing Atmosphere or Terrain, no top layer built")
		set_process(false)
		return

	var centre: Vector3 = terrain.global_position
	var half: float = terrain.world_size * 0.5 * coverage_scale
	# The TOP of the band, not the midpoint CloudDeck sits at — this reads
	# as the highest visible cloud surface once you've climbed above
	# CloudDeck's own altitude.
	var top_y: float = atmosphere.cloud_base_y + atmosphere.cloud_thickness

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(half * 2.0, half * 2.0)
	mesh.subdivide_width = subdivisions
	mesh.subdivide_depth = subdivisions

	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("texture_albedo", _white_texture())
	_material.set_shader_parameter("uv1_scale", Vector3(1.0, 1.0, 1.0))
	_material.set_shader_parameter("uv1_offset", Vector3.ZERO)
	_material.set_shader_parameter("color1", color1)
	_material.set_shader_parameter("color2", color2)
	_material.set_shader_parameter("height_scale", height_scale)
	_material.set_shader_parameter("wave_speed", wave_speed)
	_material.set_shader_parameter("global_transparency", global_transparency)
	_material.set_shader_parameter("upper_transparency", upper_transparency)
	_material.set_shader_parameter("noise_scale", 1.0 / puff_wavelength)
	_material.set_shader_parameter("half_size", half)
	_material.set_shader_parameter("edge_fade_start", 0.75)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = _material
	mesh_instance.position = Vector3(centre.x, top_y, centre.z)
	# Same reasoning as CloudDeck: a cloud layer shouldn't cast a hard
	# shadow over the entire world below it.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)

	visible = enabled


## A flat 1x1-ish white texture so `texture_albedo` multiplies as a no-op —
## this layer's look comes entirely from the FBM height/color blend, not a
## sampled pattern, so there's nothing worth authoring or shipping a real
## texture asset for. Generated in memory rather than saved to disk, same
## reasoning as this project's other one-off procedural textures
## (soft_particle.png was the one exception that got saved, because it's
## reused by several scenes; this one is used by exactly one material).
func _white_texture() -> ImageTexture:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	return ImageTexture.create_from_image(img)
