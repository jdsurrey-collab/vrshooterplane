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
## main_menu.gd for the world-locked flat-screen UI and its GAME MODES
## submenu — both fleets visible but frozen behind it, faction_battle.gd
## still writes their MultiMesh transforms even while simulation_active is
## false) -> PLAYING (normal gameplay, FactionBattle simulating) ->
## GAME_OVER (gameplay paused again, match summary + "return to menu"
## prompt shown, see battle_hud.gd) -> back to MENU via reset_battle() +
## repositioning the player.
##
## Right trigger both fires the guns during PLAYING (weapon_system.gd's own
## job, untouched) and confirms the MENU/GAME_OVER prompts here — no
## conflict, since weapon_system.gd only reads the trigger while
## `not paused`, and this script sets the whole player `paused` for both
## menu states. During MENU specifically, a trigger-confirm is delegated
## entirely to `main_menu.gd`'s `confirm_selection()` — what it actually
## DOES depends on the 2D UI's own TOP/MODES state machine (open the GAME
## MODES submenu, quit, or call `start_match_with_mode()` with a chosen
## GameMode), not a fixed start-vs-quit binary anymore.

## DEAD is entered whenever crash_handler.gd reports the player destroyed
## (terrain/building impact, or cockpit/hull health reaching zero). The
## player used to be respawned silently on a timer; now death_screen.gd
## fades the view to red and the player chooses RESPAWN or MAIN MENU.
enum State { MENU, PLAYING, GAME_OVER, DEAD }

## Chosen from the main menu's GAME MODES submenu (main_menu_ui.gd's own
## identical enum — duplicated there since that 2D scene has no direct
## path to this script, see its class comment). FULL_SCALE is everything
## this project has built all along, unchanged; ONE_V_ONE is
## FactionBattle.duel_mode — see that export's own header for why it's a
## gate on the existing mass-battle system rather than a separate one.
enum GameMode { FULL_SCALE, ONE_V_ONE }

## FALLBACK ONLY. The real spawn point comes from
## FactionBattle.get_player_spawn_position() — a spot on the friendly
## mothership's flight deck — which is now the single source of truth (see
## _reposition_player). This is used only if there's no FactionBattle in the
## scene, and is kept roughly in step with faction_battle.gd's
## `spawn_distance_from_city` so the fallback isn't wildly wrong.
@export var player_spawn_xz: Vector2 = Vector2(-16000.0, 0.0)
@export var player_spawn_altitude: float = 102.0

var state: int = State.MENU

var _player: Node3D
var _flight_controller: Node
var _weapon_system: Node
var _missile_system: Node
var _flare_system: Node
var _player_damage: Node
var _battle: Node
var _tanks: Node  # TankObjective — the ground objective (see tank_objective.gd)
var _terrain: Node
var _right_controller: XRController3D
var _main_menu: Node
var _death_screen: Node
var _crash_handler: Node
var _engine_audio: Node
var _ship_engine_audio: Node
var _thruster_trails: Node
var _friendly_tags: Node
var _damage_smoke: Node
var _role_stamp: Node

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
		_main_menu = _player.get_node_or_null("MainMenu")
		_death_screen = _player.get_node_or_null("XRCamera3D/DeathScreen")
		_crash_handler = _player.get_node_or_null("CrashHandler")
		_role_stamp = _player.get_node_or_null("XRCamera3D/RoleStamp")
		_engine_audio = _player.get_node_or_null("EngineAudio")
	_battle = get_node_or_null("../FactionBattle")
	_tanks = get_node_or_null("../TankObjective")
	_terrain = get_node_or_null("../Terrain")
	if _battle:
		_ship_engine_audio = _battle.get_node_or_null("ShipEngineAudio")
		_thruster_trails = _battle.get_node_or_null("ThrusterTrails")
		_friendly_tags = _battle.get_node_or_null("FriendlyTags")
		_damage_smoke = _battle.get_node_or_null("DamageSmoke")

	_enter_menu()


func _process(_delta: float) -> void:
	if state == State.PLAYING:
		# The match ending outranks the player dying — if both land on the
		# same frame, the summary screen is the more important one.
		if _battle and _battle.game_over:
			_enter_game_over()
		elif _crash_handler and _crash_handler.crashed:
			_enter_dead()
		return

	if not _right_controller or not _right_controller.get_is_active():
		return

	var confirm_down := _right_controller.is_button_pressed("trigger_click")
	if confirm_down and not _confirm_button_was_down:
		if state == State.MENU:
			# Delegated entirely to main_menu.gd (and from there, the 2D UI's
			# own TOP/MODES state machine) — a MENU trigger-confirm no longer
			# means one fixed thing (start vs quit); it means whatever's
			# currently highlighted, including opening/backing out of the
			# GAME MODES submenu. See main_menu.gd's own header.
			if _main_menu and _main_menu.has_method("confirm_selection"):
				_main_menu.confirm_selection()
		elif state == State.GAME_OVER:
			_return_to_menu()
		elif state == State.DEAD:
			_confirm_death_choice()
	_confirm_button_was_down = confirm_down


## RESPAWN puts the player back on the mothership deck and resumes play;
## MAIN MENU abandons the match. Gated on crash_handler.can_respawn() so a
## trigger still held from the moment of impact can't skip the wreck.
func _confirm_death_choice() -> void:
	if not _crash_handler or not _crash_handler.can_respawn():
		return
	if _death_screen and _death_screen.selected_action == "menu":
		_crash_handler.respawn_now()  # clears the crashed flag before leaving
		_return_to_menu()
		return
	_crash_handler.respawn_now()
	state = State.PLAYING
	_set_player_paused(false)


## Also silences engine audio (the player's own idle hum, and the pooled
## proximity engines from every ship on the mothership deck) — without this
## the MENU/DEAD/GAME_OVER screens had audible engine noise even though
## nothing is flying yet, when the intent for those screens is only the main
## menu's own music/chatter.
func _set_player_paused(value: bool) -> void:
	if _flight_controller:
		_flight_controller.paused = value
	if _weapon_system:
		_weapon_system.paused = value
	if _missile_system:
		_missile_system.paused = value
	if _flare_system:
		_flare_system.paused = value
	if _engine_audio:
		_engine_audio.paused = value
	if _ship_engine_audio:
		_ship_engine_audio.paused = value
	if _thruster_trails:
		_thruster_trails.paused = value
	if _friendly_tags:
		_friendly_tags.paused = value
	if _damage_smoke:
		_damage_smoke.paused = value


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


## The only real entry point now — main_menu.gd's GAME MODES submenu calls
## this directly on confirm (see main_menu_ui.gd's `mode_selected` signal).
## Sets FactionBattle.duel_mode BEFORE _start_match() runs, since
## start_battle() reads it immediately to decide whether to launch the
## normal fleet or hand-place a single duel opponent.
func start_match_with_mode(mode: int) -> void:
	if _battle:
		_battle.duel_mode = (mode == GameMode.ONE_V_ONE)
	_start_match()


func _start_match() -> void:
	state = State.PLAYING
	_set_player_paused(false)
	if _battle:
		_battle.start_battle()

	var duel: bool = _battle != null and _battle.duel_mode
	# The ground objective doesn't apply to 1v1 at all — no attacker/
	# defender coin, no fixed layout, no role stamp, just two ships and a
	# kill. Direct request: "we won't really do much work into it."
	if duel:
		return

	# Tanks stay in the world PURELY AS COSMETIC SET-DRESSING now — direct
	# request: "get rid of all the tank mechanics. We can leave the tanks
	# in the game, but turn that off where enemies aren't hunting for
	# tanks... leave them in right now for cosmetics, essentially." Scoring
	# is now entirely kills + tower control (see faction_battle.gd's
	# CaptureZone system); the ground objective's attacker/defender coin
	# and mission framing are retired.
	#
	# _tanks.start_objective() still runs (tanks still spawn/scatter, still
	# destructible by the rolled attacking_faction, same rejection-sampling
	# placement as always) — that's the "leave them in for cosmetics" half.
	# _battle.assign_ground_roles() is deliberately NOT called anymore: with
	# no caller ever assigning STRIKE_ROLE/TANK_GUARD, every squad stays
	# Squad.Role.FIGHTER (its own default), so no AI ever enters
	# GROUND_ATTACK or patrols tank airspace — that's the "enemies aren't
	# hunting for tanks" half. The old ATTACKER/DEFENDER role-stamp
	# announcement is gone too, since that mission framing no longer exists.
	if _tanks:
		_tanks.start_objective()


func _enter_dead() -> void:
	state = State.DEAD
	_set_player_paused(true)


func _enter_game_over() -> void:
	state = State.GAME_OVER
	_set_player_paused(true)


func _return_to_menu() -> void:
	if _player_damage:
		_player_damage.reset_health()
	if _missile_system:
		_missile_system.reload_remaining = 0.0
	_reposition_player()
	if _battle:
		_battle.reset_battle()
	if _tanks:
		_tanks.reset_objective()
	if _role_stamp:
		_role_stamp.hide_stamp()
	_enter_menu()
