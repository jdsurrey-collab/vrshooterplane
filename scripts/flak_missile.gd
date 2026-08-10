extends Node3D

## Purely cosmetic "SAM" launch — part of ground_flak.gd's warzone-ambience
## system (see that script's header). Reuses missile.gd's visual language
## (the same body/exhaust mesh style, the same MissileTrail smoke) but
## carries NONE of its homing/damage/flare logic: no target, no damage, no
## collision check against anything. It exists purely to be seen — flies
## in a roughly-vertical line with a brief post-launch straightening arc
## (mimicking a real SAM's pitch program, since there's no target to guide
## toward), then self-destructs after `lifetime`.
##
## Orientation follows missile.gd's own convention: the spawner
## (ground_flak.gd) sets the full global_transform — position AND facing —
## BEFORE add_child(), and _ready() below derives the initial direction
## from that basis, the same "spawner sets the transform, the missile just
## reads it" pattern already established there.

const TRAIL := preload("res://scenes/MissileTrail.tscn")

@export var speed: float = 260.0
@export var lifetime: float = 6.0

## Particle count for this missile's trail, overriding MissileTrail.tscn's
## own default before add_child(). Up to MAX_MISSILES (5) of these are in
## the air at once, so they are the biggest concurrent multiplier on the
## single most fillrate-expensive effect in the game (see missile_trail.gd's
## FILLRATE BUDGET note). A cosmetic background launch several kilometres
## away over the city does not need the same smoke density as the player's
## own weapon fired from the cockpit, so it runs at roughly half — which
## bounds the flak system's whole contribution rather than letting five
## full-price trails stack.
@export var trail_particle_amount: int = 45

var _direction: Vector3 = Vector3.UP
var _age: float = 0.0


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_direction = -global_transform.basis.z
	_spawn_trail()


func _physics_process(delta: float) -> void:
	_age += delta

	# A real SAM pitches over from its launch angle toward vertical in the
	# first couple of seconds, then holds straight — approximated with a
	# slerp toward straight up rather than any real guidance, since this
	# missile has no target to guide toward.
	if _age < 2.5:
		_direction = _direction.slerp(Vector3.UP, clampf(delta * 1.5, 0.0, 1.0)).normalized()

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
	trail.amount = trail_particle_amount
	get_tree().current_scene.add_child(trail)
	trail.global_position = global_position
