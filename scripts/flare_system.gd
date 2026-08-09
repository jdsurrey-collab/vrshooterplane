extends Node

## Player countermeasure — left controller's X button ("ax_button", free
## during normal flight: options_menu.gd only reads it while its own menu
## is open, see that script's _physics_process). Deploys a flare from the
## ship.
##
## Aliens now occasionally fire real homing missiles at the player (rare,
## see faction_battle.gd's alien fire logic — most alien fire is still the
## ambient ammo-less laser bolts), so this button has a genuine defensive
## payoff: `last_flare` tracks whatever was most recently deployed, and a
## player-targeting missile (missile.gd, target_is_player) checks it
## directly the first time it enters the flare countermeasure window —
## the same 40% redirect roll as the alien side, just checking this
## script's `last_flare` instead of calling
## FactionBattle.try_deploy_alien_flare() (aliens have no button to press,
## so that path triggers automatically instead of via input).

const FLARE := preload("res://scenes/Flare.tscn")

## Set by the options menu / game_flow.gd while paused, so config/menu
## states can't trigger a deploy — same convention weapon_system.gd uses.
var paused: bool = false

## Read directly by an incoming missile.gd instance (target_is_player) —
## is_instance_valid() also happens to double as "is it still burning",
## since Flare.tscn self-frees after its 10s lifetime.
var last_flare: Node3D = null

var _left_controller: XRController3D
var _ship: Node3D
var _button_was_down: bool = false


func _ready() -> void:
	var origin := get_parent()
	_left_controller = origin.get_node_or_null("LeftHand")
	_ship = origin.get_node_or_null("Ship")


func _physics_process(_delta: float) -> void:
	if paused:
		return
	if not _left_controller or not _left_controller.get_is_active():
		return
	if not _ship:
		return

	var button_down := _left_controller.is_button_pressed("ax_button")
	if button_down and not _button_was_down:
		_deploy_flare()
	_button_was_down = button_down


func _deploy_flare() -> void:
	var flare := FLARE.instantiate()
	get_tree().current_scene.add_child(flare)
	flare.global_position = _ship.global_position
	last_flare = flare
