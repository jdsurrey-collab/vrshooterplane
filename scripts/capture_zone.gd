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
## disagree with each other. See faction_battle.gd's
## `_update_capture_zones()` for the actual capture rules (presence-based,
## contested freezes, must drain to neutral before flipping — the real
## Conquest behaviour, not an approximation of it).

## A-F, assigned by index into CityGenerator's tower array — see that
## function's own note on why the ordering has to stay deterministic.
var letter: String = "A"

## World position (the tower's own base XZ, Y irrelevant for capture —
## presence is checked horizontally, matching how a real Conquest flag's
## capture radius doesn't care about altitude within reason).
var position: Vector3 = Vector3.ZERO

## -100.0 (fully enemy-controlled) .. 0.0 (neutral) .. +100.0 (fully
## friendly-controlled).
var capture_value: float = 0.0

const FRIENDLY := 0  # matches Combatant.Faction.FRIENDLY
const ENEMY := 1  # matches Combatant.Faction.ENEMY
const NEUTRAL := -1

## The four world-scale letter markers on this zone's tower (one per
## cardinal side — see faction_battle.gd's _build_zone_letters()). Stored
## here, not just as loose nodes, so _update_zone_letters() can recolour
## exactly this zone's four without a lookup.
var letter_labels: Array[Label3D] = []

## Last colour actually written to `letter_labels`, so the per-frame
## update can skip re-touching four Label3D materials on every zone when
## nothing has changed (most zones sit stable most of a match).
var _last_owner_written: int = -999


## Derived, not stored — see the class header for why.
func owner_faction() -> int:
	if capture_value >= 100.0:
		return FRIENDLY
	if capture_value <= -100.0:
		return ENEMY
	return NEUTRAL
