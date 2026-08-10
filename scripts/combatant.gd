class_name Combatant
extends RefCounted

## Lightweight per-ship data record for faction_battle.gd's mass battle —
## deliberately NOT a Node3D+script instance (that's the pattern enemy_ai.gd
## used for the single old enemy, and would mean 200-400x that script/Node
## overhead). One manager iterates an Array[Combatant] in tight loops and
## writes the results into a MultiMesh; nothing here ever enters the scene
## tree on its own.
##
## Ships belong to a Squad (squad.gd) of 1-5 — `squad_id` indexes into its
## own faction's squad array and `squad_slot` is its formation position
## within that squad (slot 0 is the leader). Squad-level orders live on the
## Squad; `state` below is what THIS pilot is doing right now, which can
## legitimately differ from its squad's orders (one hurt pilot breaking off
## while the rest of the squad keeps fighting).

enum Faction { FRIENDLY, ENEMY }

## PARKED — sitting on the mothership's flight deck, waiting for its
##   launch slot. Doesn't move, steer, or shoot.
## LAUNCHING — climbing off the deck. Ignores combat and formation until it
##   has cleared the ship, so takeoffs read as takeoffs.
## FORMATION — holding station on the squad leader (or, if leader, flying
##   the squad's objective).
## PURSUE — actively running in on a target.
## BREAK_OFF — just made a firing pass and is flying through/past the
##   target before turning back, rather than gluing itself to its tail.
##   This is what makes fights read as real dogfight passes.
## RETREAT — disengaging entirely (own damage, or squad losses).
enum State { PARKED, LAUNCHING, FORMATION, PURSUE, BREAK_OFF, RETREAT }

var position: Vector3 = Vector3.ZERO
var heading: Vector3 = Vector3.FORWARD  # normalized, local -Z equivalent
var speed: float = 0.0  # current, throttled around base_speed to hold formation
var base_speed: float = 0.0  # this pilot's natural cruise

## Switched Omega state (see omega_motion.gd / docs/omega-flight-model.md).
## These persist between frames and are what make this ship's acceleration
## and turn rate ramp smoothly instead of snapping — the same flight model
## the player's own ship uses, from the same ShipFlightProfile. Resetting
## them without resetting the values they drive (or vice versa) leaves a
## ship accelerating or turning with no reason to, so _respawn_combatant
## clears both together.
var speed_accel: float = 0.0  # m/s^2, throttle acceleration
var turn_rate: float = 0.0  # rad/s, current heading-convergence rate

## Afterburner, the AI's counterpart to the player's B button. Lit in
## bursts when a pilot has a real reason to surge — running down a target
## or fleeing — never as a permanent state, so a boost still reads as a
## deliberate act rather than a constant. `afterburner_time` counts down
## the current burn; `afterburner_cooldown` gates the next one. Both are
## also what thruster_trails.gd reads to decide who gets a smoke plume.
var afterburner_time: float = 0.0
var afterburner_cooldown: float = 0.0

## True only while a burn is actually running — cheaper for callers than
## re-deriving it from the two timers, and unambiguous about intent.
var afterburner_active: bool = false
var faction: int = Faction.FRIENDLY
var health: float = 30.0
var alive: bool = true
var target_index: int = -1  # index into the opposing faction's array, or -1
var targeting_player: bool = false
var fire_cooldown: float = 0.0
var missile_cooldown: float = 0.0  # aliens only — see faction_battle.gd's alien-fires-missiles-at-player logic
var respawn_time_remaining: float = 0.0
var wander_point: Vector3 = Vector3.ZERO

var squad_id: int = -1
var squad_slot: int = 0

var state: int = State.PARKED
var state_timer: float = 0.0

## Seconds still to wait on the deck before this ship launches. Squads leave
## in waves rather than all at once — see faction_battle.gd's LAUNCH_*
## constants.
var launch_delay: float = 0.0

## Deck altitude this ship launched from, so "have I cleared the ship yet"
## is measured against the deck rather than the terrain thousands of meters
## below it.
var launch_deck_y: float = 0.0

## Set when a NEW target is acquired — the pilot won't open fire until it
## expires. Without it, ships snap onto a target and fire in the same frame
## they first see it, which reads as inhuman.
var reaction_timer: float = 0.0

## 0..1 skill. Scales how far the aim point is randomly displaced from the
## true intercept solution (see faction_battle.gd's _aim_point) — the knob
## that keeps the AI threatening without being unfair.
var accuracy: float = 0.8

## Random unit vector, re-rolled per shot, scaled by (1 - accuracy) and
## range into the actual aim error.
var aim_jitter: Vector3 = Vector3.ZERO

## Last result of the ground-avoidance LOOKAHEAD test. That test costs a
## terrain sample, and faction_battle.gd only re-runs it on a stagger (see
## _needs_pull_up), so the latched result is what's used on the frames in
## between. Terrain elevation along a 3-second flight path doesn't change
## meaningfully frame to frame, so holding the last answer is accurate and
## removes a per-ship-per-frame sample from the hottest loop in the game.
var pull_up_latched: bool = false
