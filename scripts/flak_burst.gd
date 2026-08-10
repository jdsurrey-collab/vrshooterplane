extends Node3D

## A single WWII-style flak burst — the "pop" of an anti-aircraft shell
## detonating at altitude, left behind as a dark, PERSISTENT smoke puff
## rather than a quick self-cleaning effect like this project's other
## impact effects (crash craters, laser impacts, hit sparks). Direct
## request: "flak explosion... mortar shells that shoot above the cloud
## line and explode into... a persistent fog of dark cloud just like World
## War Two flak did." Purely cosmetic — spawned by ground_flak.gd, no
## collision, no damage, budgeted there (`max_concurrent_bursts`) the same
## way every other spectacle effect in this project is.
##
## The FLASH is brief (a quick bright particle pop plus a light that dims
## out over LIGHT_FADE_TIME, not an instant cutoff — same convention
## flare.gd's own light already uses), but the SMOKE genuinely lingers for
## most of `lifetime` — that's the entire point here, unlike every other
## effect in this project, which is deliberately short-lived to avoid
## piling up.

const LIGHT_FADE_TIME := 0.4

@export var lifetime: float = 20.0

@onready var _light: OmniLight3D = $Light
var _light_energy: float = 0.0


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_light_energy = _light.light_energy


func _process(delta: float) -> void:
	if _light.light_energy <= 0.0:
		set_process(false)
		return
	_light.light_energy = move_toward(_light.light_energy, 0.0, (_light_energy / LIGHT_FADE_TIME) * delta)
