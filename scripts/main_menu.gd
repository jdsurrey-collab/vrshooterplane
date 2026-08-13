extends Node3D

## The actual main menu — shown while game_flow.gd's state is MENU. Now a
## genuine WORLD-LOCKED flat screen (`$Screen`, an
## `XRToolsViewport2DIn3D` displaying `scenes/MainMenuUI.tscn` — real
## Control/Button nodes rendered into a SubViewport) rather than Label3D
## text riding on the camera. Direct request: "I don't want it headlocked.
## I want it as a main screen free of clutter."
##
## Parented under `Player` (the XROrigin3D), NOT `XRCamera3D` — this is
## what makes it world-locked: it moves with the player RIG (so it's still
## wherever `game_flow.gd`'s `_reposition_player()` puts you each time the
## menu is entered) without tracking head ROTATION, unlike the old
## camera-child version. `$Screen` sits at a fixed local offset (8m ahead,
## 2m up) — you look toward it like an actual monitor, rather than it
## always filling your view.
##
## THE OLD "SOLID BLACK BACKDROP, THEN REVEAL" EFFECT IS GONE, on purpose,
## not an oversight. That design existed because the old menu was a
## camera-filling quad hiding the whole scene behind it — a small
## world-locked screen has no "behind it" to hide; the mothership deck and
## fleet are visible around the screen the moment you're in MENU state,
## same as they always were before this reveal system existed. This reads
## as more natural for an object sitting in the cockpit rather than less
## — you're looking at a display, not a curtain.
##
## SELECTION is still by THUMBSTICK (either controller, same as every
## other menu screen in this project) — this script only reads the stick
## and forwards `move_selection(+1/-1)`/`confirm_selection()` calls into
## the 2D scene (`main_menu_ui.gd`, fetched via `$Screen.get_scene_
## instance()`), which owns its own nested TOP/MODES state machine and
## button highlighting. Deliberately NOT using the addon's native
## pointer-click interaction model — this project has no hand-held laser
## pointer or visible hands ("this is a cockpit game, you don't see your
## hands"), so keeping thumbstick+trigger is what stays consistent with
## the options menu and death screen.

const STICK_DEADZONE := 0.45  # must fall back inside this before another push registers

@export var game_flow_path: NodePath = ^"../GameFlow"

var _game_flow: Node
var _left_controller: XRController3D
var _right_controller: XRController3D
var _screen: Node  # XRToolsViewport2DIn3D
var _ui: Control  # the instantiated MainMenuUI scene
var _music: AudioStreamPlayer
var _chatter: AudioStreamPlayer

var _was_menu: bool = false
var _stick_ready: bool = true


func _ready() -> void:
	_game_flow = get_node_or_null(game_flow_path)
	# MainMenu -> Player (XROrigin3D), where the controllers live directly.
	var player := get_parent()
	if player:
		_left_controller = player.get_node_or_null("LeftHand")
		_right_controller = player.get_node_or_null("RightHand")
	_screen = get_node_or_null("Screen")
	_music = get_node_or_null("Music")
	_chatter = get_node_or_null("Chatter")
	if _music:
		_music.finished.connect(_music.play)
	if _chatter:
		_chatter.finished.connect(_chatter.play)

	if _screen:
		_ui = _screen.get_scene_instance()
		_screen.connect_scene_signal("mode_selected", _on_mode_selected)
		_screen.connect_scene_signal("quit_requested", _on_quit_requested)


func _process(_delta: float) -> void:
	var is_menu: bool = _game_flow != null and _game_flow.state == GameFlow.State.MENU

	if is_menu and not _was_menu:
		if _ui and _ui.has_method("reset_to_top"):
			_ui.reset_to_top()
		if _music:
			_music.play()
		if _chatter:
			_chatter.play()
	elif not is_menu and _was_menu:
		if _music:
			_music.stop()
		if _chatter:
			_chatter.stop()
	_was_menu = is_menu

	visible = is_menu

	if is_menu:
		_update_selection(_selection_stick_x())


## Called by game_flow.gd on a trigger-confirm press while in the MENU
## state — see that script's own trigger-edge-detection, unchanged, just
## now delegating what a confirm actually DOES to the 2D UI instead of a
## hardcoded quit/start branch.
func confirm_selection() -> void:
	if _ui and _ui.has_method("confirm_selection"):
		_ui.confirm_selection()


## Stick left = previous, stick right = next, within whichever level the
## 2D UI is currently showing. Latched through the deadzone so one push
## moves the selection once rather than re-triggering every frame the
## stick is held over — same convention as every other menu in this
## project.
func _update_selection(x: float) -> void:
	if not _ui:
		return
	if absf(x) < STICK_DEADZONE:
		_stick_ready = true
	elif _stick_ready:
		_stick_ready = false
		_ui.move_selection(1 if x > 0.0 else -1)


## Either stick works — whichever one is actually being pushed wins.
func _selection_stick_x() -> float:
	var x := 0.0
	if _left_controller and _left_controller.get_is_active():
		x = _left_controller.get_vector2("primary").x
	if absf(x) < STICK_DEADZONE and _right_controller and _right_controller.get_is_active():
		x = _right_controller.get_vector2("primary").x
	return x


func _on_mode_selected(mode: int) -> void:
	if _game_flow and _game_flow.has_method("start_match_with_mode"):
		_game_flow.start_match_with_mode(mode)


func _on_quit_requested() -> void:
	get_tree().quit()
