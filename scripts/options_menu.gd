extends Label3D

## In-VR options menu — seat height calibration ("I'm too low in the seat")
## and toggling the enemy locator arrow/distance readout. Toggled open by
## the left controller's menu button; freezes flight and weapons while open
## so adjusting doesn't fight with flying. Persisted to user://settings.cfg
## so it survives between play sessions.
##
## Adjusts Ship's local Y offset (relative to Player), NOT Player's own
## position. Two earlier approaches were tried and both failed:
##
## 1. A wrapper node around the camera/hands, offset instead of Player —
##    broke Godot's XR tracking, which requires XRCamera3D to be a DIRECT
##    child of XROrigin3D to drive the actual per-eye render pose. Ordinary
##    children (like the HUD) still moved correctly via normal scene-graph
##    transform composition, which made it look like it was working — only
##    the real VR viewpoint silently didn't move.
## 2. Adjusting Player's own position.y directly — Player's position is
##    also the ship's world-space flight position, AND `Ship` is itself a
##    child of Player with a fixed local offset. Moving Player moves the
##    camera and the cockpit together as one rigid unit, so the distance
##    between your eye and the seat never actually changes. Confirmed via
##    debug logging: player.global_position.y was correctly changing, just
##    with zero visible effect, since everything moved in lockstep.
##
## Moving Ship's local offset instead is the actual fix: it changes where
## the fixed cockpit geometry sits relative to your (untouched) tracked
## head, without touching XR camera hierarchy or position at all.

const SETTINGS_PATH := "user://settings.cfg"
const HEIGHT_ADJUST_SPEED := 0.5  # m/s at full stick deflection
const MIN_SEAT_HEIGHT := -1.0
const MAX_SEAT_HEIGHT := 1.0

var _player: Node3D
var _ship: Node3D
var _flight_controller: Node
var _weapon_system: Node
var _missile_system: Node
var _flare_system: Node
var _enemy_locator: Node
var _left_controller: XRController3D

var _menu_open: bool = false
var _menu_button_was_down: bool = false
var _toggle_button_was_down: bool = false
var _seat_height: float = 0.0
var _base_ship_y: float = 0.0
var _enemy_tracking_enabled: bool = true


func _ready() -> void:
	var camera := get_parent()
	_player = camera.get_parent()
	_ship = _player.get_node_or_null("Ship")
	_flight_controller = _player.get_node_or_null("FlightController")
	_weapon_system = _player.get_node_or_null("WeaponSystem")
	_missile_system = _player.get_node_or_null("MissileSystem")
	_flare_system = _player.get_node_or_null("FlareSystem")
	_enemy_locator = camera.get_node_or_null("EnemyLocator")
	_left_controller = _player.get_node_or_null("LeftHand")

	if _ship:
		_base_ship_y = _ship.position.y

	_load_settings()
	_apply_seat_height()
	_apply_enemy_tracking()
	visible = false


func _physics_process(delta: float) -> void:
	if not _left_controller or not _left_controller.get_is_active():
		return

	var menu_button_down := _left_controller.is_button_pressed("menu_button")
	if menu_button_down and not _menu_button_was_down:
		_toggle_menu()
	_menu_button_was_down = menu_button_down

	if not _menu_open:
		return

	var stick: Vector2 = _left_controller.get_vector2("primary")
	if absf(stick.y) > 0.15:
		_seat_height = clampf(
				_seat_height + stick.y * HEIGHT_ADJUST_SPEED * delta, MIN_SEAT_HEIGHT, MAX_SEAT_HEIGHT)
		_apply_seat_height()

	# Left controller's X button ("ax_button") — free to reuse for this
	# since weapons moved to the right trigger.
	var toggle_button_down := _left_controller.is_button_pressed("ax_button")
	if toggle_button_down and not _toggle_button_was_down:
		_enemy_tracking_enabled = not _enemy_tracking_enabled
		_apply_enemy_tracking()
	_toggle_button_was_down = toggle_button_down

	_update_text()


func _update_text() -> void:
	text = "OPTIONS\nSeat height: %+.2f m  (left stick)\nEnemy tracking: %s  (X button)\nMenu button: close" % [
			_seat_height, "ON" if _enemy_tracking_enabled else "OFF"]


## Pushing the seat height up should raise your apparent viewpoint relative
## to the cockpit — since your tracked head doesn't move, that means moving
## the ship DOWN by the same amount.
func _apply_seat_height() -> void:
	if _ship:
		_ship.position.y = _base_ship_y - _seat_height


func _apply_enemy_tracking() -> void:
	if _enemy_locator:
		_enemy_locator.tracking_enabled = _enemy_tracking_enabled


## Every player weapon system has to be paused here, not just flight and
## guns. The X button is shared: this menu uses it to toggle enemy tracking
## while open, and flare_system.gd uses it to deploy a flare during normal
## flight — so leaving FlareSystem live meant every menu toggle also burned
## a flare. MissileSystem has the same problem with the left trigger.
func _toggle_menu() -> void:
	_menu_open = not _menu_open
	visible = _menu_open
	if _flight_controller:
		_flight_controller.paused = _menu_open
	if _weapon_system:
		_weapon_system.paused = _menu_open
	if _missile_system:
		_missile_system.paused = _menu_open
	if _flare_system:
		_flare_system.paused = _menu_open

	if _menu_open:
		_update_text()
	else:
		_save_settings()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		_seat_height = cfg.get_value("player", "seat_height", 0.0)
		_enemy_tracking_enabled = cfg.get_value("player", "enemy_tracking_enabled", true)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "seat_height", _seat_height)
	cfg.set_value("player", "enemy_tracking_enabled", _enemy_tracking_enabled)
	cfg.save(SETTINGS_PATH)
