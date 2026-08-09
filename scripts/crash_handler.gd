extends Node

## Makes the terrain unpassable — the ship (flight_controller.gd) has no
## physics body of its own, it just moves by direct position updates, so
## nothing was ever stopping it flying straight through the ground. Each
## physics frame this checks the ship's position against the terrain's
## heightmap surface (Terrain.get_height_at) directly, rather than a
## physics raycast, since that's exact and the terrain already has the
## sampled height data in memory.
##
## Buildings are unpassable too — CrashEffects.check_building_collision()
## queries the physics space directly (buildings have real collision
## shapes, see city_generator.gd) since there's no heightmap shortcut for
## discrete scattered objects the way there is for terrain.
##
## On impact: freeze flight/weapons (reusing their `paused` flag — the same
## convention the options menu uses), spawn the crash site (CrashEffects,
## shared with enemy_ai.gd), count down RESPAWN_DELAY seconds, then reset
## the ship back to the spawn point.

const RESPAWN_DELAY := 10.0

@export var terrain_path: NodePath = ^"../../Terrain"
@export var respawn_height_offset: float = 2.0

## Live status, readable by the HUD.
var crashed: bool = false
var respawn_time_remaining: float = 0.0

var _player: Node3D
var _flight_controller: Node
var _weapon_system: Node
var _terrain: Node


func _ready() -> void:
	_player = get_parent()
	_flight_controller = _player.get_node_or_null("FlightController")
	_weapon_system = _player.get_node_or_null("WeaponSystem")
	_terrain = get_node_or_null(terrain_path)


func _physics_process(delta: float) -> void:
	if not _player or not _terrain:
		return

	if crashed:
		respawn_time_remaining = maxf(0.0, respawn_time_remaining - delta)
		if respawn_time_remaining <= 0.0:
			_respawn()
		return

	var pos := _player.global_position
	var ground_height: float = _terrain.get_height_at(pos.x, pos.z)
	if pos.y <= ground_height:
		_crash(Vector3(pos.x, ground_height, pos.z))
		return

	if CrashEffects.check_building_collision(_player.get_world_3d().direct_space_state, pos):
		_crash(pos)


func _crash(impact: Vector3) -> void:
	crashed = true
	respawn_time_remaining = RESPAWN_DELAY
	if _flight_controller:
		_flight_controller.paused = true
		_flight_controller.reset_velocity()
	if _weapon_system:
		_weapon_system.paused = true

	CrashEffects.spawn(get_tree().current_scene, _terrain, impact)


func _respawn() -> void:
	crashed = false
	var ground_height: float = _terrain.get_height_at(0.0, 0.0)
	# Reset orientation too, not just position — otherwise you respawn still
	# tumbling/upside-down from however you hit the ground.
	_player.global_transform = Transform3D(Basis(), Vector3(0.0, ground_height + respawn_height_offset, 0.0))
	if _flight_controller:
		_flight_controller.paused = false
	if _weapon_system:
		_weapon_system.paused = false
