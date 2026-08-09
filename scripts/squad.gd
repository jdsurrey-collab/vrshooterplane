class_name Squad
extends RefCounted

## A flight of 1-5 Combatants (combatant.gd) — the unit of organisation that
## replaced "200 individual ships all independently flying at the same city
## centre", which is what made the battle read as two huge undifferentiated
## clouds converging. Each squad spawns at its OWN point along a wide front,
## flies its OWN objective inside the dome, and fights as a group: members
## hold formation on the leader and focus fire on the leader's target.
##
## Also RefCounted, never a Node — same reasoning as Combatant, and there
## are only ~20-100 of these per faction so they're cheap to update every
## frame without staggering.
##
## MORALE: squads break off when they've taken enough losses (see
## faction_battle.gd's _update_squad), fly away to REGROUP at a rally point,
## then re-enter the fight with `losses` reset. This is the "too many of
## their squad mates die" half of the disengage behaviour; the "if they are
## hurt" half is per-pilot, on Combatant.state.

enum State {
	ADVANCE,  # heading for its objective inside the dome, no fight yet
	ENGAGE,   # at least one member has a live target
	RETREAT,  # broke off after losses — running for the rally point
	REGROUP,  # re-forming at the rally point before advancing again
}

var faction: int = Combatant.Faction.FRIENDLY

## Indices into the owning faction's Combatant array. Fixed at build time —
## membership never changes, dead members just respawn back into the same
## slot (matching how the MultiMesh instance buffer is indexed).
var members: Array[int] = []

## Index (into the faction array, NOT into `members`) of the current leader.
## Reassigned to a living member when the leader dies.
var leader: int = -1

var state: int = State.ADVANCE
var state_timer: float = 0.0

## Deaths since the squad last finished a REGROUP. Drives the morale break.
var losses: int = 0

## Where this squad is currently trying to be — a point inside the dome,
## refreshed when reached. Distinct per squad, which is what spreads the
## fleet across the whole objective area instead of piling onto one point.
var objective: Vector3 = Vector3.ZERO

## Where the squad runs to when it breaks off, and re-forms before
## re-advancing.
var rally_point: Vector3 = Vector3.ZERO

## The squad's own spawn cluster along the faction's front line.
var spawn_center: Vector3 = Vector3.ZERO

## The leader's current target, mirrored here so members can focus fire on
## it instead of each independently chasing whatever is nearest to them.
var focus_target: int = -1
var focus_is_player: bool = false
