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
## convention the options menu uses), play the crash sound, spawn the crash
## site (CrashEffects, shared with enemy_ai.gd), count down RESPAWN_DELAY
## seconds, then reset the ship back to the spawn point.

## How long after impact before the death screen will accept a respawn.
## Short: it exists to stop a trigger held at the moment of death from
## instantly skipping the wreck, not to make the player wait.
const RESPAWN_DELAY := 2.0

@export var terrain_path: NodePath = ^"../../Terrain"
@export var respawn_height_offset: float = 102.0  # +100m above the old 2.0, matches the initial spawn height
## Matches heightmap_terrain.gd's spawn_position_xz / faction_battle.gd's
## friendly_spawn_center — respawning should put the player back with their
## own squadron, not alone at the world origin.
@export var respawn_position_xz: Vector2 = Vector2.ZERO

## Live status, readable by the HUD.
var crashed: bool = false
var respawn_time_remaining: float = 0.0

var _player: Node3D
var _flight_controller: Node
var _weapon_system: Node
var _missile_system: Node
var _flare_system: Node
var _terrain: Node
var _crash_audio: AudioStreamPlayer
var _player_damage: Node
var _damage_audio: Node


func _ready() -> void:
	_player = get_parent()
	_flight_controller = _player.get_node_or_null("FlightController")
	_weapon_system = _player.get_node_or_null("WeaponSystem")
	_missile_system = _player.get_node_or_null("MissileSystem")
	_flare_system = _player.get_node_or_null("FlareSystem")
	_terrain = get_node_or_null(terrain_path)
	_crash_audio = get_node_or_null("CrashAudio")
	_player_damage = _player.get_node_or_null("PlayerDamage")
	_damage_audio = _player.get_node_or_null("DamageAudio")


## Freezing on a crash has to cover every player weapon, not just the guns —
## otherwise missiles and flares stay live through the whole wreck/respawn
## sequence.
func _set_systems_paused(value: bool) -> void:
	if _flight_controller:
		_flight_controller.paused = value
	if _weapon_system:
		_weapon_system.paused = value
	if _missile_system:
		_missile_system.paused = value
	if _flare_system:
		_flare_system.paused = value


func _physics_process(delta: float) -> void:
	if not _player or not _terrain:
		return

	if crashed:
		# Counts down to zero and then WAITS. Respawning is now the player's
		# call, made from the death screen (death_screen.gd / game_flow.gd's
		# DEAD state) rather than happening automatically — this timer only
		# gates how soon that choice becomes available, so a trigger still
		# held down at the moment of impact can't instantly skip the wreck.
		respawn_time_remaining = maxf(0.0, respawn_time_remaining - delta)
		return

	var pos := _player.global_position
	var ground_height: float = _terrain.get_height_at(pos.x, pos.z)
	if pos.y <= ground_height:
		_crash(Vector3(pos.x, ground_height, pos.z))
		return

	if CrashEffects.check_building_collision(_player.get_world_3d().direct_space_state, pos):
		_crash(pos)


## Public entry point for anything other than terrain/building impact to
## start the crash sequence — currently just player_damage.gd, when cockpit
## or hull health hits 0.
func trigger_crash() -> void:
	if not crashed:
		_crash(_player.global_position)


## True once the wreck has played out and the player may choose to respawn.
func can_respawn() -> bool:
	return crashed and respawn_time_remaining <= 0.0


## Called by game_flow.gd when the player confirms RESPAWN on the death
## screen. The old behaviour respawned automatically on a timer.
func respawn_now() -> void:
	if crashed:
		_respawn()


func _crash(impact: Vector3) -> void:
	crashed = true
	respawn_time_remaining = RESPAWN_DELAY
	_set_systems_paused(true)
	if _flight_controller:
		_flight_controller.reset_velocity()
	if _crash_audio:
		_crash_audio.play()
	# Hit sounds must not outlive the ship that was being hit.
	if _damage_audio and _damage_audio.has_method("stop_all"):
		_damage_audio.stop_all()

	CrashEffects.spawn(get_tree().current_scene, _terrain, impact)


func _respawn() -> void:
	crashed = false
	# Respawn on the friendly mothership's flight deck with the fleet, the
	# same place the match starts from. FactionBattle owns the mothership's
	# position and deck height, so it's asked rather than re-derived here;
	# respawn_position_xz is only the fallback for a scene without a battle.
	var spawn_point: Vector3
	var battle := get_tree().current_scene.get_node_or_null("FactionBattle")
	if battle and battle.has_method("get_player_spawn_position"):
		spawn_point = battle.get_player_spawn_position()
	else:
		var ground_height: float = _terrain.get_height_at(respawn_position_xz.x, respawn_position_xz.y)
		spawn_point = Vector3(
				respawn_position_xz.x, ground_height + respawn_height_offset, respawn_position_xz.y)
	# Reset orientation too, not just position — otherwise you respawn still
	# tumbling/upside-down from however you hit the ground.
	_player.global_transform = Transform3D(Basis(), spawn_point)
	_set_systems_paused(false)
	if _player_damage:
		_player_damage.reset_health()
	# A fresh ship off the deck comes with a fresh reload, same reasoning as
	# resetting health here rather than making the player wait out whatever
	# cooldown was running on the ship they just died in.
	if _missile_system:
		_missile_system.reload_remaining = 0.0
	if _damage_audio and _damage_audio.has_method("stop_all"):
		_damage_audio.stop_all()
