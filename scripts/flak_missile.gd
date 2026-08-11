extends Node3D

## Purely cosmetic "SAM" launch — part of ground_flak.gd's warzone-ambience
## system (see that script's header). Reuses missile.gd's visual language
## (the same body/exhaust mesh style, the same MissileTrail smoke) but
## carries NONE of its homing/damage/flare logic: no target, no damage, no
## collision check against anything. It exists purely to be seen — the city
## throwing big ballistic missiles up out of the skyline for the spectacle of
## it — then self-destructs after `lifetime`.
##
## IT FLIES A STRAIGHT BALLISTIC LINE ALONG ITS LAUNCH ANGLE. There used to be
## a post-launch slerp toward straight up over the first 2.5s, on the
## reasoning that it mimicked a real SAM's pitch program. That turned out to
## be self-defeating: ground_flak.gd already launches these across a cone
## (MISSILE_CONE_DEGREES), and the straightening erased that spread before it
## was ever visible, so every missile read as going dead vertical — reported
## as exactly that. A launch angle you cannot see is not a launch angle, so
## the pitch program is gone and the cone is now what actually shows.
##
## Orientation follows missile.gd's own convention: the spawner
## (ground_flak.gd) sets the full global_transform — position AND facing —
## BEFORE add_child(), and _ready() below derives the initial direction
## from that basis, the same "spawner sets the transform, the missile just
## reads it" pattern already established there.

const TRAIL := preload("res://scenes/MissileTrail.tscn")

@export var speed: float = 260.0
@export var lifetime: float = 6.0

## Trail width multiplier, overriding RibbonTrail's own default before
## add_child(). Now WIDER than the player's own missile rather than narrower:
## the body is a 42m ballistic missile (10x the original 4.2m SAM), and a thin
## trail behind something that size reads as wrong. It also has to be legible
## from across the city, which is the whole point of the effect.
##
## Up to MAX_MISSILES (5) are in the air at once, so this is the biggest
## concurrent multiplier on trail cost — but a ribbon is several times cheaper
## than the particle system it replaced, which is what makes going wider
## affordable at all. Exported so it can come straight back down if five fat
## plumes over the city read as too much in the headset.
@export var trail_width_scale: float = 1.8

var _direction: Vector3 = Vector3.UP
var _age: float = 0.0


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_direction = -global_transform.basis.z
	_spawn_trail()


func _physics_process(delta: float) -> void:
	_age += delta
	# Straight along the launch angle — see the header for why the old
	# straightening slerp toward vertical was removed.
	global_position += _direction * speed * delta

	# up_ref is unconditionally FORWARD, not a conditional UP/FORWARD switch
	# — _direction here always stays within a modest cone of vertical (see
	# ground_flak.gd's launch cone and the straightening slerp above), so
	# FORWARD can never be colinear with it. See ground_flak.gd's matching
	# comment for why the conditional version (borrowed initially from
	# faction_battle.gd, where headings can point anywhere) doesn't fit a
	# missile that only ever flies roughly upward.
	global_transform.basis = Basis.looking_at(_direction, Vector3.FORWARD)


## The trail lives at scene level and merely follows this missile — same
## reasoning as missile.gd's real combat missile (world-space particles, so
## the smoke doesn't vanish the instant this one is freed).
func _spawn_trail() -> void:
	var trail := TRAIL.instantiate()
	trail.follow = self
	# Assigned BEFORE add_child(), per this project's standing rule that
	# add_child() runs _ready() immediately — see missile.gd / this file's
	# own header for the bug that established it.
	trail.width_scale = trail_width_scale
	get_tree().current_scene.add_child(trail)
	trail.global_position = global_position
