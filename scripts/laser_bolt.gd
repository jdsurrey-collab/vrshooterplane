extends Node3D

## Basic laser bolt — travels forward at a fixed speed, checks each frame
## for a terrain or building hit, and explodes (CrashEffects.spawn_laser_impact)
## on impact instead of just despawning silently. Despawns quietly if it
## reaches max range/lifetime without hitting anything.
##
## `damage` carries the bolt's hit strength for a future health/damage
## system — not consumed by anything yet (no health system exists), but
## bolts should already have this data ready for when one does.
##
## Hit detection currently only checks terrain (Terrain.get_height_at) and
## buildings (CrashEffects.check_building_collision) — see _check_hit().
## Hitting the enemy ship or the player's own ship is NOT implemented yet;
## that's the planned next step (per-ship health, "smoke the same way" on
## damage) once that system exists. _check_hit() is the single point to
## extend when it does.

@export var speed: float = 500.0  # m/s
@export var lifetime: float = 3.0  # seconds
@export var damage: float = 10.0  # for a future health/damage system

var _traveled: float = 0.0
var _max_range: float = 0.0
var _terrain: Node


func _ready() -> void:
	_max_range = speed * lifetime
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_terrain = get_tree().current_scene.get_node_or_null("Terrain")


func _physics_process(delta: float) -> void:
	var step := speed * delta
	translate(Vector3(0.0, 0.0, -step))
	_traveled += step

	if _check_hit():
		CrashEffects.spawn_laser_impact(get_tree().current_scene, global_position)
		queue_free()
		return

	if _traveled >= _max_range:
		queue_free()


## Single decision point for "did this bolt hit something" — extend here
## when enemy/player ship hit detection is added.
func _check_hit() -> bool:
	if _terrain:
		var ground_height: float = _terrain.get_height_at(global_position.x, global_position.z)
		if global_position.y <= ground_height:
			return true

	if CrashEffects.check_building_collision(get_world_3d().direct_space_state, global_position):
		return true

	return false
