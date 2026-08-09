class_name GameFlow
extends Node

## Basic start-menu / end-of-match flow, wrapping the Faction Battle
## simulation and the player's own controls. Everything lives in one scene
## (Town.tscn) — "returning to main menu" is a soft reset back to the
## pre-match state, not a real scene reload. This project has never done
## scene-switching (project.godot's run/main_scene is the only scene ever
## loaded), and reloading a live OpenXR session mid-play is real added
## risk/complexity a "basic" menu doesn't call for.
##
## States: MENU (gameplay paused, the real main menu shown — see
## main_menu.gd for the fade-from-black/music/START-QUIT selection — both
## fleets visible but frozen behind it, faction_battle.gd still writes
## their MultiMesh transforms even while simulation_active is false) ->
## PLAYING (normal gameplay, FactionBattle simulating) -> GAME_OVER
## (gameplay paused again, match summary + "return to menu" prompt shown,
## see battle_hud.gd) -> back to MENU via reset_battle() + repositioning
## the player.
##
## Right trigger both fires the guns during PLAYING (weapon_system.gd's own
## job, untouched) and confirms the MENU/GAME_OVER prompts here — no
## conflict, since weapon_system.gd only reads the trigger while
## `not paused`, and this script sets the whole player `paused` for both
## menu states. During MENU specifically, which action a trigger-confirm
## performs depends on main_menu.gd's gaze-based `selected_action`
## ("start" starts the match, "quit" calls get_tree().quit()).

enum State { MENU, PLAYING, GAME_OVER }

## Matches faction_battle.gd's friendly_spawn_center and
## heightmap_terrain.gd's spawn_position_xz / crash_handler.gd's
## respawn_position_xz — update all three by hand together if the friendly
## spawn formula in faction_battle.gd ever changes.
@export var player_spawn_xz: Vector2 = Vector2(-4000.0, 0.0)
@export var player_spawn_altitude: float = 102.0

var state: int = State.MENU

var _player: Node3D
var _flight_controller: Node
var _weapon_system: Node
var _missile_system: Node
var _flare_system: Node
var _player_damage: Node
var _battle: Node
var _terrain: Node
var _right_controller: XRController3D
var _main_menu: Node

var _confirm_button_was_down: bool = false


func _ready() -> void:
	_player = get_node_or_null("../Player")
	if _player:
		_flight_controller = _player.get_node_or_null("FlightController")
		_weapon_system = _player.get_node_or_null("WeaponSystem")
		_missile_system = _player.get_node_or_null("MissileSystem")
		_flare_system = _player.get_node_or_null("FlareSystem")
		_player_damage = _player.get_node_or_null("PlayerDamage")
		_right_controller = _player.get_node_or_null("RightHand")
		_main_menu = _player.get_node_or_null("XRCamera3D/MainMenu")
	_battle = get_node_or_null("../FactionBattle")
	_terrain = get_node_or_null("../Terrain")

	_enter_menu()


func _process(_delta: float) -> void:
	if state == State.PLAYING:
		if _battle and _battle.game_over:
			_enter_game_over()
		return

	if not _right_controller or not _right_controller.get_is_active():
		return

	var confirm_down := _right_controller.is_button_pressed("trigger_click")
	if confirm_down and not _confirm_button_was_down:
		if state == State.MENU:
			if _main_menu and _main_menu.selected_action == "quit":
				get_tree().quit()
			else:
				_start_match()
		elif state == State.GAME_OVER:
			_return_to_menu()
	_confirm_button_was_down = confirm_down


func _set_player_paused(value: bool) -> void:
	if _flight_controller:
		_flight_controller.paused = value
	if _weapon_system:
		_weapon_system.paused = value
	if _missile_system:
		_missile_system.paused = value
	if _flare_system:
		_flare_system.paused = value


## The player starts on the friendly mothership's flight deck alongside the
## fleet, so asking FactionBattle for the spot is authoritative — it owns the
## mothership's position, altitude and deck height. The exported
## player_spawn_xz below is only the fallback for a scene with no battle in
## it; it used to be one of three hand-synced copies of the same coordinate.
func _reposition_player() -> void:
	if not _player:
		return
	var spawn_point: Vector3
	if _battle and _battle.has_method("get_player_spawn_position"):
		spawn_point = _battle.get_player_spawn_position()
	elif _terrain:
		var ground: float = _terrain.get_height_at(player_spawn_xz.x, player_spawn_xz.y)
		spawn_point = Vector3(player_spawn_xz.x, ground + player_spawn_altitude, player_spawn_xz.y)
	else:
		return
	_player.global_transform = Transform3D(Basis(), spawn_point)
	if _flight_controller and _flight_controller.has_method("reset_velocity"):
		_flight_controller.reset_velocity()


func _enter_menu() -> void:
	state = State.MENU
	_set_player_paused(true)
	# Put the player on the mothership deck for the menu too, so the reveal
	# fade opens onto the flight deck rather than wherever they were left.
	_reposition_player()


func _start_match() -> void:
	state = State.PLAYING
	_set_player_paused(false)
	if _battle:
		_battle.start_battle()


func _enter_game_over() -> void:
	state = State.GAME_OVER
	_set_player_paused(true)


func _return_to_menu() -> void:
	if _player_damage:
		_player_damage.reset_health()
	_reposition_player()
	if _battle:
		_battle.reset_battle()
	_enter_menu()
