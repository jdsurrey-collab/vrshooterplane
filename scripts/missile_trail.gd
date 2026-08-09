extends GPUParticles3D

## Thick smoke trail for a missile in flight — the thing that actually lets
## you see and track a missile you just fired. At 400 m/s the missile body
## itself is off-screen almost immediately; the trail is what stays.
##
## This is deliberately NOT a child of the missile. Two reasons:
##
## 1. The particles are emitted in WORLD space (`local_coords = false`), so
##    they stay where they were laid down instead of being dragged along
##    with the emitter — which is what makes it a trail rather than a puff
##    stuck to the nose.
## 2. A missile queue_free()s the instant it hits something, and freeing the
##    emitter would take the whole existing trail with it, popping a
##    kilometre of smoke out of the sky in one frame. Living at scene level
##    and merely *following* the missile means that when the missile dies
##    the trail just stops emitting and dissipates naturally.
##
## Set `follow` to the missile immediately after instantiating.

## Must comfortably exceed the emitter's own `lifetime` so the last puff
## finishes its animation before the node is removed.
const LINGER := 6.0

var follow: Node3D

var _released: bool = false


func _process(_delta: float) -> void:
	if is_instance_valid(follow):
		global_position = follow.global_position
		return
	if _released:
		return
	# The missile is gone — stop laying down new smoke and let what's
	# already in the air finish on its own.
	_released = true
	emitting = false
	get_tree().create_timer(LINGER).timeout.connect(queue_free)
