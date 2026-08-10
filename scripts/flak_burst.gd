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
##
## FILLRATE NOTE. Because these deliberately accumulate (up to
## ground_flak.gd's cap) and last ~20s, their alpha-blend cost is paid
## concurrently by every burst in the sky, and it scales with the SQUARE of
## the puff's on-screen size. The smoke quad started at 30m with a 3-6x
## scale — a 135m puff, so ten concurrent bursts covered ~28x the whole
## screen in alpha blending when the player was flying through the flak
## field. It is now a 14m quad at the same 3-6x scale (a ~63m puff, still
## generous next to a real flak burst's ~20-30m), which is ~4.6x cheaper
## while keeping the accumulate-into-a-fog behaviour that was the point of
## the request. See missile_trail.gd's FILLRATE BUDGET note for the full
## reasoning on why particle SIZE is the expensive dial here, not count.

const LIGHT_FADE_TIME := 0.4

@export var lifetime: float = 20.0

@onready var _light: OmniLight3D = $Light
var _light_energy: float = 0.0


func _ready() -> void:
	get_tree().create_timer(lifetime).timeout.connect(queue_free)
	_light_energy = _light.light_energy


func _process(delta: float) -> void:
	if _light.light_energy <= 0.0:
		# Hide it outright rather than leaving a zero-energy light in the
		# scene: a visible OmniLight3D is still binned into the renderer's
		# light clusters every frame whether or not it contributes anything,
		# and these nodes outlive their flash by most of a 20s lifetime.
		# Same thing ship_explosion.gd already does with its fireball light.
		_light.visible = false
		set_process(false)
		return
	_light.light_energy = move_toward(_light.light_energy, 0.0, (_light_energy / LIGHT_FADE_TIME) * delta)
