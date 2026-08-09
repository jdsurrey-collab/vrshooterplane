extends Node3D

## Ground fog covering ONLY the city footprint. Nothing anywhere else.
##
## Two jobs, both specific:
##
## 1. HIDE THE BUILDING FOUNDATIONS. city_generator.gd places each building
##    at the terrain height sampled at its own centre point, but a building
##    footprint can be 250m across on terrain that slopes, so the downhill
##    side of the base hangs in the air. A shallow fog layer sitting at
##    ground level masks that seam without needing per-building terrain
##    conforming (which would mean deforming the mesh or sinking every
##    building, and would break the collision box sizing).
##
## 2. CATCH SHADOWS. This is volumetric fog specifically because depth fog
##    cannot receive shadows — it is a per-pixel distance blend with no
##    notion of occlusion, so nothing can ever cast into it. Volumetric fog
##    accumulates density into a froxel grid and lights each froxel through
##    the scene's shadow maps, so towers lay real shadow across the fog
##    below them.
##
## STATIC, AND ONLY OVER THE CITY. Earlier versions covered the world around
## the player — first as drifting banks (which read as blobs arriving
## nearby) and then as a sheet that followed the player. Both put fog
## everywhere, which is not wanted. These tiles are built once over the
## city's own footprint and never move, so there is no per-frame cost at all
## and no fog over the mountains, the spawn areas, or anywhere between.
##
## The volumetric froxel grid only reaches `volumetric_fog_length` from the
## camera, so this is visible as you approach and fly through the city, not
## from the mothership 22km out. That is inherent to the technique.
##
## COST: the froxel grid is evaluated every frame per eye in VR whenever
## `volumetric_fog_enabled` is on. `enabled` here removes the fog itself;
## turning the Environment's `volumetric_fog_enabled` off as well reclaims
## the grid entirely.

@export var enabled: bool = true:
	set(value):
		enabled = value
		visible = enabled

## Footprint of each fog tile. Each samples the terrain once at its own
## centre, so smaller tiles follow uneven ground more closely at the cost of
## more volumes.
@export var tile_size: float = 1200.0

## Total height of each fog box. Only the bottom of it holds meaningful
## density (see `height_falloff`) — the box just has to be tall enough to
## contain the layer plus any terrain wobble inside one tile.
@export var tile_height: float = 400.0

## Where the BOTTOM of the fog box sits relative to the terrain under it.
## Slightly negative so the layer starts just below ground level and there
## is no gap between the fog and the surface.
@export var fog_base_offset: float = -25.0

## How fast density falls off with height. Lower spreads the fog further up
## (better at swallowing a tall floating foundation), higher keeps it as a
## tighter carpet. This is the main dial for "is it covering the bases".
@export var height_falloff: float = 1.0

@export var density: float = 0.09
@export var albedo: Color = Color(0.76, 0.78, 0.77)

@export var city_path: NodePath = ^"../City"
@export var terrain_path: NodePath = ^"../Terrain"


func _ready() -> void:
	var city := get_node_or_null(city_path)
	var terrain := get_node_or_null(terrain_path)
	if not city or not terrain:
		push_warning("CityFog: missing City or Terrain, no fog built")
		return

	# Match the city's own footprint exactly rather than hardcoding it —
	# city_generator.gd's grid_size and block_pitch are deliberately inverse
	# and get retuned for density, so reading them keeps the fog in step.
	var centre: Vector3 = city.city_center
	var half: float = city.grid_size * city.block_pitch * 0.5

	var noise_texture := _build_noise()
	var steps := int(ceil((half * 2.0) / tile_size))

	for i in steps:
		for j in steps:
			var x: float = centre.x - half + (float(i) + 0.5) * tile_size
			var z: float = centre.z - half + (float(j) + 0.5) * tile_size
			_add_tile(x, z, terrain, noise_texture)

	visible = enabled


## One shared 3D noise texture across every tile — the same structure
## sampled at different world offsets, which is what keeps the layer from
## reading as a flat slab.
func _build_noise() -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.022
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5

	var tex := NoiseTexture3D.new()
	tex.width = 48
	tex.height = 48
	tex.depth = 48
	tex.seamless = true
	tex.noise = noise
	return tex


func _add_tile(x: float, z: float, terrain: Node, noise_texture: NoiseTexture3D) -> void:
	var volume := FogVolume.new()
	# Oversized against tile_size so neighbours overlap; with edge_fade that
	# hides the seam between tiles sitting at different terrain heights.
	volume.size = Vector3(tile_size * 1.3, tile_height, tile_size * 1.3)

	var mat := FogMaterial.new()
	mat.density = density
	mat.albedo = albedo
	mat.height_falloff = height_falloff
	mat.edge_fade = 0.5
	mat.density_texture = noise_texture
	volume.material = mat

	add_child(volume)

	# The box is positioned by its CENTRE, so lift it half its height above
	# where the fog is meant to start.
	var ground: float = terrain.get_height_at(x, z)
	volume.global_position = Vector3(x, ground + fog_base_offset + tile_height * 0.5, z)
