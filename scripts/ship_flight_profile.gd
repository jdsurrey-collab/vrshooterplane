class_name ShipFlightProfile
extends Resource

## The performance definition for one class of ship — the single shared set
## of numbers that BOTH the player (flight_controller.gd) and every AI
## combatant (faction_battle.gd) fly by, so the player genuinely flies the
## same craft the AI does rather than two separately-tuned approximations of
## each other.
##
## This is deliberately a Resource, not a pile of constants: today there is
## exactly one of these (ship_profiles/standard_fighter.tres, the standard
## fighter every ship in the game currently is), and a future ship variant
## is a second .tres with different numbers and zero code changes. That is
## the intended growth path — one canonical profile now, per-ship-type
## variants later.
##
## GOAL-BASED TUNING. Every value here is a PERFORMANCE GOAL ("this ship
## reaches 300 m/s", "it takes about a third of a second to lean into full
## thrust"), not an engine-internal quantity like a thruster capacity or a
## jerk in units/s^3. That's taken directly from the source material's ship
## tuning section: designers should describe how they want a ship to
## PERFORM and let the control system work out how to deliver it. See
## docs/omega-flight-model.md.
##
## The max speeds and max accelerations below are carried over unchanged
## from flight_controller.gd's previously-tuned values, which are grounded
## in real F-16 / NASA figures — see docs/flight-physics-reference.md for
## those derivations. The `*_accel_time` values are new (jerk limits, which
## the old 2nd-order model had no concept of) and are first-pass.

@export_group("Forward / reverse")
@export var max_forward_speed: float = 300.0  # m/s
@export var max_reverse_speed: float = 150.0  # m/s
@export var forward_max_accel: float = 500.0  # m/s^2
## Jerk limit as a time constant: roughly how long thrust takes to lean into
## its maximum — used symmetrically for both winding thrust UP under input
## and winding it back down to idle when input is released. There is no
## separate "coast" braking constant: this ship is flight-assist OFF (see
## flight_controller.gd), so releasing input idles the engine rather than
## commanding a return to zero velocity. What used to be here (a softer
## braking accel for the coast case) was still an assist — actively
## fighting the ship's own momentum — which is exactly what got corrected
## after direct playtest feedback.
@export var forward_accel_time: float = 0.35  # seconds

## Reverse thrust is a distinct, weaker system from the main drive, not
## the same engine run backwards — direct instruction: "reverse is going
## to be different than braking... left squeeze should only have about
## 40% of the power that full thrust has... not reliable for space
## braking and also not incredibly powerful for flying backwards."
## flight_controller.gd scales the commanded acceleration by this fraction
## whenever the LEFT grip (reverse) is what's driving the forward axis —
## the right grip (forward) always gets the full forward_max_accel.
@export var reverse_thrust_fraction: float = 0.4

@export_group("Vertical / lateral (maneuvering thrusters)")
@export var max_vertical_speed: float = 100.0  # m/s
@export var max_lateral_speed: float = 100.0  # m/s
@export var maneuver_max_accel: float = 120.0  # m/s^2
@export var maneuver_accel_time: float = 0.25  # seconds

@export_group("Pitch")
## ~25 deg/s, between the F-16's sustained (17.5) and peak (34) pitch rate.
## This is the NOSE-UP figure; nose-down is a fraction of it, see below.
@export var max_pitch_speed: float = 0.44  # rad/s
@export var pitch_max_accel: float = 1.2  # rad/s^2
@export var pitch_accel_time: float = 0.20  # seconds

## Real, source-grounded asymmetry, toned down to a stylistic level rather
## than applied at the literal real-world ratio. IFCS3_0.pdf documents a
## real subsystem, "G-force Safety" — thruster output limited by pilot
## g-tolerance — and real g-tolerance genuinely is asymmetric: a trained
## pilot sustains roughly +9G pulling a nose up (blood pools toward the
## feet) but only about -3G pushing a nose over (blood rushes to the head,
## tolerated far less before redout/injury) — a real ~3:1 ratio. NOT
## "air friction," which doesn't apply here at all: this ship is a pure
## RCS-thruster craft with an always-active gravity compensator (see
## flight_controller.gd), and IFCS3_0.pdf's own atmospheric-flight section
## is explicit that these ships "do not use aerodynamic forces to achieve
## flight." The full 3:1 ratio would read as extreme stacked on top of this
## game's already-arcade acceleration scale (forward thrust alone is
## already ~51G-equivalent), so this lands at 70% instead — a real,
## felt asymmetry without being punishing.
@export var pitch_down_fraction: float = 0.7

@export_group("Yaw")
## Split out from pitch after direct feedback that the two "felt
## identical" and shouldn't — pitch and yaw sharing one number was
## inherited from this project's original pre-Omega flight code, never a
## deliberate realism choice. Real fighters have distinctly weaker yaw
## authority than pitch (rudder-limited, and pitch is the primary combat
## axis, not yaw), so yaw is cut to roughly 65% of pitch's rate and accel
## here — a first-pass ratio, easy to retune further.
@export var max_yaw_speed: float = 0.29  # rad/s (~65% of pitch)
@export var yaw_max_accel: float = 0.8  # rad/s^2 (~65% of pitch)
@export var yaw_accel_time: float = 0.20  # seconds

@export_group("Roll")
## ~86 deg/s. Deliberately well below a real fighter's ~240 deg/s: fast
## rotation is a VR comfort issue independent of realism, and this rate was
## never reported as feeling wrong.
@export var max_roll_speed: float = 1.5  # rad/s
@export var roll_max_accel: float = 4.0  # rad/s^2
## Shortest of the three — ailerons are aerodynamically cheap and roll has
## the least inertia, so it should feel the most immediate.
@export var roll_accel_time: float = 0.12  # seconds

@export_group("Air brake")
## The ONE deliberate exception to this ship's flight-assist-OFF rule (see
## flight_controller.gd) — a direct, explicit pilot command, not an
## automatic assist that kicks in whenever input is released. Holding the
## air brake button overrides every other control input and decelerates
## every axis toward zero — forward/reverse, vertical, lateral, pitch,
## yaw, AND roll — at this fraction of forward_max_accel. "Air braking is
## the equivalent of sixty percent of the forward thrust in break to
## zero... completely stop every axis from moving and override any
## buttons that are pushed for movement," per direct instruction.
@export var air_brake_fraction: float = 0.6

@export_group("AI-only")
## Heading convergence for AI ships, which re-point their nose
## omnidirectionally toward a steering target rather than rolling into a
## turn the way a player does. Matches PITCH's figures (not yaw's weaker
## ones, and not roll's faster ones) — pitch is the honest, real-fighter-
## grounded limit on how fast a nose can be brought around in the plane
## that matters most for combat maneuvering, and it's independent of these
## exports so retuning pitch or yaw for the player doesn't silently retune
## every AI ship's turn rate too.
@export var ai_turn_max_rate: float = 0.44  # rad/s
@export var ai_turn_max_accel: float = 1.2  # rad/s^2

## AI cruise speed as a fraction of max_forward_speed, rolled per pilot so a
## formation isn't uniform. Expressed as a fraction rather than absolute m/s
## so retuning the ship's top speed carries the whole fleet with it instead
## of silently leaving the AI behind at old absolute numbers — which is
## exactly the drift this profile exists to prevent.
@export var ai_cruise_fraction_min: float = 0.75
@export var ai_cruise_fraction_max: float = 0.95
