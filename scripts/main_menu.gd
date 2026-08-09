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
## SELECTION is gaze-based: whichever button the camera is currently
## pointing closest to is highlighted, the same aim-cone approach
## missile_system.gd used to use for its own target lock (now replaced by
## a target_lock.gd dependency, see that script), just applied to two
## fixed points instead of a moving alien. This script only tracks/shows
## the selection (`selected_action`) — game_flow.gd reads it when the
## right trigger is pressed and decides what to actually do, since it's
## already the sole owner of trigger-confirm actions for both menu states.

const FADE_DURATION := 2.5

@export var game_flow_path: NodePath = ^"../../../GameFlow"

## Read by game_flow.gd on trigger-confirm — "start" or "quit".
var selected_action: String = "start"

var _game_flow: Node
var _camera: Node3D
var _fade: MeshInstance3D
var _fade_material: StandardMaterial3D
var _title_label: Label3D
var _start_label: Label3D
var _quit_label: Label3D
var _music: AudioStreamPlayer
var _chatter: AudioStreamPlayer

var _was_menu: bool = false
var _revealing: bool = false
var _reveal_time: float = 0.0


func _ready() -> void:
	_game_flow = get_node_or_null(game_flow_path)
	_camera = get_parent()
	_fade = get_node_or_null("Fade")
	if _fade:
		_fade_material = _fade.material_override
	_title_label = get_node_or_null("Title")
	_start_label = get_node_or_null("StartLabel")
	_quit_label = get_node_or_null("QuitLabel")
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

	if _title_label:
		_title_label.visible = is_menu
	if _start_label:
		_start_label.visible = is_menu
	if _quit_label:
		_quit_label.visible = is_menu

	if is_menu:
		_update_selection()
	elif _revealing:
		_reveal_time += delta
		var a := clampf(1.0 - _reveal_time / FADE_DURATION, 0.0, 1.0)
		if _fade_material:
			_fade_material.albedo_color.a = a
		if _reveal_time >= FADE_DURATION:
			_revealing = false

	visible = is_menu or _revealing


func _update_selection() -> void:
	if not _camera or not _start_label or not _quit_label:
		return
	var forward: Vector3 = -_camera.global_transform.basis.z
	var cam_pos: Vector3 = _camera.global_position
	var to_start := (_start_label.global_position - cam_pos).normalized()
	var to_quit := (_quit_label.global_position - cam_pos).normalized()

	selected_action = "start" if forward.angle_to(to_start) <= forward.angle_to(to_quit) else "quit"

	_start_label.modulate = Color(1, 1, 1, 1) if selected_action == "start" else Color(0.45, 0.45, 0.45, 1)
	_quit_label.modulate = Color(1, 1, 1, 1) if selected_action == "quit" else Color(0.45, 0.45, 0.45, 1)
