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
## sourced reference distances.
##
## NOW DYNAMIC, computed every physics frame from gunnery.gd's shared
## solution rather than toed in once in `_ready()` at a fixed 229m. See
## gunnery.gd's own header for exactly why the fixed version was a real bug,
## not just a simplification: even a shot lined up perfectly on
## target_lock.gd's PIP only truly landed when the target happened to be at
## almost exactly 229m — at any other range the two barrels crossed at the
## wrong point in space and straddled the target regardless of where the
## ship's nose pointed. `_update_gun_convergence()` re-aims both mounts at
## `Gunnery.gun_aim_point` every frame; with no target locked that point
## falls back to the same fixed 229m point along the ship's own bore,
## exactly matching the old behaviour.
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
@export var gunnery_path: NodePath = ^"../Gunnery"
## Fallback only, used if `_gunnery` is somehow absent — matches
## gunnery.gd's own `default_convergence_distance` (229m, the RAF WWII
## harmonization figure). The live value comes from Gunnery every frame.
@export var convergence_distance: float = 229.0
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

## Distinct, cockpit-only "tink" for HIT CONFIRMATION — plain
## AudioStreamPlayer, not 3D, for the same reason missile_system.gd's own
## lock/launch tones are plain players: this is feedback about the player's
## own shot landing, happening inside their own cockpit, so proximity is
## meaningless. Node path, not a preload, because the stream lives on a
## scene child (HitConfirmAudio under WeaponSystem in Player.tscn) — the
## same pattern MissileSystem's LockAudio/LaunchAudio already use.
@export var hit_confirm_audio_path: NodePath = ^"HitConfirmAudio"

## How hard and how long the glass crosshair punches out on a landed hit —
## see notify_hit(). Deliberately brief: this is a confirmation flash, not a
## sustained state change.
const HIT_PULSE_DURATION := 0.14
const HIT_PULSE_PEAK_SCALE := 1.7

var _right_controller: XRController3D
var _gun_left: Node3D
var _gun_right: Node3D
var _crosshair: Node3D
var _audio_left: AudioStreamPlayer3D
var _audio_right: AudioStreamPlayer3D
var _hit_audio: AudioStreamPlayer
var _gunnery: Node

var _crosshair_base_scale: Vector3 = Vector3.ONE
var _hit_pulse_time: float = -1.0  # negative = idle, no pulse in progress

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
	_hit_audio = get_node_or_null(hit_confirm_audio_path)
	_gunnery = get_node_or_null(gunnery_path)
	if _crosshair:
		_crosshair_base_scale = _crosshair.scale
	print("[Weapon] right_controller=%s gun_left=%s gun_right=%s crosshair=%s gunnery=%s" % [
			_right_controller, _gun_left, _gun_right, _crosshair, _gunnery])

	_position_crosshair()
	_update_gun_convergence()  # first frame, so the guns aren't at their raw scene orientation before physics starts


## Parks the crosshair SYMBOL once — it stays a fixed "glass" mark at
## `crosshair_distance`/`crosshair_height` regardless of what the guns are
## doing (see the class comment on why the symbol and the real gun aim were
## deliberately separated). This does NOT aim the guns; see
## `_update_gun_convergence()` for that, which runs every frame instead of
## once.
func _position_crosshair() -> void:
	if not _gun_left or not _gun_right or not _crosshair:
		return
	var mid_local := (_gun_left.position + _gun_right.position) * 0.5
	_crosshair.position = Vector3(mid_local.x, crosshair_height, crosshair_distance)


## Points both gun mounts at Gunnery's `gun_aim_point` every physics frame —
## dynamic convergence at the target's true range, deflected further onto
## the true lead point when the gimbal assist is active (both computed by
## gunnery.gd; this function only consumes the result). `look_at()` handles
## the toe-in angle correctly from each mount's own position regardless of
## its existing orientation.
##
## UP-REFERENCE GUARD, a genuinely new failure mode from going per-frame:
## the old one-shot version only ever ran at spawn, when the ship's bore is
## always roughly level — `look_at(..., Vector3.UP)` was safe by
## construction. This ship can dive or climb steeply at any time, and once
## the bore direction approaches vertical, UP becomes a degenerate up-hint
## for look_at() (the same "Target and up vectors are colinear" class of
## warning this project has already hit and fixed elsewhere — see
## ground_flak.gd/faction_battle.gd's own guards). Swapping to FORWARD near
## vertical is the same fix already established in both of those.
func _update_gun_convergence() -> void:
	if not _gun_left or not _gun_right:
		return

	var target_world: Vector3
	if _gunnery:
		target_world = _gunnery.gun_aim_point
	else:
		# Fallback with no Gunnery node — reproduces the original fixed
		# convergence exactly, so the weapon still works without it.
		var ship := _gun_left.get_parent() as Node3D
		var mid_local := (_gun_left.position + _gun_right.position) * 0.5
		target_world = ship.to_global(mid_local + Vector3(0.0, 0.0, convergence_distance))

	var bore: Vector3 = _gunnery.bore_direction if _gunnery else Vector3.FORWARD
	var up_ref := Vector3.FORWARD if absf(bore.dot(Vector3.UP)) > 0.99 else Vector3.UP

	_gun_left.look_at(target_world, up_ref)
	_gun_right.look_at(target_world, up_ref)


## Called by laser_bolt.gd the instant the player's own bolt lands a hit —
## kill or not. Plays the cockpit "tink" and punches the glass crosshair out
## briefly. Runs BEFORE the paused/controller-active early-outs below so an
## in-flight pulse always finishes decaying rather than freezing mid-punch if
## the menu opens or the controller drops out a frame later.
func notify_hit() -> void:
	if _hit_audio:
		_hit_audio.play()
	_hit_pulse_time = 0.0


func _physics_process(delta: float) -> void:
	_update_hit_pulse(delta)
	_update_gun_convergence()

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


## Decays the crosshair back to its base scale over HIT_PULSE_DURATION. A
## plain scale pulse rather than an emission-brightness change specifically
## to sidestep this project's own known gotcha: a headless resave has been
## observed stripping emission_enabled/emission/emission_energy_multiplier
## from StandardMaterial3D_crosshair specifically (see CLAUDE.md's Flight HUD
## section) — scale carries no such risk and needs no material edit at all.
func _update_hit_pulse(delta: float) -> void:
	if _hit_pulse_time < 0.0 or not _crosshair:
		return
	_hit_pulse_time += delta
	var t := clampf(_hit_pulse_time / HIT_PULSE_DURATION, 0.0, 1.0)
	var scale_mult := lerpf(HIT_PULSE_PEAK_SCALE, 1.0, t)
	_crosshair.scale = _crosshair_base_scale * scale_mult
	if t >= 1.0:
		_hit_pulse_time = -1.0


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

	# RANGE DISPERSION — see gunnery.gd's class comment for why this is
	# driven off `convergence_distance` rather than a separate range lookup.
	# Zero with nothing locked (guns zeroed at their default 229m), ramping
	# up past `lethal_range` so a shot at a target beyond it is genuinely
	# unreliable rather than just "the guns didn't converge right."
	if _gunnery and _gunnery.dispersion_deg > 0.0:
		_apply_dispersion(bolt, _gunnery.dispersion_deg)

	shots_fired += 1

	if audio:
		audio.play()


## Perturbs a freshly-spawned bolt's own firing direction by a random angle
## within a cone of `max_deg` — tilt off-axis by a random amount up to
## max_deg, then spin around the axis by a random full turn, the identical
## two-step construction ground_flak.gd's `_cone_direction()` already uses
## for exactly this "random direction within a cone" problem, reused here
## rather than inventing a second version of the same idea.
func _apply_dispersion(bolt: Node3D, max_deg: float) -> void:
	var forward := -bolt.global_transform.basis.z
	var arbitrary := Vector3.RIGHT if absf(forward.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var perp := forward.cross(arbitrary).normalized()
	var tilted := forward.rotated(perp, deg_to_rad(randf_range(0.0, max_deg)))
	var new_forward := tilted.rotated(forward, randf_range(0.0, TAU)).normalized()
	var up_ref := Vector3.FORWARD if absf(new_forward.dot(Vector3.UP)) > 0.99 else Vector3.UP
	bolt.global_transform = Transform3D(Basis.looking_at(new_forward, up_ref), bolt.global_position)
