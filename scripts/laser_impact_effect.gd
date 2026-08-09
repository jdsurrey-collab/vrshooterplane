extends Node3D

## Small laser-hit marker: a brief bright flash, a small scorch crater, and
## a puff of smoke that dissipates on its own.
##
## Deliberately NOT permanent like the ship-crash CrashEffect — guns fire
## every ~0.12s while held, so a permanent effect per hit would pile up
## hundreds of craters/smoke columns in seconds of sustained fire against a
## building. This self-destructs once its (one-shot) particles finish.

const LIFETIME := 6.0


func _ready() -> void:
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)
