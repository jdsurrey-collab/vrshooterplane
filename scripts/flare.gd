extends Node3D

## Countermeasure flare (see missile.gd / faction_battle.gd's
## try_deploy_alien_flare() for how it's triggered). Two pellets eject from
## the single deploy point and fall/diverge under gravity while burning —
## converged at the source, spreading apart below/behind it as they fall,
## tracing an upside-down "Y" — the same shape real flare pairs make
## falling away from an aircraft. Each pellet is a bright OmniLight3D +
## a hot core sprite + a trailing smoke column (reusing
## smoke_flipbook.png, same as the rest of this project's smoke). Burns
## for LIFETIME (10s, real flare burn time), then self-cleans.

const LIFETIME := 10.0
const GRAVITY := 800.0  # matches flight_controller.gd's scaled gravity / falling_debris.gd's convention
const EJECT_SPEED := 25.0
const LIGHT_FADE_START := 8.0  # start dimming 2s before burnout, not an instant cutoff

var _pellets: Array = []
var _velocities: Array = []
var _lights: Array = []
var _light_base_energy: Array = []
var _age: float = 0.0


func _ready() -> void:
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)

	var left: Node3D = get_node_or_null("PelletLeft")
	var right: Node3D = get_node_or_null("PelletRight")
	_pellets = [left, right]

	# Diverge down/back and to either side — the two branches of the
	# upside-down Y, ejected from the same point at the top.
	var base_dir := Vector3(0.0, -0.6, 1.0).normalized()
	_velocities = [
		(base_dir + Vector3(-0.6, 0.0, 0.0)).normalized() * EJECT_SPEED,
		(base_dir + Vector3(0.6, 0.0, 0.0)).normalized() * EJECT_SPEED,
	]

	for pellet in _pellets:
		var light: OmniLight3D = pellet.get_node_or_null("Light") if pellet else null
		_lights.append(light)
		_light_base_energy.append(light.light_energy if light else 0.0)


func _physics_process(delta: float) -> void:
	_age += delta

	for i in _pellets.size():
		var pellet: Node3D = _pellets[i]
		if not pellet:
			continue
		var vel: Vector3 = _velocities[i]
		vel.y -= GRAVITY * delta
		_velocities[i] = vel
		pellet.global_position += vel * delta

	if _age > LIGHT_FADE_START:
		var f := clampf(1.0 - (_age - LIGHT_FADE_START) / (LIFETIME - LIGHT_FADE_START), 0.0, 1.0)
		for i in _lights.size():
			var light: OmniLight3D = _lights[i]
			if light:
				light.light_energy = (_light_base_energy[i] as float) * f
