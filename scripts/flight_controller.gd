extends Node

## Inertia-based 6DOF flight controller — **flight assist OFF, on every
## axis, no exceptions.** Stick and grip input commands a target
## ACCELERATION directly (not a velocity, not a goal to return to);
## releasing input idles that acceleration back to zero over a short jerk
## ramp and leaves the ship coasting at whatever velocity/rotation rate it
## already had. Nothing in this script ever auto-brakes the ship back
## toward zero. This was a direct, explicit correction after an earlier
## pass reintroduced auto-braking on throttle release: "this is flight
## assist off on all fronts... not flight assistance in any way."
##
## Right joystick: pitch (Y axis) and yaw (X axis)
## Left joystick:  roll (X axis) and elevation / vertical thrust (Y axis)
## Right grip:     forward thrust
## Left grip:      reverse thrust — a distinct, weaker system from the main
##                  drive, not the same engine run backwards (see
##                  ShipFlightProfile.reverse_thrust_fraction): only ~40% of
##                  forward_max_accel, "not reliable for space braking and
##                  also not incredibly powerful for flying backwards."
## Right A button:  air brake — the ONE deliberate exception to flight-assist
##                  OFF (see below). Holding it overrides every other input
##                  and decelerates all six axes toward zero at
##                  ShipFlightProfile.air_brake_fraction of forward_max_accel.
##
## Attached to a child of the player's XROrigin3D; moves/rotates its parent
## directly each physics frame.
##
## SHARED FLIGHT MODEL, DIFFERENT CONTROL MODE. Every axis runs through
## `OmegaMotion.step_acceleration()` (see scripts/omega_motion.gd and
## docs/omega-flight-model.md) against a `ShipFlightProfile` resource — the
## SAME max-speed/max-accel numbers the 100-200 AI combatants in
## faction_battle.gd fly by, so the player and the AI are still the same
## craft with the same performance envelope. What differs is HOW input maps
## to motion: the AI's own autopilot is goal-seeking (`step_velocity`/
## `step_position` — it always has a concrete target speed or heading to
## hold), while the player's stick is pure acceleration control with no
## goal at all. This split is drawn directly from the user's own reference
## material: "acceleration control is used for decoupled mode linear
## control... positional and rotational control is used for all automated
## ship control, including AI movement" (IFCS3_0.pdf).
##
## What changed from the ORIGINAL (pre-Omega) version, and why it matters:
## every axis used to be driven by `move_toward(current, goal, accel *
## delta)` with a separate flat damping constant for when input was
## released — 2nd-order motion with a hard corner in acceleration at both
## ends, AND an assist that braked the ship back to a stop. Both problems
## are gone: acceleration itself ramps up and down smoothly (the jerk
## limit), and there is no goal to brake toward — only real inertia.
## `docs/flight-physics-reference.md` keeps the old drag-equation section
## as historical/sourcing context; that code path no longer exists.
##
## GRAVITY COMPENSATOR STANDARD — every flight-capable craft on this planet
## is built with drives that actively cancel gravity while powered, so
## dogfighting never has to fight a constant sink rate. This is the
## reference implementation: `gravity_compensator_active` gates whether
## gravity is added to the craft's velocity at all. Any future ship script
## should follow the same convention — compensator on by default, and
## flipping it off (e.g. on a power/systems failure) is what lets the craft
## fall.

## The shared performance definition. Swap this resource to fly a different
## ship class; edit the .tres to retune the player and the entire AI fleet
## together.
@export var profile: ShipFlightProfile = preload("res://Assets/ShipProfiles/standard_fighter.tres")

@export_group("Gravity Compensator")
@export var gravity_compensator_active: bool = true
@export var gravity_accel: float = 800.0  # m/s^2, scaled for the 100x world

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

## The jerk-limiting acceleration state step_acceleration() carries between
## frames (see omega_motion.gd). Discarding these would degrade the whole
## model back to an instant-acceleration snap.
##
## `_linear_accel` is stored in WORLD space, exactly like `_linear_velocity`
## above, and reprojected into the ship's current local frame alongside it
## every frame. That pairing is what preserves the Newtonian flip-and-thrust
## behaviour this project documents: flip the ship 180 degrees mid-drift and
## thrust, and the existing drift is decelerated first — velocity passes
## through zero — before speed builds the new way, with no special-casing,
## because thrust always acts along the ship's CURRENT nose like a real
## engine. Storing acceleration in local space instead would let a rotation
## silently redirect in-progress acceleration, which is not how a rocket
## works.
var _linear_accel: Vector3 = Vector3.ZERO  # world space
var _angular_accel: Vector3 = Vector3.ZERO  # local pitch/yaw/roll

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

	if _right_controller.is_button_pressed("ax_button"):
		# Air brake overrides every other control input entirely — see
		# _apply_air_brake()'s own doc comment for why this is the one
		# deliberate exception to flight-assist OFF.
		_apply_air_brake(delta)
	else:
		_update_rotation(right_stick, left_stick, delta)
		_update_translation(right_grip, left_grip, left_stick, delta)

	_origin.rotate_object_local(Vector3.UP, _angular_velocity.y * delta)
	_origin.rotate_object_local(Vector3.RIGHT, _angular_velocity.x * delta)
	_origin.rotate_object_local(Vector3.FORWARD, _angular_velocity.z * delta)
	_origin.global_position += _linear_velocity * delta


## Stick position commands a rotation ACCELERATION, not a rate — centering
## the stick idles that acceleration to zero and leaves the ship spinning
## at whatever rate it already had (real tumble/spin persistence) until
## countered by opposite stick input. The rate itself is still clamped to
## max_pitch_yaw_speed/max_roll_speed — the artificial governor every ship
## in this game has — but that clamp only ever engages at the ceiling, it
## never pulls the rate back down on its own.
func _update_rotation(right_stick: Vector2, left_stick: Vector2, delta: float) -> void:
	var yaw_input := -right_stick.x
	var pitch_input := -right_stick.y
	var roll_input := left_stick.x
	roll_input_value = roll_input

	var yaw := OmegaMotion.step_acceleration(
			_angular_velocity.y, _angular_accel.y, yaw_input,
			profile.pitch_yaw_max_accel, profile.pitch_yaw_accel_time, delta,
			-profile.max_pitch_yaw_speed, profile.max_pitch_yaw_speed)
	_angular_velocity.y = yaw.x
	_angular_accel.y = yaw.y

	var pitch := OmegaMotion.step_acceleration(
			_angular_velocity.x, _angular_accel.x, pitch_input,
			profile.pitch_yaw_max_accel, profile.pitch_yaw_accel_time, delta,
			-profile.max_pitch_yaw_speed, profile.max_pitch_yaw_speed)
	_angular_velocity.x = pitch.x
	_angular_accel.x = pitch.y

	var roll := OmegaMotion.step_acceleration(
			_angular_velocity.z, _angular_accel.z, roll_input,
			profile.roll_max_accel, profile.roll_accel_time, delta,
			-profile.max_roll_speed, profile.max_roll_speed)
	_angular_velocity.z = roll.x
	_angular_accel.z = roll.y


func _update_translation(right_grip: float, left_grip: float, left_stick: Vector2, delta: float) -> void:
	var basis := _origin.global_transform.basis
	var forward_input := right_grip - left_grip
	var vertical_input := left_stick.y
	vertical_input_value = vertical_input

	# Work in the craft's local frame so thrust acts along the axes the
	# pilot actually feels, then convert straight back to world space.
	# Acceleration is carried through the same round trip as velocity — see
	# _linear_accel's declaration for why that pairing matters.
	var inv := basis.inverse()
	var local_velocity := inv * _linear_velocity
	var local_accel := inv * _linear_accel

	# -Z is forward, so positive forward_input (right grip) needs to drive
	# velocity.z NEGATIVE — same sign convention the old goal-based version
	# used. The speed governor is asymmetric (max_forward_speed vs.
	# max_reverse_speed) — and now so is the acceleration itself: reverse
	# (left grip, forward_input < 0) is scaled down to reverse_thrust_fraction
	# of forward_max_accel, a distinct weaker system from the main drive, not
	# the same engine run backwards. Scaling the INPUT rather than passing a
	# different max_accel keeps this a one-line change at the call site
	# instead of needing a second branch through step_acceleration.
	var reverse_scale := 1.0 if forward_input >= 0.0 else profile.reverse_thrust_fraction
	var forward := OmegaMotion.step_acceleration(
			local_velocity.z, local_accel.z, -forward_input * reverse_scale,
			profile.forward_max_accel, profile.forward_accel_time, delta,
			-profile.max_forward_speed, profile.max_reverse_speed)
	local_velocity.z = forward.x
	local_accel.z = forward.y

	var vertical := OmegaMotion.step_acceleration(
			local_velocity.y, local_accel.y, vertical_input,
			profile.maneuver_max_accel, profile.maneuver_accel_time, delta,
			-profile.max_vertical_speed, profile.max_vertical_speed)
	local_velocity.y = vertical.x
	local_accel.y = vertical.y

	# No lateral input is bound to any control — this axis only ever
	# reflects whatever the world-space velocity vector looks like once
	# reprojected into the ship's new local frame after a turn (real
	# inertia/skid: carrying momentum through a turn, exactly as a
	# flight-assist-off craft should). Input is always 0 here, so this call
	# does nothing but let existing lateral drift persist rather than
	# auto-correcting it — the old goal-of-zero "bleed off drift" behavior
	# was itself an assist, and is gone along with the others.
	var lateral := OmegaMotion.step_acceleration(
			local_velocity.x, local_accel.x, 0.0,
			profile.maneuver_max_accel, profile.maneuver_accel_time, delta,
			-profile.max_lateral_speed, profile.max_lateral_speed)
	local_velocity.x = lateral.x
	local_accel.x = lateral.y

	_linear_velocity = basis * local_velocity
	_linear_accel = basis * local_accel

	if not gravity_compensator_active:
		_linear_velocity.y -= gravity_accel * delta


## The ONE deliberate exception to this ship's flight-assist-OFF rule (see
## this file's header) — a direct, explicit pilot command, not an automatic
## assist that kicks in whenever input is released. While held, this
## replaces _update_rotation()/_update_translation() entirely rather than
## running alongside them, which is what makes it "override any buttons
## that are pushed for movement" — no other input is even read this frame.
##
## Uses Vector3.move_toward() directly rather than OmegaMotion: there's no
## goal-switching/overshoot concern to manage here (the goal is always
## exactly zero, held for as long as the button is), so a flat linear
## approach to zero is both correct and simpler than reusing the jerk-
## limited machinery built for a continuously-changing goal.
##
## Accel state is zeroed every frame this runs, not just left alone —
## releasing the brake should resume normal flight from a clean idle
## engine, not from whatever acceleration happened to be stored the instant
## the brake was pressed.
func _apply_air_brake(delta: float) -> void:
	var linear_decel: float = profile.air_brake_fraction * profile.forward_max_accel
	_linear_velocity = _linear_velocity.move_toward(Vector3.ZERO, linear_decel * delta)
	_linear_accel = Vector3.ZERO

	_angular_velocity.x = move_toward(_angular_velocity.x, 0.0, profile.pitch_yaw_max_accel * delta)
	_angular_velocity.y = move_toward(_angular_velocity.y, 0.0, profile.pitch_yaw_max_accel * delta)
	_angular_velocity.z = move_toward(_angular_velocity.z, 0.0, profile.roll_max_accel * delta)
	_angular_accel = Vector3.ZERO


func _apply_deadzone(stick: Vector2) -> Vector2:
	if stick.length() < stick_deadzone:
		return Vector2.ZERO
	return stick


func get_speed() -> float:
	return _linear_velocity.length()


## World-space velocity vector — the real "where the ship is actually
## headed" direction, as distinct from where its nose points. This is what
## flight_hud.gd's flight-path marker is built on: on a flight-assist-off
## ship, momentum and heading routinely diverge (a turn carries sideways
## drift, see this file's header), so the marker showing true velocity
## direction is meaningfully different information from the boresight.
func get_velocity() -> Vector3:
	return _linear_velocity


## Zeroes velocity so the ship doesn't keep drifting through the ground
## while frozen after a crash, and doesn't carry speed into a respawn.
## Acceleration is cleared too — leaving a stored acceleration behind would
## have the ship spontaneously accelerate itself on the frame after a
## respawn, without any input.
func reset_velocity() -> void:
	_linear_velocity = Vector3.ZERO
	_angular_velocity = Vector3.ZERO
	_linear_accel = Vector3.ZERO
	_angular_accel = Vector3.ZERO
