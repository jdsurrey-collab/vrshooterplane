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
## Right B button:   afterburner — hold to raise the forward speed ceiling by
##                  ShipFlightProfile.afterburner_speed_bonus (200 m/s) for as
##                  long as fuel lasts (afterburner_max_duration, 10s),
##                  recharging over afterburner_recharge_time while not held.
##                  Does NOT auto-thrust — the pilot still has to hold the
##                  right grip to use the extra headroom, same flight-assist-
##                  OFF philosophy as everything else here.
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

@export_group("Afterburner trail")
## The player's own boost plume (scenes/ThrusterTrail.tscn, instanced under
## Ship so it sits at the exhaust). Emits ONLY while the afterburner is
## lit — not on ordinary throttle. An earlier version ran it off the main
## drive's grip, which meant a permanent smoke stack any time you were
## flying at all; the trail is meant to mark a boost, so it's tied to the
## same `afterburner_active` the B button drives. Its particles are
## world-space (`local_coords = false`), so the trail stays where it was
## laid down instead of dragging along behind the ship.
@export var thruster_trail_path: NodePath = ^"../Ship/ThrusterTrail"

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
## `_linear_accel` is stored in the ship's own LOCAL/BODY frame, unlike
## `_linear_velocity` (world space) — and that difference is the whole
## point, not an inconsistency. Velocity is momentum: conserved in world
## space, so turning the ship must NOT change it. Acceleration is engine
## thrust: body-fixed, pointing wherever the nose currently points, so it
## must turn WITH the ship. An earlier version stored acceleration in world
## space and reprojected it every frame alongside velocity, which meant a
## turn dragged the previous frame's thrust direction along into the new
## local frame — measured as a real bug, since that stale reprojected
## acceleration then tripped the speed governor on whatever axis it landed
## on and deleted genuine momentum. Only the ENGINE SPOOL state (how far
## thrust has ramped up on each body axis) persists here; the direction is
## always the ship's current one.
var _linear_accel: Vector3 = Vector3.ZERO  # LOCAL/body space — see above
var _angular_accel: Vector3 = Vector3.ZERO  # local pitch/yaw/roll

# Latest raw input values, 0..1 (grips) or -1..1 (stick axes), for other
# systems to react to (e.g. engine_audio.gd) without re-reading controllers.
var right_grip_value: float = 0.0
var left_grip_value: float = 0.0
var roll_input_value: float = 0.0
var vertical_input_value: float = 0.0

## Afterburner fuel, in seconds remaining (0..profile.afterburner_max_duration).
## Starts full. See _update_afterburner() and this file's header.
var _afterburner_fuel: float = 0.0
var afterburner_active: bool = false  # readable by engine_audio.gd/flight_hud.gd

var _thruster_trail: GPUParticles3D


func _ready() -> void:
	_origin = get_parent()
	_left_controller = _origin.get_node_or_null("LeftHand")
	_right_controller = _origin.get_node_or_null("RightHand")
	_afterburner_fuel = profile.afterburner_max_duration
	_thruster_trail = get_node_or_null(thruster_trail_path) as GPUParticles3D


func _physics_process(delta: float) -> void:
	# Every early-out below has to stop the plume, not just skip the flight
	# update — otherwise the trail keeps smoking off a frozen ship through
	# the menu, the crash sequence and the death screen, since `emitting`
	# is sticky state rather than something re-evaluated per frame.
	if paused or not _left_controller or not _right_controller \
			or not _left_controller.get_is_active() or not _right_controller.get_is_active():
		if _thruster_trail:
			_thruster_trail.emitting = false
		return

	var right_stick: Vector2 = _apply_deadzone(_right_controller.get_vector2("primary"))
	var left_stick: Vector2 = _apply_deadzone(_left_controller.get_vector2("primary"))
	var right_grip: float = _right_controller.get_float("grip")
	var left_grip: float = _left_controller.get_float("grip")
	right_grip_value = right_grip
	left_grip_value = left_grip

	_update_afterburner(delta)

	# Plume marks the AFTERBURNER, nothing else — not ordinary throttle,
	# not reverse, not the air brake. `_update_afterburner()` above has
	# already resolved whether the burner is lit this frame (button held
	# AND fuel remaining), so this is just mirroring that one flag.
	if _thruster_trail:
		_thruster_trail.emitting = afterburner_active

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


## ROTATION IS VELOCITY CONTROL, not acceleration control — the stick
## commands a rotation RATE, and centering it brings that rate back to
## zero. This is NOT a contradiction of the flight-assist-OFF rule that
## governs translation; it is exactly what the source material specifies
## for both modes:
##
##   "velocity control is used for coupled and decoupled rotational
##    control" — IFCS3_0.pdf
##
## Only LINEAR control is decoupled ("acceleration control is used for
## decoupled mode linear control"). Physically this is the ship's reaction
## control system holding attitude — the same RCS that IFCS3_0.pdf
## describes as providing "3-axis stabilization of the ship's attitude."
##
## THIS WAS A REAL BUG. An earlier version ran rotation through
## step_acceleration alongside translation, so releasing the stick left
## the ship rotating forever at whatever rate it had. That made the flight
## path marker impossible to converge — the nose kept drifting away from
## the velocity vector faster than drag could pull velocity onto the nose —
## reported as "I can never get it back into that position no matter how
## straight I'm going and how much I boost."
##
## Pitch and yaw are deliberately SEPARATE tunables (not shared, as they
## used to be) — see ship_flight_profile.gd's "Yaw" group for why.
func _update_rotation(right_stick: Vector2, left_stick: Vector2, delta: float) -> void:
	var yaw_input := -right_stick.x
	var pitch_input := -right_stick.y
	var roll_input := left_stick.x
	roll_input_value = roll_input

	var yaw := OmegaMotion.step_velocity(
			_angular_velocity.y, _angular_accel.y, yaw_input * profile.max_yaw_speed,
			profile.yaw_max_accel, profile.yaw_accel_time, delta)
	_angular_velocity.y = yaw.x
	_angular_accel.y = yaw.y

	# Positive pitch_input is nose-UP (pulling back); negative is nose-DOWN
	# (pushing over). Nose-down authority is scaled down to
	# pitch_down_fraction — see ship_flight_profile.gd's "Pitch" group for
	# the real G-force-tolerance grounding.
	var pitch_ceiling := profile.max_pitch_speed
	if pitch_input < 0.0:
		pitch_ceiling *= profile.pitch_down_fraction
	var pitch := OmegaMotion.step_velocity(
			_angular_velocity.x, _angular_accel.x, pitch_input * pitch_ceiling,
			profile.pitch_max_accel, profile.pitch_accel_time, delta)
	_angular_velocity.x = pitch.x
	_angular_accel.x = pitch.y

	var roll := OmegaMotion.step_velocity(
			_angular_velocity.z, _angular_accel.z, roll_input * profile.max_roll_speed,
			profile.roll_max_accel, profile.roll_accel_time, delta)
	_angular_velocity.z = roll.x
	_angular_accel.z = roll.y


## Drains/recharges afterburner fuel and sets `afterburner_active` — the
## actual speed-ceiling bump is applied in _update_translation(). Runs
## unconditionally (even under air brake) since it's a resource meter, not
## a movement input; holding both simultaneously just drains fuel for no
## effect, not worth special-casing.
func _update_afterburner(delta: float) -> void:
	var held := _right_controller.is_button_pressed("by_button")
	if held and _afterburner_fuel > 0.0:
		afterburner_active = true
		_afterburner_fuel = maxf(0.0, _afterburner_fuel - delta)
	else:
		afterburner_active = false
		var recharge_rate := profile.afterburner_max_duration / maxf(profile.afterburner_recharge_time, 0.001)
		_afterburner_fuel = minf(profile.afterburner_max_duration, _afterburner_fuel + recharge_rate * delta)


## 0..1 remaining fuel fraction, for flight_hud.gd's gauge.
func get_afterburner_fuel_fraction() -> float:
	return _afterburner_fuel / maxf(profile.afterburner_max_duration, 0.001)


func _update_translation(right_grip: float, left_grip: float, left_stick: Vector2, delta: float) -> void:
	var basis := _origin.global_transform.basis
	var forward_input := right_grip - left_grip
	var vertical_input := left_stick.y
	vertical_input_value = vertical_input

	# VELOCITY is reprojected from world space into the ship's current local
	# frame (momentum is conserved in world space, so turning must not
	# change it — this reprojection is exactly what carries drift/skid
	# through a turn). ACCELERATION is NOT reprojected: it's already stored
	# body-fixed, because engine thrust points wherever the nose currently
	# points. See _linear_accel's declaration for the bug that caused.
	var inv := basis.inverse()
	var local_velocity := inv * _linear_velocity
	var local_accel := _linear_accel

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
	# Afterburner raises the forward CEILING only — it doesn't touch reverse,
	# and it doesn't auto-thrust; the pilot still has to be holding the
	# right grip to actually reach the extra headroom. See
	# _update_afterburner() and this file's header.
	var forward_ceiling := profile.max_forward_speed
	if afterburner_active:
		forward_ceiling += profile.afterburner_speed_bonus
	var forward := OmegaMotion.step_acceleration(
			local_velocity.z, local_accel.z, -forward_input * reverse_scale,
			profile.forward_max_accel, profile.forward_accel_time, delta,
			-forward_ceiling, profile.max_reverse_speed)
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

	local_velocity = _apply_axis_drag(local_velocity, delta)

	_linear_velocity = basis * local_velocity
	_linear_accel = local_accel  # already body-fixed, see _linear_accel's declaration

	if not gravity_compensator_active:
		_linear_velocity.y -= gravity_accel * delta


## Per-axis quadratic aerodynamic drag, applied in the ship's LOCAL frame so
## each axis uses its own coefficient — straight from IFCS3_0.pdf: "Each
## ship is tuned with a separate coefficient for each axial direction to
## indicate its relative performance when moving along each axial direction
## through atmosphere."
##
## This is the airframe's own shape doing the work, NOT an assist: a fighter
## is streamlined nose-on and barn-door broadside, so sideways/vertical
## drift bleeds off ~40x faster than forward speed does. That asymmetry is
## what makes a decoupled ship's velocity naturally settle onto its nose a
## few seconds after you turn and thrust — the behaviour that was reported
## missing. Without it, pure vacuum physics leaves the ship permanently
## diagonal (measured: locked at a 45-degree offset forever, since forward
## thrust only ever ADDS a forward component, it never removes the sideways
## one).
##
## Deceleration always opposes motion and can never reverse it (the
## move_toward floor at zero), so this bleeds drift off without ever
## becoming a spring that pulls the ship backwards.
func _apply_axis_drag(local_velocity: Vector3, delta: float) -> Vector3:
	local_velocity.x = _drag_axis(
			local_velocity.x, profile.drag_coefficient_lateral, profile.drag_linear_lateral, delta)
	local_velocity.y = _drag_axis(
			local_velocity.y, profile.drag_coefficient_vertical, profile.drag_linear_vertical, delta)
	local_velocity.z = _drag_axis(
			local_velocity.z, profile.drag_coefficient_forward, profile.drag_linear_forward, delta)
	return local_velocity


## Combined linear + quadratic drag: decel = linear*|v| + quadratic*v^2.
## Real drag is a sum of both, and here the linear term is load-bearing —
## the quadratic one alone fades as speed^2 and leaves drift asymptotically
## crawling toward zero instead of actually reaching it. See
## ship_flight_profile.gd's drag_linear_* for why forward's linear term is
## zero.
func _drag_axis(v: float, quadratic: float, linear: float, delta: float) -> float:
	if is_zero_approx(v):
		return v
	var speed := absf(v)
	var decel := quadratic * speed * speed + linear * speed
	if decel <= 0.0:
		return v
	return move_toward(v, 0.0, decel * delta)


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

	_angular_velocity.x = move_toward(_angular_velocity.x, 0.0, profile.pitch_max_accel * delta)
	_angular_velocity.y = move_toward(_angular_velocity.y, 0.0, profile.yaw_max_accel * delta)
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
