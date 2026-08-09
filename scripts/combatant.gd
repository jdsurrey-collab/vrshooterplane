class_name Combatant
extends RefCounted

## Lightweight per-ship data record for faction_battle.gd's 400-combatant
## battle — deliberately NOT a Node3D+script instance (that's the pattern
## enemy_ai.gd used for the single old enemy, and would mean 400x that
## script/Node overhead). One manager iterates an Array[Combatant] in tight
## loops and writes the results into a MultiMesh; nothing here ever enters
## the scene tree on its own.

enum Faction { FRIENDLY, ENEMY }

var position: Vector3 = Vector3.ZERO
var heading: Vector3 = Vector3.FORWARD  # normalized, local -Z equivalent
var speed: float = 0.0
var faction: int = Faction.FRIENDLY
var health: float = 30.0
var alive: bool = true
var target_index: int = -1  # index into the opposing faction's array, or -1
var targeting_player: bool = false
var fire_cooldown: float = 0.0
var respawn_time_remaining: float = 0.0
var wander_point: Vector3 = Vector3.ZERO
