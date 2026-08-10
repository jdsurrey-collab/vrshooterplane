extends Node

## Basic twin-gun laser weapon. Right trigger (OpenXR action "trigger_click")
## fires a continuous stream of bolts from the front guns while held,
## alternating muzzle each shot ("stagger fire") rather than both guns
## firing together.
##
## GUN CONVERGENCE — real fixed-gun fighters don't fire straight ahead from
## each mount; the guns are "toed in" so their lines of fire cross at a
## chosen distance ("harmonization"), concentrating fire on target instead of
## two parallel streams that never meet. See docs/gunnery-reference.md for
## sourced reference distances. `convergence_distance` drives the gun
## mounts' toe-in angle, computed once in _ready().
##
## The CROSSHAIR SYMBOL is drawn separately, at `crosshair_distance` — NOT
## at the real 229m convergence point any more. Direct instruction: "the
## crosshair should be sitting point nine meters out too. It should be
## directly on the glass, not out in front of me." This matches a real
## HUD combiner rather than a literal floating reticle: an actual jet's HUD
## glass sits at a fixed physical depth close to the pilot regardless of
## how far a real gunsight would need to project a lead solution, and this
## project's own `flight_hud.gd` cluster already sits at that same close
## "glass" depth (its `hud_center.z`). The GUNS' actual aim is unaffected —
## `_gun_left`/`_gun_right` still toe in toward the real convergence point
## via `target_world` below, which is pure ballistics math independent of
## where the crosshair symbol happens to be drawn.

const LASER_BOLT := preload("res://scenes/LaserBolt.tscn")

@export var fire_cooldown: float = 0.12  # seconds between shots
@export var gun_left_path: NodePath = ^"../Ship/GunMountLeft"
@export var gun_right_path: NodePath = ^"../Ship/GunMountRight"
@export var crosshair_path: NodePath = ^"../Ship/Crosshair"
@export var convergence_distance: float = 229.0  # meters (250 yards, RAF WWII standard) — GUN AIM only
@export var crosshair_distance: float = 0.9  # meters — where the SYMBOL is drawn, on the glass, not at the real convergence point
## Local Y for the crosshair symbol — NOT the gun mounts' own Y (1.9).
## Matches flight_hud.gd's hud_center.y (2.8): now that the crosshair sits
## at the same close glass depth as the rest of that cluster (see above),
## using the gun mounts' height instead of the cluster's own tuned height
## put it visibly below everything else — reported live as "sitting way
## too low" the moment the crosshair actually became visible at this
## distance for the first time.
@export var crosshair_height: float = 2.8

## Set by the options menu while it's open, so config adjustments can't
## trigger weapon fire.
var paused: bool = false

var _right_controller: XRController3D
var _gun_left: Node3D
var _gun_right: Node3D
var _crosshair: Node3D
var _audio_left: AudioStreamPlayer3D
var _audio_right: AudioStreamPlayer3D

var _fire_from_left: bool = true

# Live status, readable by other scripts (e.g. the cockpit HUD) for
# in-headset diagnostics — console prints are useless once the user is
# actually wearing the headset.
var right_controller_active: bool = false
var trigger_pressed: bool = false
var cooldown_remaining: float = 0.0
var shots_fired: int = 0

var _last_pressed_state: bool = false
var _last_active_state: bool = false


func _ready() -> void:
	var origin := get_parent()
	_right_controller = origin.get_node_or_null("RightHand")
	_gun_left = get_node_or_null(gun_left_path)
	_gun_right = get_node_or_null(gun_right_path)
	_crosshair = get_node_or_null(crosshair_path)
	if _gun_left:
		_audio_left = _gun_left.get_node_or_null("Audio")
	if _gun_right:
		_audio_right = _gun_right.get_node_or_null("Audio")
	print("[Weapon] right_controller=%s gun_left=%s gun_right=%s crosshair=%s" % [
			_right_controller, _gun_left, _gun_right, _crosshair])

	_setup_convergence()


## Points both gun mounts at a single world-space point straight ahead of
## the ship at `convergence_distance` — `look_at()` handles the toe-in angle
## correctly regardless of the mounts' existing orientation, since it works
## from actual world positions. The crosshair SYMBOL is parked separately,
## at `crosshair_distance` (see this file's header) — deliberately not the
## same point the guns are aimed at.
func _setup_convergence() -> void:
	if not _gun_left or not _gun_right:
		return
	var ship := _gun_left.get_parent() as Node3D
	var mid_local := (_gun_left.position + _gun_right.position) * 0.5
	var target_local := mid_local + Vector3(0.0, 0.0, convergence_distance)
	var target_world: Vector3 = ship.to_global(target_local)

	_gun_left.look_at(target_world, Vector3.UP)
	_gun_right.look_at(target_world, Vector3.UP)

	if _crosshair:
		_crosshair.position = Vector3(mid_local.x, crosshair_height, crosshair_distance)


func _physics_process(delta: float) -> void:
	if paused:
		return
	if not _right_controller:
		return

	right_controller_active = _right_controller.get_is_active()
	if right_controller_active != _last_active_state:
		print("[Weapon] right controller active=%s" % right_controller_active)
		_last_active_state = right_controller_active
	if not right_controller_active:
		return
	if not _gun_left or not _gun_right:
		return

	cooldown_remaining = maxf(0.0, cooldown_remaining - delta)

	trigger_pressed = _right_controller.is_button_pressed("trigger_click")
	if trigger_pressed != _last_pressed_state:
		print("[Weapon] trigger pressed=%s" % trigger_pressed)
		_last_pressed_state = trigger_pressed
	if trigger_pressed:
		_try_fire()


func _try_fire() -> void:
	if cooldown_remaining > 0.0:
		return
	cooldown_remaining = fire_cooldown

	var mount := _gun_left if _fire_from_left else _gun_right
	var audio := _audio_left if _fire_from_left else _audio_right
	_fire_from_left = not _fire_from_left

	var bolt := LASER_BOLT.instantiate()
	get_tree().current_scene.add_child(bolt)
	bolt.global_transform = mount.global_transform
	shots_fired += 1

	if audio:
		audio.play()
