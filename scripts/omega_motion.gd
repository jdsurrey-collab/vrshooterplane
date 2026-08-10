class_name OmegaMotion
extends RefCounted

## Shared motion controller for every piloted craft in this game — the
## player's ship (flight_controller.gd) and all 100-200 AI combatants
## (faction_battle.gd) draw from these same functions and the same
## ShipFlightProfile numbers, so "the player flies the same ship as the AI"
## is true in code, not just visually.
##
## Two DIFFERENT control philosophies live here, matching a real
## distinction the user's own reference material (IFCS3_0.pdf) draws
## between pilot input modes:
##
##  * step_acceleration() — "acceleration control" / decoupled/flight-assist
##    OFF: input directly commands an acceleration, jerk-smoothed, with NO
##    automatic return to any goal. Releasing input idles the thrust and
##    leaves the ship coasting at whatever velocity/rate it already had —
##    true inertia. This is what the PLAYER's ship uses, on every axis, no
##    exceptions: "this is flight assist off on all fronts... not flight
##    assistance in any way," per direct instruction after an earlier pass
##    accidentally reintroduced auto-braking on throttle release.
##  * step_velocity() / step_position() — goal-seeking control, used ONLY by
##    the AI's own autopilot (a squad ordering a wingman to hold a cruise
##    speed, or steering toward a heading is inherently "be at this value,"
##    not player stick input). This distinction is explicit in the source
##    material too: "acceleration control is used for decoupled mode linear
##    control... positional and rotational control is used for all
##    automated ship control, including AI movement." The AI has no
##    "pilot input" to leave decoupled from anything — it always has a
##    concrete target it's trying to reach.
##
## Modelled on John Pritchett's "Switched Omega" (see
## docs/omega-flight-model.md for the full write-up and the two source
## PDFs). The short version of why this exists at all:
##
## What this project used to do on every axis was `move_toward(current,
## goal, accel * delta)` — a 2nd-order/quadratic-polynomial motion model.
## That assumes acceleration can change INSTANTANEOUSLY: the instant you
## touch the stick, the craft snaps from 0 to full acceleration, and the
## instant you reach the goal it snaps back to 0. Infinite jerk (jerk = the
## rate of change of acceleration). It's cheap and stable, and it is exactly
## what both source documents identify as the thing that makes game craft
## feel "extremely stiff and unnatural".
##
## Switched Omega bounds jerk instead: acceleration itself is a controlled
## value that ramps smoothly up to a maximum, HOLDS there while velocity
## climbs linearly, then ramps smoothly back down as the goal is
## approached. Pritchett's key point is that this is achievable at roughly
## 2nd-order cost — which is what makes it affordable to run for 200 ships
## every physics frame here.
##
## BOTH functions are static and return a Vector2 rather than mutating
## anything or allocating: Vector2 is a value type in GDScript, so there is
## no heap allocation and no garbage per call. At 200 ships x several axes x
## 60Hz, returning a small object or an Array instead would be real churn in
## the hottest loop in the game — the same reasoning already documented for
## why faction_battle.gd walks its spatial grid inline.


## ACCELERATION CONTROL — pure inertia, flight-assist OFF. Input directly
## commands a TARGET ACCELERATION (`input` is a -1..1 fraction of
## `max_accel`), jerk-smoothed via the same exponential lag step_velocity
## uses on its accel channel — so a tapped stick still ramps in smoothly
## rather than snapping, which is the one and only thing being "assisted"
## here. There is no goal velocity anywhere in this function and nothing
## ever drives `value` back toward zero. Centering the stick sends
## `input = 0.0`, which idles the acceleration back to zero over
## `accel_time` — the engine spools down, but whatever velocity the ship
## already had is left completely alone. `value` is still clamped to
## [min_value, max_value] (this project's ships all have an artificial
## top-speed/rotation-rate governor, same as IFCS's own "Speed Regulation" —
## "strictly enforced" even with everything else disabled — but that
## clamp only ever engages AT the cap, it never actively decelerates the
## ship back down off of it).
##
## This is what the player's ship uses on every one of its 6 axes. The AI
## never calls this — an autopilot always has a concrete target speed/rate
## it's trying to hold, which is what step_velocity/step_position are for.
static func step_acceleration(value: float, accel: float, input: float,
		max_accel: float, accel_time: float, delta: float,
		min_value: float, max_value: float) -> Vector2:
	var target_accel := clampf(input, -1.0, 1.0) * max_accel

	var blend: float = 1.0 - exp(-delta / maxf(accel_time, 0.0001))
	var new_accel: float = accel + (target_accel - accel) * blend
	var new_value: float = clampf(value + new_accel * delta, min_value, max_value)

	return Vector2(new_value, new_accel)


## VELOCITY CONTROL — drives `value` toward a goal VELOCITY (or angular
## rate), with a bounded, smoothly-ramped acceleration between them.
##
## Used by the AI's own autopilot (throttle-to-cruise-speed); NOT used by
## the player — see step_acceleration() above and this file's header.
##
## Returns Vector2(new_value, new_accel) — `accel` is persistent state the
## caller must store and hand back next frame. That stored acceleration is
## the whole point: it's what carries the ramp between frames and makes jerk
## finite. A caller that discards it degenerates back to 2nd-order motion.
##
##  * `max_accel`  — the acceleration ceiling, i.e. the cruising accel of
##                   the "hold" phase.
##  * `accel_time` — roughly how long acceleration takes to reach that
##                   ceiling. This is the jerk limit, expressed as a time
##                   constant rather than a raw units/s^3 figure because a
##                   time is what a designer can actually reason about
##                   ("this ship takes a third of a second to lean into
##                   full thrust"). Smaller = snappier/stiffer, larger =
##                   heavier/smoother. Pritchett's tuning section describes
##                   this same range as running from "a formula one racer"
##                   to "a luxury sedan".
static func step_velocity(value: float, accel: float, goal: float,
		max_accel: float, accel_time: float, delta: float) -> Vector2:
	var error := goal - value
	if is_zero_approx(error) and is_zero_approx(accel):
		return Vector2(goal, 0.0)

	# THE "SWITCH". How much further this axis would still coast if it began
	# easing acceleration off toward zero RIGHT NOW. Under the exponential
	# lag used below, acceleration decays with time constant `accel_time`,
	# so the remaining change is exactly its integral: accel * accel_time.
	#
	# While the remaining error is larger than that, run at full
	# acceleration (the ramp-up and hold phases); once it isn't, switch to
	# braking, so the value arrives at the goal with acceleration already
	# back at zero rather than slamming into it. This switch is what
	# separates Switched Omega from plain Omega — plain Omega's impulse
	# peaks early and decays with no sustained cruise phase at all, which
	# Pritchett notes is wrong for anything but very short movements.
	var brake_distance := accel * accel_time

	var target_accel: float
	if absf(error) > absf(brake_distance) or signf(error) != signf(accel):
		target_accel = signf(error) * max_accel
	else:
		# Braking: aim acceleration at whatever value would bleed the
		# remaining error out over roughly `accel_time`, clamped so it can
		# never exceed the ship's real capability.
		target_accel = clampf(error / maxf(accel_time, 0.0001), -max_accel, max_accel)

	# Exponential lag toward the target acceleration. Framerate-independent
	# (an explicit exp() rather than a raw `lerp(a, b, k * delta)`, which
	# changes behaviour with frame time), and smooth in every higher-order
	# derivative — this is the discrete realization of the critically-damped
	# Omega impulse applied to the acceleration channel.
	var blend: float = 1.0 - exp(-delta / maxf(accel_time, 0.0001))
	var new_accel: float = accel + (target_accel - accel) * blend
	var new_value: float = value + new_accel * delta

	# Stability guard: if this frame would carry the value PAST the goal,
	# land exactly on it and dump the residual acceleration instead of
	# oscillating around it. Pritchett's own document is explicit that a
	# small snap is acceptable "unless they are near enough to the final
	# value that this snap is imperceptible" — this is that case, one frame
	# of travel from the goal.
	if signf(goal - new_value) != signf(error) and not is_zero_approx(error):
		return Vector2(goal, 0.0)

	return Vector2(new_value, new_accel)


## POSITIONAL CONTROL — drives `value` (a remaining DISTANCE-to-goal) to
## `goal` (normally 0.0) through a bounded rate, ramping that rate up to a
## cruise maximum and braking it back down so it arrives with zero
## overshoot.
##
## The difference from step_velocity is what's being commanded: there, the
## input was already a goal velocity. Here the caller only knows "I am this
## far from where I want to be" and needs the controller to invent the whole
## velocity profile — ramp up, cruise, brake — which is Pritchett's
## positional/Double-Switched-Omega case.
##
## Used by AI combatants for heading convergence: `value` is the angle in
## radians between the ship's current heading and its desired heading, and
## the returned rate is the angular speed to actually rotate at this frame.
## The player never needs this (their stick input is a direct rate command,
## which is step_velocity's job) — but every AI ship is continuously
## "rotate to face that point", which is exactly a positional problem.
##
## Returns Vector2(new_value, new_rate); `rate` is persistent state the
## caller must store, same as `accel` above.
static func step_position(value: float, rate: float, goal: float,
		max_rate: float, max_accel: float, delta: float) -> Vector2:
	var error := goal - value
	if is_zero_approx(error) and is_zero_approx(rate):
		return Vector2(goal, 0.0)

	# The braking curve. sqrt(2 * a * d) is the exact speed from which a
	# constant deceleration `a` comes to rest in remaining distance `d` —
	# so capping the rate by it guarantees the turn can always be stopped
	# precisely on the target heading rather than swinging past and
	# hunting back. Below that cap the ship simply cruises at max_rate.
	var distance := absf(error)
	var allowed_rate: float = minf(max_rate, sqrt(2.0 * maxf(max_accel, 0.0001) * distance))
	var target_rate := signf(error) * allowed_rate

	# Rate is still approached through a bounded acceleration rather than
	# jumping to `target_rate` — without this the ramp-UP would be
	# instantaneous (infinite jerk) even though the ramp-DOWN was smooth,
	# which is the asymmetric-jerk case Pritchett describes as desirable
	# only when deliberately tuned, not as an accident.
	var new_rate: float = move_toward(rate, target_rate, max_accel * delta)
	var new_value: float = value + new_rate * delta

	if signf(goal - new_value) != signf(error) and not is_zero_approx(error):
		return Vector2(goal, 0.0)

	return Vector2(new_value, new_rate)
