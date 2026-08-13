extends Control

## The actual 2D content of the main menu — real Control/Button nodes,
## rendered into a SubViewport by `addons/godot-xr-tools/objects/
## viewport_2d_in_3d.tscn` and displayed on a flat quad in the 3D world
## (see `scripts/main_menu.gd`, the wrapper that positions that quad and
## drives this scene). Direct request: "I don't want it headlocked. I want
## it as a main screen free of clutter" — replacing the old Label3D/
## camera-child menu (hand-positioned 3D text, one binary left/right
## choice) with genuine flat 2D UI and a real nested menu.
##
## NOT using Godot's native pointer/mouse-click UI interaction — this
## project deliberately has no hand-held laser pointer or visible hands
## ("this is a cockpit game, you don't see your hands"), so buttons are
## never actually clicked. Instead this script owns a simple "which button
## is highlighted" state, driven externally by `move_selection()`/
## `confirm_selection()` calls from the 3D wrapper (which reads the
## thumbstick/trigger, the same convention already used for the death
## screen and options menu) — the SAME interaction model as before, just
## pointed at real Button nodes instead of manually-styled Label3Ds.
##
## DECOUPLED FROM GameFlow ENTIRELY. This scene doesn't know GameFlow
## exists — it only emits `mode_selected`/`quit_requested`, and
## `main_menu.gd` (which does have a path to GameFlow) connects to both via
## `XRToolsViewport2DIn3D.connect_scene_signal()`. Keeps this scene a pure,
## reusable UI component.

signal mode_selected(mode: int)
signal quit_requested

enum Level { TOP, MODES }
## Mirrors GameFlow.GameMode — duplicated rather than referenced directly
## since this scene is instanced inside a SubViewport with no direct path
## to GameFlow (see the class comment).
enum Mode { FULL_SCALE, ONE_V_ONE }

const COLOR_SELECTED := Color(1.0, 0.95, 0.5, 1.0)
const COLOR_UNSELECTED := Color(0.5, 0.55, 0.6, 1.0)
const COLOR_SELECTED_BG := Color(0.35, 0.24, 0.02, 0.9)
const COLOR_UNSELECTED_BG := Color(0.08, 0.09, 0.11, 0.85)

var _level: int = Level.TOP
var _selected_index: int = 0

@onready var _top_buttons: Array[Button] = [
	%GameModesButton,
	%QuitButton,
]
@onready var _mode_buttons: Array[Button] = [
	%FullScaleButton,
	%OneVOneButton,
	%BackButton,
]
@onready var _top_container: Control = %TopButtons
@onready var _mode_container: Control = %ModeButtons


func _ready() -> void:
	_show_level(Level.TOP)


## direction: -1 (previous) or +1 (next), wrapping. Called from
## main_menu.gd on a latched thumbstick push.
func move_selection(direction: int) -> void:
	var buttons := _current_buttons()
	if buttons.is_empty():
		return
	_selected_index = wrapi(_selected_index + direction, 0, buttons.size())
	_apply_highlight()


## Called from main_menu.gd on a trigger press. What "confirm" means
## depends on which level/button is currently highlighted.
func confirm_selection() -> void:
	match _level:
		Level.TOP:
			match _selected_index:
				0:  # GAME MODES
					_show_level(Level.MODES)
				1:  # QUIT
					quit_requested.emit()
		Level.MODES:
			match _selected_index:
				0:  # FULL SCALE
					mode_selected.emit(Mode.FULL_SCALE)
				1:  # 1 V 1
					mode_selected.emit(Mode.ONE_V_ONE)
				2:  # BACK
					_show_level(Level.TOP)


## Reset to the top level — called by main_menu.gd whenever the menu is
## freshly (re)entered, so returning from a match never leaves the
## GAME MODES submenu open from last time.
func reset_to_top() -> void:
	_show_level(Level.TOP)


func _current_buttons() -> Array[Button]:
	return _top_buttons if _level == Level.TOP else _mode_buttons


func _show_level(new_level: int) -> void:
	_level = new_level
	_selected_index = 0
	_top_container.visible = (_level == Level.TOP)
	_mode_container.visible = (_level == Level.MODES)
	_apply_highlight()


## Deliberately heavy-handed (colour, background and scale all change
## together) — same reasoning the old Label3D menu's own highlight used: a
## subtle brightness difference is genuinely hard to read at VR
## resolutions.
func _apply_highlight() -> void:
	var buttons := _current_buttons()
	for i in buttons.size():
		var button := buttons[i]
		var selected := i == _selected_index
		button.add_theme_color_override("font_color", COLOR_SELECTED if selected else COLOR_UNSELECTED)
		var style := StyleBoxFlat.new()
		style.bg_color = COLOR_SELECTED_BG if selected else COLOR_UNSELECTED_BG
		style.border_width_left = 4
		style.border_width_right = 4
		style.border_width_top = 4
		style.border_width_bottom = 4
		style.border_color = COLOR_SELECTED if selected else Color(0.2, 0.22, 0.25, 1.0)
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("focus", style)
		button.scale = Vector2(1.08, 1.08) if selected else Vector2.ONE
		button.pivot_offset = button.size * 0.5
