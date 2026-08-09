extends Node

## Inertia-based 6DOF flight controller — "flight assist ON" handling, the
## default mode on Star Citizen fighters (Arrow/Gladius class): stick and
## trigger input drives acceleration, not position directly. Releasing input
## lets dampers bleed velocity back to zero rather than stopping instantly or
## drifting forever.
##
## Right joystick: pitch (Y axis) and yaw (X axis)
## Left joystick:  roll (X axis) and elevation / vertical thrust (Y axis)
## Right grip:     forward thrust
## Left grip:      backward thrust
##
## Attached to a child of the player's XROrigin3D; moves/rotates its parent
## directly each physics frame.
##
## GRAVITY COMPENSATOR STANDARD — every flight-capable craft on this planet
## is built with drives that actively cancel gravity while powered, so
## dogfighting never has to fight a constant sink rate. This is the
## reference implementation: `gravity_compensator_active` gates whether
## gravity is added to the craft's velocity at all. Any future ship script
## should follow the same convention — compensator on by default, and
## flipping it off (e.g. on a power/systems failure) is what lets the craft
## fall.
##
## Tunable constants below (gravity, air density, drag) are grounded in real
## NASA-sourced reference data — see docs/flight-physics-reference.md for the
## derivations and worked examples.

@export_group("Gravity Compensator")
@export var gravity_compensator_active: bool = true
@export var gravity_accel: float = 800.0  # m/s^2, scaled for the 100x world

@export_group("Rotation")
## Pitch/yaw grounded in real F-16 data: max observed pitch rate ~34°/s,
## sustained turn rate ~17.5°/s at altitude — 0.44 rad/s (~25°/s) sits
## between those. The previous value (1.5 rad/s, ~86°/s, applied uniformly
## to all three axes) was 3-4x faster than even a real fighter jet sustains
## on pitch, which is what made it feel "touchy." See
## docs/flight-physics-reference.md for the sourced figures.
@export var max_pitch_yaw_speed: float = 0.44  # radians/sec (~25°/s)
@export var pitch_yaw_acceleration: float = 1.2  # radians/sec^2
@export var pitch_yaw_damping: float = 1.8  # radians/sec^2 (braking, no stick input)

## Roll is legitimately much faster than pitch/yaw on a real aircraft —
## ailerons roll efficiently, while pitch/yaw are limited by G-tolerance and
## engine/rudder authority. Kept at the original value (not flagged as
## touchy) rather than pushed toward a real fighter's ~240°/s max, partly
## because fast rotation is a common VR-comfort issue independent of
## realism.
@export var max_roll_speed: float = 1.5  # radians/sec (~86°/s)
@export var roll_acceleration: float = 4.0  # radians/sec^2
@export var roll_damping: float = 6.0  # radians/sec^2 (braking, no stick input)

@export_group("Translation")
@export var max_forward_speed: float = 300.0  # m/s
@export var max_reverse_speed: float = 150.0  # m/s
@export var max_vertical_speed: float = 100.0  # m/s
@export var forward_acceleration: float = 500.0  # m/s^2
@export var vertical_acceleration: float = 120.0  # m/s^2
@export var linear_damping: float = 180.0  # m/s^2 (braking, vertical/side axes only)

@export_group("Coasting Drag (forward axis, throttle released)")
## Releasing the throttle no longer snaps to a stop — it coasts down under
## real quadratic air drag (F_drag = 0.5 * air_density * drag_coefficient *
## speed^2), same as an aircraft at 300 m/s through Earth's atmosphere would:
## fast bleed-off up high, a long gentle coast near idle speed.
@export var air_density: float = 1.225  # kg/m^3, Earth sea-level atmosphere
@export var drag_coefficient: float = 0.00015  # combined Cd*frontal_area/(2*mass); tune to taste

@export_group("Input")
@export var stick_deadzone: float = 0.15

## Set by the options menu while it's open, so adjusting settings doesn't
## fight with live flight input.
var paused: bool = false

var _left_controller: XRController3D
var _right_controller: XRController3D
var _origin: Node3D

var _linear_velocity: Vector3 = Vector3.ZERO  # world space
var _angular_velocity: Vector3 = Vector3.ZERO  # local pitch/yaw/roll rates

# Latest raw input values, 0..1 (grips) or -1..1 (stick axes), for other
# systems to react to (e.g. engine_audio.gd) without re-reading controllers.
var right_grip_value: float = 0.0
var left_grip_value: float = 0.0
var roll_input_value: float = 0.0
var vertical_input_value: float = 0.0


func _ready() -> void:
	_origin = get_parent()
	_left_controller = _origin.get_node_or_null("LeftHand")
	_right_controller = _origin.get_node_or_null("RightHand")


func _physics_process(delta: float) -> void:
	if paused:
		return
	if not _left_controller or not _right_controller:
		return
	if not _left_controller.get_is_active() or not _right_controller.get_is_active():
		return

	var right_stick: Vector2 = _apply_deadzone(_right_controller.get_vector2("primary"))
	var left_stick: Vector2 = _apply_deadzone(_left_controller.get_vector2("primary"))
	var right_grip: float = _right_controller.get_float("grip")
	var left_grip: float = _left_controller.get_float("grip")
	right_grip_value = right_grip
	left_grip_value = left_grip

	_update_rotation(right_stick, left_stick, delta)
	_update_translation(right_grip, left_grip, left_stick, delta)

	_origin.rotate_object_local(Vector3.UP, _angular_velocity.y * delta)
	_origin.rotate_object_local(Vector3.RIGHT, _angular_velocity.x * delta)
	_origin.rotate_object_local(Vector3.FORWARD, _angular_velocity.z * delta)
	_origin.global_position += _linear_velocity * delta


func _update_rotation(right_stick: Vector2, left_stick: Vector2, delta: float) -> void:
	var yaw_input := -right_stick.x
	var pitch_input := -right_stick.y
	var roll_input := left_stick.x
	roll_input_value = roll_input

	_angular_velocity.y = _approach_axis(
			_angular_velocity.y, yaw_input, max_pitch_yaw_speed, pitch_yaw_acceleration, pitch_yaw_damping, delta)
	_angular_velocity.x = _approach_axis(
			_angular_velocity.x, pitch_input, max_pitch_yaw_speed, pitch_yaw_acceleration, pitch_yaw_damping, delta)
	_angular_velocity.z = _approach_axis(
			_angular_velocity.z, roll_input, max_roll_speed, roll_acceleration, roll_damping, delta)


func _update_translation(right_grip: float, left_grip: float, left_stick: Vector2, delta: float) -> void:
	var basis := _origin.global_transform.basis
	var forward_input := right_grip - left_grip
	var vertical_input := left_stick.y
	vertical_input_value = vertical_input

	# Work in the craft's local frame so damping pulls velocity to zero along
	# the axes the pilot actually feels, then convert back to world space.
	var local_velocity := basis.inverse() * _linear_velocity

	var forward_max := max_forward_speed if forward_input >= 0.0 else max_reverse_speed
	if absf(forward_input) > 0.0:
		local_velocity.z = move_toward(local_velocity.z, -forward_input * forward_max, forward_acceleration * delta)
	else:
		local_velocity.z = _apply_coasting_drag(local_velocity.z, delta)
	local_velocity.y = _approach_axis(
			local_velocity.y, vertical_input, max_vertical_speed, vertical_acceleration, linear_damping, delta)
	local_velocity.x = _approach_axis(
			local_velocity.x, 0.0, max_vertical_speed, vertical_acceleration, linear_damping, delta)

	_linear_velocity = basis * local_velocity

	if not gravity_compensator_active:
		_linear_velocity.y -= gravity_accel * delta


## Real quadratic air-drag deceleration: a = air_density * drag_coefficient *
## speed^2, opposing whatever direction the craft is currently coasting in.
func _apply_coasting_drag(z_velocity: float, delta: float) -> float:
	var speed := absf(z_velocity)
	if speed < 0.01:
		return 0.0
	var drag_decel := air_density * drag_coefficient * speed * speed
	var new_speed := maxf(0.0, speed - drag_decel * delta)
	return signf(z_velocity) * new_speed


## Drives `current` toward `input * max_value` using `accel`, and brakes it
## back toward zero at a flat `damping` rate whenever there's no input on
## this axis — this pairing is what gives the "flight assist" feel (bounded,
## dampened) rather than true Newtonian drift or instant direct control.
func _approach_axis(current: float, input: float, max_value: float, accel: float, damping: float, delta: float) -> float:
	if absf(input) > 0.0:
		return move_toward(current, input * max_value, accel * delta)
	return move_toward(current, 0.0, damping * delta)


func _apply_deadzone(stick: Vector2) -> Vector2:
	if stick.length() < stick_deadzone:
		return Vector2.ZERO
	return stick


func get_speed() -> float:
	return _linear_velocity.length()


## Zeroes velocity so the ship doesn't keep drifting through the ground
## while frozen after a crash, and doesn't carry speed into a respawn.
func reset_velocity() -> void:
	_linear_velocity = Vector3.ZERO
	_angular_velocity = Vector3.ZERO
