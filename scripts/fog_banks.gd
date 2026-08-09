extends Node3D

## A continuous, terrain-following ground fog sheet that SHADOWS FALL INTO —
## so buildings cast visible darker shafts through the fog instead of only
## onto the ground.
##
## WHY THIS EXISTS AT ALL. The Environment's depth fog (Town.tscn) is a
## per-pixel distance blend between the scene colour and a fog colour. It
## has no notion of occlusion, so nothing can ever cast a shadow into it —
## no amount of tuning will get shadows riding over that fog. Volumetric fog
## is a different mechanism: density is accumulated into a 3D froxel grid
## and each froxel is lit by the scene's lights *including their shadow
## maps*, so a froxel sitting in a building's shadow is genuinely darker.
## That shadowing is the entire reason this system is back.
##
## HOW THIS DIFFERS FROM THE FIRST ATTEMPT. v1 was a handful of independent
## FogVolumes drifting on random headings and recycling when they passed a
## radius around the player. Live, that read as "I can't see fog in the
## distance, but it's appearing next to me" — which was accurate: they were
## discrete blobs arriving nearby, with nothing between them. v2 is instead
## a CONTINUOUS SHEET: a fixed grid of overlapping tiles covering everything
## around the player, snapped to a world-space grid so they do not slide or
## pop as you fly, each sampling the terrain height at its own centre so the
## sheet drapes over hills and valleys. No drift, no recycling, no gaps.
##
## THE RANGE LIMIT IS REAL AND CANNOT BE TUNED AWAY. Volumetric fog only
## exists inside the froxel grid, which reaches `volumetric_fog_length`
## (12km) at most. Beyond that there is no volumetric fog and therefore no
## fog shadowing — the Environment's depth fog takes over for distance haze.
## So this is ground fog you fly *into*, not something visible from the
## mothership 22km away. That is a property of the technique, not a bug.
##
## COST — THE MOST EXPENSIVE VISUAL FEATURE IN THE PROJECT. A 3D froxel grid
## evaluated every frame, with a shadow lookup per lit froxel, and in VR all
## of that happens per eye. `enabled` switches the whole thing off in one
## click, and doing so also wants `volumetric_fog_enabled = false` on the
## Environment to stop paying for the empty grid. Check the HUD PERF line
## with this on before raising `grid_radius` or the froxel resolution in
## project.godot.

## Off switches the sheet off entirely. Also set the Environment's
## `volumetric_fog_enabled` to false to reclaim the froxel grid cost.
@export var enabled: bool = true:
	set(value):
		enabled = value
		_apply_enabled()

## Tile footprint. Smaller tiles follow terrain more closely (each samples
## one height at its centre) but need more of them for the same coverage.
@export var tile_size: float = 1500.0
## Tiles extend this many steps out from the player's tile in each
## direction, so the sheet is (grid_radius * 2 + 1) squared tiles.
## 4 -> 9x9 = 81 tiles covering 13.5km, comfortably filling the 12km froxel
## range.
@export var grid_radius: int = 4
## Box height. The fog itself occupies far less than this — see
## `height_falloff` below — but the box has to be tall enough to contain the
## layer plus terrain wobble within a tile.
@export var tile_height: float = 320.0
## How far the fog sits above the ground beneath each tile.
@export var height_above_terrain: float = 18.0
@export var density: float = 0.055
## Concentrates density hard at the bottom of each box, which is what makes
## a ~30m blanket out of a 320m tall volume rather than filling it.
@export var height_falloff: float = 3.0

@export var terrain_path: NodePath = ^"../Terrain"

var _terrain: Node
var _player: Node3D
var _tiles: Array = []
var _noise_texture: NoiseTexture3D


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)
	_player = get_tree().current_scene.get_node_or_null("Player")
	_noise_texture = _build_noise()
	_build_tiles()
	_apply_enabled()


## One shared 3D noise texture across every tile — the same cloud structure
## sampled at different world offsets. It's what stops the sheet reading as
## a flat slab, giving it thicker and thinner patches.
func _build_noise() -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.02
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5

	var tex := NoiseTexture3D.new()
	tex.width = 48
	tex.height = 48
	tex.depth = 48
	tex.seamless = true
	tex.noise = noise
	return tex


func _build_tiles() -> void:
	var span := grid_radius * 2 + 1
	for i in span * span:
		var volume := FogVolume.new()
		# Slightly oversized so neighbours overlap; combined with edge_fade
		# that hides the seams between tiles sitting at different heights.
		volume.size = Vector3(tile_size * 1.25, tile_height, tile_size * 1.25)

		var mat := FogMaterial.new()
		mat.density = density
		mat.albedo = Color(0.74, 0.76, 0.75)
		mat.height_falloff = height_falloff
		mat.edge_fade = 0.5
		mat.density_texture = _noise_texture
		volume.material = mat

		add_child(volume)
		_tiles.append(volume)


func _apply_enabled() -> void:
	visible = enabled
	set_process(enabled)


func _process(_delta: float) -> void:
	if not _player or _tiles.is_empty():
		return

	# Snap the grid to world space rather than centring it exactly on the
	# player. If tiles tracked the player continuously they would slide
	# along with the camera and the fog would feel welded to your face; this
	# way each tile holds a fixed world position until the player crosses
	# into the next cell, and only then does the far row jump — behind you,
	# and inside fog you cannot see through anyway.
	var base_x: float = floorf(_player.global_position.x / tile_size) * tile_size
	var base_z: float = floorf(_player.global_position.z / tile_size) * tile_size

	var index := 0
	for i in range(-grid_radius, grid_radius + 1):
		for j in range(-grid_radius, grid_radius + 1):
			var x := base_x + float(i) * tile_size
			var z := base_z + float(j) * tile_size
			# Per-tile terrain sample: this is what drapes the sheet over
			# hills instead of leaving one flat slab cutting through them.
			var ground: float = _terrain.get_height_at(x, z) if _terrain else 0.0
			var volume: FogVolume = _tiles[index]
			volume.global_position = Vector3(x, ground + height_above_terrain, z)
			index += 1
