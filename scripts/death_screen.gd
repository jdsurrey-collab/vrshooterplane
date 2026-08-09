extends Node3D

## Shown when the player is destroyed — fades to red, then offers RESPAWN
## or MAIN MENU. Replaces the old behaviour, which froze the player and
## silently auto-respawned them on a 10-second timer with no explanation of
## what had happened.
##
## Deliberately built as a close sibling of main_menu.gd, and for the same
## reasons — see that script's header for the full reasoning:
##
##  * Selection is by THUMBSTICK (either controller), latched through a
##    deadzone, confirmed with the right trigger. NOT gaze: this node is a
##    child of XRCamera3D, so its labels are locked to the player's face and
##    the angle from the camera's forward vector to each one never changes.
##    Gaze selection on head-locked UI is mathematically inert — that bug
##    shipped once already on the main menu and made QUIT unselectable.
##  * `_update_selection()` takes the stick axis as a parameter so the logic
##    can be driven by a headless test, since controllers don't exist
##    without a live OpenXR session.
##  * The `Fade` quad sits nearer the camera than the labels and carries
##    `render_priority = -1` so Godot's back-to-front transparency sort
##    draws it behind them. Without that the fade paints over its own text.
##
## Unlike the main menu's fade this one animates IN (clear -> red) rather
## than revealing out, and it never reaches full opacity — `max_alpha` keeps
## the wreck visible through it, since a solid red screen would hide the
## crash the player presumably wants to see.
##
## This script only tracks and displays `selected_action`; game_flow.gd owns
## the trigger-confirm and performs the actual respawn, matching how it
## already owns confirmation for every other menu state.

const FADE_IN_DURATION := 1.1
const STICK_DEADZONE := 0.45

@export var game_flow_path: NodePath = ^"../../../GameFlow"
@export var max_alpha: float = 0.62

## Read by game_flow.gd on trigger-confirm — "respawn" or "menu".
var selected_action: String = "respawn"

var _game_flow: Node
var _left_controller: XRController3D
var _right_controller: XRController3D
var _fade: MeshInstance3D
var _fade_material: StandardMaterial3D
var _title_label: Label3D
var _respawn_label: Label3D
var _menu_label: Label3D
var _hint_label: Label3D

var _was_dead: bool = false
var _fade_time: float = 0.0
var _stick_ready: bool = true


func _ready() -> void:
	_game_flow = get_node_or_null(game_flow_path)
	var camera := get_parent()
	var player := camera.get_parent() if camera else null
	if player:
		_left_controller = player.get_node_or_null("LeftHand")
		_right_controller = player.get_node_or_null("RightHand")
	_fade = get_node_or_null("Fade")
	if _fade:
		_fade_material = _fade.material_override
	_title_label = get_node_or_null("Title")
	_respawn_label = get_node_or_null("RespawnLabel")
	_menu_label = get_node_or_null("MenuLabel")
	_hint_label = get_node_or_null("Hint")
	visible = false


func _process(delta: float) -> void:
	var is_dead: bool = _game_flow != null and _game_flow.state == GameFlow.State.DEAD

	if is_dead and not _was_dead:
		_fade_time = 0.0
		selected_action = "respawn"
		_stick_ready = true
	_was_dead = is_dead

	visible = is_dead
	if not is_dead:
		return

	_fade_time = minf(_fade_time + delta, FADE_IN_DURATION)
	if _fade_material:
		_fade_material.albedo_color.a = max_alpha * (_fade_time / FADE_IN_DURATION)

	_update_selection(_selection_stick_x())


func _selection_stick_x() -> float:
	var x := 0.0
	if _left_controller and _left_controller.get_is_active():
		x = _left_controller.get_vector2("primary").x
	if absf(x) < STICK_DEADZONE and _right_controller and _right_controller.get_is_active():
		x = _right_controller.get_vector2("primary").x
	return x


## Stick left = RESPAWN, right = MAIN MENU. See the class comment for why
## this takes the axis rather than reading the controllers itself.
func _update_selection(x: float) -> void:
	if not _respawn_label or not _menu_label:
		return

	if absf(x) < STICK_DEADZONE:
		_stick_ready = true
	elif _stick_ready:
		_stick_ready = false
		selected_action = "menu" if x > 0.0 else "respawn"

	_apply_highlight(_respawn_label, selected_action == "respawn")
	_apply_highlight(_menu_label, selected_action == "menu")


func _apply_highlight(label: Label3D, selected: bool) -> void:
	if selected:
		label.modulate = Color(1.0, 0.95, 0.6, 1.0)
		label.outline_modulate = Color(0.8, 0.12, 0.05, 1.0)
		label.outline_size = 26
		label.scale = Vector3(1.25, 1.25, 1.25)
	else:
		label.modulate = Color(0.5, 0.36, 0.36, 1.0)
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.0)
		label.outline_size = 0
		label.scale = Vector3.ONE
