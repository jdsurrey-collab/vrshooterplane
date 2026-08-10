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
##
## FILLRATE BUDGET — read this before raising `amount` or the quad size.
## Smoke is large alpha-blended quads, and transparent overdraw is the single
## most expensive thing on a VR renderer: every covered pixel is shaded again,
## once per eye. The cost of this emitter is `amount * (quad_size * scale)^2`
## in screen area — LINEAR in particle count but QUADRATIC in particle size.
##
## An earlier version ran 280 particles of 16m quads at scale 3.0-7.5 (an
## 84m average puff). Measured against a 2064x2208-per-eye target at 90Hz,
## a single trail of that size viewed from 200m covered **14.7x the entire
## screen** in alpha blending per eye — roughly fifteen times the whole
## frame's fillrate budget, for one missile, before anything else in the
## scene drew at all. With flak SAMs able to put several trails in the air
## at once that was comfortably the most expensive object in the game.
##
## Now 100 particles of 11m quads at scale 2.5-6.0 (a ~47m puff): ~8.8x
## cheaper. The trail stays continuous because continuity comes from
## particle SPACING against puff width, not from raw count — at 400 m/s over
## a 4.5s lifetime the trail is ~1800m long, so 100 particles sit ~18m apart
## while each is ~47m across, still a 2.6x overlap along its whole length.
## The old 280 gave a 13x overlap: entirely invisible extra saturation, paid
## for at full price every frame.

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
