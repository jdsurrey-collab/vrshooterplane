extends Node3D

## Tiny mid-air spark burst for a non-lethal hit on a ship — the visual that
## tells you a bolt actually connected, as opposed to the big ShipExplosion
## that only fires on a kill.
##
## Deliberately separate from CrashEffects.spawn_laser_impact(): that one is
## built around a scorch crater on a SURFACE, which makes no sense floating
## in the sky where these happen, and it lives for 6 seconds where this
## wants to be gone almost immediately. Kept extremely short-lived and
## budgeted by the caller (faction_battle.gd caps concurrent sparks and only
## spawns them near the player) because at full battle intensity these would
## otherwise be spawning many times a second.

const LIFETIME := 1.2


func _ready() -> void:
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)
