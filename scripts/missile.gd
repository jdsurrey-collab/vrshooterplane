extends Node3D

## Homing missile — either player-fired at an alien (missile_system.gd,
## left trigger) or, rarely, alien-fired at the PLAYER
## (faction_battle.gd's alien fire logic). `target_is_player` picks which
## mode: true tracks the player's own ship directly and damages
## `player_damage.gd` on impact; false (the original/default) tracks an
## alien by index through `battle` and damages it via `apply_damage()`.
##
## Damage (30) always meets-or-exceeds a mass-battle alien's max health
## (30, see faction_battle.gd), so a missile always kills an alien outright
## — `FactionBattle.apply_damage()`'s own kill path already spawns the big
## ShipExplosion fireball and a kill-feed entry, so this doesn't need a
## separate impact visual, just its hit sound. Against the player, damage
## is split by hit zone the same way laser_bolt.gd's player-hit path
## already works.
##
## FLARE COUNTERMEASURE — one-shot, edge-triggered the first frame the
## missile is within [FLARE_MIN_RANGE, FLARE_MAX_RANGE] of its target.
## Against an alien: faction_battle.gd's try_deploy_alien_flare() spawns
## one automatically (aliens have no button to press). Against the
## player: flare_system.gd's last_flare (whatever the player most recently
## deployed with X, if it's still burning) is used instead — this is the
## actual payoff for that button. Either way, FLARE_REDIRECT_CHANCE (40%)
## decides whether the missile's tracked target permanently switches to
## the flare Node3D — it flies at and detonates on the flare instead, a
## miss for the real target. Only one attempt per missile per flight.
##
## OVERSHOOT / BALLISTIC HANDOFF — real pursuit (turn-rate capped, see
## turn_rate), not an instant snap onto the target's bearing, so a target
## breaking hard enough can end up almost directly behind the missile. Past
## MAX_ENGAGE_ANGLE (150°) between the missile's current heading and the
## bearing to target, re-engaging would mean an almost-U-turn no real
## missile could pull off either — instead of endlessly trying, it gives up
## for good (_lost_lock, sticky) and continues straight along whatever
## heading it already had, for the rest of its lifetime. It can still
## score a hit via the ordinary swept-segment check if something crosses
## its path, it just stops actively steering.

const DAMAGE := 30.0  # >= a mass-battle alien's max health — every alien hit is a kill
const PLAYER_DAMAGE := 30.0
const HIT_RADIUS := 8.0
const HIT_SOUND := preload("res://Assets/Audio/missile_hit.mp3")

const FLARE_MIN_RANGE := 100.0
const FLARE_MAX_RANGE := 400.0
const FLARE_REDIRECT_CHANCE := 0.4
const MAX_ENGAGE_ANGLE := deg_to_rad(150.0)  # beyond this the target's effectively behind — give up and fly straight rather than loop back endlessly

@export var speed: float = 400.0  # m/s — still much slower than the 900 m/s laser bolt, and slow enough to be dodgeable with hard maneuvering, not an instant hit
@export var turn_rate: float = 1.2  # rad/s
@export var lifetime: float = 15.0

var target_index: int = -1
var battle: Node
var target_is_player: bool = false
var player: Node3D  # set by faction_battle.gd when target_is_player is true

var _player_damage: Node
var _flare_system: Node
var _terrain: Node
var _velocity: Vector3 = Vector3.ZERO
var _flare_target: Node3D = null
var _flare_check_done: bool = false
var _lost_lock: bool = false


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_velocity = -global_transform.basis.z * speed
	_terrain = get_tree().current_scene.get_node_or_null("Terrain")
	if target_is_player:
		add_to_group("player_seeking_missiles")
		if player:
			_player_damage = player.get_node_or_null("PlayerDamage")
			_flare_system = player.get_node_or_null("FlareSystem")


func _physics_process(delta: float) -> void:
	var target_pos: Vector3

	if _flare_target:
		if not is_instance_valid(_flare_target):
			queue_free()
			return
		target_pos = _flare_target.global_position
	elif target_is_player:
		if not is_instance_valid(player):
			queue_free()
			return
		target_pos = player.global_position
		_maybe_check_flare(target_pos)
	else:
		if not battle or not battle.is_alive(target_index):
			queue_free()
			return
		target_pos = battle.get_alien_position(target_index)
		_maybe_check_flare(target_pos)

	var previous_position := global_position

	if not _lost_lock:
		var desired_dir := (target_pos - global_position).normalized()
		var current_dir := _velocity.normalized() if _velocity.length() > 0.01 else -global_transform.basis.z
		if current_dir.angle_to(desired_dir) > MAX_ENGAGE_ANGLE:
			_lost_lock = true
		else:
			var new_dir := current_dir.slerp(desired_dir, clampf(turn_rate * delta, 0.0, 1.0)).normalized()
			_velocity = new_dir * speed

	global_position += _velocity * delta

	var facing := _velocity.normalized() if _velocity.length() > 0.01 else -global_transform.basis.z
	var up_ref := Vector3.FORWARD if absf(facing.dot(Vector3.UP)) > 0.99 else Vector3.UP
	global_transform.basis = Basis.looking_at(facing, up_ref)

	# Terrain/buildings stop a missile like they stop everything else in this
	# project — otherwise a missile chasing a low target (or one that has gone
	# ballistic after an overshoot) simply flies on through a mountain.
	if _hit_environment():
		_play_hit_sound(global_position)
		queue_free()
		return

	var closest := _closest_point_on_segment(target_pos, previous_position, global_position)
	if closest.distance_to(target_pos) > HIT_RADIUS:
		return

	if _flare_target:
		_play_hit_sound(closest)
		queue_free()
	elif target_is_player:
		if _player_damage:
			var zone: String = _player_damage.classify_hit_zone(closest)
			_player_damage.apply_damage(PLAYER_DAMAGE, zone)
		_play_hit_sound(closest)
		queue_free()
	else:
		battle.apply_damage(target_index, DAMAGE, "destroyed by PLAYER missile")
		_play_hit_sound(closest)
		queue_free()


func _hit_environment() -> bool:
	if _terrain:
		var ground_height: float = _terrain.get_height_at(global_position.x, global_position.z)
		if global_position.y <= ground_height:
			return true
	return CrashEffects.check_building_collision(get_world_3d().direct_space_state, global_position)


func _maybe_check_flare(target_pos: Vector3) -> void:
	if _flare_check_done:
		return
	var dist := global_position.distance_to(target_pos)
	if dist > FLARE_MAX_RANGE or dist < FLARE_MIN_RANGE:
		return
	_flare_check_done = true

	var flare: Node3D = null
	if target_is_player:
		if _flare_system and "last_flare" in _flare_system and is_instance_valid(_flare_system.last_flare):
			flare = _flare_system.last_flare
	elif battle and battle.has_method("try_deploy_alien_flare"):
		flare = battle.try_deploy_alien_flare(target_index)

	if flare and randf() < FLARE_REDIRECT_CHANCE:
		_flare_target = flare


## A short-lived, self-cleaning positional sound at the impact point —
## missile hits can happen well away from the player (out at the lock's
## LOCK_RANGE), so unlike the launch sound (played close to the player,
## see missile_system.gd), "proximity" actually matters here: farther hits
## should read as quieter and more muffled, not just quieter. Godot's
## AudioStreamPlayer3D does this natively via attenuation_filter_*, tuned
## more aggressively than this project's other 3D sounds (which sit close
## to the player and never needed it) specifically for that distant effect.
func _play_hit_sound(at_position: Vector3) -> void:
	var stream_player := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(stream_player)
	stream_player.global_position = at_position
	stream_player.stream = HIT_SOUND
	stream_player.max_distance = 4000.0
	stream_player.attenuation_filter_cutoff_hz = 1800.0
	stream_player.attenuation_filter_db = -36.0
	stream_player.play()
	stream_player.finished.connect(stream_player.queue_free)


func _closest_point_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t
