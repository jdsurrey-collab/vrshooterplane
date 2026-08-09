extends Node3D

## Basic laser bolt — travels forward at a fixed speed, checks each frame
## for an enemy-ship, terrain, or building hit, and explodes on impact
## instead of just despawning silently. Despawns quietly if it reaches max
## range/lifetime without hitting anything.
##
## `damage` is consumed by faction_battle.gd's apply_damage() on an alien
## hit — see that script for the mass-battle health/kill design.
##
## ENEMY HIT DETECTION uses a swept segment check (previous frame's position
## to this frame's), not a single point-in-radius test at the current
## position — at 900 m/s a bolt can cover ~10-15m in one physics frame,
## comfortably more than a ship's own size, so a point check alone could
## tunnel straight through it between two sampled frames. Enemy hits are
## checked against faction_battle.gd's alien roster (the 200-ship mass
## battle, see that script) via get_nearest_alive_alien() — the old single
## hardcoded HOSTILE-1 enemy is retired.
##
## `fired_by_player` gates which side a bolt can damage — true (the
## default, and the only value weapon_system.gd currently spawns bolts
## with) checks only for an enemy hit; false would check only for a player
## hit. Without this split, checking player hits unconditionally would
## self-damage the player on every shot, since a bolt spawns right at its
## own gun mount, well inside the player's own ShipHull bounding radius.
## No enemy weapon exists yet to spawn a `fired_by_player = false` bolt —
## see player_damage.gd — but the check is real and ready for when one does.

@export var speed: float = 900.0  # m/s — was 500; bumped up to shrink the window where a bolt can get occluded by the ship's own nose right after firing during a hard pitch
@export var lifetime: float = 3.0  # seconds
@export var damage: float = 10.0  # consumed by enemy_ai.gd's / player_damage.gd's apply_damage()
@export var enemy_hit_radius: float = 4.0  # meters — approximates the enemy ship's bounding sphere
@export var player_hit_radius: float = 4.0  # meters — approximates the player's ShipHull bounding sphere
@export var fired_by_player: bool = true

var _traveled: float = 0.0
var _max_range: float = 0.0
var _terrain: Node
var _battle: Node
var _player: Node3D
var _player_damage: Node


func _ready() -> void:
	_max_range = speed * lifetime
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_terrain = get_tree().current_scene.get_node_or_null("Terrain")
	_battle = get_tree().current_scene.get_node_or_null("FactionBattle")
	if not fired_by_player:
		_player = get_tree().current_scene.get_node_or_null("Player")
		if _player:
			_player_damage = _player.get_node_or_null("PlayerDamage")


func _physics_process(delta: float) -> void:
	var previous_position := global_position
	var step := speed * delta
	translate(Vector3(0.0, 0.0, -step))
	_traveled += step

	if fired_by_player:
		if _check_enemy_hit(previous_position):
			queue_free()
			return
	elif _check_player_hit(previous_position):
		queue_free()
		return

	if _check_ground_or_building_hit():
		CrashEffects.spawn_laser_impact(get_tree().current_scene, global_position)
		queue_free()
		return

	if _traveled >= _max_range:
		queue_free()


## Swept segment-vs-sphere check against the nearest living alien — see the
## class comment for why a single-point check isn't good enough at this
## speed. Only the nearest-to-current-position alien is checked (not every
## alien within the swept segment) — with 200 aliens spread across an
## 8000m-radius dome, the odds of a second alien also being within a few
## meters of this exact segment are negligible, and the player only ever
## has one bolt in flight at a time, so a full spatial-grid lookup (as
## faction_battle.gd uses internally for its own hundreds of ambient bolts)
## would be unneeded overhead here.
func _check_enemy_hit(previous_position: Vector3) -> bool:
	if not _battle:
		return false

	var index: int = _battle.get_nearest_alive_alien(global_position)
	if index < 0:
		return false

	var target_pos: Vector3 = _battle.get_alien_position(index)
	var closest := _closest_point_on_segment(target_pos, previous_position, global_position)
	if closest.distance_to(target_pos) > enemy_hit_radius:
		return false

	_battle.apply_damage(index, damage)
	return true


## Mirror of _check_enemy_hit() for the player's own ship — see
## player_damage.gd for the zone/health design.
func _check_player_hit(previous_position: Vector3) -> bool:
	if not _player or not _player_damage:
		return false

	var closest := _closest_point_on_segment(_player.global_position, previous_position, global_position)
	if closest.distance_to(_player.global_position) > player_hit_radius:
		return false

	var zone: String = _player_damage.classify_hit_zone(closest)
	_player_damage.apply_damage(damage, zone)
	return true


func _check_ground_or_building_hit() -> bool:
	if _terrain:
		var ground_height: float = _terrain.get_height_at(global_position.x, global_position.z)
		if global_position.y <= ground_height:
			return true

	return CrashEffects.check_building_collision(get_world_3d().direct_space_state, global_position)


func _closest_point_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t
