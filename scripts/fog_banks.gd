extends Node3D

## Rolling banks of fog that hug the ground and climb terrain — the
## billowing plumes that flat depth fog fundamentally cannot do.
##
## WHY THIS IS A SEPARATE SYSTEM. The Environment's depth fog (see
## Town.tscn) is a per-pixel distance function: it can only ever be a smooth
## gradient with distance, optionally biased by height. It has no shape, so
## it can't pool in a valley, break over a ridge, or roll up a mountainside.
## Getting that requires actual 3D fog volumes, which in Godot means
## FogVolume nodes fed by a noise density texture, rendered through the
## Environment's VOLUMETRIC fog froxel grid.
##
## The two are used together on purpose and do different jobs: depth fog
## still provides the overall aerial perspective (cheap, global, reaches
## 70km), while `volumetric_fog_density` on the Environment is set to ZERO
## so the volumetric pass contributes nothing on its own and exists purely
## to render these banks. That avoids double-fogging the whole world and
## keeps the froxel grid mostly empty.
##
## TERRAIN FOLLOWING is what sells "rolling up mountains". Each bank
## re-samples the terrain height beneath itself every frame and sits a fixed
## distance above it, so as a bank drifts onto rising ground it rides up the
## slope. Combined with the FogMaterial's `height_falloff` (density
## concentrated at the bottom of the volume) the fog clings to the surface
## instead of floating as a detached slab.
##
## COST — READ THIS BEFORE TURNING IT UP. Volumetric fog is the single most
## expensive visual feature in this project: it evaluates a 3D froxel grid
## every frame, and in VR that happens per eye. This project already has an
## unresolved frame-rate question, so it ships deliberately conservative:
## few banks, a modest froxel grid (see project.godot's
## rendering/environment/volumetric_fog/volume_size), and an `enabled`
## export that switches the whole thing off in one click. Check the HUD's
## PERF line with this on before adding more.

@export var enabled: bool = true:
	set(value):
		enabled = value
		_apply_enabled()

## Number of drifting banks kept alive around the player. Each is large, so
## a handful covers a lot of ground — this is not a particle count.
@export var bank_count: int = 8
## Banks live within this radius of the player and are recycled to the far
## side when they drift beyond it, so fog is always where you are without
## paying for the whole 100km map.
@export var spread_radius: float = 6500.0
@export var bank_size: Vector3 = Vector3(2800.0, 1000.0, 2800.0)
@export var height_above_terrain: float = 90.0
@export var drift_speed_min: float = 12.0
@export var drift_speed_max: float = 34.0
@export var density: float = 0.05

@export var terrain_path: NodePath = ^"../Terrain"

var _terrain: Node
var _player: Node3D
var _banks: Array = []  # {"node": FogVolume, "drift": Vector3}
var _noise_texture: NoiseTexture3D


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)
	_player = get_tree().current_scene.get_node_or_null("Player")
	_noise_texture = _build_noise()
	_build_banks()
	_apply_enabled()


## One shared 3D noise texture across every bank — it's the same cloud
## structure sampled at different offsets, and generating one per bank would
## cost memory for no visible variety.
func _build_noise() -> NoiseTexture3D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.018
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5

	var tex := NoiseTexture3D.new()
	tex.width = 48
	tex.height = 48
	tex.depth = 48
	# Seamless so a bank's density doesn't visibly clip at its own edges as
	# it drifts through the noise field.
	tex.seamless = true
	tex.noise = noise
	return tex


func _build_banks() -> void:
	for i in bank_count:
		var volume := FogVolume.new()
		volume.size = bank_size

		var mat := FogMaterial.new()
		mat.density = density * randf_range(0.6, 1.4)
		mat.albedo = Color(0.74, 0.76, 0.75)
		# Concentrates density at the bottom of the volume, so the bank
		# hugs whatever surface it's sitting on rather than filling its box.
		mat.height_falloff = 0.75
		# Fades density toward the volume's faces, so neighbouring banks
		# blend instead of showing hard box seams.
		mat.edge_fade = 0.4
		mat.density_texture = _noise_texture
		volume.material = mat

		add_child(volume)
		_banks.append({"node": volume, "drift": _random_drift()})
		_recycle(_banks[i], true)


func _random_drift() -> Vector3:
	var angle := randf() * TAU
	var speed := randf_range(drift_speed_min, drift_speed_max)
	return Vector3(cos(angle) * speed, 0.0, sin(angle) * speed)


func _apply_enabled() -> void:
	visible = enabled
	set_process(enabled)


func _process(delta: float) -> void:
	if not _player:
		return
	var listener := _player.global_position
	for bank in _banks:
		var volume: FogVolume = bank["node"]
		volume.global_position += (bank["drift"] as Vector3) * delta

		# Ride the terrain. Re-sampled every frame, which is what makes a
		# bank climb as it drifts onto rising ground.
		if _terrain:
			var ground: float = _terrain.get_height_at(
					volume.global_position.x, volume.global_position.z)
			volume.global_position.y = ground + height_above_terrain

		var flat_dist := Vector2(volume.global_position.x - listener.x,
				volume.global_position.z - listener.z).length()
		if flat_dist > spread_radius:
			_recycle(bank, false)


## Places a bank somewhere around the player. `initial` scatters it
## anywhere in the radius; otherwise it is pushed out to the far edge so it
## drifts back across the player's view rather than popping in nearby.
func _recycle(bank: Dictionary, initial: bool) -> void:
	if not _player:
		return
	var volume: FogVolume = bank["node"]
	var angle := randf() * TAU
	var dist := randf_range(0.0, spread_radius) if initial else spread_radius * randf_range(0.85, 1.0)
	var x: float = _player.global_position.x + cos(angle) * dist
	var z: float = _player.global_position.z + sin(angle) * dist
	var ground: float = _terrain.get_height_at(x, z) if _terrain else 0.0
	volume.global_position = Vector3(x, ground + height_above_terrain, z)
	bank["drift"] = _random_drift()
