class_name CaptureZone
extends RefCounted

## One Battlefield Conquest-style capture point — one per mega tower
## (`CityGenerator.get_mega_tower_positions()`). Direct request: "instead
## of the one dome that we had earlier, we have multiple domes, kind of
## like battlefield games where you have the conquest areas... this could
## be signified by the main big buildings... straight rip from battlefield
## in every regard."
##
## OWNERSHIP IS DERIVED FROM `capture_value`, NEVER TRACKED SEPARATELY —
## a single -100..0..+100 scalar (mirrors the retired air_superiority
## scalar's own range, deliberately, for continuity) is the only source of
## truth, so "what does this zone show" and "who owns it" can never
## disagree with each other.
##
## THE SCALAR DOUBLES AS A CLOCK-HAND SWEEP, direct follow-up request
## after the flat-rate version read as "it just instantly captures when
## somebody gets in that field": `abs(capture_value) / 100.0` is the
## fraction of one full 0->360 degree clockwise sweep, reaching a full
## turn ("twelve o'clock") exactly when a side fully owns the zone. See
## `faction_battle.gd`'s `_update_capture_zones()` / `_update_zone_visual()`
## for the presence-count-driven variable speed and the hand/glow math —
## the reversal-then-recapture behaviour described in the request ("clears
## in the opposite direction... back to neutral and then clockwise again
## in the other color") isn't special-cased anywhere; it falls straight out
## of `move_toward()` chasing whichever faction currently has more ships
## present, the same "let the math produce the behaviour" reasoning the
## original flip-through-neutral rule already used.

## A-F, assigned by index into CityGenerator's tower array — see that
## function's own note on why the ordering has to stay deterministic.
var letter: String = "A"

## World position (the tower's own base XZ, Y irrelevant for capture —
## presence is checked horizontally, matching how a real Conquest flag's
## capture radius doesn't care about altitude within reason).
var position: Vector3 = Vector3.ZERO

## -100.0 (fully enemy-controlled) .. 0.0 (neutral) .. +100.0 (fully
## friendly-controlled). See the class header for the clock-sweep reading
## of this same value.
var capture_value: float = 0.0

const FRIENDLY := 0  # matches Combatant.Faction.FRIENDLY
const ENEMY := 1  # matches Combatant.Faction.ENEMY
const NEUTRAL := -1


## The four world-scale letter markers on this zone's tower (one per
## cardinal side — see faction_battle.gd's _build_zone_letters()). Stored
## here, not just as loose nodes, so _update_zone_visual() can recolour
## exactly this zone's four without a lookup.
var letter_labels: Array[Label3D] = []

## The four clock-hand pivots, same side/order as `letter_labels` — each a
## small `Node3D` sitting just in front of its letter whose local Z
## rotation IS the sweep angle, with the actual hand mesh offset as its
## child (see `_build_zone_letters()`'s own header for why rotating the
## pivot rather than the mesh directly is required to sweep around the
## letter's centre instead of the hand's own midpoint).
var hand_pivots: Array[Node3D] = []

## The hand meshes' own materials, parallel to `hand_pivots` — kept here
## rather than re-fetched every frame so `_update_zone_visual()` can write
## colour/emission directly.
var hand_materials: Array[StandardMaterial3D] = []

## Per-zone pulse-animation clock, randomised at build time so the six
## towers don't all glow in lockstep — the same "don't phase-lock" reason
## already used for the mothership drone layers and thruster-trail start
## offsets elsewhere in this project.
var pulse_phase: float = 0.0

## Faction this zone was last observed to genuinely FLIP TO — distinct
## from `owner_faction()`, which is derived live every frame from
## `capture_value` alone. Used only by `faction_battle.gd`'s
## `_update_capture_zones()` to fire the one-shot "objective captured"
## audio cue exactly once per real capture event (including a zone
## flipping back and forth more than once across a match), never for
## anything visual.
var last_captured_owner: int = NEUTRAL


## Derived, not stored — see the class header for why.
func owner_faction() -> int:
	if capture_value >= 100.0:
		return FRIENDLY
	if capture_value <= -100.0:
		return ENEMY
	return NEUTRAL
