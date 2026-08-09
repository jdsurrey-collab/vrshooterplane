extends Node3D

## The actual main menu — shown while game_flow.gd's state is MENU.
## Replaces the earlier plain "PULL TRIGGER TO BEGIN" prompt
## (start_menu_hud.gd, now superseded/removed) with: a solid black
## backdrop (the menu itself is black the whole time it's up, NOT a quick
## fade revealing the cockpit behind it — the reveal happens once, at the
## moment START is chosen, dissolving into the already-live flight/battle
## rather than showing it prematurely), two menu tracks playing
## simultaneously (music + radio-chatter ambience), and two selectable
## options — START and QUIT.
##
## Still no real scene switching (see game_flow.gd's header for why) — the
## "fade" is a literal opaque quad positioned closer to the camera than
## everything else (Fade, at z=-0.15 vs. the labels' -0.4/-0.55), using
## ordinary depth testing rather than the no_depth_test trick the rest of
## this project's HUD uses, specifically so it reliably occludes both the
## title/button labels AND the background scene while opaque.
##
## SEQUENCE: while `state == MENU`, the Fade stays fully opaque (alpha 1)
## and the title/buttons/music sit on top of it — a real black menu
## screen, not a translucent overlay on top of the flying scene. The
## instant game_flow.gd moves off MENU (START was confirmed — GameFlow
## already unpauses the player and starts the battle immediately, no
## artificial delay to the actual gameplay logic), this script notices the
## state change and independently begins a REVEAL: title/button labels and
## audio stop right away, but the Fade quad keeps rendering by itself,
## animating alpha 1 -> 0 over FADE_DURATION, dissolving into the flight
## that's already underway underneath. Re-entering MENU later (post-match)
## snaps the Fade straight back to fully opaque, ready to be black again
## next time.
##
## SELECTION is by THUMBSTICK (either controller): push left for START,
## right for QUIT, then pull the right trigger to confirm. This script only
## tracks/shows the selection (`selected_action`) — game_flow.gd reads it on
## the trigger press and decides what to actually do, since it's already the
## sole owner of trigger-confirm actions for both menu states.
##
## This REPLACED a gaze-based version that could not work, and whose failure
## mode was that QUIT was literally unselectable. The reasoning is worth
## keeping because it's a trap any future head-locked UI here would fall
## into: MainMenu is a child of XRCamera3D, so the labels are rigidly
## attached to the player's face. Gaze selection compared the angle between
## the camera's forward vector and the direction to each label — but because
## the labels move with the head, those directions are constant in camera
## space, so both angles were fixed. Worse, the two labels sit symmetrically
## (x = -0.13 and +0.13, identical y and z), which made the two angles
## exactly equal, so the `<=` comparison always resolved to START and
## turning your head did nothing at all. Gaze can only ever work against
## WORLD-locked UI; a stick axis is unambiguous, needs no aiming, and
## matches how the rest of this project takes input.

const FADE_DURATION := 2.5
const STICK_DEADZONE := 0.45  # must fall back inside this before another push registers — see _update_selection

@export var game_flow_path: NodePath = ^"../../../GameFlow"

## Read by game_flow.gd on trigger-confirm — "start" or "quit".
var selected_action: String = "start"

var _game_flow: Node
var _camera: Node3D
var _left_controller: XRController3D
var _right_controller: XRController3D
var _fade: MeshInstance3D
var _fade_material: StandardMaterial3D
var _title_label: Label3D
var _start_label: Label3D
var _quit_label: Label3D
var _hint_label: Label3D
var _music: AudioStreamPlayer
var _chatter: AudioStreamPlayer

var _was_menu: bool = false
var _revealing: bool = false
var _reveal_time: float = 0.0
var _stick_ready: bool = true


func _ready() -> void:
	_game_flow = get_node_or_null(game_flow_path)
	_camera = get_parent()
	# MainMenu -> XRCamera3D -> Player (XROrigin3D), where the controllers live.
	var player := _camera.get_parent()
	if player:
		_left_controller = player.get_node_or_null("LeftHand")
		_right_controller = player.get_node_or_null("RightHand")
	_fade = get_node_or_null("Fade")
	if _fade:
		_fade_material = _fade.material_override
	_title_label = get_node_or_null("Title")
	_start_label = get_node_or_null("StartLabel")
	_quit_label = get_node_or_null("QuitLabel")
	_hint_label = get_node_or_null("Hint")
	_music = get_node_or_null("Music")
	_chatter = get_node_or_null("Chatter")
	if _music:
		_music.finished.connect(_music.play)
	if _chatter:
		_chatter.finished.connect(_chatter.play)


func _process(delta: float) -> void:
	var is_menu: bool = _game_flow != null and _game_flow.state == GameFlow.State.MENU

	if is_menu and not _was_menu:
		# Fresh entry (first launch, or back from a match) — snap straight
		# back to a fully opaque black menu.
		_revealing = false
		if _fade_material:
			_fade_material.albedo_color.a = 1.0
		if _music:
			_music.play()
		if _chatter:
			_chatter.play()
	elif not is_menu and _was_menu:
		# START was just confirmed — begin the reveal. Labels/audio stop
		# immediately; the Fade quad keeps animating on its own below.
		_revealing = true
		_reveal_time = 0.0
		if _music:
			_music.stop()
		if _chatter:
			_chatter.stop()
	_was_menu = is_menu

	# Hidden individually rather than relying on the root's `visible` below —
	# the root deliberately stays visible through the reveal so the Fade quad
	# can keep animating, and the text must not linger over the flight
	# underneath while it does.
	for label in [_title_label, _start_label, _quit_label, _hint_label]:
		if label:
			label.visible = is_menu

	if is_menu:
		_update_selection(_selection_stick_x())
	elif _revealing:
		_reveal_time += delta
		var a := clampf(1.0 - _reveal_time / FADE_DURATION, 0.0, 1.0)
		if _fade_material:
			_fade_material.albedo_color.a = a
		if _reveal_time >= FADE_DURATION:
			_revealing = false

	visible = is_menu or _revealing


## Stick left = START, stick right = QUIT. Latched through the deadzone so
## one push moves the selection once rather than re-triggering every frame
## the stick is held over.
##
## Takes the axis as a parameter rather than reading the controllers itself
## so the selection logic can be driven directly by a headless test — there
## are no controllers without a live OpenXR session, and this is exactly the
## kind of logic that reads fine and still doesn't work (see the class
## comment for the gaze version that shipped broken).
func _update_selection(x: float) -> void:
	if not _start_label or not _quit_label:
		return

	if absf(x) < STICK_DEADZONE:
		_stick_ready = true
	elif _stick_ready:
		_stick_ready = false
		selected_action = "quit" if x > 0.0 else "start"

	_apply_highlight(_start_label, selected_action == "start")
	_apply_highlight(_quit_label, selected_action == "quit")


## Either stick works — whichever one is actually being pushed wins, so the
## player doesn't have to remember which hand the menu listens to.
func _selection_stick_x() -> float:
	var x := 0.0
	if _left_controller and _left_controller.get_is_active():
		x = _left_controller.get_vector2("primary").x
	if absf(x) < STICK_DEADZONE and _right_controller and _right_controller.get_is_active():
		x = _right_controller.get_vector2("primary").x
	return x


## Deliberately heavy-handed: colour, size and outline all change together.
## At VR resolutions across a dark screen, a subtle brightness difference
## between two small labels is genuinely hard to read.
func _apply_highlight(label: Label3D, selected: bool) -> void:
	if selected:
		label.modulate = Color(1.0, 0.95, 0.5, 1.0)
		label.outline_modulate = Color(0.9, 0.5, 0.05, 1.0)
		label.outline_size = 26
		label.scale = Vector3(1.25, 1.25, 1.25)
	else:
		label.modulate = Color(0.42, 0.42, 0.45, 1.0)
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.0)
		label.outline_size = 0
		label.scale = Vector3.ONE
