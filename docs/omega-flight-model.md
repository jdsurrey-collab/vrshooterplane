# Omega Flight Model Reference

Where this project's flight *control algorithm* comes from, condensed from
two PDFs the user supplied (`Vrgame/FlightModelJP/`, outside the Godot
project): John Pritchett's `FMDOC3.pdf` ("Flight Motion and Control — X4:
Foundations", describing his "Omega" motion algorithm) and `IFCS3_0.pdf`
(his Star Citizen IFCS design document). Pritchett designed the flight
control systems for both games.

This document is about the *algorithm*. For the real-world-sourced numeric
values it's tuned against (gravity, drag, F-16 pitch/roll rates), see
`docs/flight-physics-reference.md` — that document's numbers are still
current; only the code path that used to consume its drag section has
changed (see "Coasting drag is retired" below).

## The problem: 2nd-order motion

Before this pass, every control axis in this project — the player's
rotation and translation, and the AI's throttle and heading — was driven by
`move_toward(current, goal, accel * delta)`: a flat linear ramp. The moment
input is applied, acceleration jumps instantly from zero to its maximum.
The moment the goal is reached, it jumps back to zero. This is what control
theory calls 2nd-order motion (position is a 2nd-order polynomial of time),
and it assumes **infinite jerk** — jerk being the rate of change of
acceleration.

Both source documents identify this as the thing that makes vehicles feel
wrong: "if we would allow our ships to switch between zero and maximum
acceleration instantaneously, the motion of our ships would be extremely
stiff and unnatural" (`IFCS3_0.pdf`).

## The fix: bounding jerk

Pritchett's Omega algorithm treats acceleration itself as a controlled
quantity that changes smoothly rather than snapping. The simplest form
("Basic Omega") is a critically-damped 2nd-order impulse — front-loaded and
responsive, but continuous. For anything that needs a real sustained
cruising phase (a throttle held down for seconds, not fractions of a
second), Pritchett describes "**Switched Omega**": acceleration ramps
smoothly up to a maximum, **holds** there while velocity climbs, then
ramps smoothly back down as the goal is approached — a trapezoidal
velocity profile with rounded corners instead of square ones. This project
implements the Switched Omega tier, for both the player and every AI ship.

## Two control philosophies, not one

Pritchett's own material (`IFCS3_0.pdf`) draws a real distinction between
pilot input modes that this project's control scheme follows exactly:

> "Acceleration control — Pilot input is interpreted as a percentage of
> maximum available acceleration... Currently, acceleration control is used
> for decoupled mode linear control... Positional and rotational control is
> used for all automated ship control, including AI movement."

**The player's ship is flight-assist OFF, on every single axis, with no
exceptions.** Stick and grip input commands an acceleration directly;
releasing input idles that acceleration back to zero and leaves the ship
coasting at whatever velocity or rotation rate it already had. Nothing
ever auto-brakes the ship back toward a goal — that would be an assist,
and this project doesn't have one. This was a direct, explicit correction
made live, after an early pass reintroduced exactly that ("if I let off
the gas I slow down incredibly fast, this should not be the case" →
"this is flight assist off on all fronts... not flight assistance in any
way").

**The AI's autopilot is goal-seeking**, because it genuinely has concrete
targets (a cruise speed to hold, a heading to turn onto) that a real
autopilot — unlike a human hand on a stick — is always actively trying to
reach. This is not an inconsistency with "the player flies the same ship as
the AI": the *ship* (its max speeds, max accelerations, max rates) is
identical either way, sourced from the same profile; only *how input gets
translated into thrust* differs, exactly as it should between a pilot's
hand and an autopilot.

## This project's implementation

`scripts/omega_motion.gd` (`class_name OmegaMotion`) — three static,
allocation-free functions (each returns a `Vector2`, a value type in
GDScript, so calling these hundreds of times a frame for 200 AI ships costs
no heap allocation):

- **`step_acceleration(value, accel, input, max_accel, accel_time, delta,
  min_value, max_value)`** — **the player's function, used on all 6 axes.**
  `input` (-1..1) directly sets a target acceleration; there is no goal
  velocity anywhere in this function and nothing ever pulls `value` back
  toward zero. `value` is clamped to `[min_value, max_value]` — every ship
  still has an artificial top-speed/rotation-rate governor (IFCS's own
  "Speed Regulation," "strictly enforced" even with everything else
  disabled) — but that clamp only ever engages exactly at the ceiling; it
  never actively decelerates the ship off of it. The only thing "smoothed"
  here is how fast the commanded acceleration itself ramps in and out
  (the jerk limit, via the same framerate-independent exponential lag,
  `1 - exp(-delta / accel_time)`, that `step_velocity` uses on its own
  accel channel below) — not the velocity, ever.
- **`step_velocity(value, accel, goal, max_accel, accel_time, delta)`** —
  **the AI's throttle only.** The goal is directly a velocity. Acceleration
  is smoothed toward a target (±max_accel, or a scaled-down braking value
  once close enough to the goal that continuing at full accel would
  overshoot) via the same exponential lag — the discrete realization of a
  critically-damped Omega impulse applied to the acceleration channel.
- **`step_position(value, rate, goal, max_rate, max_accel, delta)`** —
  **the AI's heading convergence only.** The goal is a *distance* (here,
  always an angle to close to zero), and the function has to invent the
  entire rate profile: ramp up, cruise, brake. Uses the textbook
  trapezoidal-motion-profile cap `allowed_rate = min(max_rate, sqrt(2 *
  max_accel * distance))`, which guarantees the turn can always stop
  exactly on target with zero overshoot. This is Pritchett's
  positional/Double-Switched-Omega case.

All three carry a small persistent state variable (`accel` or `rate`) that
the caller stores and hands back next frame — that stored state is what
actually bounds jerk between calls. Dropping it silently degrades back to
2nd-order motion, so every call site pairs a value with its own accel/rate
field (`flight_controller.gd`'s `_linear_accel`/`_angular_accel`,
`combatant.gd`'s `speed_accel`/`turn_rate`).

## One shared ship, not two separately-tuned ones

`scripts/ship_flight_profile.gd` (`class_name ShipFlightProfile extends
Resource`) — a single `.tres` resource
(`Assets/ShipProfiles/standard_fighter.tres`) holding every performance
number: max speeds, max accelerations, and the new jerk time-constants
(`*_accel_time`). Both `flight_controller.gd` (the player) and
`faction_battle.gd` (every AI combatant) hold an `@export`ed reference to
the *same* resource. This is the direct answer to "my ship should have the
same characteristics as the AI ship" — they are not two approximations of
each other, they are the same numbers run through the same functions.
Retuning the `.tres` retunes the player and the entire 200-ship fleet at
once.

This is also the intended template for the future: a second ship class is
a second `.tres` with different numbers, not a fork of the control code.

**Values** — max speeds/accelerations are carried over unchanged from the
player's previously-tuned, F-16/NASA-grounded numbers (see
`flight-physics-reference.md`); `*_accel_time` values are new and
first-pass, like every other tunable in this project:

| axis | max value | max accel | accel_time |
|---|---|---|---|
| forward | 300 m/s | 500 m/s² | 0.35 s |
| reverse | 150 m/s | 500 m/s² | 0.35 s |
| vertical/lateral | 100 m/s | 120 m/s² | 0.25 s |
| pitch/yaw | 0.44 rad/s (~25°/s) | 1.2 rad/s² | 0.20 s |
| roll | 1.5 rad/s (~86°/s) | 4.0 rad/s² | 0.12 s |

Plus AI-only fields: `ai_turn_max_rate`/`ai_turn_max_accel` (reuse the
pitch/yaw numbers, not roll's — an AI ship re-points its nose
omnidirectionally rather than rolling into a bank, so the more
conservative, real-fighter-grounded limit is the honest one; letting AI
turn at roll speed would make it strictly more maneuverable than the
player flying the identical ship) and `ai_cruise_fraction_min/max` (0.75 /
0.95 of `max_forward_speed`, replacing AI's old flat `140-210 m/s` band —
expressed as a fraction specifically so retuning the ship's top speed
carries the AI's cruise speed with it instead of leaving it stranded at
stale absolute numbers, which is exactly the drift that had already
happened between the player and AI before this pass).

## Coasting drag is retired — twice, in two different directions

`flight_controller.gd` originally bled off speed on throttle release under
a real quadratic air-drag curve (`0.5 * air_density * drag_coefficient *
speed^2`, grounded in the NASA drag equation — see
`flight-physics-reference.md` sections 2-3). That model was realistic *for
an unpowered glider*, but wrong for a thruster-driven spacecraft, so it was
replaced with... an assisted brake to a goal velocity of zero. Direct
playtest feedback immediately caught that this was still an assist, just a
much stronger one (up to `forward_max_accel`, ~30x the old drag's
deceleration at cruise speed) — "if I let off the gas I slow down
incredibly fast."

The actual fix isn't a softer brake, it's **no brake at all**: this is a
flight-assist-off ship (see above), so releasing the throttle now idles
thrust and leaves velocity exactly where it was — real inertia, matching
how the reference material itself frames un-assisted "decoupled mode"
control. `air_density`, `drag_coefficient`, and `_apply_coasting_drag()` no
longer exist in `flight_controller.gd`; `flight-physics-reference.md` keeps
its drag-equation section and NASA sourcing as historical/reference
context only.

The AI is unaffected by any of this — its `_update_throttle()` always drove
straight at a commanded speed via `step_velocity`, which is correct for an
autopilot and was never the thing that needed fixing.

## Deliberately out of scope

- **`missile.gd`** keeps its own simple turn-rate steering
  (`heading.slerp(desired, turn_rate * delta)`). It's a guided munition
  with already-tuned, deliberately-dodgeable game feel
  (`MAX_ENGAGE_ANGLE`'s overshoot/ballistic handoff), not a piloted ship —
  the ask was about ships flying like ships.
- **Motherships** are stationary; no flight model applies.
- **`target_lock.gd`'s PIP intercept math** reads `heading * speed` /
  `get_velocity()` through the existing public API. That shape hasn't
  changed, so it needed no changes and stays correct regardless of how
  heading/speed are computed internally now.

## Verified

Headless (`--headless --script`, this project's only testing surface — see
CLAUDE.md's Testing workflow section):

- `step_velocity`: acceleration ramps in smoothly (no instant jump), holds,
  and brakes to exactly the goal with no overshoot in either direction
  (throttle-up and release-to-zero both checked).
- `step_position`: a hard 150° heading reversal converges to exactly 0
  angle-off with no overshoot, the turn rate visibly ramps up to
  `max_rate` and back down to 0 rather than snapping (peak rate measured
  at 0.44 rad/s, matching the cap exactly).
- Full-scene 100v100 battle, 150 simulated seconds: 96-97 ships alive per
  side (matches the previously-measured mothership-launch baseline
  exactly), real kill attribution throughout, and mean nearest-same-faction
  spacing at 697m — *higher* than the pre-change ~550-620m baseline despite
  the ~50% AI cruise-speed increase, i.e. no clustering regression from the
  faster, harder-turning AI. `BREAK_OFF_RANGE`/`FORMATION_SPACING`/
  `SEPARATION_RADIUS` show no measured need for a follow-up retune at this
  time.

Not yet confirmed live in the headset — the actual *feel* of the new stick
response, throttle spool-up, and AI turn behavior, like every other
first-pass tunable in this project.
